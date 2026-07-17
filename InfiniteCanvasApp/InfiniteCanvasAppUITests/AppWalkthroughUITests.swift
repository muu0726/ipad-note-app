import XCTest

/// アプリの「使用感」探索テスト(ウォークスルー)。
/// 主要フローを一気通貫でなぞり、各節目でスクリーンショットを keepAlways で残す。
/// 目的はパス/フェイルのゲートではなく、複数デバイスサイズでの実描画の証跡収集と
/// 破綻箇所の可視化。途中で1手が失敗しても止まらないよう best-effort で進める。
final class AppWalkthroughUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    @MainActor
    func testFullWalkthrough() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment["ALLOW_FINGER_DRAWING"] = "1"
        app.launch()

        shot(app, "01-launch-library")

        // ノート2枚を作成
        let n1 = "WT1_\(Int.random(in: 1000...9999))"
        let n2 = "WT2_\(Int.random(in: 1000...9999))"
        createNote(app, named: n1)
        shot(app, "02-note1-blank-canvas")

        // ペンで描く
        tapIfExists(app.buttons["toolbar-tool-pen"])
        draw(app, from: (0.35, 0.4), to: (0.6, 0.6))
        draw(app, from: (0.4, 0.55), to: (0.65, 0.45))
        shot(app, "03-pen-strokes")

        // マーカーで描く(白紙上で見えたまま残るか)
        tapIfExists(app.buttons["toolbar-tool-marker"])
        draw(app, from: (0.3, 0.35), to: (0.7, 0.35))
        shot(app, "04-marker-stroke")

        // Todo を挿入
        insert(app, item: "toolbar-insert-todo", menuLabel: "Todoリスト")
        shot(app, "05-insert-todo")

        // テキストを挿入して数字入力(日本語IME回避で数字のみ)
        insert(app, item: nil, menuLabel: "テキスト")
        if app.keyboards.firstMatch.waitForExistence(timeout: 3) {
            app.typeText("12345")
        }
        // 背景タップで確定(キーボードを閉じる。上寄りを叩く)
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.25)).tap()
        shot(app, "06-insert-text")

        // Undo を数回
        for _ in 0..<3 { tapIfExists(app.buttons["toolbar-undo"]) }
        shot(app, "07-after-undo")

        // 背景テンプレ切替(方眼)
        tapIfExists(app.buttons["背景"])
        tapIfExists(app.buttons["方眼"])
        shot(app, "08-grid-background")

        // 2枚目を作成 → 右側で開いて分割
        createNote(app, named: n2)
        shot(app, "09-note2-blank")
        openRight(app, tabNamed: n1)
        shot(app, "10-split-active")

        // 分割の各ペインで描く
        tapIfExists(app.buttons["toolbar-tool-pen"])
        draw(app, from: (0.15, 0.5), to: (0.35, 0.65))   // 左ペイン
        draw(app, from: (0.65, 0.5), to: (0.85, 0.65))   // 右ペイン
        shot(app, "11-split-drew-both")

        // 「書類」でライブラリへ戻り、2枚目を開き直す(分割維持の確認)
        tapIfExists(app.buttons["書類"])
        shot(app, "12-library-with-open-notes")
        tapIfExists(element(app, id: "grid-note-\(n2)"))
        shot(app, "13-reopened-still-split")

        // グラフビューを開く(「書類」でライブラリへ戻るとサイドバーが再表示される)
        tapIfExists(app.buttons["書類"])
        tapIfExists(app.staticTexts["グラフビュー"])
        tapIfExists(app.buttons["グラフビュー"])
        // グラフの中央フィット(約500ms後+トランジション)を待ってから撮影
        Thread.sleep(forTimeInterval: 2.0)
        shot(app, "14-graph-view")
    }

    // MARK: - ヘルパー(best-effort)

    @MainActor private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    @MainActor private func element(_ app: XCUIApplication, id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    @MainActor private func tapIfExists(_ el: XCUIElement, timeout: TimeInterval = 3) {
        if el.waitForExistence(timeout: timeout), el.isHittable { el.tap() }
    }

    @MainActor private func draw(_ app: XCUIApplication, from: (CGFloat, CGFloat), to: (CGFloat, CGFloat)) {
        let win = app.windows.firstMatch
        win.coordinate(withNormalizedOffset: CGVector(dx: from.0, dy: from.1))
            .press(forDuration: 0.05,
                   thenDragTo: win.coordinate(withNormalizedOffset: CGVector(dx: to.0, dy: to.1)))
    }

    @MainActor private func insert(_ app: XCUIApplication, item: String?, menuLabel: String) {
        tapIfExists(element(app, id: "toolbar-insert-menu"))
        tapIfExists(app.buttons[menuLabel])
    }

    @MainActor private func openRight(_ app: XCUIApplication, tabNamed name: String) {
        let chip = element(app, id: "note-tab-\(name)")
        if chip.waitForExistence(timeout: 5) {
            chip.press(forDuration: 1.1)
            tapIfExists(app.buttons["右側で開く"])
        }
    }

    @MainActor private func createNote(_ app: XCUIApplication, named name: String) {
        let backToLibrary = app.buttons["書類"]
        if backToLibrary.waitForExistence(timeout: 3) { backToLibrary.tap() }
        let addTile = app.buttons["add-note-tile"]
        if addTile.waitForExistence(timeout: 5) { addTile.tap() }
        else { tapIfExists(app.buttons["新規ノート"].firstMatch) }
        let field = app.textFields["名前"]
        if field.waitForExistence(timeout: 3) {
            field.tap()
            field.typeText(name)
        }
        tapIfExists(app.buttons["作成"])
        _ = backToLibrary.waitForExistence(timeout: 5)
    }
}
