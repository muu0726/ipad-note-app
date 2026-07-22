import UIKit
import PencilKit

/// 通常ノートの1ページ分の描画面。ページ矩形と同サイズの独立した PKCanvasView。
/// スクロール・ズームは外側の UIScrollView が担うため、自身のスクロールは無効化する。
final class PageCanvasView: PKCanvasView {
    /// このキャンバスが担当するページ index(ページローカル描画の書き戻し先)
    var pageIndex: Int = 0
    /// オブジェクトに当たったタッチの転送先(コンテンツ座標の単一オブジェクト層)
    weak var objectLayer: ObjectLayerUIView?
    /// 描画ジェスチャのゲート(「開く」ボタン上・指×オブジェクト上でインクを始めない)。
    /// drawingGestureRecognizer.delegate は弱参照のため各キャンバス自身が保持する。
    /// ページ内判定(isTouchAllowed)は不要(ページ外に描画面が物理的に存在しない)。
    let drawingTouchGate = DrawingTouchGate()

    // PKCanvasView は既定で自身を1つのアクセシビリティ要素にし、周囲のオブジェクトの
    // 露出を妨げることがあるため、既定のサブビュー走査へ戻す(旧構成と同じ方針)。
    override var isAccessibilityElement: Bool {
        get { false }
        set {}
    }
    override var accessibilityElements: [Any]? {
        get { nil }
        set {}
    }

    /// オブジェクト層はページキャンバスより背面にあり、素のヒットテストではタッチが届かない。
    /// オブジェクトに当たったタッチは常にオブジェクト層へ通す(指の選択・移動、ボタン類)。
    /// Apple Pencil の描画振り分けは DrawingTouchGate(指×オブジェクト上の除外)が担う。
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if let objectLayer {
            let converted = convert(point, to: objectLayer)
            if let hit = objectLayer.hitTest(converted, with: event), hit !== objectLayer {
                return hit
            }
        }
        return super.hitTest(point, with: event)
    }
}

/// GoodNotes 型ページネーションの通常ノートコンテナ。
/// 素の UIScrollView(ズーム対象 = contentView)の中に、
///   背景(机のグレー+ページ用紙、BackgroundPatternUIView)
///   < オブジェクト層(コンテンツ座標のまま単一・全域)
///   < ページごとの独立した PKCanvasView 群(インク最前面)
/// を重ねる。ページ外(グレー)には描画面が物理的に存在しないため、ページ外には描けない。
/// ページキャンバスは表示範囲±2のみ実体化するプール方式(ページ数は無制限に増えるため)。
final class PagedCanvasContainerUIView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {

    // MARK: - 構成ビュー

    let scrollView = UIScrollView()
    /// ズーム対象。bounds はコンテンツ座標(非ズーム)のままで、ズームは transform で掛かる。
    let contentView = UIView()
    let backgroundView = BackgroundPatternUIView()
    let objectLayer = ObjectLayerUIView()
    /// 「隣のページを隠す」モードでアクティブページの左右を覆う机色マスク(コンテンツ座標・最前面)
    private let leftMask = UIView()
    private let rightMask = UIView()

    /// 実体化中のページキャンバス(pageIndex → canvas)
    private(set) var pageCanvases: [Int: PageCanvasView] = [:]
    /// ページローカル座標の描画正本(全ページ分)。canvas の有無に関係なく保持する。
    private(set) var pageDrawings: [PKDrawing] = [PKDrawing()]

    // MARK: - 外部から設定される状態

    var layout = PagedLayoutCalculator(pageCount: 1, isTwoPageLayout: false, isHorizontalScroll: true)
    var pkTool: PKTool = PKInkingTool(.pen, color: .black, width: 4) {
        didSet { for canvas in pageCanvases.values { canvas.tool = pkTool } }
    }
    var isZoomLocked = false { didSet { updateZoomLimits() } }
    /// 「隣のページを隠す(完全独立表示モード)」。ON でスクロール停止時にアクティブページ以外を遮蔽する。
    var hideAdjacentPages = false {
        didSet {
            guard hideAdjacentPages != oldValue else { return }
            updateAdjacentPageMask()
        }
    }
    /// タップ位置配置モードのツール(.text / .todo)。nil のとき通常のタップ(選択解除)。
    var placementTool: CanvasTool? {
        didSet {
            let enabled = (placementTool == nil)
            for canvas in pageCanvases.values { canvas.drawingGestureRecognizer.isEnabled = enabled }
        }
    }
    var onPlaceObject: ((CanvasTool, CGPoint) -> CanvasObjectItem?)?

    /// 選択モード: 選択中の単指ドラッグはオブジェクト移動に使うため、スクロールは2本指に限定
    var isSelectMode = false {
        didSet {
            guard isSelectMode != oldValue else { return }
            objectLayer.isSelectMode = isSelectMode
            scrollView.panGestureRecognizer.minimumNumberOfTouches = isSelectMode ? 2 : 1
        }
    }

    // MARK: - コールバック

    /// ページローカル描画が変わり、merged(コンテンツ座標)を書き戻すとき
    var onMergedDrawingChanged: ((PKDrawing) -> Void)?
    var onViewportChanged: ((CanvasViewport) -> Void)?
    /// 末尾を超えて引っ張ったときのページ追加要求
    var onAppendPage: (() -> Void)?
    /// 現在ページのキャンバスが切り替わったとき(Undo ブリッジの attach 先更新)
    var onActiveCanvasChanged: ((PKCanvasView) -> Void)?
    /// ページキャンバスの生成時(delegate 設定・図形認識等の準備を Representable 側で行う)
    var onPageCanvasCreated: ((PageCanvasView) -> Void)?
    var onBoundsChange: (() -> Void)?

    // MARK: - 内部状態

    /// 外部からの描画配布中は didChange の再入を無視する
    private(set) var isDistributing = false
    /// 直近の merged(外部変更との差分判定に使う)
    private(set) var lastMergedDrawing = PKDrawing()
    /// 末尾オーバースクロールでのページ追加を要求済みか(1ドラッグにつき1回)
    var didRequestPageAppend = false
    /// スクロール(ドラッグ/慣性)中か。true の間はマスクを一時的に外して滑らかにスライドさせる。
    private var isScrollActive = false
    /// 初回フィット済みか(bounds 確定後に一度だけ)
    private var didInitialFit = false
    /// 復元待ちのビューポート(bounds 確定後に適用)
    var pendingInitialViewport: CanvasViewport?
    private var lastLayoutBoundsSize: CGSize = .zero
    /// Undo ブリッジへ attach 済みの現在ページ
    private var lastActivePage = -1

    // MARK: - 初期化

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemGray5  // 机(バウンス領域含む)

        scrollView.delegate = self
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.bouncesZoom = true
        scrollView.delaysContentTouches = false  // 長押し等をオブジェクトへ即時に渡す
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        // ページスナップは isPagingEnabled ではなく scrollViewWillEndDragging のカスタム実装
        // (ズーム倍率によりページ実幅と画面幅が一致しないため)
        scrollView.isPagingEnabled = false
        addSubview(scrollView)

        contentView.backgroundColor = .clear
        scrollView.addSubview(contentView)

        backgroundView.isUserInteractionEnabled = false
        contentView.addSubview(backgroundView)
        contentView.addSubview(objectLayer)
        objectLayer.clipsToBounds = false  // ページ間へはみ出したオブジェクトも見せる(タッチも層が受ける)

        // 「隣のページを隠す」マスク(既定は非表示)。机色で覆い、タッチは下のスクロール/ページへ素通しする。
        for (mask, id) in [(leftMask, "paged-adjacent-mask-left"), (rightMask, "paged-adjacent-mask-right")] {
            mask.backgroundColor = .systemGray5
            mask.isUserInteractionEnabled = false
            mask.isHidden = true
            // 非表示時はツリーに現れないため、XCUITest で ON/OFF を検証できるよう要素として公開する
            mask.isAccessibilityElement = true
            mask.accessibilityIdentifier = id
            contentView.addSubview(mask)
        }

        // オブジェクトのない場所のタップで選択解除 / 配置モードのタップ配置
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleBackgroundTap(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        addGestureRecognizer(tap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        if bounds.size != lastLayoutBoundsSize {
            let isFirstLayout = lastLayoutBoundsSize == .zero
            lastLayoutBoundsSize = bounds.size
            updateZoomLimits()
            NSLog("PagedDBG layout bounds=%@ first=%d fit=%.3f zoom=%.3f min=%.3f",
                  NSCoder.string(for: bounds.size), isFirstLayout ? 1 : 0,
                  minimumFitZoom(), scrollView.zoomScale, scrollView.minimumZoomScale)
            if isFirstLayout || !didInitialFit {
                applyInitialViewportOrFit()
            } else {
                // 回転・Split View リサイズ: ズーム下限の変化に追従し、センタリングを直す
                clampZoomIntoLimits()
                updateCenteringInset()
            }
            onBoundsChange?()
        }
    }

    // MARK: - レイアウト(ページ配置・コンテンツサイズ)

    /// レイアウト・スタイルの変更を反映する(冪等)。
    func applyLayout(style: CanvasBackgroundStyle, pageColor: CanvasPageColor) {
        // スクロール方向のバウンスは常に許可する。フィットズームではコンテンツが画面より
        // 狭くなるため、これが無いと末尾オーバースクロール(ページ追加ジェスチャ)が効かない。
        scrollView.alwaysBounceHorizontal = layout.scrollsHorizontally
        scrollView.alwaysBounceVertical = !layout.scrollsHorizontally
        backgroundView.configure(noteType: .paged, layout: layout, style: style, pageColor: pageColor)
        objectLayer.backgroundStyle = style
        objectLayer.pageColor = pageColor
        applyContentSize()
        // レイアウト変更(見開きトグル等)でページ矩形が動くため、実体化済みキャンバスも追従させる
        for (index, canvas) in pageCanvases { canvas.frame = layout.pageRect(index) }
        updateZoomLimits()
        updateVisiblePages()
        updateAdjacentPageMask()  // 見開きトグル等でページ矩形が動いたらマスクも再計算
    }

    /// contentView / 背景 / オブジェクト層をコンテンツ座標サイズへ合わせる。
    /// ズームは contentView の transform に掛かっているため bounds/center で調整する。
    private func applyContentSize() {
        let size = layout.contentSize
        let zoom = scrollView.zoomScale
        contentView.bounds = CGRect(origin: .zero, size: size)
        contentView.center = CGPoint(x: size.width * zoom / 2, y: size.height * zoom / 2)
        scrollView.contentSize = CGSize(width: size.width * zoom, height: size.height * zoom)
        backgroundView.frame = CGRect(origin: .zero, size: size)
        objectLayer.frame = CGRect(origin: .zero, size: size)
        updateCenteringInset()
    }

    /// ページ数の変化を反映する(pageDrawings の伸縮とページキャンバスの張り替え)。
    func setPageCount(_ count: Int) {
        let target = max(1, count)
        if pageDrawings.count < target {
            pageDrawings.append(contentsOf: (pageDrawings.count..<target).map { _ in PKDrawing() })
        } else if pageDrawings.count > target {
            pageDrawings.removeLast(pageDrawings.count - target)
        }
        // 範囲外になったキャンバスを回収
        for (index, canvas) in pageCanvases where index >= target {
            recycle(canvas, at: index)
        }
    }

    // MARK: - ページキャンバスのプール(表示範囲±2のみ実体化)

    /// 現在の可視範囲に必要なページキャンバスを実体化し、離れたものを回収する。
    func updateVisiblePages() {
        guard layout.pageCount > 0, bounds.width > 0 else { return }
        let zoom = scrollView.zoomScale
        let visible = CGRect(
            x: scrollView.contentOffset.x / zoom,
            y: scrollView.contentOffset.y / zoom,
            width: scrollView.bounds.width / zoom,
            height: scrollView.bounds.height / zoom
        )
        var needed = Set<Int>()
        for index in 0..<layout.pageCount where layout.pageRect(index).intersects(visible) {
            needed.insert(index)
        }
        // 前後2ページ分を先読み(スナップ・めくり中のチラつき防止)。
        // 半開レンジで書く(末尾ページ可視時に lower > upper の閉レンジを作るとクラッシュする)
        if let lo = needed.min() { for i in max(0, lo - 2)..<lo { needed.insert(i) } }
        if let hi = needed.max() { for i in (hi + 1)..<min(layout.pageCount, hi + 3) { needed.insert(i) } }

        for (index, canvas) in pageCanvases where !needed.contains(index) {
            recycle(canvas, at: index)
        }
        for index in needed where pageCanvases[index] == nil {
            materializeCanvas(at: index)
        }
        notifyActiveCanvasIfNeeded()
        updateAdjacentPageMask()  // materialize 後にマスクを最前面へ保ち、アクティブ変化へ追従
    }

    private func materializeCanvas(at index: Int) {
        let canvas = PageCanvasView()
        canvas.pageIndex = index
        canvas.objectLayer = objectLayer
        canvas.frame = layout.pageRect(index)
        canvas.isScrollEnabled = false
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        // ダークモードのインク色自動反転を止める(用紙色はアプリ側で管理)
        canvas.overrideUserInterfaceStyle = .light
        // Apple Pencil のみ描画(XCUITest 用に ALLOW_FINGER_DRAWING=1 のときだけ指も許可)
        let allowFinger = ProcessInfo.processInfo.environment["ALLOW_FINGER_DRAWING"] == "1"
        canvas.drawingPolicy = allowFinger ? .anyInput : .pencilOnly
        canvas.tool = pkTool
        canvas.drawingGestureRecognizer.isEnabled = (placementTool == nil)
        // ゲート(「開く」ボタン・指×オブジェクトの除外)を差し込む。ページ内判定は不要。
        canvas.drawingTouchGate.forward = canvas.drawingGestureRecognizer.delegate
        canvas.drawingGestureRecognizer.delegate = canvas.drawingTouchGate

        isDistributing = true
        canvas.drawing = index < pageDrawings.count ? pageDrawings[index] : PKDrawing()
        isDistributing = false

        contentView.addSubview(canvas)
        pageCanvases[index] = canvas
        onPageCanvasCreated?(canvas)  // Representable 側で delegate を設定する
    }

    private func recycle(_ canvas: PageCanvasView, at index: Int) {
        // 正本(pageDrawings)は didChange で常に同期済み。回収時は履歴だけ破棄する
        // (オフスクリーンページの Undo 喪失は GoodNotes 同等の割り切り)。
        canvas.delegate = nil
        canvas.undoManager?.removeAllActions(withTarget: canvas)
        canvas.removeFromSuperview()
        pageCanvases[index] = nil
        // attach 中のページを回収したら、再実体化時に onActiveCanvasChanged が再発火するようにする
        if index == lastActivePage { lastActivePage = -1 }
    }

    /// 現在ページのキャンバスを Undo ブリッジへ通知する(変化時のみ)
    private func notifyActiveCanvasIfNeeded() {
        let page = currentPageIndex()
        guard page != lastActivePage, let canvas = pageCanvases[page] else { return }
        lastActivePage = page
        onActiveCanvasChanged?(canvas)
    }

    /// 現在ビューポート中心のページ index
    func currentPageIndex() -> Int {
        guard bounds.width > 0 else { return 0 }
        if layout.scrollsHorizontally {
            return PagePlanner.currentPage(
                contentOffsetX: scrollView.contentOffset.x,
                viewWidth: scrollView.bounds.width,
                zoomScale: scrollView.zoomScale,
                layout: layout
            )
        }
        // 縦スクロール(レガシー): 中心Yに最も近いページ
        let centerY = (scrollView.contentOffset.y + scrollView.bounds.height / 2) / scrollView.zoomScale
        var best = 0
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for i in 0..<max(1, layout.pageCount) {
            let d = abs(layout.pageRect(i).midY - centerY)
            if d < bestDistance { bestDistance = d; best = i }
        }
        return best
    }

    // MARK: - 隣のページを隠す(完全独立表示モード)

    /// アクティブページ以外を机色マスクで覆う(定常時のみ)。スクロール中(isScrollActive)は
    /// 隣ページを見せて滑らかにスライドさせるため一旦外す。マスクはコンテンツ座標の contentView 子
    /// なのでズーム/スクロール追従は自動。ページ実体化(materialize)の後に呼ぶと最前面を保てる。
    private func updateAdjacentPageMask() {
        guard hideAdjacentPages, !isScrollActive, bounds.width > 0, layout.pageCount > 0 else {
            leftMask.isHidden = true
            rightMask.isHidden = true
            return
        }
        let rects = AdjacentPageMask.maskRects(activePage: currentPageIndex(), layout: layout)
        leftMask.frame = rects.left
        rightMask.frame = rects.right
        leftMask.isHidden = rects.left.width <= 0
        rightMask.isHidden = rects.right.width <= 0
        // materialize で後から addSubview されるページキャンバスより前面に保つ
        contentView.bringSubviewToFront(leftMask)
        contentView.bringSubviewToFront(rightMask)
    }

    /// スクロール開始/停止でマスクの一時解除・再適用を切り替える。
    private func setScrollActive(_ active: Bool) {
        guard isScrollActive != active else { return }
        isScrollActive = active
        updateAdjacentPageMask()
    }

    // MARK: - 描画の配布と回収

    /// merged 描画(コンテンツ座標)を分割して全ページへ配布する(外部差し替え時)。
    func distribute(merged: PKDrawing) {
        lastMergedDrawing = merged
        pageDrawings = PagedDrawingStore.split(merged, layout: layout)
        isDistributing = true
        for (index, canvas) in pageCanvases {
            canvas.drawing = index < pageDrawings.count ? pageDrawings[index] : PKDrawing()
        }
        isDistributing = false
    }

    /// レイアウト変更(見開きトグル等)後に、ページローカル正本から merged を作り直して返す。
    /// ページ矩形が動いてもインクはページに追従する(GoodNotes 挙動)。
    /// 外部差し替え判定の基準(lastMergedDrawing)も新レイアウトへ更新する。
    func remergeAfterLayoutChange() -> PKDrawing {
        lastMergedDrawing = PagedDrawingStore.merge(pageDrawings, layout: layout)
        return lastMergedDrawing
    }

    /// ページキャンバスの描画変更を正本へ書き戻し、merged を親へ通知する。
    /// (PKCanvasViewDelegate は Representable の Coordinator が受け、ここへ委譲する)
    func pageDrawingDidChange(_ canvas: PageCanvasView) {
        guard !isDistributing else { return }
        let index = canvas.pageIndex
        guard index >= 0, index < pageDrawings.count else { return }
        pageDrawings[index] = canvas.drawing
        lastMergedDrawing = PagedDrawingStore.merge(pageDrawings, layout: layout)
        onMergedDrawingChanged?(lastMergedDrawing)
    }

    // MARK: - ズーム・フィット

    /// 1ユニット(1ページ or 見開き)が margin 込みで画面に収まるフィット倍率。
    func minimumFitZoom() -> CGFloat {
        guard bounds.width > 0, bounds.height > 0 else { return 0.5 }
        let unitWidth: CGFloat
        let unitHeight = PageMetrics.height
        if layout.isTwoPageLayout {
            unitWidth = 2 * PageMetrics.width + (layout.isHorizontalScroll ? 0 : PageMetrics.gap)
        } else {
            unitWidth = PageMetrics.width
        }
        let availW = max(1, bounds.width - PageMetrics.margin * 2)
        let availH = max(1, bounds.height - PageMetrics.margin * 2)
        return min(availW / unitWidth, availH / unitHeight)
    }

    private func updateZoomLimits() {
        if isZoomLocked {
            let locked = scrollView.zoomScale
            scrollView.minimumZoomScale = locked
            scrollView.maximumZoomScale = locked
        } else {
            scrollView.maximumZoomScale = 3.0
            scrollView.minimumZoomScale = min(minimumFitZoom(), 3.0)
        }
    }

    /// ズームが下限を割っていたら(回転などで下限が上がったら)範囲へ収める
    private func clampZoomIntoLimits() {
        let clamped = min(max(scrollView.zoomScale, scrollView.minimumZoomScale), scrollView.maximumZoomScale)
        if clamped != scrollView.zoomScale {
            scrollView.zoomScale = clamped
            applyContentSize()
        }
    }

    /// 初回レイアウト時: 保存ビューポートがあればクランプして復元、無ければページフィット。
    private func applyInitialViewportOrFit() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        didInitialFit = true
        applyContentSize()
        if let viewport = pendingInitialViewport {
            pendingInitialViewport = nil
            // 保存ズームは現在の min/max へクランプ(#1: 素通し解消)
            let zoom = min(max(viewport.zoomScale, scrollView.minimumZoomScale), scrollView.maximumZoomScale)
            scrollView.zoomScale = zoom
            applyContentSize()
            // 横断方向は中央寄せに任せ、スクロール方向の位置だけ復元する
            let offset = layout.scrollsHorizontally
                ? CGPoint(x: viewport.contentOffset.x, y: -scrollView.contentInset.top)
                : CGPoint(x: -scrollView.contentInset.left, y: viewport.contentOffset.y)
            scrollView.contentOffset = clampOffset(offset)
        } else {
            fitToPage(0, animated: false)
        }
        objectLayer.applyZoom(scrollView.zoomScale)
        backgroundView.applyZoom(scrollView.zoomScale)
        updateVisiblePages()
    }

    /// 指定ページをフィット倍率で画面中央へ(「ページにフィット」・初期表示)。
    func fitToPage(_ page: Int, animated: Bool) {
        guard bounds.width > 0 else { return }
        updateZoomLimits()
        let fit = min(max(minimumFitZoom(), scrollView.minimumZoomScale), scrollView.maximumZoomScale)
        let apply = {
            self.scrollView.zoomScale = fit
            self.applyContentSize()
            self.scrollView.contentOffset = self.offsetForPage(page, zoom: fit)
        }
        if animated {
            UIView.animate(withDuration: 0.25, animations: apply) { _ in
                self.afterProgrammaticViewportChange()
            }
        } else {
            apply()
            afterProgrammaticViewportChange()
        }
    }

    /// ズームを 100% に戻す(既存メニュー互換)。表示中のページ位置は保つ。
    func resetZoomTo100(animated: Bool) {
        let page = currentPageIndex()
        let zoom = min(max(1.0, scrollView.minimumZoomScale), scrollView.maximumZoomScale)
        let apply = {
            self.scrollView.zoomScale = zoom
            self.applyContentSize()
            self.scrollView.contentOffset = self.offsetForPage(page, zoom: zoom)
        }
        if animated {
            UIView.animate(withDuration: 0.25, animations: apply) { _ in
                self.afterProgrammaticViewportChange()
            }
        } else {
            apply()
            afterProgrammaticViewportChange()
        }
    }

    /// 指定ページ先頭へスクロールする(しおり/目次ジャンプ)。
    func scrollToPage(_ page: Int, completion: @escaping () -> Void) {
        let target = clampOffset(offsetForPage(page, zoom: scrollView.zoomScale))
        NSLog("PagedDBG scrollToPage %d zoom=%.3f raw=%@ clamped=%@ contentSize=%@ bounds=%@",
              page, scrollView.zoomScale,
              NSCoder.string(for: offsetForPage(page, zoom: scrollView.zoomScale)),
              NSCoder.string(for: target),
              NSCoder.string(for: scrollView.contentSize),
              NSCoder.string(for: scrollView.bounds.size))
        // プログラムスクロール中の誤タッチ(PencilKit の長押し誤検知)を防ぐ
        scrollView.isUserInteractionEnabled = false
        UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseInOut]) {
            self.scrollView.contentOffset = target
        } completion: { _ in
            self.scrollView.isUserInteractionEnabled = true
            self.afterProgrammaticViewportChange()
            completion()
        }
    }

    private func afterProgrammaticViewportChange() {
        objectLayer.applyZoom(scrollView.zoomScale)
        backgroundView.applyZoom(scrollView.zoomScale)
        updateVisiblePages()
        emitViewport()
    }

    /// ページ先頭表示の contentOffset(横は PagePlanner のスナップと同一算出、縦は上端寄せ)
    private func offsetForPage(_ page: Int, zoom: CGFloat) -> CGPoint {
        if layout.scrollsHorizontally {
            let x = PagePlanner.scrollOffsetX(
                toPage: page, zoomScale: zoom, layout: layout,
                margin: PageMetrics.margin, viewWidth: scrollView.bounds.width
            )
            return CGPoint(x: x, y: -scrollView.contentInset.top)
        }
        return CGPoint(
            x: -scrollView.contentInset.left,
            y: layout.pageRect(page).minY * zoom - PageMetrics.margin
        )
    }

    /// 横断方向(スクロールと直交する側)を中央寄せする contentInset
    private func updateCenteringInset() {
        let size = layout.contentSize
        let zoom = scrollView.zoomScale
        if layout.scrollsHorizontally {
            let contentH = size.height * zoom
            let vInset = max(0, (scrollView.bounds.height - contentH) / 2)
            scrollView.contentInset = UIEdgeInsets(
                top: max(vInset, PageMetrics.margin), left: PageMetrics.margin,
                bottom: max(vInset, PageMetrics.margin), right: PageMetrics.margin
            )
        } else {
            let contentW = size.width * zoom
            let hInset = max(0, (scrollView.bounds.width - contentW) / 2)
            scrollView.contentInset = UIEdgeInsets(
                top: PageMetrics.margin, left: max(hInset, PageMetrics.margin),
                bottom: PageMetrics.margin, right: max(hInset, PageMetrics.margin)
            )
        }
    }

    private func clampOffset(_ offset: CGPoint) -> CGPoint {
        let inset = scrollView.contentInset
        let minX = -inset.left
        let minY = -inset.top
        let maxX = max(minX, scrollView.contentSize.width - scrollView.bounds.width + inset.right)
        let maxY = max(minY, scrollView.contentSize.height - scrollView.bounds.height + inset.bottom)
        return CGPoint(x: min(max(offset.x, minX), maxX), y: min(max(offset.y, minY), maxY))
    }

    // MARK: - UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { contentView }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        // めくり中は隣ページを見せて滑らかにスライドさせる(定常時に再遮蔽)
        setScrollActive(true)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateVisiblePages()
        emitViewport()
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        objectLayer.applyZoom(scrollView.zoomScale)
        backgroundView.applyZoom(scrollView.zoomScale)
        updateCenteringInset()
        updateVisiblePages()
        emitViewport()
    }

    private func emitViewport() {
        onViewportChanged?(
            CanvasViewport(contentOffset: scrollView.contentOffset, zoomScale: scrollView.zoomScale)
        )
    }

    /// スクロール限界より右(横)/下(縦)へバウンスした量。末尾ページ追加の判定に使う。
    private func trailingOverscroll(_ scrollView: UIScrollView) -> CGFloat {
        if layout.scrollsHorizontally {
            let maxX = max(-scrollView.contentInset.left,
                           scrollView.contentSize.width - scrollView.bounds.width + scrollView.contentInset.right)
            return scrollView.contentOffset.x - maxX
        }
        let maxY = max(-scrollView.contentInset.top,
                       scrollView.contentSize.height - scrollView.bounds.height + scrollView.contentInset.bottom)
        return scrollView.contentOffset.y - maxY
    }

    /// 末尾を超えて一定量めくったら、指を離した時点でページを1枚追加する(GoodNotes 風)。
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        let threshold = min(scrollView.bounds.width * 0.15, 140)
        if !didRequestPageAppend, trailingOverscroll(scrollView) > threshold {
            didRequestPageAppend = true  // ページ数増加の反映時に解除される
            onAppendPage?()
        }
        // 減速へ移らずここで止まる場合は停止確定。減速するなら scrollViewDidEndDecelerating で再遮蔽する。
        if !decelerate { setScrollActive(false) }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        setScrollActive(false)  // 慣性停止 → 隣ページを再遮蔽
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        setScrollActive(false)  // プログラムスクロールのアニメ停止 → 再遮蔽
    }

    /// カスタムページスナップ(横スクロールのみ)。フリック速度とズームを考慮して
    /// 最寄りページへスナップする。isPagingEnabled は倍率次第でズレるため使わない。
    func scrollViewWillEndDragging(
        _ scrollView: UIScrollView,
        withVelocity velocity: CGPoint,
        targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        guard layout.scrollsHorizontally, layout.pageCount > 0 else { return }
        let currentPage = PagePlanner.currentPage(
            contentOffsetX: scrollView.contentOffset.x,
            viewWidth: scrollView.bounds.width,
            zoomScale: scrollView.zoomScale,
            layout: layout
        )
        var targetPage = currentPage
        let velocityThreshold: CGFloat = 0.2
        if velocity.x > velocityThreshold {
            targetPage = min(layout.pageCount - 1, currentPage + 1)
        } else if velocity.x < -velocityThreshold {
            targetPage = max(0, currentPage - 1)
        }
        let targetX = PagePlanner.scrollOffsetX(
            toPage: targetPage, zoomScale: scrollView.zoomScale, layout: layout,
            margin: PageMetrics.margin, viewWidth: scrollView.bounds.width
        )
        targetContentOffset.pointee = CGPoint(x: targetX, y: scrollView.contentOffset.y)
    }

    // MARK: - タップ(選択解除・タップ配置)

    @objc private func handleBackgroundTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: objectLayer)
        if let tool = placementTool {
            // 配置は用紙(ページ矩形)内のみ許可する
            let onPage = (0..<max(1, layout.pageCount)).contains { layout.pageRect($0).contains(point) }
            if onPage, let item = onPlaceObject?(tool, point) {
                // タップのタッチ文脈内で生成・編集開始する(becomeFirstResponder が
                // タッチ文脈外になるとソフトキーボードが出ないため、同期実行が必須)。
                objectLayer.placeAndFocus(item: item)
            }
            return
        }
        objectLayer.handleBackgroundTap(at: point)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool { true }
}
