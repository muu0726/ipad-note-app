import XCTest

/// リンク「元」ノート(リンクカードを持つ側)をフォルダへ移動しても、
/// フォルダ内から開いてリンクが機能することを検証する。
final class NoteLinkSourceMoveUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testNoteLinkSurvivesSourceFolderMove() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment["RESET_STORE"] = "1"  // テスト毎にDBを初期化(蓄積防止)
        app.launch()

        let targetName = "TGT\(Int.random(in: 10000...99999))"
        let sourceName = "SRC\(Int.random(in: 10000...99999))"
        let folderName = "FLD\(Int.random(in: 10000...99999))"

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

        // ライブラリへ戻り、フォルダを作成
        app.buttons["canvas-to-library"].tap()
        let addMenu = app.buttons["library-add-menu"]
        XCTAssertTrue(addMenu.waitForExistence(timeout: 5), "ライブラリの追加メニューが無い")
        addMenu.tap()
        app.buttons["新規フォルダ"].tap()
        let folderField = app.textFields["名前"]
        XCTAssertTrue(folderField.waitForExistence(timeout: 3), "フォルダ名の入力欄が無い")
        folderField.tap()
        folderField.typeText(folderName)
        app.buttons["作成"].tap()
        let folderTile = app.buttons["grid-folder-\(folderName)"]
        XCTAssertTrue(folderTile.waitForExistence(timeout: 5), "作成したフォルダのタイルが無い")

        // リンク元ノートをフォルダタイルへドラッグ&ドロップで移動
        let sourceTile = app.buttons["grid-note-\(sourceName)"]
        XCTAssertTrue(sourceTile.waitForExistence(timeout: 5), "リンク元ノートのタイルが無い")
        sourceTile.press(forDuration: 1.0, thenDragTo: folderTile)

        // 移動後、リンク元ノートはルートから消えている
        XCTAssertFalse(app.buttons["grid-note-\(sourceName)"].waitForExistence(timeout: 2),
                       "ドラッグ移動したのにルートにリンク元ノートが残っている")

        // フォルダを開き、その中のリンク元ノートを開く
        folderTile.tap()
        let sourceInFolder = app.buttons["grid-note-\(sourceName)"]
        XCTAssertTrue(sourceInFolder.waitForExistence(timeout: 5),
                      "フォルダ内にリンク元ノートが無い(移動失敗)")
        sourceInFolder.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "note-tab-\(sourceName)").firstMatch.waitForExistence(timeout: 5),
                      "フォルダ内のリンク元ノートが開かない")

        // カードは生きていて、ダブルタップでジャンプできる
        let card = app.staticTexts[targetName].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5),
                      "フォルダ移動後にリンクカードのタイトルが消えた(リンク切れ)")
        XCTAssertFalse(app.staticTexts["(削除されたノート)"].exists,
                       "フォルダ移動でリンクが削除扱いになっている")
        attachScreenshot(app, name: "1-source-in-folder")

        card.doubleTap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "note-tab-\(targetName)").firstMatch.waitForExistence(timeout: 5),
                      "リンク元フォルダ移動後にリンク先へジャンプできない")
        attachScreenshot(app, name: "2-jumped-from-folder")
    }

    // MARK: - ヘルパー

    @MainActor
    private func createNote(_ app: XCUIApplication, named name: String?) {
        let backToLibrary = app.buttons["toolbar-tool-pen"]
        if backToLibrary.waitForExistence(timeout: 3) { app.buttons["canvas-to-library"].tap() }
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
