import XCTest

/// 図形オブジェクトの配置・編集の検証(追加機能 タスク#1〜#5)。
/// ＋メニュー → 図形 → 種別選択 → タップ位置に配置 → ダブルタップで編集ポップオーバー。
final class ShapeObjectUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// 四角を配置し、ダブルタップで編集ポップオーバー(太さスライダー)が開くこと。
    @MainActor
    func testPlaceRectangleAndOpenEditor() throws {
        let app = launchApp()
        try openAnyNote(app)
        let window = app.windows.firstMatch

        // ＋メニュー → 図形 → 四角
        openInsertMenu(app)
        tapByIdentifier(app, "toolbar-insert-shape")
        tapByIdentifier(app, "toolbar-shape-rectangle")

        // キャンバス中央へ配置
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        attachScreenshot(app, name: "1-rectangle-placed")

        // 配置した図形をダブルタップ → 編集ポップオーバー(太さスライダー)
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleTap()
        let widthSlider = app.sliders["shape-line-width"]
        XCTAssertTrue(widthSlider.waitForExistence(timeout: 5),
                      "図形ダブルタップで編集ポップオーバーが開かない")
        attachScreenshot(app, name: "2-shape-editor-open")
    }

    /// 6種すべてを順に配置してもクラッシュせず、ツールバーが操作可能なままであること。
    @MainActor
    func testPlaceAllShapeTypes() throws {
        let app = launchApp()
        try openAnyNote(app)
        let window = app.windows.firstMatch

        let types = ["rectangle", "ellipse", "triangle", "line", "arrow", "star"]
        let spots: [(CGFloat, CGFloat)] = [
            (0.30, 0.35), (0.50, 0.35), (0.70, 0.35),
            (0.30, 0.60), (0.50, 0.60), (0.70, 0.60),
        ]
        for (type, spot) in zip(types, spots) {
            openInsertMenu(app)
            tapByIdentifier(app, "toolbar-insert-shape")
            tapByIdentifier(app, "toolbar-shape-\(type)")
            window.coordinate(withNormalizedOffset: CGVector(dx: spot.0, dy: spot.1)).tap()
            // 配置後は投げ縄へ戻る(選択解除のため空き部分を軽くタップ)
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.15)).tap()
        }
        attachScreenshot(app, name: "3-all-shapes-placed")

        XCTAssertTrue(app.buttons["toolbar-tool-pen"].isHittable,
                      "図形を6種配置後にツールバーが操作不能(ハング)")
    }

    // MARK: - ヘルパー

    @MainActor
    private func openInsertMenu(_ app: XCUIApplication) {
        let insert = app.buttons["toolbar-insert-menu"]
        XCTAssertTrue(insert.waitForExistence(timeout: 5), "＋インサートメニューが無い")
        insert.tap()
    }

    /// Menu 内の項目(サブメニュー含む)を識別子で探してタップする。
    @MainActor
    private func tapByIdentifier(_ app: XCUIApplication, _ id: String) {
        let element = app.descendants(matching: .any).matching(identifier: id).firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 5), "メニュー項目が無い: \(id)")
        element.tap()
    }

    @MainActor
    private func launchApp() -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment["RESET_STORE"] = "1"
        app.launch()
        return app
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
        let inCanvas = app.buttons["toolbar-tool-pen"]
        if inCanvas.waitForExistence(timeout: 3) { return }
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
        XCTAssertTrue(inCanvas.waitForExistence(timeout: 5), "ノートが開かない")
    }
}
