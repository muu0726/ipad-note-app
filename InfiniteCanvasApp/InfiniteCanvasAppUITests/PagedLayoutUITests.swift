import XCTest

/// 通常ノートの「見開き2ページ / 横スクロール」設定の検証。
/// - 設定ボタン(info.circle)→ ポップオーバーで2つのトグルが出る。
/// - トグルを切り替えても即時かつ安全(クラッシュ・ハングなし)にレイアウトが組み替わる。
/// レイアウト幾何そのものは PagedLayoutCalculatorTests(ユニット)で担保し、ここでは
/// 4通りの組み合わせを実際に切り替えて UI が応答し続けることを確認する。
final class PagedLayoutUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testToggleLayoutsStayResponsive() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launch()
        createPagedNote(app)

        let addPage = app.buttons["canvas-add-page"]
        XCTAssertTrue(addPage.waitForExistence(timeout: 5), "通常ノートが開かない")

        // 2ページ目を追加(見開き/横の効果が見えるように)
        addPage.tap()
        _ = app.buttons["toolbar-tool-pen"].waitForExistence(timeout: 3)

        let settings = app.buttons["paged-settings-button"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "設定ボタンが出ない")

        // 4通り(見開き × 横スクロール)を順に切り替え、毎回 UI が応答することを確認
        setLayout(app, twoPage: true, horizontal: false)
        assertResponsive(app, step: "見開き・縦")

        setLayout(app, twoPage: true, horizontal: true)
        assertResponsive(app, step: "見開き・横")

        setLayout(app, twoPage: false, horizontal: true)
        assertResponsive(app, step: "単ページ・横")

        setLayout(app, twoPage: false, horizontal: false)
        assertResponsive(app, step: "単ページ・縦(初期に戻す)")
    }

    // MARK: - ヘルパー

    /// 設定ポップオーバーを開き、2つのトグルを目標状態へ合わせて閉じる
    @MainActor
    private func setLayout(_ app: XCUIApplication, twoPage: Bool, horizontal: Bool) {
        app.buttons["paged-settings-button"].tap()

        let twoPageToggle = app.switches["toggle-two-page"]
        XCTAssertTrue(twoPageToggle.waitForExistence(timeout: 5), "見開きトグルが出ない")
        setSwitch(twoPageToggle, on: twoPage)

        let horizontalToggle = app.switches["toggle-horizontal-scroll"]
        XCTAssertTrue(horizontalToggle.waitForExistence(timeout: 3), "横スクロールトグルが出ない")
        setSwitch(horizontalToggle, on: horizontal)

        // ポップオーバーを閉じる(キャンバス上部を軽くタップ)
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
    }

    /// スイッチを目標状態へ(現在値と違うときだけタップ)
    @MainActor
    private func setSwitch(_ toggle: XCUIElement, on: Bool) {
        let isOn = (toggle.value as? String) == "1"
        if isOn != on { toggle.tap() }
    }

    /// レイアウト切替後も UI がハングせず操作できることを確認する
    @MainActor
    private func assertResponsive(_ app: XCUIApplication, step: String) {
        let addPage = app.buttons["canvas-add-page"]
        XCTAssertTrue(addPage.waitForExistence(timeout: 5), "[\(step)] ページ追加ボタンが消えた")
        XCTAssertTrue(addPage.isHittable, "[\(step)] レイアウト切替後に UI がハングしている")
        // ペン選択 → 一筆描いて描画系が生きていることも確認
        app.buttons["toolbar-tool-pen"].tap()
        let canvas = app.windows.firstMatch
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.35))
            .press(forDuration: 0.05,
                   thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        XCTAssertTrue(app.buttons["paged-settings-button"].isHittable,
                      "[\(step)] 描画後に設定ボタンが操作不能")
        attachScreenshot(app, name: step)
    }

    @MainActor
    private func createPagedNote(_ app: XCUIApplication) {
        let backToLibrary = app.buttons["書類"]
        if backToLibrary.waitForExistence(timeout: 3) { backToLibrary.tap() }
        let addTile = app.buttons["add-note-tile"]
        if addTile.waitForExistence(timeout: 5) { addTile.tap() }
        else { app.buttons["新規ノート"].firstMatch.tap() }
        let pagedSegment = app.segmentedControls.buttons["通常ノート"]
        _ = pagedSegment.waitForExistence(timeout: 5)
        pagedSegment.tap()
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
