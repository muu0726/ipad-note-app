import XCTest

/// 通常ノート(paged)のスクロール方向切替(縦連続スクロール ⇄ 横めくり)を検証する。
/// - 既定は Goodnotes 同様「縦連続スクロール」。設定の「スクロール方向」で横めくりへ切り替えられること。
/// - 縦モードでは下端を超えて上へ引っ張るとページが自動追加されること(縦オーバースクロール)。
/// - 設定がノート再オープン後も保持されること。
/// レイアウト幾何は PagedLayoutCalculatorTests(ユニット)で担保。ここでは配線と永続化を見る。
final class PagedScrollDirectionUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testDefaultIsVerticalAndDirectionSwitchPersists() throws {
        let app = launchApp()
        try createPagedNote(app)

        // 既定は縦連続スクロール(Goodnotes 同等)= セグメントは「縦スクロール」が選択されている
        openPagedSettings(app)
        XCTAssertTrue(segment(app, "縦スクロール").isSelected, "既定が縦スクロールではない")
        dismissPopover(app)

        // 縦モード: 下端を超えて上へ引っ張るとページが1枚追加される(縦オーバースクロール)
        XCTAssertTrue(addPageByVerticalOverscroll(app),
                      "縦スクロールで下端オーバースクロールしてもページが追加されない")
        attachScreenshot(app, name: "1-vertical-overscroll-added-page")

        // 横めくりへ切替 → 閉じて再オープン → 横のまま(永続化)
        openPagedSettings(app)
        segment(app, "横めくり").tap()
        dismissPopover(app)
        app.buttons["canvas-to-library"].tap()
        try reopenFirstNote(app)
        openPagedSettings(app)
        XCTAssertTrue(segment(app, "横めくり").isSelected,
                      "スクロール方向が永続化されていない(再オープンで縦へ戻った)")
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
    private func createPagedNote(_ app: XCUIApplication) throws {
        if app.buttons["toolbar-tool-pen"].waitForExistence(timeout: 3) {
            app.buttons["canvas-to-library"].tap()
        }
        let addTile = app.buttons["add-note-tile"]
        if addTile.waitForExistence(timeout: 5) { addTile.tap() }
        else { app.buttons["新規ノート"].firstMatch.tap() }
        let pagedSegment = app.segmentedControls.buttons["note-type-paged"].firstMatch
        let pagedByLabel = app.buttons["通常ノート"].firstMatch
        if pagedSegment.waitForExistence(timeout: 3) { pagedSegment.tap() }
        else if pagedByLabel.waitForExistence(timeout: 2) { pagedByLabel.tap() }
        app.buttons["作成"].tap()
        XCTAssertTrue(app.buttons["paged-settings-button"].waitForExistence(timeout: 5),
                      "通常ノートが開かない(paged 判定失敗)")
    }

    /// スクロール方向セグメント(横めくり / 縦スクロール)の1要素。
    @MainActor
    private func segment(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        let inPicker = app.segmentedControls["picker-scroll-direction"].buttons[label]
        return inPicker.exists ? inPicker : app.buttons[label]
    }

    @MainActor
    private func openPagedSettings(_ app: XCUIApplication) {
        let button = app.buttons["paged-settings-button"]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "設定ボタンが無い")
        button.tap()
        XCTAssertTrue(segment(app, "縦スクロール").waitForExistence(timeout: 5),
                      "設定ポップオーバー(スクロール方向)が開かない")
    }

    /// 縦モードで下端を超えて上へ引っ張り、ページを1枚追加する。
    /// 縦は用紙幅フィット(用紙が画面より縦長)なので、まず末尾まで下スクロールしてから
    /// さらに引っ張ると末尾オーバースクロールになる。数回の強い上ドラッグで到達させる。
    @MainActor
    private func addPageByVerticalOverscroll(_ app: XCUIApplication) -> Bool {
        let canvas = app.windows.firstMatch
        let deletePage = app.buttons["canvas-delete-page"]  // 複数ページ時のみ現れる
        for _ in 0..<6 {
            let a = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
            let b = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05))
            a.press(forDuration: 0.05, thenDragTo: b)
            if deletePage.waitForExistence(timeout: 2) { return true }
        }
        return false
    }

    @MainActor
    private func reopenFirstNote(_ app: XCUIApplication) throws {
        let anyNote = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'grid-note-'")).firstMatch
        XCTAssertTrue(anyNote.waitForExistence(timeout: 5), "ライブラリにノートが無い")
        anyNote.tap()
        XCTAssertTrue(app.buttons["paged-settings-button"].waitForExistence(timeout: 5),
                      "ノートが再オープンできない")
    }

    @MainActor
    private func dismissPopover(_ app: XCUIApplication) {
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        _ = app.buttons["picker-scroll-direction"].waitForNonExistence(timeout: 3)
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
