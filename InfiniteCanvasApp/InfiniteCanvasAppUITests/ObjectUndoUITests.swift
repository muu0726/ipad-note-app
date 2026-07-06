import XCTest

/// キャンバスオブジェクト(テキスト等)の追加・編集・移動・削除が
/// ツールバーの「元に戻す / やり直し」で往復できることのエンドツーエンド検証。
/// 既存データ(ノートが1つ以上ある状態)を前提とする。
final class ObjectUndoUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testTextObjectUndoRedoLifecycle() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launch()

        try openAnyNote(app)

        let undoButton = app.buttons["toolbar-undo"]
        let redoButton = app.buttons["toolbar-redo"]
        XCTAssertTrue(undoButton.waitForExistence(timeout: 5), "ツールバーが表示されていない")

        // ① テキストオブジェクトを挿入(挿入直後に編集が始まる)
        // 日本語IMEの変換(未確定文字)を避けるため数字のみのマーカーを使う
        let marker = "\(Int.random(in: 10_000_000...99_999_999))"
        app.buttons["toolbar-insert-menu"].tap()
        let insertText = app.buttons["テキスト"]
        XCTAssertTrue(insertText.waitForExistence(timeout: 3), "挿入メニューが開かない")
        insertText.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5),
                      "テキスト編集が自動開始されない")
        app.typeText(marker)

        // 編集終了: キーボードに隠れない位置(右上寄りの空きスペース)をタップして選択解除
        let canvasArea = app.windows.firstMatch
        canvasArea.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.3)).tap()
        expectation(for: NSPredicate(format: "exists == false"),
                    evaluatedWith: app.keyboards.firstMatch)
        waitForExpectations(timeout: 5)

        let markerView = app.textViews
            .containing(NSPredicate(format: "value CONTAINS %@", marker)).firstMatch
        XCTAssertTrue(markerView.waitForExistence(timeout: 5), "挿入したテキストが表示されない")
        attachScreenshot(app, name: "1-テキスト挿入後")

        // ② Undo: テキスト編集を取り消し → 内容が空へ戻る
        XCTAssertTrue(undoButton.isEnabled, "オブジェクト操作後に Undo が有効になっていない")
        undoButton.tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: markerView)
        waitForExpectations(timeout: 5)

        // ③ Undo: 挿入自体を取り消し → オブジェクトが消える
        undoButton.tap()
        attachScreenshot(app, name: "2-Undo2回で挿入取り消し")

        // ④ Redo x2: 挿入 → テキスト内容が復元される
        XCTAssertTrue(redoButton.waitForExistence(timeout: 3) && redoButton.isEnabled,
                      "Undo 後に Redo が有効になっていない")
        redoButton.tap()
        redoButton.tap()
        XCTAssertTrue(markerView.waitForExistence(timeout: 5), "Redo でテキストが復元されない")
        attachScreenshot(app, name: "3-Redo2回で復元")

        // ⑤ 移動 → Undo で元の位置に戻る
        let frameBeforeMove = markerView.frame
        let start = markerView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let destination = start.withOffset(CGVector(dx: 180, dy: 120))
        start.press(forDuration: 0.1, thenDragTo: destination)

        let moved = expectation(description: "オブジェクトが移動した")
        wait(until: { abs(markerView.frame.minX - frameBeforeMove.minX) > 40 },
             timeout: 5, fulfill: moved)
        waitForExpectations(timeout: 5)

        // 移動がアンドゥスタックへ登録される(0.8秒デバウンス)のを待ってから Undo
        settle(1.0)
        undoButton.tap()
        let movedBack = expectation(description: "Undo で元の位置へ戻った")
        wait(until: {
            abs(markerView.frame.minX - frameBeforeMove.minX) < 10
                && abs(markerView.frame.minY - frameBeforeMove.minY) < 10
        }, timeout: 5, fulfill: movedBack)
        waitForExpectations(timeout: 5)

        // ⑥ 長押し削除 → Undo で復元される
        // (UIEditMenu のアイテムは menuItems として公開される)
        markerView.press(forDuration: 1.0)
        var deleteAction = app.menuItems["削除"]
        if !deleteAction.waitForExistence(timeout: 3) {
            deleteAction = app.buttons["削除"]
        }
        XCTAssertTrue(deleteAction.waitForExistence(timeout: 3), "削除メニューが表示されない")
        deleteAction.tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: markerView)
        waitForExpectations(timeout: 5)

        undoButton.tap()
        XCTAssertTrue(markerView.waitForExistence(timeout: 5), "Undo で削除が復元されない")

        // 後始末: もう一度削除を Redo して残さない
        redoButton.tap()
    }

    /// 手書きストロークとオブジェクト操作が同じ履歴に混在し、
    /// 新しい操作から順に(互いを壊さず)戻ることの検証。
    @MainActor
    func testDrawingAndObjectUndoInterleave() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launch()

        try openAnyNote(app)

        let undoButton = app.buttons["toolbar-undo"]
        XCTAssertTrue(undoButton.waitForExistence(timeout: 5), "ツールバーが表示されていない")

        // ① テキストオブジェクトを挿入して確定
        let marker = "\(Int.random(in: 10_000_000...99_999_999))"
        app.buttons["toolbar-insert-menu"].tap()
        let insertText = app.buttons["テキスト"]
        XCTAssertTrue(insertText.waitForExistence(timeout: 3), "挿入メニューが開かない")
        insertText.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5),
                      "テキスト編集が自動開始されない")
        app.typeText(marker)
        let canvasArea = app.windows.firstMatch
        canvasArea.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.3)).tap()
        expectation(for: NSPredicate(format: "exists == false"),
                    evaluatedWith: app.keyboards.firstMatch)
        waitForExpectations(timeout: 5)

        let markerView = app.textViews
            .containing(NSPredicate(format: "value CONTAINS %@", marker)).firstMatch
        XCTAssertTrue(markerView.waitForExistence(timeout: 5), "挿入したテキストが表示されない")

        // ② ペンに切り替えてストロークを1本描く(オブジェクトの無い場所)
        app.buttons["toolbar-tool-pen"].tap()
        let strokeStart = canvasArea.coordinate(
            withNormalizedOffset: CGVector(dx: 0.75, dy: 0.55))
        strokeStart.press(forDuration: 0.05,
                          thenDragTo: strokeStart.withOffset(CGVector(dx: 120, dy: 60)))

        // ③ Undo 1回目: 直近のストロークだけが消え、テキストは残る
        XCTAssertTrue(undoButton.isEnabled, "描画後に Undo が有効になっていない")
        undoButton.tap()
        XCTAssertTrue(markerView.waitForExistence(timeout: 5),
                      "ストロークの Undo でオブジェクトが巻き込まれた")

        // ④ Undo 2回目: 今度はテキスト編集が戻る(混在履歴が新しい順に処理される)
        undoButton.tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: markerView)
        waitForExpectations(timeout: 5)

        // 後始末: 挿入も取り消してキャンバスを空へ戻す
        undoButton.tap()
    }

    // MARK: - ヘルパー

    /// 一定時間だけ画面更新を待つ(自動保存デバウンス・アンドゥ登録の確定待ち)。
    /// テストケースに登録されない独立した expectation を使う
    /// (self.expectation(...) は後続の waitForExpectations が再度待とうとして例外になる)。
    @MainActor
    private func settle(_ seconds: TimeInterval) {
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "settle")], timeout: seconds)
    }

    /// 検証証跡としてスクリーンショットを残す(成功時も保持)
    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// タブ復元でキャンバスが開いていればそのまま、ライブラリなら最初のノートを開く。
    /// ノートが1つもなければ新規作成する(作成後そのままタブで開かれる)。
    @MainActor
    private func openAnyNote(_ app: XCUIApplication) throws {
        let backToLibrary = app.buttons["書類"]
        if backToLibrary.waitForExistence(timeout: 3) {
            return  // すでにキャンバスが開いている
        }
        let anyNote = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'grid-note-'")).firstMatch
        if anyNote.waitForExistence(timeout: 5) {
            anyNote.tap()
        } else {
            // 空のライブラリ: 空状態の「新規ノート」ボタン → 作成シート → 作成
            let createButton = app.buttons["新規ノート"]
            XCTAssertTrue(createButton.waitForExistence(timeout: 5),
                          "ライブラリの新規ノートボタンが見つからない")
            createButton.tap()
            let confirmCreate = app.buttons["作成"]
            XCTAssertTrue(confirmCreate.waitForExistence(timeout: 5), "作成シートが開かない")
            confirmCreate.tap()
        }
        XCTAssertTrue(backToLibrary.waitForExistence(timeout: 5), "ノートが開かない")
    }

    /// 条件が真になるまでポーリングして expectation を満たす
    @MainActor
    private func wait(
        until condition: @escaping () -> Bool,
        timeout: TimeInterval,
        fulfill expectation: XCTestExpectation
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        func poll() {
            if condition() {
                expectation.fulfill()
            } else if Date() < deadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { poll() }
            }
        }
        poll()
    }
}
