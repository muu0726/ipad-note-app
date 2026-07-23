import XCTest

/// フリーボード改修 Phase2-b step1: 複数オブジェクト選択の統一枠(SelectionOverlayView)+
/// 8方向リサイズハンドルの検証。2個のテキストをグループ化して選択すると統一枠が出て、
/// 右下ハンドルのドラッグで選択全体が比例拡大し、Undo1回で両方が元へ戻ることを確認する。
final class UnifiedSelectionUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testUnifiedResizeScalesWholeSelection() throws {
        let app = launchAndOpenNote()

        // 離れた2箇所にテキストを配置
        let a = insertText(app, at: CGVector(dx: 0.38, dy: 0.42))
        let b = insertText(app, at: CGVector(dx: 0.62, dy: 0.58))
        let aBefore = a.frame
        let bBefore = b.frame

        // 複数選択 → グループ化(選択を安定させるため)
        a.tap()
        b.press(forDuration: 1.1)
        tapMenuItem(app, "グループ化")

        // いったん解除して、グループをタップし直すとメニュー無しで統一枠が出る
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.2)).tap()
        a.tap()

        let handle = app.descendants(matching: .any)
            .matching(identifier: "selection-resize-handle-bottomRight").firstMatch
        XCTAssertTrue(handle.waitForExistence(timeout: 5), "統一枠の右下リサイズハンドルが出ない")

        // 右下ハンドルを外側(右下)へドラッグ → 選択全体が拡大
        let from = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        from.press(forDuration: 0.1, thenDragTo: from.withOffset(CGVector(dx: 180, dy: 140)))

        let grew = expectation(description: "grew")
        pollUntil({ a.frame.width > aBefore.width + 8 && b.frame.width > bBefore.width + 8 },
                  timeout: 6, fulfill: grew)
        wait(for: [grew], timeout: 6.5)

        // Undo 1回で両方のサイズが元へ戻る(同一イベント=1グループ)
        app.buttons["toolbar-undo"].tap()
        let reverted = expectation(description: "reverted")
        pollUntil({ abs(a.frame.width - aBefore.width) < 8 && abs(b.frame.width - bBefore.width) < 8 },
                  timeout: 6, fulfill: reverted)
        wait(for: [reverted], timeout: 6.5)
    }

    // MARK: - ヘルパー

    @MainActor
    private func launchAndOpenNote() -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment["RESET_STORE"] = "1"
        app.launch()
        let inCanvas = app.buttons["toolbar-tool-pen"]
        if !inCanvas.waitForExistence(timeout: 3) {
            let anyNote = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH 'grid-note-'")).firstMatch
            if anyNote.waitForExistence(timeout: 5) { anyNote.tap() }
            else {
                (app.buttons["add-note-tile"].exists ? app.buttons["add-note-tile"] : app.buttons["新規ノート"].firstMatch).tap()
                app.buttons["作成"].tap()
            }
            _ = inCanvas.waitForExistence(timeout: 5)
        }
        return app
    }

    /// 指定位置へテキストオブジェクトを配置し、数字を入力して確定して返す。
    /// 複数配置しても取り違えないよう、配置直後の「空の」テキストビューをタップして編集開始し、
    /// 入力値で同定する(シミュレータは配置autofocusでキーボードが出ないため明示タップが必要)。
    @MainActor
    private func insertText(_ app: XCUIApplication, at offset: CGVector) -> XCUIElement {
        let text = "\(Int.random(in: 10_000_000...99_999_999))"
        app.buttons["toolbar-tool-text"].tap()
        app.windows.firstMatch.coordinate(withNormalizedOffset: offset).tap()  // 配置 + 選択
        // 既存(入力済み)のテキストと取り違えないよう、値が空の新規テキストビューを掴む
        let placed = app.textViews.matching(NSPredicate(format: "value == %@", "")).firstMatch
        XCTAssertTrue(placed.waitForExistence(timeout: 5), "テキストが配置されない")
        placed.tap()  // 編集開始
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "編集が始まらない")
        app.typeText(text)
        // 編集終了(キーボードに隠れない右上をタップ)+ 選択解除
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.2)).tap()
        _ = app.keyboards.firstMatch.waitForNonExistence(timeout: 5)
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.2)).tap()
        let marker = app.textViews.containing(NSPredicate(format: "value CONTAINS %@", text)).firstMatch
        XCTAssertTrue(marker.waitForExistence(timeout: 5), "テキストオブジェクトが見つからない")
        return marker
    }

    @MainActor
    private func tapMenuItem(_ app: XCUIApplication, _ title: String) {
        var item = app.menuItems[title]
        if !item.waitForExistence(timeout: 3) { item = app.buttons[title] }
        XCTAssertTrue(item.waitForExistence(timeout: 3), "メニュー項目『\(title)』が出ない")
        item.tap()
    }

    @MainActor
    private func pollUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval, fulfill exp: XCTestExpectation) {
        let deadline = Date().addingTimeInterval(timeout)
        func step() {
            if condition() { exp.fulfill() }
            else if Date() < deadline { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { step() } }
        }
        step()
    }
}
