import XCTest

/// フリーボード改修 Phase3: コネクタ線(自動追従)の検証。
/// 2オブジェクトを選択→「コネクタで接続」で線が出て、片方を動かすと追従し、
/// 片方を削除すると線も消えることを確認する(指示書2.3-2・受け入れ基準4)。
final class ConnectorUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testConnectorFollowsAndRemovesWithEndpoint() throws {
        let app = launchAndOpenNote()

        let a = placeText(app, at: CGVector(dx: 0.38, dy: 0.40))
        let b = placeText(app, at: CGVector(dx: 0.62, dy: 0.40))

        // 2つを選択 → 長押しメニュー →「コネクタで接続」
        a.tap()
        b.press(forDuration: 1.1)
        tapMenuItem(app, "コネクタで接続")

        let connector = app.descendants(matching: .any)
            .matching(identifier: "canvas-connector").firstMatch
        XCTAssertTrue(connector.waitForExistence(timeout: 5), "コネクタ線が作成されない")
        let frameBefore = connector.frame

        // b を選び直して下へ動かす → コネクタが追従して形が変わる
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.18)).tap()
        b.tap()
        let bc = b.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        bc.press(forDuration: 0.2, thenDragTo: bc.withOffset(CGVector(dx: 0, dy: 240)))

        let moved = expectation(description: "connector followed")
        pollUntil({ connector.exists && connector.frame != frameBefore }, timeout: 6, fulfill: moved)
        wait(for: [moved], timeout: 6.5)

        // b を削除 → コネクタも消える(端点が無くなると描かれない)
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.18)).tap()
        b.press(forDuration: 1.1)
        tapMenuItem(app, "削除")

        let gone = expectation(description: "connector removed")
        pollUntil({ !connector.exists }, timeout: 6, fulfill: gone)
        wait(for: [gone], timeout: 6.5)
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

    @MainActor
    private func placeText(_ app: XCUIApplication, at offset: CGVector) -> XCUIElement {
        let text = "\(Int.random(in: 10_000_000...99_999_999))"
        app.buttons["toolbar-tool-text"].tap()
        app.windows.firstMatch.coordinate(withNormalizedOffset: offset).tap()
        let placed = app.textViews.matching(NSPredicate(format: "value == %@", "")).firstMatch
        XCTAssertTrue(placed.waitForExistence(timeout: 5), "テキストが配置されない")
        placed.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "編集が始まらない")
        app.typeText(text)
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.18)).tap()
        _ = app.keyboards.firstMatch.waitForNonExistence(timeout: 5)
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.18)).tap()
        let marker = app.textViews.containing(NSPredicate(format: "value CONTAINS %@", text)).firstMatch
        XCTAssertTrue(marker.waitForExistence(timeout: 5), "テキストが見つからない")
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
