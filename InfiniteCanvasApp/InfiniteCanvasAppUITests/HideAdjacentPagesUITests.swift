import XCTest

/// 通常ノート(paged)の「隣のページを隠す(完全独立表示モード)」トグルの配線と永続化を検証する。
/// マスクの遮蔽幾何は AdjacentPageMaskTests(ユニット)で担保。ここでは複数ページのノートで
/// トグル → マスク要素の出現/消失、およびノート再オープン後の設定保持を確認する。
/// (1ページのみのノートは隠すべき隣ページが無く、マスクは正しく非表示になるため2ページ用意する)
final class HideAdjacentPagesUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testToggleShowsMaskAndPersists() throws {
        let app = launchApp()
        try createPagedNote(app)
        try addOnePageByOverscroll(app)  // 隣ページを1枚用意(この後アクティブは末尾ページ)

        // どちらの端に立つかはアクティブページ依存のため、左右いずれかのマスク出現を見る
        let anyMask = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'paged-adjacent-mask'")).firstMatch

        // 初期状態(OFF): マスクは存在しない
        openPagedSettings(app)
        XCTAssertEqual(hideToggleValue(app), "0", "初期状態は OFF のはず")
        XCTAssertFalse(anyMask.exists, "OFF なのにマスクが出ている")

        // ON にする → ポップオーバーを閉じてマスク出現を確認
        setHideToggle(app, on: true)
        dismissPopover(app)
        XCTAssertTrue(anyMask.waitForExistence(timeout: 5),
                      "ON にしても隣ページ遮蔽マスクが出ない")
        attachScreenshot(app, name: "1-mask-on")

        // 永続化: ノートを閉じて再オープン → トグルは ON のまま
        app.buttons["canvas-to-library"].tap()
        try reopenFirstNote(app)
        openPagedSettings(app)
        XCTAssertEqual(hideToggleValue(app), "1",
                       "設定が永続化されていない(再オープンで OFF に戻った)")

        // OFF に戻す → マスク消失
        setHideToggle(app, on: false)
        dismissPopover(app)
        XCTAssertTrue(anyMask.waitForNonExistence(timeout: 5), "OFF にしてもマスクが消えない")
        attachScreenshot(app, name: "2-mask-off")
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

    /// 通常ノート(paged)を新規作成して開く。
    @MainActor
    private func createPagedNote(_ app: XCUIApplication) throws {
        let backToLibrary = app.buttons["toolbar-tool-pen"]
        if backToLibrary.waitForExistence(timeout: 3) { app.buttons["canvas-to-library"].tap() }
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

    /// 末尾を超えて横に引っ張り、ページを1枚自動追加する(PagedNoteUITests と同手)。
    @MainActor
    private func addOnePageByOverscroll(_ app: XCUIApplication) throws {
        let canvas = app.windows.firstMatch
        let deletePage = app.buttons["canvas-delete-page"]  // 複数ページ時のみ現れる
        var added = false
        for _ in 0..<4 {
            let a = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
            let b = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5))
            a.press(forDuration: 0.05, thenDragTo: b)
            if deletePage.waitForExistence(timeout: 2) { added = true; break }
        }
        XCTAssertTrue(added, "オーバースクロールでページを追加できない")
        // 追加ページへのスクロールアニメ完了を待つ(定常化 → マスク再計算のタイミング)
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "scrollAnimation")], timeout: 1.2)
    }

    /// ライブラリの先頭ノートを開き直す。
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
    private func openPagedSettings(_ app: XCUIApplication) {
        let button = app.buttons["paged-settings-button"]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "設定ボタンが無い")
        button.tap()
        XCTAssertTrue(app.switches["toggle-hide-adjacent"].waitForExistence(timeout: 5),
                      "設定ポップオーバーが開かない")
    }

    @MainActor
    private func hideToggleValue(_ app: XCUIApplication) -> String {
        app.switches["toggle-hide-adjacent"].value as? String ?? "?"
    }

    /// 「隣のページを隠す」トグルを目標状態へ合わせる。SwiftUI Toggle は行全体が switch 要素として
    /// 報告され、要素中心タップ(=ラベル)ではトグルされないため、末尾(スイッチ本体)を座標タップする。
    @MainActor
    private func setHideToggle(_ app: XCUIApplication, on: Bool) {
        let toggle = app.switches["toggle-hide-adjacent"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "「隣のページを隠す」トグルが無い")
        let target = on ? "1" : "0"
        for _ in 0..<3 {
            if (toggle.value as? String) == target { return }
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
            _ = XCTWaiter.wait(for: [XCTestExpectation(description: "toggle")], timeout: 0.4)
        }
        XCTAssertEqual(toggle.value as? String, target, "トグルを \(target) にできない")
    }

    /// ポップオーバーを閉じる(キャンバス中央をタップ = ポップオーバー外)。
    @MainActor
    private func dismissPopover(_ app: XCUIApplication) {
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        _ = app.switches["toggle-hide-adjacent"].waitForNonExistence(timeout: 3)
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
