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

    @MainActor
    func testDeletePageRemovesObjectsAndUndoRestores() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launch()
        createPagedNote(app)

        // 2ページ目を追加して、そのページへスクロール
        let addPage = app.buttons["canvas-add-page"]
        XCTAssertTrue(addPage.waitForExistence(timeout: 5), "ページ追加ボタンが出ない")
        addPage.tap()
        _ = app.buttons["toolbar-tool-pen"].waitForExistence(timeout: 3)

        // 2ページ目にテキストオブジェクトを挿入
        let marker = "\(Int.random(in: 10_000_000...99_999_999))"
        app.buttons["toolbar-insert-menu"].tap()
        app.buttons["テキスト"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "編集が始まらない")
        app.typeText(marker)
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.28)).tap()
        _ = app.keyboards.firstMatch.waitForNonExistence(timeout: 5)
        let markerView = app.textViews.containing(NSPredicate(format: "value CONTAINS %@", marker)).firstMatch
        XCTAssertTrue(markerView.waitForExistence(timeout: 5), "テキストが2ページ目に置けていない")

        // ページ削除(確認アラート → 削除)
        let deletePage = app.buttons["canvas-delete-page"]
        XCTAssertTrue(deletePage.waitForExistence(timeout: 3), "ページ削除ボタンが出ない")
        deletePage.tap()
        app.buttons["削除"].tap()

        // 2ページ目のオブジェクトが消え、ページ数が1に戻る(削除ボタンが消える)
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: markerView)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(deletePage.exists, "ページが減っていない(削除ボタンが残っている)")
        attachScreenshot(app, name: "1-after-delete-page")

        // Undo でページとオブジェクトが復活する
        app.buttons["toolbar-undo"].tap()
        XCTAssertTrue(markerView.waitForExistence(timeout: 5), "Undo でオブジェクトが復活しない")
        XCTAssertTrue(app.buttons["canvas-delete-page"].waitForExistence(timeout: 3),
                      "Undo でページ数が戻っていない")
        attachScreenshot(app, name: "2-after-undo")
    }

    // MARK: - ヘルパー

    /// 「通常ノート」を新規作成して開く
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
