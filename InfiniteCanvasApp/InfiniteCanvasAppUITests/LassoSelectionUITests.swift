import XCTest

/// フリーボード改修 Phase2-b step2: 自前の範囲選択(ドラッグ・マーキー)で
/// 手書きインク(PKDrawing のストローク)と CanvasObject を区別なく一括選択し、
/// 統一枠で一括削除・移動できることを検証する(指示書 2.2「ドラッグおよび投げ縄」)。
/// インクは XCUITest のアクセシビリティに現れないため、「オブジェクトが無い状態で
/// 範囲選択したら統一枠(削除ボタン)が出る=ストロークが選択された」ことで確認する。
final class LassoSelectionUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// インクのみ: ストロークを範囲選択すると統一枠(削除ボタン)が出る。
    /// オブジェクトが1つも無いので、枠が出る=ストロークが選ばれた証拠になる。
    @MainActor
    func testMarqueeSelectsInkStroke() throws {
        let app = launchAndOpenNote()
        let canvas = app.windows.firstMatch

        // ペンで中央付近にストロークを1本描く
        app.buttons["toolbar-tool-pen"].tap()
        let s = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.48, dy: 0.48))
        s.press(forDuration: 0.05, thenDragTo: s.withOffset(CGVector(dx: 90, dy: 70)))

        // 範囲選択ツールで、空き領域からストロークを囲むように斜めドラッグ
        app.buttons["toolbar-tool-lasso"].tap()
        marquee(canvas, from: (0.30, 0.30), to: (0.70, 0.72))

        let deleteButton = app.descendants(matching: .any)
            .matching(identifier: "lasso-delete-button").firstMatch
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 5),
                      "範囲選択でストロークが選ばれず統一枠が出ない(インク一括選択が機能していない)")
    }

    /// オブジェクト: テキストを範囲選択→削除でオブジェクトが消え、Undo1回で戻る。
    @MainActor
    func testMarqueeSelectsAndDeletesObject() throws {
        let app = launchAndOpenNote()
        let canvas = app.windows.firstMatch

        let marker = placeText(app, at: CGVector(dx: 0.5, dy: 0.5))

        app.buttons["toolbar-tool-lasso"].tap()
        marquee(canvas, from: (0.32, 0.30), to: (0.68, 0.72))

        let deleteButton = app.descendants(matching: .any)
            .matching(identifier: "lasso-delete-button").firstMatch
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 5), "範囲選択の統一枠が出ない")
        deleteButton.tap()

        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: marker)
        waitForExpectations(timeout: 6)

        app.buttons["toolbar-undo"].tap()
        XCTAssertTrue(marker.waitForExistence(timeout: 6), "Undo1回でオブジェクトが復元されない")
    }

    // MARK: - ヘルパー

    @MainActor
    private func launchAndOpenNote() -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment["ALLOW_FINGER_DRAWING"] = "1"  // 指でインクを描けるようにする
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

    /// 範囲選択(マーキー)を斜めドラッグで行う。速度を付けずに正確な矩形を作る。
    @MainActor
    private func marquee(_ element: XCUIElement, from: (CGFloat, CGFloat), to: (CGFloat, CGFloat)) {
        let a = element.coordinate(withNormalizedOffset: CGVector(dx: from.0, dy: from.1))
        let b = element.coordinate(withNormalizedOffset: CGVector(dx: to.0, dy: to.1))
        a.press(forDuration: 0.1, thenDragTo: b)
    }

    /// テキストオブジェクトを配置し、数字を入力して確定して返す。
    @MainActor
    private func placeText(_ app: XCUIApplication, at offset: CGVector) -> XCUIElement {
        let text = "\(Int.random(in: 10_000_000...99_999_999))"
        app.buttons["toolbar-tool-text"].tap()
        app.windows.firstMatch.coordinate(withNormalizedOffset: offset).tap()
        let placed = app.textViews.matching(NSPredicate(format: "value == %@", "")).firstMatch
        XCTAssertTrue(placed.waitForExistence(timeout: 5), "テキストが配置されない")
        placed.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "編集が始まらない")
        app.typeText(text)
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.2)).tap()
        _ = app.keyboards.firstMatch.waitForNonExistence(timeout: 5)
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.2)).tap()
        let marker = app.textViews.containing(NSPredicate(format: "value CONTAINS %@", text)).firstMatch
        XCTAssertTrue(marker.waitForExistence(timeout: 5), "テキストオブジェクトが見つからない")
        return marker
    }
}
