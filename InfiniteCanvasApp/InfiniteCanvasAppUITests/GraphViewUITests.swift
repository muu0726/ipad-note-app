import XCTest

/// グラフビュー(力学ネットワーク)の検証。
/// - サイドバーから開ける。
/// - ノートとノートリンクの件数が正しく集計・表示される(Swift→WebView へのデータ抽出が届く)。
/// - 検索・孤立ノート非表示のコントロールが操作できる。
///
/// WKWebView 内の d3.js ノード(SVG)は XCUITest から個別要素として見えないため、
/// ノードタップ→ジャンプの結線は NoteLinkUITests(挿入元でのダブルタップ遷移)と
/// GraphView.openNote のユニット経路で担保し、ここでは集計表示までを実操作で確認する。
final class GraphViewUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testGraphCountsReflectNotesAndLinks() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launch()

        // リンク先ノートとリンク元ノートを作り、リンクカードを1枚挿入する
        let targetName = "GTARGET\(Int.random(in: 10000...99999))"
        createNote(app, named: targetName)
        createNote(app, named: nil)

        app.buttons["toolbar-insert-menu"].tap()
        let linkItem = app.buttons["ノートリンク"]
        XCTAssertTrue(linkItem.waitForExistence(timeout: 3), "挿入メニューにノートリンクが無い")
        linkItem.tap()
        let pick = app.buttons["notelink-pick-\(targetName)"]
        XCTAssertTrue(pick.waitForExistence(timeout: 5), "リンク先ピッカーに対象ノートが出ない")
        pick.tap()
        XCTAssertTrue(app.staticTexts[targetName].firstMatch.waitForExistence(timeout: 5),
                      "リンクカードが挿入されない")

        // サイドバーからグラフビューを開く(識別子はラベルに付くため行セルで拾う)
        app.buttons["書類"].tap()
        var graphEntry = app.cells
            .containing(NSPredicate(format: "identifier == 'sidebar-graph'")).firstMatch
        if !graphEntry.waitForExistence(timeout: 3) || !graphEntry.isHittable {
            // サイドバーが畳まれていたらナビバーのトグルで開く
            app.navigationBars.buttons.element(boundBy: 0).tap()
            graphEntry = app.cells
                .containing(NSPredicate(format: "identifier == 'sidebar-graph'")).firstMatch
        }
        // グラフビューはサイドバーの「ライブラリ」セクション(可変長のフォルダ/ノート一覧)の
        // 下に固定配置されている。クローンシミュレーターに蓄積した大量のフォルダ/ノートで
        // リストが伸びていると、遅延生成される List のセルとしてまだ存在せず
        // waitForExistence だけでは見つからない。サイドバーの CollectionView 上で
        // 上方向へスワイプし、見つかるまでスクロールする。
        if !graphEntry.exists {
            let sidebarList = app.collectionViews["Sidebar"]
            var attempts = 0
            while !graphEntry.exists, attempts < 15 {
                sidebarList.swipeUp()
                graphEntry = app.cells
                    .containing(NSPredicate(format: "identifier == 'sidebar-graph'")).firstMatch
                attempts += 1
            }
        }
        XCTAssertTrue(graphEntry.waitForExistence(timeout: 5), "サイドバーにグラフビューが無い")
        graphEntry.tap()

        // 集計表示から件数を読む。クローンシミュレーターでも他テストのノートが
        // 同一ストアに残り得るため、正確な一致ではなく下限で検証する。
        let counts = app.staticTexts["graph-counts"]
        XCTAssertTrue(counts.waitForExistence(timeout: 5), "グラフの集計表示が出ない")
        let (nodeCount, linkCount) = parseCounts(counts.label)
        XCTAssertGreaterThanOrEqual(nodeCount, 2, "ノート数が2未満: \(counts.label)")
        XCTAssertGreaterThanOrEqual(linkCount, 1, "作成したリンクが集計されていない: \(counts.label)")
        attachScreenshot(app, name: "1-graph-overview")

        // 孤立ノートを隠しても、リンクで繋がったノード対とリンクは残る
        // (button スタイルの Toggle は Button 型として現れないことがあるため型を限定しない)
        let hideToggle = app.descendants(matching: .any)
            .matching(identifier: "graph-hide-isolated").firstMatch
        XCTAssertTrue(hideToggle.waitForExistence(timeout: 3), "孤立を隠すトグルが無い")
        hideToggle.tap()
        let (nodeAfter, linkAfter) = parseCounts(counts.label)
        XCTAssertGreaterThanOrEqual(nodeAfter, 2, "連結ノードまで隠れてしまった: \(counts.label)")
        XCTAssertEqual(linkAfter, linkCount, "孤立を隠してもリンク数は変わらないはず: \(counts.label)")
        XCTAssertLessThanOrEqual(nodeAfter, nodeCount, "孤立を隠したのにノード数が増えた: \(counts.label)")
        attachScreenshot(app, name: "2-hide-isolated")
    }

    // MARK: - ヘルパー

    /// "N ノート ・ M リンク" 形式のラベルから (N, M) を取り出す
    private func parseCounts(_ label: String) -> (nodes: Int, links: Int) {
        let numbers = label
            .components(separatedBy: CharacterSet.decimalDigits.inverted)
            .compactMap { Int($0) }
        return (numbers.first ?? -1, numbers.count > 1 ? numbers[1] : -1)
    }

    @MainActor
    private func createNote(_ app: XCUIApplication, named name: String?) {
        let backToLibrary = app.buttons["書類"]
        if backToLibrary.waitForExistence(timeout: 3) { backToLibrary.tap() }
        let addTile = app.buttons["add-note-tile"]
        if addTile.waitForExistence(timeout: 5) { addTile.tap() }
        else { app.buttons["新規ノート"].firstMatch.tap() }

        if let name {
            let field = app.textFields["名前"]
            if field.waitForExistence(timeout: 3) {
                field.tap()
                field.typeText(name)
            }
        }
        app.buttons["作成"].tap()
        _ = backToLibrary.waitForExistence(timeout: 5)
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
