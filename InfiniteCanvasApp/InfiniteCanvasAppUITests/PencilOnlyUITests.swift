import XCTest

/// Pencil Only の検証: 指でのドラッグでは描画されない(スクロール扱い)こと。
/// XCUITest は Apple Pencil を模倣できないため「指では描けない」ことを確認する。
/// (ALLOW_FINGER_DRAWING フラグは付けない = 製品既定の pencilOnly)
final class PencilOnlyUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testFingerDoesNotDraw() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launch()

        // 空の新規ノートを作成して開く(Undo は無効な状態から始まる)
        let backToLibrary = app.buttons["書類"]
        if backToLibrary.waitForExistence(timeout: 3) { backToLibrary.tap() }
        let addTile = app.buttons["add-note-tile"]
        if addTile.waitForExistence(timeout: 5) { addTile.tap() }
        else { app.buttons["新規ノート"].firstMatch.tap() }
        app.buttons["作成"].tap()
        _ = backToLibrary.waitForExistence(timeout: 5)

        let undoButton = app.buttons["toolbar-undo"]
        XCTAssertTrue(undoButton.waitForExistence(timeout: 5), "ツールバーが出ない")
        XCTAssertFalse(undoButton.isEnabled, "新規ノートなのに最初から Undo が有効")

        // ペンに切り替えて、指でキャンバスをドラッグ(描画を試みる)
        app.buttons["toolbar-tool-pen"].tap()
        let canvas = app.windows.firstMatch
        let start = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.45))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 160, dy: 90)))

        // pencilOnly のため指では描かれない → ストロークが増えず Undo は無効のまま
        settle(1.0)
        XCTAssertFalse(undoButton.isEnabled,
                       "指で描けてしまっている(pencilOnly が効いていない)")
        attachScreenshot(app, name: "1-finger-did-not-draw")
    }

    @MainActor
    private func settle(_ seconds: TimeInterval) {
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "settle")], timeout: seconds)
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
