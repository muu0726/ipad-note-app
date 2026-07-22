import XCTest

/// 無限キャンバスの Freeform 風挙動の検証(実機検証エラー #3/#4/#5 の回帰テスト)。
/// - #3: 最大ズームでもオブジェクトが描画され続ける(clipsToBounds の GPU 上限破綻の解消)
/// - #4: 背景の格子がズームと線形に一体拡縮する(タイル間隔のズーム連動焼き直しの撤廃)
/// - #5: スクロールが「コンテンツ+余白1画面分」で止まる(InfiniteScrollLimiter)
///
/// 指描画は許可しない(pencilOnly のまま)= 単指ドラッグがスクロールになることを利用し、
/// コンテンツはテキストオブジェクトで作る。
final class InfiniteCanvasFreeformUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// 通常ノート(paged)でピンチインするとズーム倍率が上がること(scrollView 化前は
    /// フィット倍率 ≈0.51 付近で頭打ちになる回帰があった。commit 9902de5 で解消)。
    /// ※ ズームアウト(ピンチ scale<1)は XCUITest では paged/infinite とも合成できないため
    ///   自動検証しない(min=フィット倍率であり実機は UIScrollView 標準で動作する)。
    @MainActor
    func testPagedPinchZoomsIn() throws {
        let app = launchApp()
        try openPagedNote(app)   // 既定は infinite のため paged を明示選択
        let window = app.windows.firstMatch
        let start = zoomPercent(app)
        XCTAssertGreaterThan(start, 0, "初期ズーム%が読めない")
        for _ in 0..<3 { window.pinch(withScale: 3.0, velocity: 3.0) }
        let zoomed = zoomPercent(app)
        XCTAssertGreaterThan(
            zoomed, start + 20,
            "paged でピンチインしてもズームが上がらない(回帰): start=\(start)% zoomed=\(zoomed)%"
        )
    }

    /// #3: テキストオブジェクトを置いて最大ズームまでピンチしても、オブジェクトが
    /// アクセシビリティ上もスクリーン上も存在し続けること。
    @MainActor
    func testObjectStaysVisibleAtMaxZoom() throws {
        let app = launchApp()
        try openAnyNote(app)
        let window = app.windows.firstMatch

        placeTextObject(app, marker: "3434")
        dismissKeyboardAndDeselect(app)
        attachScreenshot(app, name: "1-object-at-100pct")

        // オブジェクト自身をアンカーにピンチインを繰り返して高ズームへ上げる。
        // (ウィンドウ中心アンカーの pinch はほとんど拡大されず、二本指のドリフトで
        //  オブジェクトが画面外へ出てしまうため、要素アンカー+複数回で確実に上げる)
        let text = app.textViews.containing(NSPredicate(format: "value CONTAINS '3434'")).firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 3), "テキストオブジェクトが見つからない")
        for _ in 0..<4 {
            text.pinch(withScale: 1.8, velocity: 1.0)
        }
        attachScreenshot(app, name: "2-object-at-high-zoom")

        // 実際に高ズームへ達していること(ズームバッジの%表示で確認)
        let percent = zoomPercent(app)
        XCTAssertGreaterThanOrEqual(percent, 200, "ピンチでズームが上がっていない(\(percent)%)")

        // オブジェクトがアクセシビリティツリーに残り、画面内にフレームを持つこと。
        // (旧実装では clipsToBounds × 巨大層 × 高ズームで層ごと描画が消えていた)
        XCTAssertTrue(text.exists, "高ズームでテキストオブジェクトが消えた")
        XCTAssertTrue(text.frame.intersects(window.frame), "高ズームでオブジェクトが画面外へ消えた")

        // ズームを戻しても健在であること
        window.pinch(withScale: 0.3, velocity: -2.0)
        attachScreenshot(app, name: "3-object-after-zoom-out")
        XCTAssertTrue(app.buttons["toolbar-tool-pen"].isHittable, "ズーム後にツールバーが操作不能(ハング)")
    }

    /// #4: 背景ドット(無限キャンバスは常にドット)がズームと一体で線形拡縮すること。
    /// ドット間隔がズームの2乗で変わったり、突然増殖しないことをスクショ系列で目視確認する。
    /// ピンチはオブジェクトをアンカーにして確実にズームさせ、%バッジで実ズームを検証する。
    @MainActor
    func testDotsScaleLinearlyWithZoom() throws {
        let app = launchApp()
        try openAnyNote(app)
        let window = app.windows.firstMatch

        placeTextObject(app, marker: "7878")
        dismissKeyboardAndDeselect(app)
        let text = app.textViews.containing(NSPredicate(format: "value CONTAINS '7878'")).firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 3), "アンカー用オブジェクトが無い")
        attachScreenshot(app, name: "1-dots-zoom100")

        // ズームイン(帯2のまま: ドット間隔は画面上で拡大するはず)
        for _ in 0..<3 { text.pinch(withScale: 1.8, velocity: 1.0) }
        let zoomedIn = zoomPercent(app)
        XCTAssertGreaterThanOrEqual(zoomedIn, 180, "ズームインできていない(\(zoomedIn)%)")
        attachScreenshot(app, name: "2-dots-zoomIn")

        // ズームアウトして帯1(50%未満: 間隔2倍の粗いドット)へ
        for _ in 0..<4 { text.pinch(withScale: 0.5, velocity: -1.0) }
        let zoomedOut = zoomPercent(app)
        XCTAssertLessThan(zoomedOut, 50, "帯1までズームアウトできていない(\(zoomedOut)%)")
        attachScreenshot(app, name: "3-dots-zoomOut-band1")

        // さらにズームアウトして帯0(15%未満: ドット非表示)へ
        for _ in 0..<3 { text.pinch(withScale: 0.5, velocity: -1.0) }
        let minimal = zoomPercent(app)
        XCTAssertLessThan(minimal, 15, "帯0までズームアウトできていない(\(minimal)%)")
        attachScreenshot(app, name: "4-dots-zoomOut-band0-hidden")

        XCTAssertTrue(app.buttons["toolbar-tool-pen"].isHittable, "ズーム後にツールバーが操作不能(ハング)")
    }

    /// #5: スクロール可能範囲が「コンテンツ+余白1画面分」に制限されること。
    /// 中央のテキストオブジェクトから離れる方向へ画面幅の半分 × 8 回ドラッグしても、
    /// クランプにより実際は1画面分程度しか動かないので、2回戻せばオブジェクトが画面内へ戻る。
    /// (旧実装ではおよそ4画面分离れてしまい、2回では戻らない)
    @MainActor
    func testScrollIsLimitedToContentPlusMargin() throws {
        let app = launchApp()
        try openAnyNote(app)
        let window = app.windows.firstMatch

        placeTextObject(app, marker: "5656")
        dismissKeyboardAndDeselect(app)

        let text = app.textViews.containing(NSPredicate(format: "value CONTAINS '5656'")).firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 3), "テキストオブジェクトが配置されない")

        // 右方向のコンテンツへ移動(=左へドラッグ)を8回。フリック速度を付けず正確な距離で。
        for _ in 0..<8 {
            drag(window, from: (0.75, 0.5), to: (0.25, 0.5))
        }
        attachScreenshot(app, name: "1-after-8-drags-away")

        // 2回戻す(0.5画面 × 2)。クランプされていればオブジェクトが画面内へ戻る。
        for _ in 0..<2 {
            drag(window, from: (0.25, 0.5), to: (0.75, 0.5))
        }
        attachScreenshot(app, name: "2-after-2-drags-back")

        XCTAssertTrue(text.waitForExistence(timeout: 3), "戻りスクロール後にオブジェクトが見つからない")
        XCTAssertTrue(
            text.frame.intersects(window.frame),
            "スクロール制限が効いていない(8回離れて2回で戻れる範囲を超えた): frame=\(text.frame)"
        )
    }

    // MARK: - ヘルパー

    /// 左上ズームバッジの%値を読む(例 "234%" → 234)。読めなければ -1。
    @MainActor
    private func zoomPercent(_ app: XCUIApplication) -> Int {
        let badge = app.descendants(matching: .any)
            .matching(identifier: "canvas-zoom-percent").firstMatch
        guard badge.waitForExistence(timeout: 3) else { return -1 }
        let digits = badge.label.filter(\.isNumber)
        return Int(digits) ?? -1
    }

    @MainActor
    private func launchApp() -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment["RESET_STORE"] = "1"  // テスト毎にDBを初期化(蓄積防止)
        app.launch()
        return app
    }

    /// テキスト配置ツールでキャンバス中央へテキストオブジェクトを置き、数字マーカーを入力する。
    /// (かな変換を避けるため数字のみ)
    @MainActor
    private func placeTextObject(_ app: XCUIApplication, marker: String) {
        let insertText = app.buttons["toolbar-tool-text"]
        XCTAssertTrue(insertText.waitForExistence(timeout: 3), "テキストツールが無い")
        insertText.tap()
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let placedText = app.textViews.firstMatch
        XCTAssertTrue(placedText.waitForExistence(timeout: 5), "テキストが配置されない")
        // シミュレータでは配置時のプログラム的フォーカスにキーボードが追従しないため、タップで編集開始
        placedText.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "キーボードが出ない")
        placedText.typeText(marker)
    }

    /// 背景タップで編集終了+選択解除(キーボードに覆われない上寄りを叩く)
    @MainActor
    private func dismissKeyboardAndDeselect(_ app: XCUIApplication) {
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.25)).tap()
        _ = app.keyboards.firstMatch.waitForNonExistence(timeout: 5)
        // 選択解除(単指ドラッグをスクロールに戻す)
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.25)).tap()
    }

    @MainActor
    private func drag(_ element: XCUIElement, from: (CGFloat, CGFloat), to: (CGFloat, CGFloat)) {
        let a = element.coordinate(withNormalizedOffset: CGVector(dx: from.0, dy: from.1))
        let b = element.coordinate(withNormalizedOffset: CGVector(dx: to.0, dy: to.1))
        a.press(forDuration: 0.05, thenDragTo: b)
    }

    @MainActor
    private func setGridBackground(_ app: XCUIApplication) {
        let menu = app.buttons["背景"]
        guard menu.waitForExistence(timeout: 5) else { return }
        menu.tap()
        let grid = app.buttons["方眼"]
        if grid.waitForExistence(timeout: 3) { grid.tap() }
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// 通常ノート(paged)を新規作成して開く。作成シートは既定 infinite のため用紙種別を明示選択する。
    @MainActor
    private func openPagedNote(_ app: XCUIApplication) throws {
        let inCanvas = app.buttons["toolbar-tool-pen"]
        app.buttons["新規ノート"].tap()
        // セグメント Picker から「通常ノート」を選ぶ(identifier 優先、無ければラベル)
        let byID = app.descendants(matching: .any).matching(identifier: "note-type-paged").firstMatch
        let byLabel = app.buttons["通常ノート"]
        if byID.waitForExistence(timeout: 3) {
            byID.tap()
        } else if byLabel.waitForExistence(timeout: 3) {
            byLabel.tap()
        } else {
            XCTFail("作成シートに用紙種別ピッカーが無い")
        }
        let confirmCreate = app.buttons["dialog-create-button"]
        XCTAssertTrue(confirmCreate.waitForExistence(timeout: 5), "作成シートが開かない")
        confirmCreate.tap()
        XCTAssertTrue(inCanvas.waitForExistence(timeout: 5), "paged ノートが開かない")
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
