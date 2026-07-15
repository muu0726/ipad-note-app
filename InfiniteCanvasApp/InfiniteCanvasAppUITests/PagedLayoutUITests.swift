import XCTest

/// 通常ノートの「見開き2ページ表示」設定の検証(横スクロールは固定になったためトグルは無い)。
/// - 設定ボタン(info.circle)→ ポップオーバーで見開きトグルが出る。
/// - トグルを切り替えても即時かつ安全(クラッシュ・ハングなし)にレイアウトが組み替わる。
/// レイアウト幾何そのものは PagedLayoutCalculatorTests(ユニット)で担保する。
final class PagedLayoutUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testToggleTwoPageStaysResponsive() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        // XCUITest は Pencil 入力を模倣できないため、指描画を許可して描画系を検証する
        app.launchEnvironment["ALLOW_FINGER_DRAWING"] = "1"
        app.launch()
        createPagedNote(app)

        let settings = app.buttons["paged-settings-button"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "通常ノートが開かない(設定ボタン無し)")

        setTwoPage(app, on: true)
        assertResponsive(app, step: "見開きON")

        setTwoPage(app, on: false)
        assertResponsive(app, step: "見開きOFF")
    }

    // MARK: - ヘルパー

    /// 設定ポップオーバーを開き、見開きトグルを目標状態へ合わせて閉じる
    @MainActor
    private func setTwoPage(_ app: XCUIApplication, on: Bool) {
        app.buttons["paged-settings-button"].tap()
        let twoPageToggle = app.switches["toggle-two-page"]
        XCTAssertTrue(twoPageToggle.waitForExistence(timeout: 5), "見開きトグルが出ない")
        let isOn = (twoPageToggle.value as? String) == "1"
        if isOn != on { twoPageToggle.tap() }
        // ポップオーバーを閉じる(キャンバス上部を軽くタップ)
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
    }

    /// レイアウト切替後も UI がハングせず操作できることを確認する
    @MainActor
    private func assertResponsive(_ app: XCUIApplication, step: String) {
        let settings = app.buttons["paged-settings-button"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "[\(step)] 設定ボタンが消えた")
        XCTAssertTrue(settings.isHittable, "[\(step)] レイアウト切替後に UI がハングしている")
        // ペン選択 → 一筆描いて描画系が生きていることも確認
        app.buttons["toolbar-tool-pen"].tap()
        let canvas = app.windows.firstMatch
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.4))
            .press(forDuration: 0.05,
                   thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.5)))
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
