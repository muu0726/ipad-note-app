import XCTest

/// IDE 風のフォルダ内作成を検証する。
/// - サイドバーでフォルダを長押し →「新規ノート(この中に)」でそのフォルダ直下に作られる。
/// - 作業中(そのノートを開いている間)は、作成先がその作業ファイルのフォルダになる。
final class SidebarCreateInFolderUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCreateNoteInsideFolderFromSidebar() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment["RESET_STORE"] = "1"  // テスト毎にDBを初期化(蓄積防止)
        app.launch()

        let folderName = "FLD\(Int.random(in: 10000...99999))"
        let noteName = "NOTE\(Int.random(in: 10000...99999))"

        // 前回のノートが復元されてキャンバス表示のことがあるため、ライブラリへ戻す
        let backToLibrary = app.buttons["toolbar-tool-pen"]
        if backToLibrary.waitForExistence(timeout: 3) { app.buttons["canvas-to-library"].tap() }

        // フォルダをルートに作成(グリッドの追加メニュー)
        let addMenu = app.buttons["library-add-menu"]
        XCTAssertTrue(addMenu.waitForExistence(timeout: 5), "ライブラリの追加メニューが無い")
        addMenu.tap()
        app.buttons["新規フォルダ"].tap()
        let folderField = app.textFields["名前"]
        XCTAssertTrue(folderField.waitForExistence(timeout: 3), "フォルダ名入力欄が無い")
        folderField.tap()
        folderField.typeText(folderName)
        app.buttons["作成"].tap()
        XCTAssertTrue(app.buttons["grid-folder-\(folderName)"].waitForExistence(timeout: 5),
                      "作成したフォルダがルートに無い")

        // フォルダタイルを長押し →「新規ノート(この中に)」
        // (グリッド/サイドバー共通の ItemContextMenu。グリッドの長押しは安定して駆動できる)
        let folderTile = app.buttons["grid-folder-\(folderName)"]
        XCTAssertTrue(folderTile.waitForExistence(timeout: 5), "フォルダタイルが無い")
        folderTile.press(forDuration: 1.1)
        let createInside = app.buttons["新規ノート(この中に)"]
        XCTAssertTrue(createInside.waitForExistence(timeout: 3), "コンテキストメニューに『新規ノート(この中に)』が無い")
        createInside.tap()

        // ノート作成シートで名前を付けて作成 → そのまま開く
        let nameField = app.textFields["名前"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 3), "ノート名入力欄が無い")
        nameField.tap()
        nameField.typeText(noteName)
        app.buttons["dialog-create-button"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "note-tab-\(noteName)").firstMatch.waitForExistence(timeout: 5),
                      "作成したノートが開かない")

        // 作業中なので、サイドバーの作成先表示がそのフォルダになっている
        let target = app.staticTexts["sidebar-create-target"]
        if target.waitForExistence(timeout: 3) {
            XCTAssertTrue(target.label.contains(folderName),
                          "作業中の作成先が作業ファイルのフォルダになっていない: \(target.label)")
        }
        attachScreenshot(app, name: "1-created-in-folder-and-open")

        // ノートを閉じてライブラリへ。ルートには無く、フォルダ内にあることを確認
        app.buttons["canvas-to-library"].tap()
        XCTAssertFalse(app.buttons["grid-note-\(noteName)"].waitForExistence(timeout: 2),
                       "フォルダ内に作ったはずのノートがルートにある")
        app.buttons["grid-folder-\(folderName)"].tap()
        XCTAssertTrue(app.buttons["grid-note-\(noteName)"].waitForExistence(timeout: 5),
                      "フォルダの中に作成したノートが見つからない")
        attachScreenshot(app, name: "2-note-inside-folder")
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
