import XCTest

/// アプリ内スプリットビュー(2画面分割)の検証。
/// - タブ長押し →「右側で開く」で分割が始まる(間仕切りが出る)。
/// - アクティブ側で描画すると Undo が有効になる(左右で独立)。
/// - タブ長押し →「分割を解除」で1画面へ戻る。
/// 分割幾何・畳み込みロジックは SplitViewSessionTests(ユニット)で担保し、
/// ここでは実操作でメニュー経由の開始/解除と応答性を確認する。
final class SplitViewUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testOpenRightThenCloseSplit() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        // キャンバスは既定で Pencil Only(指では描けない)。XCUITest は Pencil 入力を
        // 模倣できないため、指描画を許可して描画系(Undo有効化)を検証する。
        app.launchEnvironment["ALLOW_FINGER_DRAWING"] = "1"
        app.launch()

        let nameA = "SPLA\(Int.random(in: 10000...99999))"
        let nameB = "SPLB\(Int.random(in: 10000...99999))"
        createNote(app, named: nameA)
        createNote(app, named: nameB)   // B が全画面・タブは A/B の2枚

        // A のタブを長押し →「右側で開く」→ B(左)/A(右)の分割
        tab(app, named: nameA).press(forDuration: 1.1)
        let openRight = app.buttons["右側で開く"]
        XCTAssertTrue(openRight.waitForExistence(timeout: 3), "「右側で開く」が出ない")
        openRight.tap()

        let divider = element(app, id: "split-divider")
        XCTAssertTrue(divider.waitForExistence(timeout: 5), "分割の間仕切りが出ない")
        attachScreenshot(app, name: "1-split-active")

        // アクティブ側(右=A)で描画 → Undo が有効になる(右側の履歴が生きている)
        app.buttons["toolbar-tool-pen"].tap()
        let win = app.windows.firstMatch
        win.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.4))
            .press(forDuration: 0.05,
                   thenDragTo: win.coordinate(withNormalizedOffset: CGVector(dx: 0.86, dy: 0.62)))
        let undo = app.buttons["toolbar-undo"]
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: undo)
        waitForExpectations(timeout: 5)
        attachScreenshot(app, name: "2-drew-on-active-side")

        // 分割解除 → 間仕切りが消える
        tab(app, named: nameB).press(forDuration: 1.1)
        let closeSplit = app.buttons["分割を解除"]
        XCTAssertTrue(closeSplit.waitForExistence(timeout: 3), "「分割を解除」が出ない")
        closeSplit.tap()
        XCTAssertTrue(element(app, id: "split-divider").waitForNonExistence(timeout: 5),
                      "分割が解除されない(間仕切りが残っている)")
        // 1画面に戻っても操作可能
        XCTAssertTrue(app.buttons["toolbar-tool-pen"].isHittable, "解除後にUIが操作不能")
        attachScreenshot(app, name: "3-split-closed")
    }

    // MARK: - ヘルパー

    @MainActor
    private func tab(_ app: XCUIApplication, named name: String) -> XCUIElement {
        let chip = element(app, id: "note-tab-\(name)")
        XCTAssertTrue(chip.waitForExistence(timeout: 5), "タブ \(name) が無い")
        return chip
    }

    @MainActor
    private func element(_ app: XCUIApplication, id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    @MainActor
    private func createNote(_ app: XCUIApplication, named name: String) {
        let backToLibrary = app.buttons["書類"]
        if backToLibrary.waitForExistence(timeout: 3) { backToLibrary.tap() }
        let addTile = app.buttons["add-note-tile"]
        if addTile.waitForExistence(timeout: 5) { addTile.tap() }
        else { app.buttons["新規ノート"].firstMatch.tap() }
        let field = app.textFields["名前"]
        if field.waitForExistence(timeout: 3) {
            field.tap()
            field.typeText(name)
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
