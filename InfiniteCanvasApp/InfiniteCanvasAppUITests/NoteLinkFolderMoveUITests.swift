import XCTest

/// ノートリンク先ノートをフォルダへ移動しても、リンクが壊れずジャンプできることを検証する。
/// (「フォルダ移動でノートリンクがうまく動作しない」不具合の再現/回帰テスト)
final class NoteLinkFolderMoveUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testNoteLinkSurvivesTargetFolderMove() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment["RESET_STORE"] = "1"  // テスト毎にDBを初期化(蓄積防止)
        app.launch()

        let targetName = "TGT\(Int.random(in: 10000...99999))"
        let sourceName = "SRC\(Int.random(in: 10000...99999))"
        let folderName = "FLD\(Int.random(in: 10000...99999))"

        createNote(app, named: targetName)
        createNote(app, named: sourceName)

        // リンク元にリンクカードを挿入(この時点で source が開いている)
        app.buttons["toolbar-insert-menu"].tap()
        let linkItem = app.buttons["ノートリンク"]
        XCTAssertTrue(linkItem.waitForExistence(timeout: 3), "挿入メニューにノートリンクが無い")
        linkItem.tap()
        let pick = app.buttons["notelink-pick-\(targetName)"]
        XCTAssertTrue(pick.waitForExistence(timeout: 5), "リンク先ピッカーに対象ノートが出ない")
        pick.tap()
        XCTAssertTrue(app.staticTexts[targetName].firstMatch.waitForExistence(timeout: 5),
                      "リンクカードにタイトルが出ない")

        // ライブラリへ戻る
        app.buttons["canvas-to-library"].tap()

        // フォルダを新規作成
        let addMenu = app.buttons["library-add-menu"]
        XCTAssertTrue(addMenu.waitForExistence(timeout: 5), "ライブラリの追加メニューが無い")
        addMenu.tap()
        app.buttons["新規フォルダ"].tap()
        let folderField = app.textFields["名前"]
        XCTAssertTrue(folderField.waitForExistence(timeout: 3), "フォルダ名の入力欄が無い")
        folderField.tap()
        folderField.typeText(folderName)
        app.buttons["作成"].tap()
        XCTAssertTrue(app.buttons["grid-folder-\(folderName)"].waitForExistence(timeout: 5),
                      "作成したフォルダのタイルが無い")

        // リンク先ノートを長押し → 「移動…」でフォルダへ移動
        let targetTile = app.buttons["grid-note-\(targetName)"]
        XCTAssertTrue(targetTile.waitForExistence(timeout: 5), "リンク先ノートのタイルが無い")
        targetTile.press(forDuration: 1.1)
        let moveMenu = app.buttons["移動…"]
        XCTAssertTrue(moveMenu.waitForExistence(timeout: 3), "コンテキストメニューに移動が無い")
        moveMenu.tap()
        let destination = app.buttons[folderName].firstMatch
        XCTAssertTrue(destination.waitForExistence(timeout: 3), "移動先にフォルダが出ない")
        destination.tap()

        // 移動後、リンク先ノートはルートから消えている
        XCTAssertFalse(app.buttons["grid-note-\(targetName)"].waitForExistence(timeout: 2),
                       "移動したのにルートにリンク先ノートが残っている")

        // リンク元ノートを開き直す(ビューが作り直され、カードのタイトルを引き直す)
        let sourceTile = app.buttons["grid-note-\(sourceName)"]
        XCTAssertTrue(sourceTile.waitForExistence(timeout: 5), "リンク元ノートのタイルが無い")
        sourceTile.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "note-tab-\(sourceName)").firstMatch.waitForExistence(timeout: 5),
                      "リンク元ノートが開かない")

        // カードは「(削除されたノート)」にならず、リンク先タイトルを保っているはず
        let card = app.staticTexts[targetName].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5),
                      "フォルダ移動後にリンクカードのタイトルが消えた(リンク切れ)")
        XCTAssertFalse(app.staticTexts["(削除されたノート)"].exists,
                       "フォルダ移動でリンクが削除扱いになっている")
        attachScreenshot(app, name: "1-card-after-move")

        // ダブルタップでリンク先へジャンプできる
        card.doubleTap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "note-tab-\(targetName)").firstMatch.waitForExistence(timeout: 5),
                      "フォルダ移動後にリンク先へジャンプできない")
        attachScreenshot(app, name: "2-jumped-after-move")
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
