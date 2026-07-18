import XCTest

/// 起動フラグ `RESET_STORE=1` で、起動のたびに Core Data ストアが初期化されることを検証する。
/// これにより UIテストのノート蓄積(ライブラリのグリッド崩れ・`add-note-tile` の画面外化)を根絶する。
final class StoreResetUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testResetStoreClearsNotesBetweenLaunches() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment["RESET_STORE"] = "1"
        app.launch()

        let seed = "SEED\(Int.random(in: 10000...99999))"
        createNote(app, named: seed)

        // 作成直後はライブラリのグリッドに存在する
        app.buttons["canvas-to-library"].tap()
        XCTAssertTrue(gridNote(app, seed).waitForExistence(timeout: 5),
                      "作成したノートがグリッドに無い")

        // 再起動(RESET_STORE 有効のまま)→ ストアが初期化され、作成したノートは消える
        app.terminate()
        app.launch()
        XCTAssertFalse(gridNote(app, seed).waitForExistence(timeout: 3),
                       "再起動後もノートが残っている(RESET_STORE が効いていない)")
    }

    // MARK: - ヘルパー

    @MainActor
    private func gridNote(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "grid-note-\(name)").firstMatch
    }

    @MainActor
    private func createNote(_ app: XCUIApplication, named name: String) {
        let backToLibrary = app.buttons["toolbar-tool-pen"]
        if backToLibrary.waitForExistence(timeout: 3) { app.buttons["canvas-to-library"].tap() }
        let addTile = app.buttons["add-note-tile"]
        if addTile.waitForExistence(timeout: 5) { addTile.tap() }
        else { app.buttons["新規ノート"].firstMatch.tap() }
        let field = app.textFields["名前"]
        if field.waitForExistence(timeout: 3) {
            field.tap()
            field.typeText(name)
        }
        app.buttons["作成"].tap()
        _ = backToLibrary.waitForExistence(timeout: 5)
    }
}
