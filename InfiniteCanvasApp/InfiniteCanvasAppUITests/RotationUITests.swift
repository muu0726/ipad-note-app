import XCTest

/// フリーボード改修: 単一オブジェクトの回転(回転ハンドル)の検証。
/// オブジェクトを単一選択すると上に回転ハンドルが出て、ドラッグで回転し、Undo で戻る。
final class RotationUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testRotateObjectAndUndo() throws {
        let app = launchAndOpenNote()

        let marker = placeText(app, at: CGVector(dx: 0.5, dy: 0.5))
        let frameBefore = marker.frame

        // 単一選択 → 回転ハンドルが出る
        marker.tap()
        let handle = app.descendants(matching: .any)
            .matching(identifier: "object-rotate-handle").firstMatch
        XCTAssertTrue(handle.waitForExistence(timeout: 5), "回転ハンドルが出ない")

        // 回転ハンドルを横へ大きくドラッグ → オブジェクトが回転し、accessibility frame(外接矩形)が変わる
        let hc = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        hc.press(forDuration: 0.1, thenDragTo: hc.withOffset(CGVector(dx: 180, dy: 180)))

        let rotated = expectation(description: "rotated")
        pollUntil({ marker.exists && marker.frame != frameBefore }, timeout: 6, fulfill: rotated)
        wait(for: [rotated], timeout: 6.5)

        // Undo で回転前の外接矩形へ戻る
        app.buttons["toolbar-undo"].tap()
        let reverted = expectation(description: "reverted")
        pollUntil({ marker.exists && abs(marker.frame.width - frameBefore.width) < 6
                    && abs(marker.frame.height - frameBefore.height) < 6 }, timeout: 6, fulfill: reverted)
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
    private func pollUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval, fulfill exp: XCTestExpectation) {
        let deadline = Date().addingTimeInterval(timeout)
        func step() {
            if condition() { exp.fulfill() }
            else if Date() < deadline { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { step() } }
        }
        step()
    }
}
