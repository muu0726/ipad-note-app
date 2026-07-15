import XCTest

/// 背景テンプレートに「横線」を追加した検証。
/// 背景メニューから「横線」を選べ、選択後もキャンバスが応答する(クラッシュ・ハングしない)。
final class BackgroundLinesUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSelectLinesBackground() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment["ALLOW_FINGER_DRAWING"] = "1"
        app.launch()

        // 空の新規ノートを作成して開く
        let backToLibrary = app.buttons["書類"]
        if backToLibrary.waitForExistence(timeout: 3) { backToLibrary.tap() }
        let addTile = app.buttons["add-note-tile"]
        if addTile.waitForExistence(timeout: 5) { addTile.tap() }
        else { app.buttons["新規ノート"].firstMatch.tap() }
        app.buttons["作成"].tap()
        _ = backToLibrary.waitForExistence(timeout: 5)

        // 背景メニュー →「横線」を選ぶ
        let bgMenu = app.buttons["背景"]
        XCTAssertTrue(bgMenu.waitForExistence(timeout: 5), "背景メニューが無い")
        bgMenu.tap()
        let linesOption = app.buttons["横線"]
        XCTAssertTrue(linesOption.waitForExistence(timeout: 3), "背景メニューに『横線』が無い")
        linesOption.tap()
        attachScreenshot(app, name: "1-lines-background")

        // 横線背景でも描画系が生きている(選択ツールでなくペンで一筆)
        app.buttons["toolbar-tool-pen"].tap()
        let canvas = app.windows.firstMatch
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.05,
                   thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.55)))
        XCTAssertTrue(app.buttons["toolbar-undo"].waitForExistence(timeout: 3),
                      "横線背景でツールバーが応答しない")
        attachScreenshot(app, name: "2-drawn-on-lines")
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
