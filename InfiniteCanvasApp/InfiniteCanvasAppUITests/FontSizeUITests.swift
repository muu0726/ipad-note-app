import XCTest

/// 選択したテキストオブジェクトのフォントサイズをツールバーから変更でき、
/// Undo/Redo が効くことを検証する。
final class FontSizeUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testChangeFontSizeAndUndo() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment["RESET_STORE"] = "1"  // テスト毎にDBを初期化(蓄積防止)
        app.launch()
        openNote(app)

        // テキストを挿入して確定
        let text = "\(Int.random(in: 10_000_000...99_999_999))"
        app.buttons["toolbar-tool-text"].tap()
        // テキストは配置ツール: キャンバス中央をタップして配置する
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        // 配置直後は選択・編集状態(実機ではキーボードも表示)。ただしシミュレータでは
        // プログラム的フォーカスにソフトキーボードが追従しないことがあるため、配置した
        // テキストを一度タップして編集(キーボード)を確実に開始する。
        let placed = app.textViews.firstMatch
        XCTAssertTrue(placed.waitForExistence(timeout: 5), "テキストが配置されない")
        placed.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "編集が始まらない")
        app.typeText(text)
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.28)).tap()
        _ = app.keyboards.firstMatch.waitForNonExistence(timeout: 5)
        let marker = app.textViews.containing(NSPredicate(format: "value CONTAINS %@", text)).firstMatch
        XCTAssertTrue(marker.waitForExistence(timeout: 5), "テキストが見つからない")

        // テキストを選択 → フォントサイズUIが出る
        marker.tap()
        let sizeLabel = app.staticTexts["toolbar-font-size"]
        XCTAssertTrue(sizeLabel.waitForExistence(timeout: 3), "フォントサイズUIが出ない")
        XCTAssertEqual(sizeLabel.label, "24", "初期フォントサイズが24でない")

        // 3回大きくする → 24 + 2*3 = 30
        let increase = app.buttons["toolbar-font-increase"]
        for _ in 0..<3 { increase.tap() }
        XCTAssertTrue(waitForLabel(sizeLabel, equals: "30", timeout: 5),
                      "増加後のフォントサイズが30でない(実際: \(sizeLabel.label))")

        // 自動保存(0.8秒デバウンス)とアンドゥ登録が確定するのを待ってから Undo する
        settle(1.0)

        // Undo で1段階戻る(28)
        app.buttons["toolbar-undo"].tap()
        XCTAssertTrue(waitForLabel(sizeLabel, equals: "28", timeout: 5),
                      "Undo でフォントサイズが戻らない(実際: \(sizeLabel.label))")

        // 上限(72)でクランプ。大きいフォントでは折り返して高さが増える
        for _ in 0..<30 { increase.tap() }
        XCTAssertTrue(waitForLabel(sizeLabel, equals: "72", timeout: 5),
                      "上限72でクランプされない(実際: \(sizeLabel.label))")
        settle(0.5)
        let heightLarge = marker.frame.height

        // 下限(12)でクランプ。小さいフォントでは高さが小さくなる
        let decrease = app.buttons["toolbar-font-decrease"]
        for _ in 0..<40 { decrease.tap() }
        XCTAssertTrue(waitForLabel(sizeLabel, equals: "12", timeout: 5),
                      "下限12でクランプされない(実際: \(sizeLabel.label))")
        settle(0.5)
        let heightSmall = marker.frame.height

        XCTAssertGreaterThan(heightLarge, heightSmall + 20,
                             "フォントサイズに応じた高さ自動調整が効いていない(大\(heightLarge) 小\(heightSmall))")
    }

    // MARK: - ヘルパー

    /// 一定時間だけ画面更新を待つ(自動保存デバウンス・アンドゥ登録の確定待ち)。
    /// テストケースに登録されない独立した expectation を使う。
    @MainActor
    private func settle(_ seconds: TimeInterval) {
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "settle")], timeout: seconds)
    }

    @MainActor
    private func waitForLabel(_ element: XCUIElement, equals value: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.label == value { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return element.label == value
    }

    @MainActor
    private func openNote(_ app: XCUIApplication) {
        let backToLibrary = app.buttons["toolbar-tool-pen"]
        if backToLibrary.waitForExistence(timeout: 3) { return }
        let anyNote = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'grid-note-'")).firstMatch
        if anyNote.waitForExistence(timeout: 5) { anyNote.tap() }
        else {
            (app.buttons["add-note-tile"].exists ? app.buttons["add-note-tile"] : app.buttons["新規ノート"].firstMatch).tap()
            app.buttons["作成"].tap()
        }
        _ = backToLibrary.waitForExistence(timeout: 5)
    }
}
