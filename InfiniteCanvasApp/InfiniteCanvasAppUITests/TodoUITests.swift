import XCTest

/// キャンバスに置く Todoリスト(チェックリスト)オブジェクトの
/// 挿入・テキスト入力・チェック切替を単独で検証する。
final class TodoUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// 挿入 → 数字マーカーを入力 → テキスト欄に残ることを確認
    @MainActor
    func testInsertAndEditTodo() throws {
        let app = launchAndOpenNote()
        let marker = "\(Int.random(in: 10_000_000...99_999_999))"
        insertTodo(app, typing: marker)

        let field = app.textFields.containing(NSPredicate(format: "value CONTAINS %@", marker)).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Todo のテキスト欄に入力が残らない")
    }

    /// チェックボックスをタップすると done 状態(a11y value)が切り替わる
    @MainActor
    func testToggleCheckbox() throws {
        let app = launchAndOpenNote()
        insertTodo(app, typing: "\(Int.random(in: 10_000_000...99_999_999))")

        // 入力を終了(キーボードに隠れない上寄りをタップ)
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.28)).tap()
        _ = app.keyboards.firstMatch.waitForNonExistence(timeout: 5)

        let checkbox = app.buttons["todo-checkbox"].firstMatch
        XCTAssertTrue(checkbox.waitForExistence(timeout: 5), "チェックボックスが見つからない")
        XCTAssertEqual(checkbox.value as? String, "todo", "初期状態は未完了のはず")

        checkbox.tap()

        let becameDone = expectation(description: "done")
        pollUntil({ (app.buttons["todo-checkbox"].firstMatch.value as? String) == "done" },
                  timeout: 5, fulfill: becameDone)
        wait(for: [becameDone], timeout: 5.5)
    }

    // MARK: - ヘルパー

    @MainActor
    private func launchAndOpenNote() -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment["RESET_STORE"] = "1"  // テスト毎にDBを初期化(蓄積防止)
        app.launch()
        let backToLibrary = app.buttons["toolbar-tool-pen"]
        if !backToLibrary.waitForExistence(timeout: 3) {
            let anyNote = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH 'grid-note-'")).firstMatch
            if anyNote.waitForExistence(timeout: 5) { anyNote.tap() }
            else {
                (app.buttons["add-note-tile"].exists ? app.buttons["add-note-tile"] : app.buttons["新規ノート"].firstMatch).tap()
                app.buttons["作成"].tap()
            }
            _ = backToLibrary.waitForExistence(timeout: 5)
        }
        return app
    }

    /// Todoリストを挿入し、先頭行に marker を入力する(挿入直後は編集状態)
    @MainActor
    private func insertTodo(_ app: XCUIApplication, typing marker: String) {
        app.buttons["toolbar-insert-menu"].tap()
        let item = app.buttons["toolbar-insert-todo"].exists
            ? app.buttons["toolbar-insert-todo"]
            : app.buttons["Todoリスト"]
        XCTAssertTrue(item.waitForExistence(timeout: 3), "挿入メニューに Todoリストがない")
        item.tap()  // Todo 配置ツールを選択
        // 配置ツール: キャンバス中央をタップして Todo を配置する
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        // 配置直後は選択・編集状態。シミュレータではプログラム的フォーカスに
        // ソフトキーボードが追従しないため、配置した Todo の行を一度タップして編集を開始する。
        let placedRow = app.textFields.firstMatch
        XCTAssertTrue(placedRow.waitForExistence(timeout: 5), "Todo が配置されない")
        placedRow.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "Todo の編集が始まらない")
        app.typeText(marker)
    }

    @MainActor
    private func pollUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval, fulfill exp: XCTestExpectation) {
        let deadline = Date().addingTimeInterval(timeout)
        func step() {
            if condition() { exp.fulfill() }
            else if Date() < deadline { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { step() } }
        }
        step()
    }
}
