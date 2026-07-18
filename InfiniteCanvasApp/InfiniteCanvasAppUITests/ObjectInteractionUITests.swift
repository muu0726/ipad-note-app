import XCTest

/// スクロールビュー内部に置いたオブジェクトへの「移動」「長押し削除」が
/// 単独で確実に動くことを検証する(連鎖に依存しない堅牢なテスト)。
final class ObjectInteractionUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testDragMovesObject() throws {
        let app = launchAndOpenNote()
        let marker = insertText(app)
        let before = marker.frame

        // 新モデル(選択してから移動): まず指タップで選択し、その上でドラッグして動かす
        marker.tap()
        let start = marker.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.2, thenDragTo: start.withOffset(CGVector(dx: 220, dy: 150)))

        let moved = expectation(description: "moved")
        pollUntil({ hypot(marker.frame.minX - before.minX, marker.frame.minY - before.minY) > 60 },
                  timeout: 6, fulfill: moved)
        wait(for: [moved], timeout: 6.5)
    }

    @MainActor
    func testLongPressDeletesObject() throws {
        let app = launchAndOpenNote()
        let marker = insertText(app)

        marker.press(forDuration: 1.1)
        var deleteItem = app.menuItems["削除"]
        if !deleteItem.waitForExistence(timeout: 3) { deleteItem = app.buttons["削除"] }
        XCTAssertTrue(deleteItem.waitForExistence(timeout: 3), "長押しで削除メニューが出ない")
        deleteItem.tap()

        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: marker)
        waitForExpectations(timeout: 5)
    }

    // MARK: - ヘルパー

    @MainActor
    private func launchAndOpenNote() -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment["RESET_STORE"] = "1"  // テスト毎にDBを初期化(蓄積防止)
        app.launch()
        let backToLibrary = app.buttons["toolbar-tool-pen"]
        if !backToLibrary.waitForExistence(timeout: 3) {
            let anyNote = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH 'grid-note-'")).firstMatch
            if anyNote.waitForExistence(timeout: 5) { anyNote.tap() }
            else {
                (app.buttons["add-note-tile"].exists ? app.buttons["add-note-tile"] : app.buttons["新規ノート"].firstMatch).tap()
                app.buttons["作成"].tap()
            }
            _ = backToLibrary.waitForExistence(timeout: 5)
        }
        return app
    }

    /// テキストオブジェクトを挿入し、確定して返す
    @MainActor
    private func insertText(_ app: XCUIApplication) -> XCUIElement {
        let text = "\(Int.random(in: 10_000_000...99_999_999))"
        app.buttons["toolbar-tool-text"].tap()
        // テキストは配置ツール: キャンバス中央をタップして配置する
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        // 配置直後は選択・編集状態(実機ではキーボードも表示)。シミュレータでは
        // プログラム的フォーカスにソフトキーボードが追従しないため、配置したテキストを
        // 一度タップして編集(キーボード)を確実に開始する。
        let placed = app.textViews.firstMatch
        XCTAssertTrue(placed.waitForExistence(timeout: 5), "テキストが配置されない")
        placed.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "編集が始まらない")
        app.typeText(text)
        // 編集終了(キーボードに隠れない右上をタップ)
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.28)).tap()
        _ = app.keyboards.firstMatch.waitForNonExistence(timeout: 5)
        let marker = app.textViews.containing(NSPredicate(format: "value CONTAINS %@", text)).firstMatch
        XCTAssertTrue(marker.waitForExistence(timeout: 5), "テキストオブジェクトが見つからない")
        return marker
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
