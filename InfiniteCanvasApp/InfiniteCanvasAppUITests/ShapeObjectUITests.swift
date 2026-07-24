import XCTest

/// 図形オブジェクトの配置・編集の検証(追加機能 タスク#1〜#5)。
/// ＋メニュー → 図形 → 種別選択 → タップ位置に配置 → ダブルタップで編集ポップオーバー。
final class ShapeObjectUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// 四角を配置し、ダブルタップで図形の中にテキストを書ける(Freeform 同等)こと。
    @MainActor
    func testShapeTextEditing() throws {
        let app = launchApp()
        try openAnyNote(app)
        let window = app.windows.firstMatch

        placeRectangle(app)
        // 配置直後の選択を解除
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.2)).tap()

        // 図形をダブルタップ → テキスト編集(キーボード)
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleTap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5),
                      "図形ダブルタップでテキスト編集が始まらない")
        let text = "5656"
        app.typeText(text)
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.2)).tap()
        _ = app.keyboards.firstMatch.waitForNonExistence(timeout: 5)

        let shapeText = app.textViews.matching(identifier: "canvas-object-shape-text").firstMatch
        XCTAssertTrue(shapeText.waitForExistence(timeout: 5), "図形内テキストの要素が見つからない")
        XCTAssertTrue((shapeText.value as? String)?.contains(text) == true,
                      "図形内テキストが反映されない: \(String(describing: shapeText.value))")
        attachScreenshot(app, name: "2-shape-with-text")
    }

    /// 図形の色/塗り/太さ編集は長押しメニュー「図形を編集」から開くこと。
    @MainActor
    func testShapeStyleEditorViaLongPress() throws {
        let app = launchApp()
        try openAnyNote(app)
        let window = app.windows.firstMatch

        placeRectangle(app)
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.2)).tap()

        // 長押し → メニュー「図形を編集」 → 太さスライダー
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1.1)
        var edit = app.menuItems["図形を編集"]
        if !edit.waitForExistence(timeout: 3) { edit = app.buttons["図形を編集"] }
        XCTAssertTrue(edit.waitForExistence(timeout: 3), "長押しメニューに『図形を編集』が無い")
        edit.tap()
        XCTAssertTrue(app.sliders["shape-line-width"].waitForExistence(timeout: 5),
                      "『図形を編集』で編集ポップオーバーが開かない")
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

    /// ＋メニュー → 図形 → 四角 をキャンバス中央へ配置する。
    @MainActor
    private func placeRectangle(_ app: XCUIApplication) {
        openInsertMenu(app)
        tapByIdentifier(app, "toolbar-insert-shape")
        tapByIdentifier(app, "toolbar-shape-rectangle")
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

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
