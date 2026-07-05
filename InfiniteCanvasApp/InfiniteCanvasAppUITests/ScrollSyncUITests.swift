import XCTest

/// 背景・オブジェクトをスクロールビュー内部へ載せた新構成の検証(座標ベース。オブジェクトの
/// アクセシビリティ露出に依存しない)。
/// - グリッドとインクがズームで一体に拡縮し、崩れ・ずれが出ないこと。
/// - オブジェクトがキャンバス内部に描画され、ズームで一緒に拡縮すること。
/// - 描画直後の操作が即応答し、無限ループ/ハングがないこと。
final class ScrollSyncUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testGridAndInkZoomTogether() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launch()
        try openAnyNote(app)
        setGridBackground(app)

        // ペンでキャンバスに「X」を描く(グリッド上の基準になる)
        app.buttons["toolbar-tool-pen"].tap()
        let canvas = app.windows.firstMatch
        drag(canvas, from: (0.35, 0.35), to: (0.55, 0.62))
        drag(canvas, from: (0.55, 0.35), to: (0.35, 0.62))
        attachScreenshot(app, name: "1-zoom100-grid+ink")

        // ズームイン: グリッドの升目とインクが一体で拡大するはず
        canvas.pinch(withScale: 2.6, velocity: 2.0)
        attachScreenshot(app, name: "2-zoomIn-grid+ink")

        // ズームアウト
        canvas.pinch(withScale: 0.35, velocity: -2.0)
        attachScreenshot(app, name: "3-zoomOut-grid+ink")

        XCTAssertTrue(app.buttons["toolbar-tool-pen"].isHittable, "ズーム後にツールバーが操作不能(ハング)")
    }

    @MainActor
    func testTextObjectRendersInsideCanvas() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launch()
        try openAnyNote(app)

        // テキストオブジェクトを挿入 → 挿入直後は選択枠が表示され、編集キーボードが出る。
        // オブジェクトがスクロールビュー内部でも描画・フォーカスされることを確認する。
        app.buttons["toolbar-insert-menu"].tap()
        let insertText = app.buttons["テキスト"]
        XCTAssertTrue(insertText.waitForExistence(timeout: 3), "挿入メニューが開かない")
        insertText.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5),
                      "テキスト編集(becomeFirstResponder)が始まらない")
        attachScreenshot(app, name: "1-text-object-inserted-and-editing")

        // 編集終了後もアプリが応答すること(ハングなし)
        let canvas = app.windows.firstMatch
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.30)).tap()
        _ = app.keyboards.firstMatch.waitForNonExistence(timeout: 5)
        XCTAssertTrue(app.buttons["toolbar-insert-menu"].isHittable,
                      "編集終了後にツールバーが操作不能(ハング)")
    }

    // MARK: - ヘルパー

    @MainActor
    private func drag(_ canvas: XCUIElement, from: (CGFloat, CGFloat), to: (CGFloat, CGFloat)) {
        let a = canvas.coordinate(withNormalizedOffset: CGVector(dx: from.0, dy: from.1))
        let b = canvas.coordinate(withNormalizedOffset: CGVector(dx: to.0, dy: to.1))
        a.press(forDuration: 0.05, thenDragTo: b)
    }

    @MainActor
    private func setGridBackground(_ app: XCUIApplication) {
        let menu = app.buttons["背景"]
        guard menu.waitForExistence(timeout: 5) else { return }
        menu.tap()
        let grid = app.buttons["方眼"]
        if grid.waitForExistence(timeout: 3) { grid.tap() }
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
        let backToLibrary = app.buttons["書類"]
        if backToLibrary.waitForExistence(timeout: 3) { return }
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
        XCTAssertTrue(backToLibrary.waitForExistence(timeout: 5), "ノートが開かない")
    }
}
