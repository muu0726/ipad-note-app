import XCTest

/// フリーボード改修 Phase3: 全体表示(Zoom to Fit)の検証。
/// 左上ズームバッジのメニュー →「全体表示」で、コンテンツに合わせてズームが変わる。
final class ZoomToFitUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testZoomToFitChangesZoom() throws {
        let app = launchAndOpenNote()

        // テキストを1つ配置(小さいコンテンツ → 全体表示で拡大される)
        placeText(app, at: CGVector(dx: 0.5, dy: 0.5))
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.2)).tap()

        let start = zoomPercent(app)
        XCTAssertEqual(start, 100, "初期ズームが100%でない: \(start)%")

        // ズームバッジ → 全体表示
        app.descendants(matching: .any).matching(identifier: "canvas-zoom-percent").firstMatch.tap()
        let fit = app.descendants(matching: .any).matching(identifier: "canvas-zoom-fit").firstMatch
        XCTAssertTrue(fit.waitForExistence(timeout: 3), "全体表示メニューが出ない")
        fit.tap()

        // 単一の小さなオブジェクトは画面いっぱいに拡大される(100%から有意に変化)
        let changed = expectation(description: "zoom changed")
        pollUntil({ self.zoomPercent(app) >= 200 }, timeout: 6, fulfill: changed)
        wait(for: [changed], timeout: 6.5)
    }

    // MARK: - ヘルパー

    @MainActor
    private func zoomPercent(_ app: XCUIApplication) -> Int {
        let badge = app.descendants(matching: .any).matching(identifier: "canvas-zoom-percent").firstMatch
        guard badge.waitForExistence(timeout: 3) else { return -1 }
        return Int(badge.label.filter(\.isNumber)) ?? -1
    }

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
    private func placeText(_ app: XCUIApplication, at offset: CGVector) {
        let text = "\(Int.random(in: 10_000_000...99_999_999))"
        app.buttons["toolbar-tool-text"].tap()
        app.windows.firstMatch.coordinate(withNormalizedOffset: offset).tap()
        let placed = app.textViews.matching(NSPredicate(format: "value == %@", "")).firstMatch
        XCTAssertTrue(placed.waitForExistence(timeout: 5), "テキストが配置されない")
        placed.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "編集が始まらない")
        app.typeText(text)
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.2)).tap()
        _ = app.keyboards.firstMatch.waitForNonExistence(timeout: 5)
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
