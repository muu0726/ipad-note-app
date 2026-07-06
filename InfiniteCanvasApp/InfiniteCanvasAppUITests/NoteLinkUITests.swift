import XCTest

/// ノートリンク(他ノートへのショートカット)オブジェクトの検証。
/// - 挿入時にリンク先ノートを選べる。
/// - カードにリンク先タイトルが表示される。
/// - ダブルタップでリンク先ノートへジャンプ(タブ切替)する。
final class NoteLinkUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testInsertNoteLinkAndJump() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launch()

        // リンク先ノートを固有名で作成
        let targetName = "TARGET\(Int.random(in: 10000...99999))"
        createNote(app, named: targetName)
        // リンク元ノート(無名)を作成 → こちらが開いた状態になる
        createNote(app, named: nil)

        // 挿入メニュー → ノートリンク → ピッカーでリンク先を選択
        app.buttons["toolbar-insert-menu"].tap()
        let linkItem = app.buttons["ノートリンク"]
        XCTAssertTrue(linkItem.waitForExistence(timeout: 3), "挿入メニューにノートリンクが無い")
        linkItem.tap()

        let pick = app.buttons["notelink-pick-\(targetName)"]
        XCTAssertTrue(pick.waitForExistence(timeout: 5), "リンク先ピッカーに対象ノートが出ない")
        pick.tap()

        // リンクカードにリンク先タイトルが表示される
        let card = app.staticTexts[targetName].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5), "リンクカードにタイトルが出ない")
        // まだリンク先には移動していない(ナビバーはリンク先タイトルではない)
        XCTAssertFalse(app.navigationBars[targetName].exists, "挿入直後にジャンプしてしまっている")
        attachScreenshot(app, name: "1-link-card-inserted")

        // ダブルタップでジャンプ → リンク先ノートがタブで開く(ナビバーがリンク先タイトルに)
        card.doubleTap()
        XCTAssertTrue(app.navigationBars[targetName].waitForExistence(timeout: 5),
                      "ダブルタップでリンク先へジャンプしない")
        attachScreenshot(app, name: "2-jumped-to-target")
    }

    // MARK: - ヘルパー

    /// 新規ノートを作成して開く(name 指定時は名前を入力)
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
