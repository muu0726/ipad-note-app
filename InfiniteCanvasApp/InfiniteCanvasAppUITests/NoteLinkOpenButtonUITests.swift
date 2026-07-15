import XCTest

/// ノートリンクカードの「開く」ボタンは、選択ツールでなくても(ペン等の描画モードでも)
/// タップでリンク先へジャンプできることを検証する。
final class NoteLinkOpenButtonUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testOpenButtonJumpsInPenMode() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launch()

        let targetName = "TGT\(Int.random(in: 10000...99999))"
        createNote(app, named: targetName)
        createNote(app, named: nil)

        // リンクカードを挿入(挿入直後は選択モード)
        app.buttons["toolbar-insert-menu"].tap()
        let linkItem = app.buttons["ノートリンク"]
        XCTAssertTrue(linkItem.waitForExistence(timeout: 3), "挿入メニューにノートリンクが無い")
        linkItem.tap()
        let pick = app.buttons["notelink-pick-\(targetName)"]
        XCTAssertTrue(pick.waitForExistence(timeout: 5), "リンク先ピッカーに対象ノートが出ない")
        pick.tap()
        XCTAssertTrue(app.staticTexts[targetName].firstMatch.waitForExistence(timeout: 5),
                      "リンクカードにタイトルが出ない")

        // 描画モード(ペン)へ切り替える。この状態では従来ダブルタップでは飛べない。
        app.buttons["toolbar-tool-pen"].tap()

        // 「開く」ボタンはペンモードでもタップでき、リンク先へジャンプする
        let openButton = app.buttons["notelink-open"].firstMatch
        XCTAssertTrue(openButton.waitForExistence(timeout: 5), "リンクカードに「開く」ボタンが無い")
        attachScreenshot(app, name: "1-open-button-in-pen-mode")
        openButton.tap()
        XCTAssertTrue(app.navigationBars[targetName].waitForExistence(timeout: 5),
                      "ペンモードで「開く」ボタンからリンク先へジャンプできない")
        attachScreenshot(app, name: "2-jumped-via-open-button")
    }

    // MARK: - ヘルパー

    @MainActor
    private func createNote(_ app: XCUIApplication, named name: String?) {
        let backToLibrary = app.buttons["書類"]
        if backToLibrary.waitForExistence(timeout: 3) { backToLibrary.tap() }
        let addTile = app.buttons["add-note-tile"]
        if addTile.waitForExistence(timeout: 5) { addTile.tap() }
        else { app.buttons["新規ノート"].firstMatch.tap() }

        if let name {
            let field = app.textFields["名前"]
            if field.waitForExistence(timeout: 3) {
                field.tap()
                field.typeText(name)
            }
        }
        app.buttons["作成"].tap()
        _ = backToLibrary.waitForExistence(timeout: 5)
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
