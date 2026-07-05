import SwiftUI
import PencilKit
import UIKit
import CoreData

/// タブごとのビューポート(スクロール位置・ズーム)。OpenNotesSession が保持する。
struct CanvasViewport {
    var contentOffset: CGPoint
    var zoomScale: CGFloat
}

/// 通常ノート(固定ページ形式)のページ寸法。A4 相当(幅800 x 高さ1130)を縦に並べる。
enum PageMetrics {
    static let width: CGFloat = 800
    static let height: CGFloat = 1130
    static let gap: CGFloat = 20        // ページ間のすき間
    static let margin: CGFloat = 24     // 上下のグレー余白(contentInset)

    /// pageCount 枚を縦に並べたときの総高さ
    static func totalHeight(pageCount: Int) -> CGFloat {
        height * CGFloat(pageCount) + gap * CGFloat(max(0, pageCount - 1))
    }

    /// index ページ目の矩形(コンテンツ座標)
    static func pageRect(_ index: Int) -> CGRect {
        CGRect(x: 0, y: CGFloat(index) * (height + gap), width: width, height: height)
    }
}

/// PKCanvasView を「巨大キャンバス + ズーム」として構成する UIViewRepresentable。
/// PKCanvasView は UIScrollView のサブクラスなので、巨大な contentSize と
/// ズーム設定だけで疑似無限キャンバス(100,000 x 100,000 pt)を実現する。
/// ズームすると描画・背景パターンごとスケーリングされる(要件②)。
struct CanvasRepresentable: UIViewRepresentable {
    static let canvasSize: CGFloat = 100_000

    @Binding var drawing: PKDrawing
    let pkTool: PKTool
    let isSelectMode: Bool
    /// 図形認識アシスト(要件): 描き終えたストロークを直線・楕円・矩形へ自動置換するか
    let isShapeAssistEnabled: Bool
    let backgroundStyle: CanvasBackgroundStyle
    let pageColor: CanvasPageColor
    /// ノート形式(無限キャンバス / 通常ノート)
    let noteType: CanvasNoteType
    /// 通常ノートのページ数
    let pageCount: Int
    let objects: [CanvasObject]
    /// 挿入直後に選択(テキストなら編集開始)するオブジェクト
    let autoFocusObjectID: NSManagedObjectID?
    let initialViewport: CanvasViewport?
    let onDrawingChanged: () -> Void
    let onViewportChanged: (CanvasViewport) -> Void
    let onObjectFrameChanged: (NSManagedObjectID, CGRect) -> Void
    let onObjectTextChanged: (NSManagedObjectID, String) -> Void
    let onObjectDeleted: (NSManagedObjectID) -> Void
    /// Undo/Redo ブリッジなどにキャンバスを渡す
    let onCanvasReady: (PKCanvasView) -> Void

    /// ノート形式に応じたキャンバスのコンテンツサイズ
    private var contentSize: CGSize {
        switch noteType {
        case .infinite:
            return CGSize(width: Self.canvasSize, height: Self.canvasSize)
        case .paged:
            return CGSize(width: PageMetrics.width, height: PageMetrics.totalHeight(pageCount: pageCount))
        }
    }

    /// コンテンツサイズ・背景レイヤーのフレーム・ページ描画を現在の形式へ合わせる。
    /// make と update の両方から呼ぶ(冪等)。
    private func applyLayout(to container: CanvasContainerUIView) {
        let size = contentSize
        container.canvasView.contentSize = size
        container.patternView.frame = CGRect(origin: .zero, size: size)
        container.objectLayer.frame = CGRect(origin: .zero, size: size)
        // 通常ノートは横スクロールさせない(A4幅に固定)
        container.canvasView.alwaysBounceHorizontal = false
        container.patternView.configure(
            noteType: noteType, pageCount: pageCount,
            style: backgroundStyle, pageColor: pageColor
        )
    }

    func makeUIView(context: Context) -> CanvasContainerUIView {
        let container = CanvasContainerUIView()
        let canvas = container.canvasView
        canvas.drawing = drawing
        context.coordinator.lastStrokeCount = drawing.strokes.count
        canvas.tool = pkTool
        canvas.delegate = context.coordinator
        // はみ出し領域の色: 無限は用紙色、通常ノートは机のグレー
        container.backgroundColor = containerBackgroundColor
        container.objectLayer.pageColor = pageColor
        applyLayout(to: container)
        context.coordinator.lastPageCount = pageCount
        context.coordinator.attach(to: container)
        onCanvasReady(canvas)

        // オブジェクト操作の書き戻し(常に最新の parent を経由させる)
        let coordinator = context.coordinator
        container.objectLayer.onFrameChanged = { [weak coordinator] id, frame in
            coordinator?.parent.onObjectFrameChanged(id, frame)
        }
        container.objectLayer.onTextChanged = { [weak coordinator] id, text in
            coordinator?.parent.onObjectTextChanged(id, text)
        }
        container.objectLayer.onDelete = { [weak coordinator] id in
            coordinator?.parent.onObjectDeleted(id)
        }

        // 初期ビューポート(保存がなければ形式ごとの初期位置)
        DispatchQueue.main.async {
            if let viewport = initialViewport {
                canvas.zoomScale = viewport.zoomScale
                canvas.contentOffset = viewport.contentOffset
            } else if noteType == .paged {
                fitPagedWidth(canvas)  // A4幅を画面幅にフィット + 先頭ページ上端
            } else {
                let size = Self.canvasSize
                canvas.contentOffset = CGPoint(
                    x: (size - canvas.bounds.width) / 2,
                    y: (size - canvas.bounds.height) / 2
                )
            }
            if noteType == .paged { centerPagedContent(canvas) }
            // 復元したズームをスナップ閾値・背景タイル解像度へ反映
            container.objectLayer.applyZoom(canvas.zoomScale)
            container.patternView.applyZoom(canvas.zoomScale)
        }
        return container
    }

    /// 通常ノートの机(背景)色。無限は用紙色
    private var containerBackgroundColor: UIColor {
        noteType == .paged ? .systemGray5 : pageColor.backgroundUIColor
    }

    /// A4 幅(800pt)が画面幅に収まるようズームフィットし、先頭ページ上端へ合わせる
    private func fitPagedWidth(_ canvas: PKCanvasView) {
        guard canvas.bounds.width > 0 else { return }
        let fit = min(
            canvas.maximumZoomScale,
            max(canvas.minimumZoomScale, canvas.bounds.width * 0.94 / PageMetrics.width)
        )
        canvas.zoomScale = fit
        canvas.contentOffset = CGPoint(x: 0, y: -PageMetrics.margin)
    }

    /// 通常ノートを横方向に中央寄せ(グレー余白を左右に出す)
    private func centerPagedContent(_ canvas: PKCanvasView) {
        let contentW = PageMetrics.width * canvas.zoomScale
        let sideInset = max(0, (canvas.bounds.width - contentW) / 2)
        canvas.contentInset = UIEdgeInsets(
            top: PageMetrics.margin, left: sideInset,
            bottom: PageMetrics.margin, right: sideInset
        )
    }

    func updateUIView(_ container: CanvasContainerUIView, context: Context) {
        context.coordinator.parent = self
        let canvas = container.canvasView
        canvas.tool = pkTool
        container.backgroundColor = containerBackgroundColor
        container.isSelectMode = isSelectMode
        container.objectLayer.backgroundStyle = backgroundStyle
        container.objectLayer.pageColor = pageColor
        applyLayout(to: container)  // 背景スタイル・用紙色・ページ数の変化を反映

        // ページが増えたら、新しいページ(最下段)へ滑らかにスクロール
        if noteType == .paged, pageCount > context.coordinator.lastPageCount {
            let targetY = PageMetrics.pageRect(pageCount - 1).minY * canvas.zoomScale - PageMetrics.margin
            centerPagedContent(canvas)
            canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: targetY), animated: true)
        }
        context.coordinator.lastPageCount = pageCount

        context.coordinator.syncObjects(into: container.objectLayer)
        context.coordinator.handleAutoFocus(in: container.objectLayer)
        // モデル側から描画が差し替わった場合のみ反映(描画中の上書きを防ぐ)
        if !context.coordinator.isCanvasSourceOfTruth, canvas.drawing != drawing {
            canvas.drawing = drawing
            // プログラムでの差し替えを新規ストローク追加と誤認しないよう基準数を更新
            context.coordinator.lastStrokeCount = drawing.strokes.count
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var parent: CanvasRepresentable
        var isCanvasSourceOfTruth = false
        /// 直近に処理したストローク数。新規ストローク追加(+1)のときだけ図形認識を試みる
        var lastStrokeCount = 0
        /// 直近のページ数。増えたらページ追加とみなしてスクロールする(通常ノート)
        var lastPageCount = 1
        /// 図形置換で drawing を差し替える間の再入を無視するフラグ(無限再描画ループ防止)
        private var isReplacingShape = false
        /// スクロール/ズームのデリゲート処理でレイヤーへアクセスするための弱参照
        private weak var container: CanvasContainerUIView?
        /// image / pdf のレンダリング結果キャッシュ(payload のデコードは1回だけ)
        private var imageCache: [NSManagedObjectID: UIImage] = [:]
        private var autoFocusHandledID: NSManagedObjectID?

        init(_ parent: CanvasRepresentable) {
            self.parent = parent
        }

        /// 背景・オブジェクトレイヤーはキャンバス(スクロールビュー)の内部に
        /// コンテンツ全体サイズで配置され、スクロール/ズーム追従は iOS のスクロール合成
        /// (GPU 加速)が行う。KVO や手動再配置は廃止し、デリゲートでは軽量な副作用のみ扱う。
        func attach(to container: CanvasContainerUIView) {
            self.container = container
        }

        // MARK: - スクロール/ズーム(UIScrollViewDelegate 経由。KVO は使わない)

        /// スクロール中の追従はスクロールビューが行うため、ここではビューポート保存だけ(軽量)。
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            parent.onViewportChanged(
                CanvasViewport(contentOffset: scrollView.contentOffset, zoomScale: scrollView.zoomScale)
            )
        }

        /// ズーム時のみ、スナップ閾値用の倍率更新と背景タイルの高解像度化を行う(スクロールには不干渉)。
        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            container?.objectLayer.applyZoom(scrollView.zoomScale)
            container?.patternView.applyZoom(scrollView.zoomScale)
            // 通常ノートはズームしても A4 を中央に保つ(左右のグレー余白を調整)
            if parent.noteType == .paged, let canvas = container?.canvasView {
                let contentW = PageMetrics.width * scrollView.zoomScale
                let sideInset = max(0, (scrollView.bounds.width - contentW) / 2)
                canvas.contentInset = UIEdgeInsets(
                    top: PageMetrics.margin, left: sideInset,
                    bottom: PageMetrics.margin, right: sideInset
                )
            }
            parent.onViewportChanged(
                CanvasViewport(contentOffset: scrollView.contentOffset, zoomScale: scrollView.zoomScale)
            )
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            // 図形認識アシスト: 直前に「1本だけ増えた」インクストロークを図形へ置換する。
            // 消しゴム(ストローク分割で数が増減)や選択操作を巻き込まないよう
            // インクツール中かつストローク数が +1 のときだけ判定する。
            if !isReplacingShape,
               parent.isShapeAssistEnabled,
               parent.pkTool is PKInkingTool,
               canvasView.drawing.strokes.count == lastStrokeCount + 1,
               let last = canvasView.drawing.strokes.last,
               let cleanStroke = ShapeRecognizer.cleanShape(from: last) {
                var newDrawing = canvasView.drawing
                newDrawing.strokes.removeLast()
                newDrawing.strokes.append(cleanStroke)
                isReplacingShape = true
                canvasView.drawing = newDrawing  // 同期再入しても上のフラグで無視される
                isReplacingShape = false
            }
            lastStrokeCount = canvasView.drawing.strokes.count

            isCanvasSourceOfTruth = true
            parent.drawing = canvasView.drawing
            parent.onDrawingChanged()
            isCanvasSourceOfTruth = false
        }

        // MARK: - オブジェクト同期(要件③)

        @MainActor
        func syncObjects(into layer: ObjectLayerUIView) {
            let items = parent.objects
                .filter { !$0.isDeleted && $0.managedObjectContext != nil }
                .sorted { $0.zOrder < $1.zOrder }
                .map { object -> CanvasObjectItem in
                    var image: UIImage?
                    if object.objectKind != .text {
                        if let cached = imageCache[object.objectID] {
                            image = cached
                        } else if let rendered = object.makeDisplayImage() {
                            imageCache[object.objectID] = rendered
                            image = rendered
                        }
                    }
                    return CanvasObjectItem(
                        id: object.objectID,
                        kind: object.objectKind,
                        frame: object.contentFrame,
                        text: object.text ?? "",
                        fontSize: object.fontSize > 0 ? object.fontSize : 24,
                        image: image
                    )
                }
            layer.sync(items: items)
        }

        /// 挿入直後のオブジェクトを選択し、テキストなら編集を開始する(1回だけ)
        @MainActor
        func handleAutoFocus(in layer: ObjectLayerUIView) {
            guard let id = parent.autoFocusObjectID, id != autoFocusHandledID else { return }
            autoFocusHandledID = id
            layer.focus(on: id)
        }
    }
}

/// 背景パターン(下) + オブジェクトレイヤー(中) を PKCanvasView(スクロールビュー)の
/// コンテンツ内部にコンテンツ全体サイズで重ね、インク(PKCanvasView 自身の描画)は最前面に置く。
/// これによりスクロール/ズーム追従は iOS のスクロール合成(GPU 加速)が完全同期で行い、
/// メインスレッドでの逐次再配置(旧 KVO 方式)が不要になる。
/// インクは常にオブジェクトの上に描かれる(画像や PDF の上に手書き注釈できる)。
/// PKCanvasView は既定で自身を1つのアクセシビリティ要素として扱い、内部へ差し込んだ
/// サブビュー(オブジェクトレイヤー)を VoiceOver / UI テストから隠してしまう。
/// 既定のサブビュー走査に戻し、キャンバス上のテキスト等オブジェクトを露出させる。
final class ObjectAccessibleCanvasView: PKCanvasView {
    /// 選択モード時にタッチを転送する先(オブジェクトレイヤー)。
    weak var objectLayer: ObjectLayerUIView?

    override var isAccessibilityElement: Bool {
        get { false }
        set {}
    }
    override var accessibilityElements: [Any]? {
        get { nil }
        set {}
    }

    /// オブジェクトレイヤーはインク描画面より下にあり、通常はタッチが届かない。
    /// 選択モード中はここでオブジェクトへのヒットを優先し、移動・長押し・タップ選択を可能にする。
    /// (スクロール用ジェスチャはスクロールビュー自身に付いているので2本指スクロールは維持される)
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if let objectLayer, objectLayer.isSelectMode {
            let converted = convert(point, to: objectLayer)
            if let hit = objectLayer.hitTest(converted, with: event), hit !== objectLayer {
                return hit
            }
        }
        return super.hitTest(point, with: event)
    }
}

final class CanvasContainerUIView: UIView, UIGestureRecognizerDelegate {
    let canvasView = ObjectAccessibleCanvasView()
    let patternView = BackgroundPatternUIView()
    let objectLayer = ObjectLayerUIView()

    /// 選択モード(要件③)。描画ジェスチャを無効化し、単指はオブジェクト操作へ回す。
    /// オブジェクトがスクロールビュー内部にあるため、単指ドラッグでの誤スクロールを防ぐべく
    /// 選択モード中のスクロールは2本指に限定する(描画モードのスクロールと同じ操作感)。
    var isSelectMode = false {
        didSet {
            guard isSelectMode != oldValue else { return }
            objectLayer.isSelectMode = isSelectMode
            canvasView.drawingGestureRecognizer.isEnabled = !isSelectMode
            canvasView.panGestureRecognizer.minimumNumberOfTouches = isSelectMode ? 2 : 1
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        let canvasSize = CanvasRepresentable.canvasSize

        // PencilKit はダークモード時にインク色を自動反転する(黒⇄白)が、
        // 用紙色(白/黒)はアプリ側で管理しているため反転を止め、選んだ色のまま描く
        overrideUserInterfaceStyle = .light

        canvasView.drawingPolicy = .anyInput  // Apple Pencil + 指の両方で描画(要件③)
        // 描画面を透過にして、最背面へ差し込む背景・オブジェクトを見せる(インクは常に上)。
        // 用紙色はコンテナ側で塗る(はみ出し/バウンス領域もこれで埋まる)。
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        canvasView.contentSize = CGSize(width: canvasSize, height: canvasSize)
        canvasView.minimumZoomScale = 0.1
        canvasView.maximumZoomScale = 5.0
        canvasView.bouncesZoom = true
        // オブジェクトがスクロールビュー内部にあるため、長押し等のジェスチャが
        // スクロールの遅延タッチに邪魔されないよう、タッチを即座に子ビューへ渡す
        canvasView.delaysContentTouches = false
        addSubview(canvasView)

        // 背景 → オブジェクトの順でキャンバス最背面へ差し込む。
        // インク描画は PKCanvasView 自身が最前面に載せるため、注釈は常にオブジェクトの上。
        let contentFrame = CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize)
        patternView.frame = contentFrame
        objectLayer.frame = contentFrame
        canvasView.insertSubview(patternView, at: 0)
        canvasView.insertSubview(objectLayer, aboveSubview: patternView)
        canvasView.objectLayer = objectLayer  // 選択モードのタッチ転送先

        // オブジェクトのない場所のタップで選択解除(スクロール等の邪魔はしない)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleBackgroundTap(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        addGestureRecognizer(tap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 背景・オブジェクトはコンテンツ座標に固定配置(スクロールビューが追従させる)。
        // ここで動かすのはビューポート = キャンバス本体のみ。
        canvasView.frame = bounds
    }

    @objc private func handleBackgroundTap(_ gesture: UITapGestureRecognizer) {
        objectLayer.handleBackgroundTap(at: gesture.location(in: objectLayer))
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool { true }
}

/// 方眼 / ドットを描く背景ビュー。キャンバス(スクロールビュー)のコンテンツ内部に
/// コンテンツ全体サイズで置かれ、スクロール/ズーム追従はスクロール合成が担う。
///
/// - **無限キャンバス**: ビュー全面に 40pt タイルの `UIColor(patternImage:)` を敷き詰める。
///   巨大ビューでも一枚絵のバッキングストアを持たず、逐次再描画も発生しない。
/// - **通常ノート(paged)**: ビュー全面を机のグレーにし、各ページ矩形(800x1130)だけを
///   用紙色 + 影 + 内側パターンのサブビューとして並べる。ページ枚数はサブビューで表す。
final class BackgroundPatternUIView: UIView {
    /// コンテンツ空間でのタイル間隔(= 方眼の1マス)
    private static let spacing: CGFloat = 40

    var style: CanvasBackgroundStyle = .blank {
        didSet { if style != oldValue, !isConfiguring { rebuild() } }
    }
    /// 用紙の色。白紙は黒い罫線・ドット、黒紙は白(要件: ノート作成時に選択)
    var pageColor: CanvasPageColor = .white {
        didSet { if pageColor != oldValue, !isConfiguring { rebuild() } }
    }
    private var noteType: CanvasNoteType = .infinite
    private var pageCount: Int = 1
    /// configure() 中は didSet の逐次 rebuild を抑止し、最後に一度だけ再構築する
    private var isConfiguring = false
    /// タイルのレンダリング解像度。ズームインで拡大されても線がボケないよう倍率を上げる
    private var tileScale: CGFloat = UIScreen.main.scale
    /// paged 用のページビュー(1枚 = 1ページ)
    private var pageViews: [UIView] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false  // タッチはインク/オブジェクトへ通す
        clipsToBounds = false              // ページの影がすき間へ落ちるように
        rebuild()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// ノート形式・ページ数・スタイル・用紙色をまとめて反映(変化時のみ再構築)。
    func configure(noteType: CanvasNoteType, pageCount: Int, style: CanvasBackgroundStyle, pageColor: CanvasPageColor) {
        let changed = noteType != self.noteType || pageCount != self.pageCount
            || style != self.style || pageColor != self.pageColor
        guard changed else { return }
        isConfiguring = true
        self.noteType = noteType
        self.pageCount = pageCount
        self.style = style
        self.pageColor = pageColor
        isConfiguring = false
        rebuild()
    }

    /// ズーム時のみ呼ばれ、拡大率に見合う解像度でタイルを焼き直す(スクロールには不干渉)。
    func applyZoom(_ zoom: CGFloat) {
        let target = min(max(UIScreen.main.scale * zoom, UIScreen.main.scale), 12)
        guard abs(target - tileScale) > 0.5 else { return }
        tileScale = target
        rebuild()
    }

    private func rebuild() {
        switch noteType {
        case .infinite:
            pageViews.forEach { $0.removeFromSuperview() }
            pageViews.removeAll()
            backgroundColor = (style == .blank)
                ? pageColor.backgroundUIColor
                : UIColor(patternImage: makeTile())
        case .paged:
            backgroundColor = .systemGray5  // 机(背景)のグレー
            rebuildPages()
        }
    }

    /// paged: ページ矩形を用紙色 + 影 + 内側パターンのサブビューとして並べ直す。
    private func rebuildPages() {
        pageViews.forEach { $0.removeFromSuperview() }
        pageViews.removeAll()

        let pageBackground: UIColor = (style == .blank)
            ? pageColor.backgroundUIColor
            : UIColor(patternImage: makeTile())

        for index in 0..<max(1, pageCount) {
            let page = UIView(frame: PageMetrics.pageRect(index))
            page.backgroundColor = pageBackground
            // 用紙らしい影と薄い境界線
            page.layer.shadowColor = UIColor.black.cgColor
            page.layer.shadowOpacity = 0.18
            page.layer.shadowRadius = 6
            page.layer.shadowOffset = CGSize(width: 0, height: 2)
            page.layer.shadowPath = UIBezierPath(rect: page.bounds).cgPath
            page.layer.borderColor = UIColor.black.withAlphaComponent(0.08).cgColor
            page.layer.borderWidth = 0.5
            addSubview(page)
            pageViews.append(page)
        }
    }

    /// 1マス分のタイル画像。タイルには用紙色の下地も含めるので、これ一枚で全面を塗れる。
    private func makeTile() -> UIImage {
        let spacing = Self.spacing
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = tileScale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: spacing, height: spacing), format: format
        )
        return renderer.image { ctx in
            let c = ctx.cgContext
            pageColor.backgroundUIColor.setFill()
            c.fill(CGRect(x: 0, y: 0, width: spacing, height: spacing))

            switch style {
            case .grid:
                // 上辺・左辺を引くと、タイリングで連続した方眼になる
                pageColor.patternUIColor.setStroke()
                c.setLineWidth(0.5)
                c.stroke(CGRect(x: 0, y: 0, width: spacing, height: spacing))
            case .dots:
                // マス中央にドット(40pt グリッドのドット背景)
                pageColor.patternUIColor.setFill()
                c.fillEllipse(in: CGRect(x: spacing / 2 - 1.5, y: spacing / 2 - 1.5, width: 3, height: 3))
            case .blank:
                break
            }
        }
    }
}
