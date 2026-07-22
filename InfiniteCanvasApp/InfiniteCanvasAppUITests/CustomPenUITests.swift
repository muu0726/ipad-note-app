import XCTest

/// カスタムペンホルダーの検証(追加機能 タスク#11〜#14)。
/// プリセット3本表示 → 追加で4本 → 編集ポップオーバー → 削除で3本。
final class CustomPenUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testFavoritePensAddEditDelete() throws {
        let app = launchApp()
        try openAnyNote(app)

        // プリセット3本(RESET_STORE で毎回プリセット)
        XCTAssertTrue(app.buttons["toolbar-favpen-0"].waitForExistence(timeout: 5), "お気に入りペン0が無い")
        XCTAssertTrue(app.buttons["toolbar-favpen-1"].exists, "お気に入りペン1が無い")
        XCTAssertTrue(app.buttons["toolbar-favpen-2"].exists, "お気に入りペン2が無い")
        XCTAssertFalse(app.buttons["toolbar-favpen-3"].exists, "最初から4本目があってはいけない")
        attachScreenshot(app, name: "1-presets-3")

        // 追加 → 4本
        app.buttons["toolbar-favpen-add"].tap()
        XCTAssertTrue(app.buttons["toolbar-favpen-3"].waitForExistence(timeout: 5), "追加で4本目が出ない")
        attachScreenshot(app, name: "2-added-4")

        // 追加直後はアクティブなので、もう一度タップで編集ポップオーバー
        app.buttons["toolbar-favpen-3"].tap()
        XCTAssertTrue(app.sliders["favpen-width"].waitForExistence(timeout: 5),
                      "アクティブペン再タップで編集ポップオーバーが開かない")
        attachScreenshot(app, name: "3-edit-popover")

        // 削除 → 3本へ戻る
        app.buttons["favpen-delete"].tap()
        _ = app.buttons["toolbar-favpen-3"].waitForNonExistence(timeout: 5)
        attachScreenshot(app, name: "4-after-delete")
        let favpenCount = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'toolbar-favpen-' AND NOT identifier ENDSWITH 'add'")
        ).count
        XCTAssertEqual(favpenCount, 3, "削除後のお気に入りペン数が3でない: \(favpenCount)")
        XCTAssertFalse(app.buttons["toolbar-favpen-3"].exists, "削除で4本目が消えていない")

        XCTAssertTrue(app.buttons["toolbar-tool-pen"].isHittable, "固定ペンボタンが消えた(併設が壊れた)")
    }

    // MARK: - ヘルパー

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
