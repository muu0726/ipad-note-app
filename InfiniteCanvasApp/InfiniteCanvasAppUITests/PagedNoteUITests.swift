import XCTest

/// 通常ノート(固定ページ形式・横スクロール)のエンドツーエンド検証。
/// - 作成シートで「通常ノート」を選んで作成できること。
/// - ページ上に手書きできること。
/// - 末尾を超えて横に引っ張るとページが自動追加されること(ページ追加ボタンは廃止)。
/// - ページ削除とその Undo。
final class PagedNoteUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCreatePagedNoteAndDraw() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        // XCUITest は Pencil 入力を模倣できないため、指描画を許可して描画系を検証する
        app.launchEnvironment["ALLOW_FINGER_DRAWING"] = "1"
        app.launch()
        createPagedNote(app)

        // 通常ノートのキャンバスが開く(設定ボタン = paged 判定)
        XCTAssertTrue(app.buttons["paged-settings-button"].waitForExistence(timeout: 5),
                      "通常ノートが開かない(paged 判定失敗)")
        attachScreenshot(app, name: "1-paged-note-created")

        // ページ上に手書き(指描画許可時)
        app.buttons["toolbar-tool-pen"].tap()
        let canvas = app.windows.firstMatch
        drag(canvas, from: (0.45, 0.40), to: (0.55, 0.55))
        attachScreenshot(app, name: "2-ink-on-page")

        XCTAssertTrue(app.buttons["paged-settings-button"].isHittable, "描画後にUIが操作不能(ハング)")
    }

    /// 末尾を超えて横に引っ張ると、ページが1枚自動追加される(GoodNotes 風)。
    /// スクロール検証のため指描画は許可しない(指=スクロール)。
    @MainActor
    func testHorizontalOverscrollAddsPage() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launch()
        createPagedNote(app)

        XCTAssertTrue(app.buttons["paged-settings-button"].waitForExistence(timeout: 5),
                      "通常ノートが開かない")
        // 1ページ目のみ = 削除ボタンはまだ無い
        XCTAssertFalse(app.buttons["canvas-delete-page"].exists, "最初から複数ページになっている")

        // 末尾を超えて左へ強く引っ張る(右方向オーバースクロール)を数回試す
        let canvas = app.windows.firstMatch
        var added = false
        for _ in 0..<4 {
            drag(canvas, from: (0.9, 0.5), to: (0.05, 0.5))
            if app.buttons["canvas-delete-page"].waitForExistence(timeout: 2) { added = true; break }
        }
        XCTAssertTrue(added, "末尾を超えて引っ張ってもページが追加されない")
        attachScreenshot(app, name: "1-page-added-by-overscroll")
    }

    @MainActor
    func testDeletePageRemovesObjectsAndUndoRestores() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launch()
        createPagedNote(app)
        XCTAssertTrue(app.buttons["paged-settings-button"].waitForExistence(timeout: 5),
                      "通常ノートが開かない")

        // 2ページ目をオーバースクロールで追加(そのページへ自動スクロール)
        let canvas = app.windows.firstMatch
        let deletePage = app.buttons["canvas-delete-page"]
        var added = false
        for _ in 0..<4 {
            drag(canvas, from: (0.9, 0.5), to: (0.05, 0.5))
            if deletePage.waitForExistence(timeout: 2) { added = true; break }
        }
        XCTAssertTrue(added, "オーバースクロールで2ページ目を追加できない")

        // ページ追加に伴うスクロールアニメーションの完了を待つ
        Thread.sleep(forTimeInterval: 1.0)

        // 末尾ページ(2ページ目)にテキストオブジェクトを挿入(削除対象のページに載る)
        let marker = "\(Int.random(in: 10_000_000...99_999_999))"
        app.buttons["toolbar-insert-menu"].tap()
        app.buttons["テキスト"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "編集が始まらない")
        app.typeText(marker)
        // 編集を確定してキーボードを閉じるため、ツールバーのペンツールボタンをタップする
        app.buttons["toolbar-tool-pen"].tap()
        _ = app.keyboards.firstMatch.waitForNonExistence(timeout: 5)
        let markerView = app.textViews.containing(NSPredicate(format: "value CONTAINS %@", marker)).firstMatch
        XCTAssertTrue(markerView.waitForExistence(timeout: 5), "テキストが末尾ページに置けていない")

        // ページ削除(確認アラート → 削除)。末尾ページとその上のオブジェクトが消える。
        // 横ページングでは削除後に先頭へクランプされ、末尾ページのオブジェクトは画面外になる。
        // (末尾へ戻すスクロールは自動ページ追加と競合するため、ここではページ構造の
        //  削除/Undo/Redo を「削除ボタンの出没」で確定的に検証する)
        XCTAssertTrue(deletePage.waitForExistence(timeout: 3), "ページ削除ボタンが出ない")
        deletePage.tap()
        app.buttons["削除"].tap()
        // ページ数が1に戻る(削除ボタンが消える)。marker も画面から消える。
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: markerView)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(deletePage.exists, "ページが減っていない(削除ボタンが残っている)")
        attachScreenshot(app, name: "1-after-delete-page")

        // Undo → ページ構造(とその上のオブジェクト)が復活し、削除ボタンが戻る
        app.buttons["toolbar-undo"].tap()
        XCTAssertTrue(app.buttons["canvas-delete-page"].waitForExistence(timeout: 5),
                      "Undo でページ数が戻っていない")
        attachScreenshot(app, name: "2-after-undo")

        // Redo → 再びページが削除され、削除ボタンが消える(履歴が双方向に効く)
        app.buttons["toolbar-redo"].tap()
        XCTAssertTrue(app.buttons["canvas-delete-page"].waitForNonExistence(timeout: 5),
                      "Redo でページ削除が再適用されない")
        attachScreenshot(app, name: "3-after-redo")
    }

    // MARK: - ヘルパー

    @MainActor
    private func createPagedNote(_ app: XCUIApplication) {
        let backToLibrary = app.buttons["書類"]
        if backToLibrary.waitForExistence(timeout: 3) { backToLibrary.tap() }
        let addTile = app.buttons["add-note-tile"]
        if addTile.waitForExistence(timeout: 5) { addTile.tap() }
        else { app.buttons["新規ノート"].firstMatch.tap() }
        let pagedSegment = segment(app, id: "note-type-paged")
        _ = pagedSegment.waitForExistence(timeout: 5)
        pagedSegment.tap()
        app.buttons["作成"].tap()
        _ = backToLibrary.waitForExistence(timeout: 5)
    }

    @MainActor
    private func segment(_ app: XCUIApplication, id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
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
