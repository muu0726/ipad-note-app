import XCTest

/// 背景テンプレート「横線」の検証。背景は **作成時のダイアログ**(通常ノート選択時)で選ぶ仕様。
/// 横線を選んで作成でき、選択後もキャンバスが応答する(クラッシュ・ハングしない)。
final class BackgroundLinesUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSelectLinesBackground() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()


        app.launchEnvironment["ALLOW_FINGER_DRAWING"] = "1"
        app.launchEnvironment["RESET_STORE"] = "1"  // テスト毎にDBを初期化(蓄積防止)
        app.launch()

        // 作成ダイアログを開く
        let backToLibrary = app.buttons["toolbar-tool-pen"]
        if backToLibrary.waitForExistence(timeout: 3) { app.buttons["canvas-to-library"].tap() }
        let addTile = app.buttons["add-note-tile"]
        if addTile.waitForExistence(timeout: 5) { addTile.tap() }
        else { app.buttons["新規ノート"].firstMatch.tap() }

        // 「通常ノート」を選ぶと背景デザイン Picker が現れる(型不一致回避のため述語で解決)
        element(app, "note-type-paged").tap()
        let lines = element(app, "bg-style-lines")
        XCTAssertTrue(lines.waitForExistence(timeout: 3), "背景デザインに『横線』が無い")
        lines.tap()
        app.buttons["作成"].tap()
        _ = app.buttons["paged-settings-button"].waitForExistence(timeout: 5)
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
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
