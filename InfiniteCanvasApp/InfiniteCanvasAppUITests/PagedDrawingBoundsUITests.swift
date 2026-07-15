import XCTest

/// 通常ノート(paged)で、用紙内は描けて用紙外(グレー余白)では描けないことを検証する。
/// (座標系が正しくコンテンツ座標=ページ矩形と一致していることの確認も兼ねる)
final class PagedDrawingBoundsUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testDrawsOnPageButNotOnGrayMargin() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        // XCUITest は Pencil を模倣できないため、指描画を許可して描画可否を検証する
        app.launchEnvironment["ALLOW_FINGER_DRAWING"] = "1"
        app.launch()

        // 通常ノートを作成して開く
        let backToLibrary = app.buttons["書類"]
        if backToLibrary.waitForExistence(timeout: 3) { backToLibrary.tap() }
        let addTile = app.buttons["add-note-tile"]
        if addTile.waitForExistence(timeout: 5) { addTile.tap() }
        else { app.buttons["新規ノート"].firstMatch.tap() }
        let pagedSegment = app.segmentedControls.buttons["note-type-paged"].firstMatch
        let pagedByLabel = app.buttons["通常ノート"].firstMatch
        if pagedSegment.waitForExistence(timeout: 3) { pagedSegment.tap() }
        else if pagedByLabel.waitForExistence(timeout: 2) { pagedByLabel.tap() }
        app.buttons["作成"].tap()
        XCTAssertTrue(app.buttons["paged-settings-button"].waitForExistence(timeout: 5),
                      "通常ノートが開かない(paged 判定失敗)")

        let undo = app.buttons["toolbar-undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5), "ツールバーが出ない")
        app.buttons["toolbar-tool-pen"].tap()
        // ウィンドウは左のサイドバー + 右のキャンバスから成る。座標はウィンドウ基準なので、
        // キャンバス(右側)の中の用紙(左寄り)とグレー余白(右寄り)を狙う。
        let canvas = app.windows.firstMatch
        attachScreenshot(app, name: "0-fresh-paged-layout")

        // 先にグレーへドラッグすると指スクロールでページが動くため、用紙内→Undo→グレーの順で検証する。
        XCTAssertFalse(undo.isEnabled, "最初から Undo が有効")

        // ① 用紙内(キャンバス中央付近)に描くと描かれる → Undo が有効になる
        drag(canvas, from: (0.5, 0.5), to: (0.58, 0.58))
        XCTAssertTrue(undo.waitForEnabled(timeout: 3),
                      "用紙内に描いてもストロークが作られない(座標判定が誤り)")
        attachScreenshot(app, name: "1-page-drawn")

        // Undo で消してクリーンな状態に戻す
        undo.tap()
        XCTAssertTrue(undo.waitForNonEnabled(timeout: 3), "Undo で消えていない")

        // ② 用紙外(右端のグレー余白)に小さくドラッグしても描かれない → Undo は無効のまま
        drag(canvas, from: (0.92, 0.45), to: (0.96, 0.5))
        settle(0.8)
        XCTAssertFalse(undo.isEnabled, "用紙外(グレー)で描けてしまっている")
        attachScreenshot(app, name: "2-gray-blocked")
    }

    // MARK: - ヘルパー

    @MainActor
    private func drag(_ element: XCUIElement, from: (CGFloat, CGFloat), to: (CGFloat, CGFloat)) {
        let start = element.coordinate(withNormalizedOffset: CGVector(dx: from.0, dy: from.1))
        let end = element.coordinate(withNormalizedOffset: CGVector(dx: to.0, dy: to.1))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    @MainActor
    private func settle(_ seconds: TimeInterval) {
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "settle")], timeout: seconds)
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private extension XCUIElement {
    /// isEnabled が true になるまで待つ
    func waitForEnabled(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isEnabled { return true }
            _ = XCTWaiter.wait(for: [XCTestExpectation(description: "poll")], timeout: 0.2)
        }
        return isEnabled
    }

    /// isEnabled が false になるまで待つ
    func waitForNonEnabled(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !isEnabled { return true }
            _ = XCTWaiter.wait(for: [XCTestExpectation(description: "poll")], timeout: 0.2)
        }
        return !isEnabled
    }
}
