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

    /// リンク先ノートをゴミ箱へ移すと、カードは「(削除されたノート)」表示になり、
    /// ダブルタップしてもジャンプしない(ダングリングリンクで壊れない)ことを検証する。
    @MainActor
    func testNoteLinkToTrashedNoteDoesNotJump() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launch()

        let targetName = "TARGET\(Int.random(in: 10000...99999))"
        let sourceName = "SOURCE\(Int.random(in: 10000...99999))"
        createNote(app, named: targetName)
        createNote(app, named: sourceName)

        // リンク元にリンクカードを挿入
        app.buttons["toolbar-insert-menu"].tap()
        let linkItem = app.buttons["ノートリンク"]
        XCTAssertTrue(linkItem.waitForExistence(timeout: 3), "挿入メニューにノートリンクが無い")
        linkItem.tap()
        let pick = app.buttons["notelink-pick-\(targetName)"]
        XCTAssertTrue(pick.waitForExistence(timeout: 5), "リンク先ピッカーに対象ノートが出ない")
        pick.tap()
        XCTAssertTrue(app.staticTexts[targetName].firstMatch.waitForExistence(timeout: 5),
                      "リンクカードにタイトルが出ない")

        // ライブラリへ戻り、リンク先ノートをゴミ箱へ移動
        app.buttons["書類"].tap()
        let targetTile = app.buttons["grid-note-\(targetName)"]
        XCTAssertTrue(targetTile.waitForExistence(timeout: 5), "リンク先ノートのタイルが無い")
        targetTile.press(forDuration: 1.1)
        let deleteMenu = app.buttons["削除"]
        XCTAssertTrue(deleteMenu.waitForExistence(timeout: 3), "コンテキストメニューに削除が無い")
        deleteMenu.tap()
        let confirm = app.buttons["ゴミ箱に移動"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 3), "ゴミ箱移動の確認が出ない")
        confirm.tap()

        // リンク元ノートを開き直す(ビューが作り直され、タイトルを引き直す)
        let sourceTile = app.buttons["grid-note-\(sourceName)"]
        XCTAssertTrue(sourceTile.waitForExistence(timeout: 5), "リンク元ノートのタイルが無い")
        sourceTile.tap()
        XCTAssertTrue(app.navigationBars[sourceName].waitForExistence(timeout: 5),
                      "リンク元ノートが開かない")

        // カードは「(削除されたノート)」表示になり、元のタイトルは消えている
        let deadCard = app.staticTexts["(削除されたノート)"].firstMatch
        XCTAssertTrue(deadCard.waitForExistence(timeout: 5),
                      "削除後のカードが「(削除されたノート)」にならない")
        XCTAssertFalse(app.staticTexts[targetName].exists,
                       "削除後もリンク先タイトルが残っている(引き直していない)")
        attachScreenshot(app, name: "3-dangling-link-card")

        // ダブルタップしてもジャンプしない(リンク切れなのでリンク元に留まる)
        deadCard.doubleTap()
        // 少し待ってもナビバーはリンク元のまま(リンク先タイトルへ切り替わらない)
        XCTAssertFalse(app.navigationBars[targetName].waitForExistence(timeout: 3),
                       "削除済みリンクなのにジャンプしてしまった")
        XCTAssertTrue(app.navigationBars[sourceName].exists, "リンク元から離れてしまった")
        attachScreenshot(app, name: "4-no-jump-after-trash")
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
