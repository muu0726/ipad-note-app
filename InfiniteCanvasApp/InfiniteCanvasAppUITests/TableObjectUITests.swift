import XCTest

/// 表オブジェクトの配置・セル編集の検証(追加機能 タスク#6〜#10)。
/// ＋メニュー → 表 → グリッドピッカーでサイズ指定 → タップ位置に配置 → セルをダブルタップで編集。
final class TableObjectUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// 表を配置し、セルをダブルタップして数字を入力できること。
    @MainActor
    func testPlaceTableAndEditCell() throws {
        let app = launchApp()
        try openAnyNote(app)
        let window = app.windows.firstMatch

        // ＋メニュー → 表 → グリッドピッカー
        openInsertMenu(app)
        tapByIdentifier(app, "toolbar-insert-table")
        let picker = app.otherElements["table-grid-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "グリッドピッカーが開かない")
        attachScreenshot(app, name: "1-grid-picker")
        // グリッド中央付近をタップ → 数行×数列を確定
        picker.tap()

        // キャンバス中央へ配置
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        attachScreenshot(app, name: "2-table-placed")

        // 中央セルをダブルタップ → 編集(キーボード) → 数字入力(かな変換を避ける)
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleTap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5),
                      "セルのダブルタップで編集キーボードが出ない")
        app.typeText("7")
        attachScreenshot(app, name: "3-cell-editing")

        // 上寄りを叩いて編集終了
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.2)).tap()
        _ = app.keyboards.firstMatch.waitForNonExistence(timeout: 5)

        // 表を選択して列/行リサイズハンドル表示を確認(スクショ)
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        attachScreenshot(app, name: "4-table-selected-handles")

        XCTAssertTrue(app.buttons["toolbar-tool-pen"].isHittable, "表操作後にツールバーが操作不能")
    }

    // MARK: - ヘルパー

    @MainActor
    private func openInsertMenu(_ app: XCUIApplication) {
        let insert = app.buttons["toolbar-insert-menu"]
        XCTAssertTrue(insert.waitForExistence(timeout: 5), "＋インサートメニューが無い")
        insert.tap()
    }

    @MainActor
    private func tapByIdentifier(_ app: XCUIApplication, _ id: String) {
        let element = app.descendants(matching: .any).matching(identifier: id).firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 5), "メニュー項目が無い: \(id)")
        element.tap()
    }

    @MainActor
    private func launchApp() -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment["RESET_STORE"] = "1"
        app.launch()
        return app
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func openAnyNote(_ app: XCUIApplication) throws {
        let inCanvas = app.buttons["toolbar-tool-pen"]
        if inCanvas.waitForExistence(timeout: 3) { return }
        let anyNote = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'grid-note-'")).firstMatch
        if anyNote.waitForExistence(timeout: 5) {
            anyNote.tap()
        } else {
            app.buttons["新規ノート"].tap()
            let confirmCreate = app.buttons["作成"]
            XCTAssertTrue(confirmCreate.waitForExistence(timeout: 5), "作成シートが開かない")
            confirmCreate.tap()
        }
        XCTAssertTrue(inCanvas.waitForExistence(timeout: 5), "ノートが開かない")
    }
}
