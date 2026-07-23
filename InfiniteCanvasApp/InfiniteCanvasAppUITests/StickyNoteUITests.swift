import XCTest

/// フリーボード改修 Phase3: 付箋(StickyNote)の配置・編集・範囲選択の検証。
final class StickyNoteUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// ＋メニューから付箋を挿入すると、キャンバス中央に付箋(テキストビュー)が現れる。
    /// ダブルタップで編集し、入力が反映されることを確認する。
    @MainActor
    func testInsertAndEditStickyNote() throws {
        let app = launchAndOpenNote()

        insertSticky(app, color: "yellow")

        // 付箋の中身は accessibilityIdentifier "canvas-object-sticky" のテキストビュー
        let sticky = app.textViews.matching(identifier: "canvas-object-sticky").firstMatch
        XCTAssertTrue(sticky.waitForExistence(timeout: 5), "付箋が配置されない")

        // ダブルタップで編集開始 → 数字を入力 → 確定
        sticky.doubleTap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "付箋の編集が始まらない")
        let text = "\(Int.random(in: 10_000_000...99_999_999))"
        app.typeText(text)
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.2)).tap()
        _ = app.keyboards.firstMatch.waitForNonExistence(timeout: 5)

        let edited = app.textViews.containing(NSPredicate(format: "value CONTAINS %@", text)).firstMatch
        XCTAssertTrue(edited.waitForExistence(timeout: 5), "付箋に入力したテキストが反映されない")
    }

    /// 付箋は CanvasObject なので、範囲選択(投げ縄)で囲んで一括削除でき、Undo で戻る。
    @MainActor
    func testStickyNoteIsSelectableAndDeletableByMarquee() throws {
        let app = launchAndOpenNote()

        insertSticky(app, color: "green")
        let sticky = app.textViews.matching(identifier: "canvas-object-sticky").firstMatch
        XCTAssertTrue(sticky.waitForExistence(timeout: 5), "付箋が配置されない")

        // 選択解除してから範囲選択で囲む
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.2)).tap()
        app.buttons["toolbar-tool-lasso"].tap()
        let canvas = app.windows.firstMatch
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.30, dy: 0.28))
            .press(forDuration: 0.1, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.70, dy: 0.74)))

        let deleteButton = app.descendants(matching: .any)
            .matching(identifier: "lasso-delete-button").firstMatch
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 5), "付箋を範囲選択できない(統一枠が出ない)")
        deleteButton.tap()

        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: sticky)
        waitForExpectations(timeout: 6)

        app.buttons["toolbar-undo"].tap()
        XCTAssertTrue(sticky.waitForExistence(timeout: 6), "Undo1回で付箋が復元されない")
    }

    // MARK: - ヘルパー

    @MainActor
    private func launchAndOpenNote() -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment["RESET_STORE"] = "1"
        app.launch()
        let inCanvas = app.buttons["toolbar-tool-pen"]
        if !inCanvas.waitForExistence(timeout: 3) {
            let anyNote = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH 'grid-note-'")).firstMatch
            if anyNote.waitForExistence(timeout: 5) { anyNote.tap() }
            else {
                (app.buttons["add-note-tile"].exists ? app.buttons["add-note-tile"] : app.buttons["新規ノート"].firstMatch).tap()
                app.buttons["作成"].tap()
            }
            _ = inCanvas.waitForExistence(timeout: 5)
        }
        return app
    }

    /// ＋メニュー →「付箋」→ 指定色 を選んで挿入する。
    @MainActor
    private func insertSticky(_ app: XCUIApplication, color: String) {
        app.buttons["toolbar-insert-menu"].tap()
        // 「付箋」サブメニューを開く
        let stickyMenu = app.descendants(matching: .any).matching(identifier: "toolbar-insert-sticky").firstMatch
        XCTAssertTrue(stickyMenu.waitForExistence(timeout: 3), "＋メニューに付箋が無い")
        stickyMenu.tap()
        let colorItem = app.descendants(matching: .any).matching(identifier: "toolbar-sticky-\(color)").firstMatch
        XCTAssertTrue(colorItem.waitForExistence(timeout: 3), "付箋の色メニューが出ない")
        colorItem.tap()
    }
}
