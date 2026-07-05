import XCTest

/// ドラッグ&ドロップによるファイル移動のエンドツーエンドテスト。
/// 既存データ(ルートにノートとフォルダが1つ以上ある状態)を使い、
/// ノートをフォルダへ移動 → サイドバーの「すべてのノート」へ戻す往復を検証する。
final class DragDropUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testDragNoteIntoFolderAndBack() throws {
        XCUIDevice.shared.orientation = .landscapeLeft  // サイドバーを常時表示にする
        let app = XCUIApplication()
        app.launch()

        // タブ復元でキャンバスが開いていたらライブラリへ戻る
        let backToLibrary = app.buttons["書類"]
        if backToLibrary.waitForExistence(timeout: 3) {
            backToLibrary.tap()
        }

        // ルートグリッドのノートとフォルダを1つずつ取得
        let anyNote = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'grid-note-'")).firstMatch
        let anyFolder = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'grid-folder-'")).firstMatch
        try XCTSkipUnless(anyNote.waitForExistence(timeout: 5) && anyFolder.exists,
                          "ルートにノートとフォルダが必要(シミュレータの既存データ前提)")

        let noteID = anyNote.identifier
        let folderID = anyFolder.identifier

        // ① ノートをフォルダタイルへドラッグ&ドロップ → ルートから消える
        anyNote.press(forDuration: 1.2, thenDragTo: anyFolder,
                      withVelocity: .slow, thenHoldForDuration: 0.8)
        let noteInRoot = app.descendants(matching: .any).matching(identifier: noteID).firstMatch
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: noteInRoot)
        waitForExpectations(timeout: 8)

        // ② フォルダを開くと中に移動したノートがある
        app.descendants(matching: .any).matching(identifier: folderID).firstMatch.tap()
        let noteInFolder = app.descendants(matching: .any).matching(identifier: noteID).firstMatch
        XCTAssertTrue(noteInFolder.waitForExistence(timeout: 5),
                      "移動したノートがフォルダ内に見つからない")

        // ③ サイドバーの「すべてのノート」へドラッグ → ルートへ戻る
        // (識別子はラベルに付くため、それを含む行セルをドロップ先にする)
        var allNotesRow = app.cells
            .containing(NSPredicate(format: "identifier == 'sidebar-all-notes'")).firstMatch
        if !allNotesRow.waitForExistence(timeout: 3) || !allNotesRow.isHittable {
            // サイドバーが畳まれていたらナビバーのトグルで開く
            app.navigationBars.buttons.element(boundBy: 0).tap()
            allNotesRow = app.cells
                .containing(NSPredicate(format: "identifier == 'sidebar-all-notes'")).firstMatch
        }
        XCTAssertTrue(allNotesRow.waitForExistence(timeout: 5), "サイドバーが表示されていない")
        noteInFolder.press(forDuration: 1.2, thenDragTo: allNotesRow,
                           withVelocity: .slow, thenHoldForDuration: 0.8)
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: noteInFolder)
        waitForExpectations(timeout: 8)

        // ④ すべてのノートに戻ってルートにあることを確認
        allNotesRow.tap()
        let noteBackInRoot = app.descendants(matching: .any).matching(identifier: noteID).firstMatch
        XCTAssertTrue(noteBackInRoot.waitForExistence(timeout: 5),
                      "ノートがルートに戻っていない")
    }

    /// ホバーせず素早く離すドロップでも移動できるか(マウス操作の再現)
    @MainActor
    func testQuickReleaseDrop() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launch()

        let backToLibrary = app.buttons["書類"]
        if backToLibrary.waitForExistence(timeout: 3) {
            backToLibrary.tap()
        }

        let anyNote = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'grid-note-'")).firstMatch
        let anyFolder = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'grid-folder-'")).firstMatch
        try XCTSkipUnless(anyNote.waitForExistence(timeout: 5) && anyFolder.exists,
                          "ルートにノートとフォルダが必要")

        let noteID = anyNote.identifier
        // ホールドなしで即リリース
        anyNote.press(forDuration: 1.0, thenDragTo: anyFolder)
        let noteInRoot = app.descendants(matching: .any).matching(identifier: noteID).firstMatch
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: noteInRoot)
        waitForExpectations(timeout: 8)

        // 後始末: フォルダを開いてサイドバーの「すべてのノート」へ戻す
        app.descendants(matching: .any).matching(identifier: anyFolder.identifier).firstMatch.tap()
        let noteInFolder = app.descendants(matching: .any).matching(identifier: noteID).firstMatch
        let allNotesRow = app.cells
            .containing(NSPredicate(format: "identifier == 'sidebar-all-notes'")).firstMatch
        if noteInFolder.waitForExistence(timeout: 3), allNotesRow.isHittable {
            noteInFolder.press(forDuration: 1.2, thenDragTo: allNotesRow,
                               withVelocity: .slow, thenHoldForDuration: 0.8)
        }
    }

    /// ポートレート(サイドバーがオーバーレイ表示)で、
    /// グリッドのノートをサイドバーのフォルダ行へドロップして移動できるか
    @MainActor
    func testDragNoteOntoSidebarFolderInPortrait() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launch()

        let backToLibrary = app.buttons["書類"]
        if backToLibrary.waitForExistence(timeout: 3) {
            backToLibrary.tap()
        }

        let anyNote = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'grid-note-'")).firstMatch
        let sidebarFolder = app.cells
            .containing(NSPredicate(format: "identifier BEGINSWITH 'sidebar-folder-'")).firstMatch
        try XCTSkipUnless(anyNote.waitForExistence(timeout: 5) && sidebarFolder.exists,
                          "ルートにノートとサイドバーのフォルダ行が必要")

        let noteID = anyNote.identifier

        // ノートをサイドバーのフォルダ行へドラッグ&ドロップ
        anyNote.press(forDuration: 1.2, thenDragTo: sidebarFolder,
                      withVelocity: .slow, thenHoldForDuration: 0.8)
        let noteInRoot = app.descendants(matching: .any).matching(identifier: noteID).firstMatch
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: noteInRoot)
        waitForExpectations(timeout: 8)

        // 後始末: サイドバーの「すべてのノート」へ戻す(フォルダ行ドロップで自動展開済み)
        let movedNote = app.cells
            .containing(NSPredicate(format: "identifier == '\(noteID)'")).firstMatch
        let allNotesRow = app.cells
            .containing(NSPredicate(format: "identifier == 'sidebar-all-notes'")).firstMatch
        if movedNote.waitForExistence(timeout: 3), allNotesRow.isHittable {
            movedNote.press(forDuration: 1.2, thenDragTo: allNotesRow,
                            withVelocity: .slow, thenHoldForDuration: 0.8)
        }
    }
}
