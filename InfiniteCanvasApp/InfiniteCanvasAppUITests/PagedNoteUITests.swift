import XCTest

/// 通常ノート(固定ページ形式)のエンドツーエンド検証。
/// - 作成シートで「通常ノート」を選んで作成できること。
/// - A4ページがグレー背景の上に表示されること。
/// - ページ上に手書きできること。
/// - 「ページを追加」でページが増え、下方向へスクロールすること。
final class PagedNoteUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCreatePagedNoteDrawAndAddPage() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launch()

        // ライブラリへ戻る(タブ復元でキャンバスが開いている場合)
        let backToLibrary = app.buttons["書類"]
        if backToLibrary.waitForExistence(timeout: 3) { backToLibrary.tap() }

        // 新規ノート作成シートを開く
        let addTile = app.buttons["add-note-tile"]
        if addTile.waitForExistence(timeout: 5) {
            addTile.tap()
        } else {
            app.buttons["新規ノート"].firstMatch.tap()
        }

        // 「通常ノート」を選択して作成
        let pagedSegment = app.segmentedControls.buttons["通常ノート"]
        XCTAssertTrue(pagedSegment.waitForExistence(timeout: 5), "ノート種類の選択が出ない")
        pagedSegment.tap()
        app.buttons["作成"].tap()

        // 通常ノートのキャンバスが開く(戻るボタン + ページ追加ボタン)
        XCTAssertTrue(backToLibrary.waitForExistence(timeout: 5), "ノートが開かない")
        let addPage = app.buttons["canvas-add-page"]
        XCTAssertTrue(addPage.waitForExistence(timeout: 5), "ページ追加ボタンが出ない(paged 判定失敗)")
        attachScreenshot(app, name: "1-paged-note-created")

        // ページ上に手書き
        app.buttons["toolbar-tool-pen"].tap()
        let canvas = app.windows.firstMatch
        drag(canvas, from: (0.30, 0.30), to: (0.55, 0.55))
        attachScreenshot(app, name: "2-ink-on-page")

        // ページを追加 → 2ページ目へスクロール
        addPage.tap()
        // アニメーション/スクロール待ち
        _ = app.buttons["toolbar-tool-pen"].waitForExistence(timeout: 3)
        attachScreenshot(app, name: "3-page-added-scrolled")

        XCTAssertTrue(addPage.isHittable, "ページ追加後にUIが操作不能(ハング)")
    }

    // MARK: - ヘルパー

    @MainActor
    private func drag(_ canvas: XCUIElement, from: (CGFloat, CGFloat), to: (CGFloat, CGFloat)) {
        let a = canvas.coordinate(withNormalizedOffset: CGVector(dx: from.0, dy: from.1))
        let b = canvas.coordinate(withNormalizedOffset: CGVector(dx: to.0, dy: to.1))
        a.press(forDuration: 0.05, thenDragTo: b)
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
