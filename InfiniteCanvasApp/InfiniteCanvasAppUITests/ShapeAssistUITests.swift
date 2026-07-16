import XCTest

/// 図形認識アシストの統合検証。
/// - トグルボタンの ON/OFF が反映されること。
/// - アシスト ON で手書き(直線ドラッグ)しても無限再描画ループにならず、
///   直後の UI 操作が即座に応答すること(メインスレッドが生きている)。
final class ShapeAssistUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testToggleAndDrawDoesNotHang() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        // XCUITest は Pencil 入力を模倣できないため、指描画を許可して描画系を検証する
        app.launchEnvironment["ALLOW_FINGER_DRAWING"] = "1"
        app.launch()
        try openAnyNote(app)

        let toggle = app.buttons["toolbar-shape-assist"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "図形アシストのトグルが見つからない")

        // ① 既定は OFF
        XCTAssertFalse(toggle.isSelected, "図形アシストの既定は OFF のはず")
        attachScreenshot(app, name: "1-アシストOFF")

        // ② ON に切り替え → selected になる
        toggle.tap()
        XCTAssertTrue(toggle.waitForSelected(true, timeout: 3), "トグルが ON にならない")

        // ③ ペンで直線ドラッグ(図形置換パイプラインを実際に走らせる)
        let canvas = app.windows.firstMatch
        let start = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.30, dy: 0.45))
        let end = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.62, dy: 0.62))
        start.press(forDuration: 0.05, thenDragTo: end)
        attachScreenshot(app, name: "2-アシストONで直線描画後")

        // ④ 無限ループ検知: 描画直後にトグルを叩き、即応答することを確認。
        //    メインスレッドが再描画で詰まっていれば、この操作はタイムアウトする。
        toggle.tap()
        XCTAssertTrue(toggle.waitForSelected(false, timeout: 3),
                      "描画後の操作に応答しない(無限再描画ループの疑い)")

        // ⑤ もう一度描いても OFF なら通常の手書きとして動作(クラッシュしないこと)
        start.press(forDuration: 0.05, thenDragTo: end)
        XCTAssertTrue(app.buttons["toolbar-shape-assist"].isHittable,
                      "OFF での描画後にツールバーが操作できない")
        attachScreenshot(app, name: "3-アシストOFFで再描画後")
    }

    /// 図形認識アシストで手書きが図形へ置換された後も Undo/Redo が機能することを検証する。
    /// 修正前は `canvasView.drawing` の直接代入で PencilKit の Undo 履歴が壊れ、
    /// 置換後に戻る/やり直しが効かなくなっていた(逆操作を UndoManager へ手動登録して解消)。
    @MainActor
    func testUndoRedoAfterShapeAssist() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        // XCUITest は Pencil 入力を模倣できないため、指描画を許可して描画系を検証する
        app.launchEnvironment["ALLOW_FINGER_DRAWING"] = "1"
        app.launch()
        try openAnyNote(app)

        let toggle = app.buttons["toolbar-shape-assist"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "図形アシストのトグルが見つからない")

        // 図形アシスト ON にして直線を描く(図形置換パイプラインを走らせる)
        if !toggle.isSelected { toggle.tap() }
        XCTAssertTrue(toggle.waitForSelected(true, timeout: 3), "トグルが ON にならない")

        let canvas = app.windows.firstMatch
        let start = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.30, dy: 0.45))
        let end = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.62, dy: 0.62))
        start.press(forDuration: 0.05, thenDragTo: end)
        attachScreenshot(app, name: "1-アシストONで直線描画後")

        // 置換後: 逆操作が UndoManager に登録され、戻るが有効になっているはず
        let undo = app.buttons["toolbar-undo"]
        let redo = app.buttons["toolbar-redo"]
        XCTAssertTrue(undo.waitForEnabled(true, timeout: 5),
                      "図形置換後に Undo が有効にならない(履歴が登録されていない)")

        // 戻る → 図形置換が取り消され、やり直しが有効になる(=可逆であること)
        undo.tap()
        XCTAssertTrue(redo.waitForEnabled(true, timeout: 5),
                      "Undo 後に Redo が有効にならない(逆操作が壊れている)")
        attachScreenshot(app, name: "2-Undo後")

        // やり直し → 図形が復元され、戻るが再び有効になる
        redo.tap()
        XCTAssertTrue(undo.waitForEnabled(true, timeout: 5),
                      "Redo 後に Undo が有効にならない(やり直しが壊れている)")
        attachScreenshot(app, name: "3-Redo後")

        // 一連の操作後もツールバーが即応答する(メインスレッドが生きている)
        XCTAssertTrue(toggle.isHittable, "Undo/Redo 後にツールバーが操作できない")
    }

    // MARK: - ヘルパー

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// キャンバスが開いていればそのまま、なければノートを開く/新規作成する
    @MainActor
    private func openAnyNote(_ app: XCUIApplication) throws {
        let backToLibrary = app.buttons["書類"]
        if backToLibrary.waitForExistence(timeout: 3) { return }

        let anyNote = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'grid-note-'")).firstMatch
        if anyNote.waitForExistence(timeout: 5) {
            anyNote.tap()
        } else {
            let createButton = app.buttons["新規ノート"]
            XCTAssertTrue(createButton.waitForExistence(timeout: 5), "新規ノートボタンが見つからない")
            createButton.tap()
            let confirmCreate = app.buttons["作成"]
            XCTAssertTrue(confirmCreate.waitForExistence(timeout: 5), "作成シートが開かない")
            confirmCreate.tap()
        }
        XCTAssertTrue(backToLibrary.waitForExistence(timeout: 5), "ノートが開かない")
    }
}

private extension XCUIElement {
    /// isSelected が期待値になるまで待つ
    func waitForSelected(_ expected: Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isSelected == expected { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return isSelected == expected
    }

    /// isEnabled が期待値になるまで待つ
    func waitForEnabled(_ expected: Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isEnabled == expected { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return isEnabled == expected
    }
}
