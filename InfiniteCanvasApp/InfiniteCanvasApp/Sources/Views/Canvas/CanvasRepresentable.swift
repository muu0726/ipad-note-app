import SwiftUI
import PencilKit
import UIKit
import CoreData

/// タブごとのビューポート(スクロール位置・ズーム)。OpenNotesSession が保持する。
struct CanvasViewport {
    var contentOffset: CGPoint
    var zoomScale: CGFloat
}

/// 通常ノート(固定ページ形式)のページ寸法。A4 相当(幅800 x 高さ1130)。
enum PageMetrics {
    static let width: CGFloat = 800
    static let height: CGFloat = 1130
    static let gap: CGFloat = 20        // ページ間のすき間
    static let margin: CGFloat = 24     // スクロール方向の端のグレー余白(contentInset)

    /// pageCount 枚を縦一列に並べたときの総高さ(既定レイアウトの後方互換ヘルパー)
    static func totalHeight(pageCount: Int) -> CGFloat {
        height * CGFloat(pageCount) + gap * CGFloat(max(0, pageCount - 1))
    }

    /// index ページ目の矩形(縦一列・既定レイアウト。PDF 背景生成などが使う)
    static func pageRect(_ index: Int) -> CGRect {
        CGRect(x: 0, y: CGFloat(index) * (height + gap), width: width, height: height)
    }
}

/// 通常ノートのページ配置を「見開き(1/2ページ)× スクロール方向(縦/横)」の4通りで
/// 計算する電卓。各ページの矩形とコンテンツ全体サイズを求める。
/// UIKit 非依存の純ロジックなのでユニットテストで担保する。
///
/// - 縦スクロール・1ページ: 縦一列(X=0固定、Y方向へ展開)
/// - 縦スクロール・2ページ: 横に2枚並べ、下へ段送り(2列グリッド)
/// - 横スクロール・1ページ: 横一列(Y=0固定、X方向へ展開)
/// - 横スクロール・2ページ: 見開き(左右を隙間なく密着)を1ユニットとし、右へユニットを増やす
struct PagedLayoutCalculator: Equatable {
    let pageCount: Int
    let isTwoPageLayout: Bool
    let isHorizontalScroll: Bool

    private var count: Int { max(1, pageCount) }

    /// index ページ目の矩形(コンテンツ座標)
    func pageRect(_ index: Int) -> CGRect {
        let w = PageMetrics.width, h = PageMetrics.height, gap = PageMetrics.gap
        let x: CGFloat
        let y: CGFloat
        if isHorizontalScroll {
            if isTwoPageLayout {
                // 見開き: 2枚を密着させて1ユニット、ユニット間に gap
                let unit = index / 2, side = index % 2
                x = CGFloat(unit) * (2 * w + gap) + CGFloat(side) * w
            } else {
                x = CGFloat(index) * (w + gap)
            }
            y = 0
        } else {
            if isTwoPageLayout {
                x = CGFloat(index % 2) * (w + gap)
                y = CGFloat(index / 2) * (h + gap)
            } else {
                x = 0
                y = CGFloat(index) * (h + gap)
            }
        }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// 全ページ矩形の外接サイズ(= キャンバスのコンテンツサイズ)
    var contentSize: CGSize {
        var maxX: CGFloat = 0, maxY: CGFloat = 0
        for index in 0..<count {
            let rect = pageRect(index)
            maxX = max(maxX, rect.maxX)
            maxY = max(maxY, rect.maxY)
        }
        return CGSize(width: maxX, height: maxY)
    }

    /// スクロール方向(true=横 / false=縦)
    var scrollsHorizontally: Bool { isHorizontalScroll }
}


/// PKCanvasView を「動的に拡張するキャンバス + ズーム」として構成する UIViewRepresentable。
/// PKCanvasView は UIScrollView のサブクラスなので、contentSize とズーム設定だけで
/// 無限キャンバスを実現する。ワールドサイズ(contentSize の一辺)はコンテンツの外接矩形に
/// 合わせて `Coordinator.worldSize` が動的に伸ばす(`DynamicCanvasBounds` 参照)。
/// 右・下方向は contentSize を伸ばすだけ、左・上方向は原点リベース(座標系全体の平行移動)で
/// 対応するため、固定サイズの壁に当たることはない。
/// ズームすると描画・背景パターンごとスケーリングされる(要件②)。
struct CanvasRepresentable: UIViewRepresentable {
    @Binding var drawing: PKDrawing
    let pkTool: PKTool
    let isSelectMode: Bool
    /// 投げ縄選択モード(`.lasso` ツール中)。true のとき PencilKit の描画/投げ縄ジェスチャを
    /// 無効化し、自前ジェスチャでインク+オブジェクトを一括選択する(infinite ノートのみ)。
    let isLassoSelectionMode: Bool
    /// タップ位置配置モードのツール(.text / .todo)。nil のときは通常(描画/選択)。
    let placementTool: CanvasTool?
    /// 配置モードでキャンバスをタップしたとき(ツール, コンテンツ座標)。
    /// オブジェクトを同期生成して item を返す(nil で配置なし)。
    let onPlaceObject: (CanvasTool, CGPoint) -> CanvasObjectItem?
    /// 図形認識アシスト(要件): 描き終えたストロークを直線・楕円・矩形へ自動置換するか
    let isShapeAssistEnabled: Bool
    let backgroundStyle: CanvasBackgroundStyle
    let pageColor: CanvasPageColor
    /// ノート形式(無限キャンバス / 通常ノート)
    let noteType: CanvasNoteType
    /// 通常ノートのページ数
    let pageCount: Int
    /// 通常ノート: 見開き2ページ表示か
    let isTwoPageLayout: Bool
    /// 通常ノート: 横スクロール(ページめくり)か
    let isHorizontalScroll: Bool
    /// ズームロック: true のときピンチズームを禁止する(min/max を現在値に固定)
    let isZoomLocked: Bool
    let objects: [CanvasObject]
    /// 挿入直後に選択(テキストなら編集開始)するオブジェクト
    let autoFocusObjectID: NSManagedObjectID?
    let initialViewport: CanvasViewport?
    let onDrawingChanged: () -> Void
    let onViewportChanged: (CanvasViewport) -> Void
    let onObjectFrameChanged: (NSManagedObjectID, CGRect) -> Void
    /// 回転確定の保存(rotation 角・Undo あり)
    let onObjectRotationChanged: (NSManagedObjectID, CGFloat) -> Void
    let onObjectTextChanged: (NSManagedObjectID, String) -> Void
    /// Todoリストの項目変更の保存(Undo あり)
    let onObjectTodoChanged: (NSManagedObjectID, [TodoItem]) -> Void
    let onObjectDeleted: (NSManagedObjectID) -> Void
    /// フォントサイズ変更に伴う高さ自動調整の保存(Undo なし)
    let onObjectAutoHeightChanged: (NSManagedObjectID, CGFloat) -> Void
    /// テキスト選択の変化(ツールバーのフォントサイズ UI 用)。テキスト以外/未選択は nil
    let onTextSelectionChanged: ((objectID: NSManagedObjectID, fontSize: CGFloat)?) -> Void
    /// 投げ縄でインクを移動したとき(元の領域, 移動量)。領域に重なるオブジェクトも移動する
    let onLassoObjectsMoved: (CGRect, CGVector) -> Void
    /// 投げ縄でインクを削除したとき(削除された領域)。領域に重なるオブジェクトも削除する
    let onLassoObjectsDeleted: (CGRect) -> Void
    /// 無限キャンバスの原点リベースで座標系全体が平行移動したとき(delta)。
    /// オブジェクト(Core Data)側の x/y にも同じ量を加算して座標を合わせる(内部実装の詳細のため Undo 対象外)。
    let onCanvasRebased: (CGVector) -> Void
    /// ノートリンクのダブルタップでリンク先ノートを開く要求
    let onNoteLinkActivated: (NSManagedObjectID) -> Void
    /// 図形のダブルタップで編集ポップオーバーを開く要求
    let onObjectShapeEditRequested: (NSManagedObjectID) -> Void
    /// 表のセル編集の保存(payload 変更・Undo あり)
    let onObjectTableChanged: (NSManagedObjectID, TablePayload) -> Void
    /// 表の列幅/行高ドラッグ確定(新フレーム + 新 payload を 1つの Undo グループで保存)
    let onObjectTableResized: (NSManagedObjectID, CGRect, TablePayload) -> Void
    /// オブジェクトのユーザーロックをトグルする要求
    let onToggleUserLock: (NSManagedObjectID) -> Void
    /// 選択中の複数オブジェクトをグループ化する要求
    let onGroupObjects: ([NSManagedObjectID]) -> Void
    /// グループを解除する要求
    let onUngroupObjects: ([NSManagedObjectID]) -> Void
    /// 選択中の2オブジェクトをコネクタ線で接続する要求
    let onConnectObjects: ([NSManagedObjectID]) -> Void
    /// 通常ノートで、最後のページを超えて横に引っ張ったときにページを1枚追加する要求
    let onAppendPage: () -> Void
    /// オブジェクトの選択状態が変わったとき(true=何か選択中 / false=未選択)。
    /// 選択中は選択モード(描画停止・単指はオブジェクト操作)へ切り替える。
    let onSelectionChanged: (Bool) -> Void
    /// Undo/Redo ブリッジなどにキャンバスを渡す
    let onCanvasReady: (PKCanvasView) -> Void
    /// 通常ノートで指定ページ先頭へスクロールする要求(しおり/目次のジャンプ)。nil で何もしない。
    let scrollToPage: Int?
    /// ジャンプを処理したら呼ぶ(要求元が nil へ戻す)
    let onScrollHandled: () -> Void
    /// ズームを 100% に戻して中央へ寄せる要求(左上バッジのメニューから)。
    let resetZoomRequested: Bool
    /// リセットを処理したら呼ぶ(要求元が false へ戻す)
    let onZoomResetHandled: () -> Void
    /// コンテンツ全体を画面に収める(Zoom to Fit)要求(左上バッジのメニューから、infinite のみ)。
    let zoomToFitRequested: Bool
    /// 全体表示を処理したら呼ぶ(要求元が false へ戻す)
    let onZoomToFitHandled: () -> Void

    /// 通常ノートのページ配置電卓(見開き × スクロール方向)
    private var layout: PagedLayoutCalculator {
        PagedLayoutCalculator(
            pageCount: pageCount,
            isTwoPageLayout: isTwoPageLayout,
            isHorizontalScroll: isHorizontalScroll
        )
    }

    /// 背景レイヤーのフレーム・ページ描画・スクロール方向を現在の形式へ合わせる。
    /// make と update の両方から呼ぶ(冪等)。無限キャンバスの contentSize/フレーム/
    /// スクロール制限は動的ワールドサイズに依存するため、ここでは扱わず
    /// `Coordinator.refreshInfiniteWorld(in:)` が別途管理する。
    private func applyLayout(to container: CanvasContainerUIView) {
        let canvas = container.canvasView       // インク(drawing の正本)
        let scrollView = container.scrollView   // スクロール/ズームの正本

        // 通常ノートのみ、ここで contentSize を確定する(ページ数・レイアウトから決定論的に計算できる)。
        // ※ CanvasRepresentable は infinite 専用(paged は PagedCanvasRepresentable)なので実行されない。
        if noteType == .paged {
            let size = layout.contentSize
            canvas.contentSize = size
            container.patternView.frame = CGRect(origin: .zero, size: size)
            container.objectLayer.frame = CGRect(origin: .zero, size: size)
        }

        // オブジェクト層のクリップ: 無限キャンバス層(ワールド全域)で masksToBounds を有効にすると、
        // ズーム時の実効ピクセルが GPU のレンダバッファ上限を超えて層ごと描画が黙って失敗し、
        // オブジェクトが全て見えなくなる。無限はクリップ不要(層=キャンバス全域)なので無効化する。
        container.objectLayer.clipsToBounds = (noteType == .paged)

        // スクロール方向: 横スクロール時のみ横バウンス、縦スクロール時は縦バウンス。
        // ページスナップは isPagingEnabled ではなく scrollViewWillEndDragging で
        // カスタム実装する(isPagingEnabled は bounds.width 単位でスナップするが、
        // 通常ノートはズーム倍率によりページ実幅と画面幅が一致しないため)。
        // スクロール/ズームは外側 scrollView が担う(ミラー方式)。バウンス・ズーム範囲は
        // すべて scrollView に設定する。インク面(canvasView)は自身のズームを持たず、
        // updateInkWindow が外側の offset/zoom をミラーするだけ(0.1〜4.0 のミラーを許すため
        // init で min0.1/max4.0 を設定済み)。
        let horizontal = noteType == .paged && isHorizontalScroll
        scrollView.alwaysBounceHorizontal = horizontal
        scrollView.alwaysBounceVertical = noteType != .paged || !isHorizontalScroll
        scrollView.isPagingEnabled = false

        if isZoomLocked {
            let locked = scrollView.zoomScale
            scrollView.minimumZoomScale = locked
            scrollView.maximumZoomScale = locked
        } else {
            switch noteType {
            case .paged:
                scrollView.maximumZoomScale = 3.0
                scrollView.minimumZoomScale = min(pagedMinimumZoom(for: canvas), scrollView.maximumZoomScale)
            case .infinite:
                scrollView.minimumZoomScale = 0.1
                scrollView.maximumZoomScale = 4.0  // Freeform に合わせて 400%
            }
        }

        // 用紙外(通常ノートのグレー余白)での描画を無効化する。
        // ページ矩形はコンテンツ座標なので、ここで現在のページ数に合わせて毎回作り直す
        // (ページ追加/削除に追従する)。
        let currentNoteType = noteType
        let pageRects = (0..<max(1, pageCount)).map { layout.pageRect($0) }
        container.drawingTouchGate.isTouchAllowed = { point in
            if currentNoteType == .infinite { return true }
            return pageRects.contains { $0.contains(point) }
        }

        container.patternView.configure(
            noteType: noteType, layout: layout,
            style: backgroundStyle, pageColor: pageColor
        )
    }

    /// 無限キャンバスのコンテンツ外接矩形(描画+オブジェクト)。コンテンツが無ければ nil。
    /// `Coordinator.refreshInfiniteWorld(in:)` がワールドサイズ・原点リベース・
    /// スクロール制限の判定にすべてこれを使う(単一の情報源)。
    fileprivate var infiniteContentUnion: CGRect? {
        var union = CGRect.null
        let drawingBounds = drawing.bounds
        if !drawingBounds.isNull, !drawingBounds.isEmpty {
            union = union.union(drawingBounds)
        }
        for object in objects where !object.isDeleted && object.managedObjectContext != nil {
            union = union.union(object.contentFrame)
        }
        return union.isNull ? nil : union
    }

    func makeUIView(context: Context) -> CanvasContainerUIView {
        let container = CanvasContainerUIView()
        let canvas = container.canvasView
        canvas.drawing = drawing
        context.coordinator.lastStrokeCount = drawing.strokes.count
        context.coordinator.seedPreviousDrawing(drawing)
        canvas.tool = pkTool
        container.scrollView.delegate = context.coordinator
        canvas.delegate = context.coordinator  // 描画+スクロール/ズーム両方(PKCanvasViewDelegate: UIScrollViewDelegate)
        // はみ出し領域の色: 無限は用紙色、通常ノートは机のグレー
        container.backgroundColor = containerBackgroundColor
        container.objectLayer.pageColor = pageColor
        applyLayout(to: container)
        if noteType == .infinite {
            context.coordinator.refreshInfiniteWorld(in: container)
        }
        context.coordinator.lastPageCount = pageCount
        context.coordinator.lastIsTwoPage = isTwoPageLayout
        context.coordinator.lastIsHorizontal = isHorizontalScroll
        context.coordinator.attach(to: container)
        onCanvasReady(canvas)

        // オブジェクト操作の書き戻し(常に最新の parent を経由させる)
        let coordinator = context.coordinator
        container.objectLayer.onFrameChanged = { [weak coordinator] id, frame in
            coordinator?.parent.onObjectFrameChanged(id, frame)
        }
        container.objectLayer.onRotationChanged = { [weak coordinator] id, rotation in
            coordinator?.parent.onObjectRotationChanged(id, rotation)
        }
        container.objectLayer.onTextChanged = { [weak coordinator] id, text in
            coordinator?.parent.onObjectTextChanged(id, text)
        }
        container.objectLayer.onTodoChanged = { [weak coordinator] id, items in
            coordinator?.parent.onObjectTodoChanged(id, items)
        }
        container.objectLayer.onDelete = { [weak coordinator] id in
            coordinator?.parent.onObjectDeleted(id)
        }
        container.objectLayer.onAutoHeightChanged = { [weak coordinator] id, height in
            coordinator?.parent.onObjectAutoHeightChanged(id, height)
        }
        container.objectLayer.onTextSelectionChanged = { [weak coordinator] info in
            coordinator?.parent.onTextSelectionChanged(info)
        }
        container.objectLayer.onNoteLinkActivated = { [weak coordinator] id in
            coordinator?.parent.onNoteLinkActivated(id)
        }
        container.objectLayer.onShapeEdit = { [weak coordinator] id in
            coordinator?.parent.onObjectShapeEditRequested(id)
        }
        container.objectLayer.onTableChanged = { [weak coordinator] id, payload in
            coordinator?.parent.onObjectTableChanged(id, payload)
        }
        container.objectLayer.onTableResized = { [weak coordinator] id, frame, payload in
            coordinator?.parent.onObjectTableResized(id, frame, payload)
        }
        container.objectLayer.onToggleUserLock = { [weak coordinator] id in
            coordinator?.parent.onToggleUserLock(id)
        }
        container.objectLayer.onGroupObjects = { [weak coordinator] ids in
            coordinator?.parent.onGroupObjects(ids)
        }
        container.objectLayer.onUngroupObjects = { [weak coordinator] ids in
            coordinator?.parent.onUngroupObjects(ids)
        }
        container.objectLayer.onConnectObjects = { [weak coordinator] ids in
            coordinator?.parent.onConnectObjects(ids)
        }
        // 選択状態の変化を SwiftUI(PenToolState.isSelectMode)へ伝える。
        // これが選択モード(描画停止・単指操作)の真実のソースになる。
        container.objectLayer.onSelectionChanged = { [weak coordinator] hasSelection in
            coordinator?.parent.onSelectionChanged(hasSelection)
        }

        // 自前投げ縄: 描画ジェスチャ → 選択計算、統一枠の移動・削除でインク側を変換する。
        container.onLassoPan = { [weak coordinator, weak container] gesture in
            guard let coordinator, let container else { return }
            coordinator.handleLassoPan(gesture, in: container)
        }
        container.objectLayer.onLassoStrokesMove = { [weak coordinator, weak container] t, state in
            guard let coordinator, let container else { return }
            coordinator.moveLassoStrokes(t, state: state, in: container)
        }
        container.objectLayer.onLassoStrokesDelete = { [weak coordinator, weak container] in
            guard let coordinator, let container else { return }
            coordinator.deleteLassoStrokes(in: container)
        }

        // 初期ビューポート(保存がなければコンテンツ中心)。ズーム/スクロールは外側 scrollView。
        DispatchQueue.main.async {
            let scrollView = container.scrollView
            if let viewport = initialViewport {
                scrollView.zoomScale = viewport.zoomScale
                scrollView.contentOffset = viewport.contentOffset
            } else {
                let size = context.coordinator.worldSize
                let viewW = scrollView.bounds.width > 0 ? scrollView.bounds.width : 1024
                let viewH = scrollView.bounds.height > 0 ? scrollView.bounds.height : 768
                scrollView.contentOffset = CGPoint(
                    x: max(0, (size - viewW) / 2),
                    y: max(0, (size - viewH) / 2)
                )
            }
            context.coordinator.refreshInfiniteWorld(in: container)
            scrollView.contentOffset = context.coordinator.clampedInfiniteOffset(scrollView.contentOffset, for: scrollView)
            container.objectLayer.applyZoom(scrollView.zoomScale)
            container.patternView.applyZoom(scrollView.zoomScale)
        }
        return container
    }

    /// 通常ノートの机(背景)色。無限は Freeform 風の板色(白紙は淡いグレー、黒紙は黒)。
    private var containerBackgroundColor: UIColor {
        if noteType == .paged { return .systemGray5 }
        return pageColor == .white ? UIColor(white: 0.949, alpha: 1) : pageColor.backgroundUIColor
    }

    /// 通常ノートの最小ズーム = 「1ユニット(1ページ or 2ページ見開き)」全体が画面に綺麗に
    /// 収まるフィット倍率。既存ノートアプリ準拠の全体フィット。
    /// bounds 未確定(=0)のときは下限 0.5 にフォールバックする。
    private func pagedMinimumZoom(for canvas: UIScrollView) -> CGFloat {
        let bounds = canvas.bounds
        guard bounds.width > 0, bounds.height > 0 else { return 0.5 }
        let unitWidth: CGFloat
        let unitHeight = PageMetrics.height
        if isTwoPageLayout {
            // 横スクロールの見開きは2枚密着(gap なし)、縦スクロールは gap ありの2列
            unitWidth = 2 * PageMetrics.width + (isHorizontalScroll ? 0 : PageMetrics.gap)
        } else {
            unitWidth = PageMetrics.width
        }
        let availW = max(1, bounds.width - PageMetrics.margin * 2)
        let availH = max(1, bounds.height - PageMetrics.margin * 2)
        return min(availW / unitWidth, availH / unitHeight)
    }

    /// ページを画面に収まるようズームフィットし、先頭ページを中央に置く。
    /// フィット倍率は `pagedMinimumZoom`(= 最小ズーム)をそのまま使う(マジックナンバー 0.94 は廃止)。
    private func fitPaged(_ canvas: UIScrollView) {
        let bounds = canvas.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        let fit = min(canvas.maximumZoomScale, max(canvas.minimumZoomScale, pagedMinimumZoom(for: canvas)))
        canvas.zoomScale = fit
        if isHorizontalScroll {
            // 先頭ページも中央寄せ(スナップと同じ算出でズレを無くす)
            let offsetX = PagePlanner.scrollOffsetX(
                toPage: 0, zoomScale: fit, layout: layout,
                margin: PageMetrics.margin, viewWidth: bounds.width
            )
            canvas.contentOffset = CGPoint(x: offsetX, y: canvas.contentOffset.y)
        } else {
            canvas.contentOffset = CGPoint(x: canvas.contentOffset.x, y: -PageMetrics.margin)
        }
    }

    /// 通常ノートを横断方向へ中央寄せ(スクロール方向と直交する側にグレー余白を出す)。
    /// 縦スクロール: 左右を中央寄せ。横スクロール: 上下を中央寄せ。
    private func centerPagedContent(_ canvas: UIScrollView) {
        pagedContentInset(for: canvas).map { canvas.contentInset = $0 }
    }

    /// 現在のズームでの通常ノート用 contentInset(横断方向センタリング + 端の余白)
    private func pagedContentInset(for canvas: UIScrollView) -> UIEdgeInsets? {
        guard noteType == .paged else { return nil }
        let size = layout.contentSize
        if isHorizontalScroll {
            let contentH = size.height * canvas.zoomScale
            let vInset = max(0, (canvas.bounds.height - contentH) / 2)
            return UIEdgeInsets(top: vInset, left: PageMetrics.margin,
                                bottom: vInset, right: PageMetrics.margin)
        } else {
            let contentW = size.width * canvas.zoomScale
            let hInset = max(0, (canvas.bounds.width - contentW) / 2)
            return UIEdgeInsets(top: PageMetrics.margin, left: hInset,
                                bottom: PageMetrics.margin, right: hInset)
        }
    }

    func updateUIView(_ container: CanvasContainerUIView, context: Context) {
        context.coordinator.parent = self
        let canvas = container.canvasView
        let scrollView = container.scrollView
        canvas.tool = pkTool
        container.backgroundColor = containerBackgroundColor
        container.isSelectMode = isSelectMode
        // 投げ縄選択モード(infinite のみ): PencilKit の描画/投げ縄ジェスチャを止め、自前ジェスチャに切り替える。
        let lassoActive = isLassoSelectionMode && noteType == .infinite
        container.isLassoMode = lassoActive
        // タップ位置配置モード(テキスト/Todo): 手書きジェスチャを止めてタップ配置に切り替える。
        container.placementTool = placementTool
        container.onPlaceObject = onPlaceObject
        canvas.drawingGestureRecognizer.isEnabled = (placementTool == nil && !lassoActive)
        container.objectLayer.backgroundStyle = backgroundStyle
        container.objectLayer.pageColor = pageColor
        applyLayout(to: container)  // 背景スタイル・用紙色・ページ数・レイアウトの変化を反映
        if noteType == .infinite {
            // 描画・オブジェクトの変化のたびにワールドサイズ(拡張/原点リベース)を再判定する
            context.coordinator.refreshInfiniteWorld(in: container)
        }

        // レイアウト設定(見開き / スクロール方向)が変わったら、安全に再フィット + 再センタリング。
        // ページ数の変化は含めない(それはページ追加スクロールで扱う)。
        // ズームや位置を作り直すのはこの変化時のみ(毎フレームやると操作を奪って無限ループの元)。
        let layoutModeChanged = isTwoPageLayout != context.coordinator.lastIsTwoPage
            || isHorizontalScroll != context.coordinator.lastIsHorizontal
        if noteType == .paged, layoutModeChanged {
            context.coordinator.lastIsTwoPage = isTwoPageLayout
            context.coordinator.lastIsHorizontal = isHorizontalScroll
            DispatchQueue.main.async {
                fitPaged(scrollView)
                centerPagedContent(scrollView)
                container.patternView.applyZoom(scrollView.zoomScale)
            }
        } else if noteType == .paged, pageCount > context.coordinator.lastPageCount {
            // ページが増えたら、新しいページへスクロール方向に沿って滑らかに移動(中央寄せ)
            centerPagedContent(scrollView)
            let lastRect = layout.pageRect(pageCount - 1)
            let target: CGPoint = isHorizontalScroll
                ? CGPoint(x: PagePlanner.scrollOffsetX(toPage: pageCount - 1, zoomScale: scrollView.zoomScale,
                                                       layout: layout, margin: PageMetrics.margin,
                                                       viewWidth: scrollView.bounds.width),
                          y: scrollView.contentOffset.y)
                : CGPoint(x: scrollView.contentOffset.x, y: lastRect.minY * scrollView.zoomScale - PageMetrics.margin)
            scrollView.setContentOffset(target, animated: true)
            // 追加が反映されたのでオーバースクロール追加のガードを解除(次のめくりで再度追加可能)
            context.coordinator.didRequestPageAppend = false
        }
        context.coordinator.lastPageCount = pageCount

        // しおり/目次のジャンプ: 指定ページ先頭へアニメーションでスクロールする
        if noteType == .paged, let target = scrollToPage, !context.coordinator.isScrollPending {
            context.coordinator.isScrollPending = true
            let targetLayout = layout
            DispatchQueue.main.async {
                let offsetX = PagePlanner.scrollOffsetX(
                    toPage: target, zoomScale: scrollView.zoomScale,
                    layout: targetLayout, margin: PageMetrics.margin,
                    viewWidth: scrollView.bounds.width
                )
                let destination = CGPoint(x: offsetX, y: scrollView.contentOffset.y)
                // 矢印タップ由来のプログラムスクロール中は、PencilKit が座標移動を「長押し」と
                // 誤検知して手書きメニュー(Select All / Insert Space)を暴発させることがある。
                // アニメーション中は画面全体の入力を遮断し、完了後に戻す。
                scrollView.isUserInteractionEnabled = false
                UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseInOut]) {
                    scrollView.contentOffset = destination
                } completion: { _ in
                    scrollView.isUserInteractionEnabled = true
                    self.onScrollHandled()
                    context.coordinator.isScrollPending = false
                }
            }
        }

        // ズームを 100% に戻して表示をコンテンツ中央へ寄せる(左上バッジのメニューから)
        if resetZoomRequested {
            let scrollView = container.scrollView
            DispatchQueue.main.async {
                UIView.animate(withDuration: 0.25) {
                    scrollView.zoomScale = 1.0
                    context.coordinator.refreshInfiniteWorld(in: container)
                    let size = context.coordinator.worldSize
                    scrollView.contentOffset = context.coordinator.clampedInfiniteOffset(
                        CGPoint(
                            x: (size - scrollView.bounds.width) / 2,
                            y: (size - scrollView.bounds.height) / 2
                        ),
                        for: scrollView
                    )
                }
                container.objectLayer.applyZoom(1.0)
                container.patternView.applyZoom(1.0)
                self.onZoomResetHandled()
            }
        }

        // コンテンツ全体を画面に収める(Zoom to Fit、infinite のみ)
        if zoomToFitRequested, noteType == .infinite {
            let scrollView = container.scrollView
            DispatchQueue.main.async {
                context.coordinator.refreshInfiniteWorld(in: container)
                if let fit = ZoomToFit.fit(
                    contentUnion: self.infiniteContentUnion, viewportSize: scrollView.bounds.size,
                    minZoom: scrollView.minimumZoomScale, maxZoom: scrollView.maximumZoomScale
                ) {
                    UIView.animate(withDuration: 0.3) {
                        scrollView.zoomScale = fit.zoomScale
                        context.coordinator.refreshInfiniteWorld(in: container)
                        scrollView.contentOffset = context.coordinator.clampedInfiniteOffset(fit.contentOffset, for: scrollView)
                        container.objectLayer.applyZoom(fit.zoomScale)
                        container.patternView.applyZoom(fit.zoomScale)
                    }
                }
                self.onZoomToFitHandled()
            }
        }

        context.coordinator.syncObjects(into: container.objectLayer)
        context.coordinator.handleAutoFocus(in: container.objectLayer)
        // モデル側から描画が差し替わった場合のみ反映(描画中の上書きを防ぐ)
        if !context.coordinator.isCanvasSourceOfTruth, canvas.drawing != drawing {
            canvas.drawing = drawing
            // プログラムでの差し替えを新規ストローク追加と誤認しないよう基準数を更新
            context.coordinator.lastStrokeCount = drawing.strokes.count
            context.coordinator.seedPreviousDrawing(drawing)
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
        /// 末尾オーバースクロールでのページ追加を要求済みか(1ドラッグにつき1回に抑える)
        var didRequestPageAppend = false
        /// ジャンプ(プログラムスクロール)を処理中か(1要求につき1回に抑える)
        var isScrollPending = false
        /// 直近のレイアウト設定(見開き/スクロール方向)。変化時のみフィット/センタリングし直す。
        /// ページ数はここに含めない(ページ追加はスクロール処理側で扱う)
        var lastIsTwoPage = false
        var lastIsHorizontal = false
        /// 無限キャンバスの現在のワールドサイズ(コンテンツ座標、正方形の一辺)。
        /// コンテンツ+マージンに応じて伸びるのみで、縮小はしない(削除操作でジャンプしないように)。
        var worldSize: CGFloat = DynamicCanvasBounds.initialWorldSize
        /// 図形置換・マーカー背面化で drawing を差し替える間の再入を無視するフラグ(無限再描画ループ防止)
        private var isReplacingDrawing = false
        /// 投げ縄でのインク移動・削除を差分検知するための直前の描画
        private var previousDrawing = PKDrawing()
        /// 自前投げ縄: ドラッグ中の頂点列(コンテンツ座標)。自由曲線/範囲マーキーの両方に使う。
        private var lassoPoints: [CGPoint] = []
        /// 自前投げ縄: 現在の一括選択(ストローク index + オブジェクト ID)
        private var lassoSelection = SelectionSession()
        /// 自前投げ縄: 統一枠ドラッグでのインク移動の基準描画(移動開始時)
        private var lassoMoveStartDrawing: PKDrawing?
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
            container.onBoundsChange = { [weak self] in self?.handleBoundsChange() }
            // オブジェクト上ピンチの補完ズームが確定したら、無限ワールドを再計算(組み込みの
            // scrollViewDidEndZooming と同じ後処理)。
            container.onSupplementalZoomEnded = { [weak self] in
                guard let self, let container = self.container else { return }
                self.refreshInfiniteWorld(in: container)
            }
        }

        /// 画面回転・Split View のリサイズ等で bounds が変わったとき、通常ノートの
        /// 横断方向センタリング(contentInset)を現在のズームに合わせて再計算する。
        /// (再フィットはせず、scrollViewDidZoom と同じ軽量な再センタリングのみ行う)
        private func handleBoundsChange() {
            guard let container else { return }
            if parent.noteType == .infinite {
                refreshInfiniteWorld(in: container)
                return
            }
            guard let inset = parent.pagedContentInset(for: container.canvasView) else { return }
            container.canvasView.contentInset = inset
        }

        // MARK: - 無限キャンバスの動的ワールド管理

        func refreshInfiniteWorld(in container: CanvasContainerUIView) {
            guard parent.noteType == .infinite else { return }
            let scrollView = container.scrollView
            // ピンチズーム中は worldSize/contentView.bounds/原点リベースを一切触らない。
            // ズーム中にワールドを書き換えるとピンチのアンカーがずれるため、確定後
            // (scrollViewDidEndZooming / 補完ズーム終了)にまとめて適用する。
            guard !scrollView.isZooming, !(container.isSupplementalZooming) else { return }
            // スクロール・慣性の最中は原点リベースを保留し、画面の跳ね・引っかかりを防ぐ
            if !scrollView.isDragging && !scrollView.isDecelerating {
                if let delta = DynamicCanvasBounds.rebaseDelta(contentUnion: parent.infiniteContentUnion) {
                    rebaseOrigin(by: delta, in: container)
                }
            }
            worldSize = DynamicCanvasBounds.expandedWorldSize(
                contentUnion: parent.infiniteContentUnion, currentWorldSize: worldSize
            )
            applyWorldSize(to: container)
            updateInkWindow(in: container)
        }

        private func applyWorldSize(to container: CanvasContainerUIView) {
            let size = CGSize(width: worldSize, height: worldSize)
            if container.contentView.bounds.size != size {
                // contentView(ズーム対象)とオブジェクト層だけを worldSize にする。
                // 背景(patternView)は画面固定のベクター描画、インク(canvasView)は可視範囲の
                // ビューポート窓(updateInkWindow がミラー配置)なので、ここでは触らない。
                container.contentView.bounds = CGRect(origin: .zero, size: size)
                container.objectLayer.frame = CGRect(origin: .zero, size: size)
            }
            // スクロール範囲(contentSize)は常に worldSize×zoom に追従させる。これを更新しないと
            // ワールド拡張後のスクロール範囲がズームとズレて、末端で引っかかる/ドリフトの原因になる。
            let scaled = CGSize(width: worldSize * container.scrollView.zoomScale,
                                height: worldSize * container.scrollView.zoomScale)
            if container.scrollView.contentSize != scaled { container.scrollView.contentSize = scaled }
            centerContentView(in: container)
        }

        /// ズーム対象 contentView を、コンテンツがビューポートより小さいときだけ中央寄せする。
        /// `scrollViewDidZoom` と `applyWorldSize` で同一ロジックを使い、ズーム後の中心を
        /// 食い違わせない(中心の食い違いがピンチ確定時のドリフトの主因だった)。
        /// contentSize(= worldSize×zoom)基準で計算するため、ズーム時もズーム後も一貫する。
        private func centerContentView(in container: CanvasContainerUIView) {
            let scrollView = container.scrollView
            let boundsSize = scrollView.bounds.size
            let contentSize = scrollView.contentSize
            let offsetX = max(0, (boundsSize.width - contentSize.width) * 0.5)
            let offsetY = max(0, (boundsSize.height - contentSize.height) * 0.5)
            let center = CGPoint(
                x: contentSize.width * 0.5 + offsetX,
                y: contentSize.height * 0.5 + offsetY
            )
            if container.contentView.center != center { container.contentView.center = center }
        }

        /// インク面(PKCanvasView)を「画面固定・ビューポートサイズのスクロールビュー」として、
        /// 外側 scrollView のオフセット/ズームへ追従(ミラー)させる。
        /// 巨大な contentView 直下に worldSize のインクを置くと、PencilKit が巨大テクスチャに
        /// ライブ描画(書いてる途中の線)を出せない。そこでインク面は contentView の外(scrollView
        /// 直下・最前面)へ置き、frame=ビューポート・contentSize=worldSize のまま自身のズーム/
        /// オフセットを外側にミラーする。PencilKit はビューポート分だけを描画するのでライブ描画が正しく出る。
        /// - `frame.origin = 外側 contentOffset`(scrollView 内で画面に固定表示)。
        /// - `contentOffset/zoomScale = 外側と一致`(表示する world 範囲と倍率を合わせる)。
        /// - drawing は world 座標のまま(contentSize=worldSize が描画可能域を全域に確保)。
        func updateInkWindow(in container: CanvasContainerUIView) {
            guard parent.noteType == .infinite else { return }
            let scrollView = container.scrollView
            guard scrollView.bounds.width > 0, scrollView.bounds.height > 0 else { return }
            let ink = container.canvasView
            let zoom = scrollView.zoomScale
            // まずズーム倍率を外側に合わせ、その上でインクの contentSize を「ズーム後サイズ(worldSize×zoom)」へ。
            // contentSize を worldSize(非ズーム)のままにすると、zoom > 約(1 + 画面幅/worldSize) で
            // 外側の contentOffset(= world×zoom 空間)がインク側の可動域を超えて頭打ちになり、
            // インク表示がズレて Pencil が描画域から外れる(130%付近で破綻していた原因)。
            if ink.zoomScale != zoom { ink.zoomScale = zoom }
            let scaledWorld = CGSize(width: worldSize * zoom, height: worldSize * zoom)
            if ink.contentSize != scaledWorld { ink.contentSize = scaledWorld }
            if ink.contentOffset != scrollView.contentOffset { ink.contentOffset = scrollView.contentOffset }
            let frame = CGRect(origin: scrollView.contentOffset, size: scrollView.bounds.size)
            if ink.frame != frame { ink.frame = frame }
            // PKCanvasView は contentSize/zoomScale 変更時に自身の pan/pinch を再有効化することがある。
            // インクにスクロール/ズームのジェスチャを持たせると外側 scrollView のピンチを奪うため、毎回無効化する。
            if ink.panGestureRecognizer.isEnabled { ink.panGestureRecognizer.isEnabled = false }
            if ink.pinchGestureRecognizer?.isEnabled == true { ink.pinchGestureRecognizer?.isEnabled = false }
            // 画面固定の背景ドット/罫線を現在のオフセット・ズームで再描画する。
            container.patternView.updateViewport(contentOffset: scrollView.contentOffset, zoomScale: scrollView.zoomScale)
        }

        /// 現在の許可範囲で contentOffset をクランプする(復元・リセット等のプログラム設定用)
        func clampedInfiniteOffset(_ offset: CGPoint, for canvas: UIScrollView) -> CGPoint {
            let allowed = InfiniteScrollLimiter.allowedRect(
                contentUnion: parent.infiniteContentUnion,
                viewportSize: canvas.bounds.size, zoomScale: canvas.zoomScale, canvasSize: worldSize
            )
            return InfiniteScrollLimiter.clampedOffset(
                offset, allowedRect: allowed,
                zoomScale: canvas.zoomScale, viewportSize: canvas.bounds.size
            )
        }

        private func rebaseOrigin(by delta: CGVector, in container: CanvasContainerUIView) {
            let canvas = container.canvasView
            let transform = CGAffineTransform(translationX: delta.dx, y: delta.dy)

            isReplacingDrawing = true
            let shifted = canvas.drawing.transformed(using: transform)
            canvas.drawing = shifted
            isCanvasSourceOfTruth = true
            parent.drawing = shifted
            isCanvasSourceOfTruth = false
            previousDrawing = shifted
            lastStrokeCount = shifted.strokes.count
            isReplacingDrawing = false

            parent.onCanvasRebased(delta)

            canvas.contentOffset = CGPoint(
                x: canvas.contentOffset.x + delta.dx * canvas.zoomScale,
                y: canvas.contentOffset.y + delta.dy * canvas.zoomScale
            )
        }

        // MARK: - スクロール/ズーム(UIScrollViewDelegate 経由。KVO は使わない)

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            guard scrollView === container?.scrollView else { return nil }
            return container?.contentView
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard scrollView === container?.scrollView else { return }
            // ズーム中はクランプしない(アンカーを乱さない)。確定後に scrollViewDidEndZooming /
            // 補完ズーム終了で収める。補完ズーム(オブジェクト上ピンチ)中も焦点を保つため触らない。
            if parent.noteType == .infinite, !scrollView.isZooming,
               !(container?.isSupplementalZooming ?? false) {
                let clamped = clampedInfiniteOffset(scrollView.contentOffset, for: scrollView)
                if clamped != scrollView.contentOffset { scrollView.contentOffset = clamped }
                // インク面の窓を可視範囲へ追従(スクロールに合わせて張り替える)
                if let container { updateInkWindow(in: container) }
            }
            parent.onViewportChanged(
                CanvasViewport(contentOffset: scrollView.contentOffset, zoomScale: scrollView.zoomScale)
            )
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        }

        func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        }

        /// 通常ノート(横スクロール)で、スクロール限界より右へバウンス(オーバースクロール)した量(pt)。
        private func rightOverscroll(_ scrollView: UIScrollView) -> CGFloat {
            guard parent.noteType == .paged, parent.isHorizontalScroll else { return 0 }
            let contentW = parent.layout.contentSize.width * scrollView.zoomScale
            let maxOffsetX = max(-scrollView.contentInset.left,
                                 contentW - scrollView.bounds.width + scrollView.contentInset.right)
            return scrollView.contentOffset.x - maxOffsetX
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            let threshold = min(scrollView.bounds.width * 0.15, 140)
            if !didRequestPageAppend, rightOverscroll(scrollView) > threshold {
                didRequestPageAppend = true
                parent.onAppendPage()
            }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        }

        func scrollViewWillEndDragging(
            _ scrollView: UIScrollView,
            withVelocity velocity: CGPoint,
            targetContentOffset: UnsafeMutablePointer<CGPoint>
        ) {
            guard parent.noteType == .paged, parent.isHorizontalScroll else { return }

            let layout = parent.layout
            let zoomScale = scrollView.zoomScale
            let margin = PageMetrics.margin
            let pageCount = parent.pageCount
            guard pageCount > 0 else { return }

            let currentPage = PagePlanner.currentPage(
                contentOffsetX: scrollView.contentOffset.x,
                viewWidth: scrollView.bounds.width,
                zoomScale: zoomScale,
                layout: layout
            )

            var targetPage = currentPage
            let velocityThreshold: CGFloat = 0.2
            if velocity.x > velocityThreshold {
                targetPage = min(pageCount - 1, currentPage + 1)
            } else if velocity.x < -velocityThreshold {
                targetPage = max(0, currentPage - 1)
            }

            let targetX = PagePlanner.scrollOffsetX(
                toPage: targetPage,
                zoomScale: zoomScale,
                layout: layout,
                margin: margin,
                viewWidth: scrollView.bounds.width
            )
            targetContentOffset.pointee = CGPoint(
                x: targetX,
                y: scrollView.contentOffset.y
            )
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            guard let container = container, scrollView === container.scrollView else { return }
            // ピンチ中の contentView(=viewForZooming)の配置とアンカー保持は UIScrollView に委ねる
            // (手動センタリングはアンカーを乱しドリフトの原因になるので行わない)。
            // contentSize(= contentView.bounds × zoom)も UIScrollView がピンチ中に自動追従する。
            container.objectLayer.applyZoom(scrollView.zoomScale)
            container.patternView.applyZoom(scrollView.zoomScale)
            // インク面(画面固定の窓)を現在のズーム/オフセットへミラーする。
            updateInkWindow(in: container)
            parent.onViewportChanged(
                CanvasViewport(contentOffset: scrollView.contentOffset, zoomScale: scrollView.zoomScale)
            )
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            guard parent.noteType == .infinite, let container else { return }
            refreshInfiniteWorld(in: container)
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            // プログラムによる置換実行中の再入(drawing 差し替え/undo による通知)は完全にスキップ。
            if isReplacingDrawing { return }

            // 図形認識アシスト: 直前に「1本だけ増えた」インクストロークを図形へ置換する。
            // 消しゴム(ストローク分割で数が増減)や選択操作を巻き込まないよう
            // インクツール中かつストローク数が +1 のときだけ判定する。マーカーは対象外。
            if parent.isShapeAssistEnabled,
               parent.pkTool is PKInkingTool,
               canvasView.drawing.strokes.count == lastStrokeCount + 1,
               let last = canvasView.drawing.strokes.last,
               last.ink.inkType != .marker,
               let cleanStroke = ShapeRecognizer.cleanShape(from: last) {
                let oldDrawing = previousDrawing  // 手書きストロークが追加される前の描画
                var newDrawing = canvasView.drawing
                newDrawing.strokes.removeLast()
                newDrawing.strokes.append(cleanStroke)

                // 1. PencilKit が自動登録した「手書き追加」の Undo アクションを取り消し、
                //    履歴上に手書き分を残さない(以降は図形置換のみを1手として扱う)。
                isReplacingDrawing = true
                canvasView.undoManager?.undo()
                isReplacingDrawing = false

                // 2. 双方向 Undo/Redo をサポートしつつ図形へ置換する。
                replaceDrawingWithUndoSupport(canvasView, to: newDrawing, from: oldDrawing)
                return
            }
            // 投げ縄ツール中のインク移動・削除を差分検知し、重なるオブジェクトも連動させる
            if parent.pkTool is PKLassoTool {
                detectLassoChange(from: previousDrawing, to: canvasView.drawing)
            }
            previousDrawing = canvasView.drawing
            lastStrokeCount = canvasView.drawing.strokes.count

            isCanvasSourceOfTruth = true
            parent.drawing = canvasView.drawing
            parent.onDrawingChanged()
            isCanvasSourceOfTruth = false
            if let container { refreshInfiniteWorld(in: container) }
        }

        /// 双方向の Undo/Redo をサポートしながら CanvasView の描画を置換する。
        /// `.drawing` の直接代入は PencilKit が Undo を自動登録しないため、
        /// 逆操作を UndoManager へ手動登録して「戻る/やり直し」を成立させる。
        /// (Undo で currentDrawing へ戻り、Redo で nextDrawing へ進む)
        private func replaceDrawingWithUndoSupport(
            _ canvasView: PKCanvasView,
            to nextDrawing: PKDrawing,
            from currentDrawing: PKDrawing
        ) {
            // 置換中は didChange の再入を無視する(async 通知を含め全体をガード)。
            isReplacingDrawing = true
            defer { isReplacingDrawing = false }

            canvasView.drawing = nextDrawing

            // 状態の同期と変更イベントの発火
            isCanvasSourceOfTruth = true
            parent.drawing = nextDrawing
            parent.onDrawingChanged()
            isCanvasSourceOfTruth = false

            // 次回比較用とストローク数の更新
            previousDrawing = nextDrawing
            lastStrokeCount = nextDrawing.strokes.count

            // 逆方向の操作を UndoManager に登録する。
            // (新規登録によりスタック上の stale な redo は自動的に破棄される)
            canvasView.undoManager?.registerUndo(withTarget: canvasView) { [weak self] targetCanvas in
                self?.replaceDrawingWithUndoSupport(targetCanvas, to: currentDrawing, from: nextDrawing)
            }
        }

        /// makeUIView / 差し替え時に基準の描画を設定する
        func seedPreviousDrawing(_ drawing: PKDrawing) {
            previousDrawing = drawing
        }

        // MARK: - 投げ縄によるインクとオブジェクトの連動(要件)

        /// 直前と現在の描画を比較し、投げ縄でのインクの「移動」または「削除」を検知して
        /// 該当領域のオブジェクトにも同じ操作を適用する。オブジェクト側の Undo は
        /// PencilKit のストローク Undo と同一イベントで登録され、まとめて元に戻せる。
        private func detectLassoChange(from old: PKDrawing, to new: PKDrawing) {
            switch LassoObjectSync.detect(from: old, to: new) {
            case .moved(let region, let delta):
                parent.onLassoObjectsMoved(region, delta)
            case .deleted(let region):
                parent.onLassoObjectsDeleted(region)
            case nil:
                break
            }
        }

        // MARK: - 自前投げ縄によるインク+オブジェクト一括選択(指示書 2.2「ドラッグおよび投げ縄」)

        /// ドラッグの点列を「自由曲線が十分な面積で囲めている」なら閉多角形へ、
        /// そうでなければ(直線ドラッグ等)外接矩形のマーキーへフォールバックしてポリゴンを作る。
        private func lassoPolygon() -> (polygon: CGPath, bounds: CGRect)? {
            let bounds = LassoHitTesting.boundingBox(lassoPoints)
            guard bounds.width > 4, bounds.height > 4 else { return nil }
            // 面積が外接矩形の20%以上なら自由曲線として扱い、未満なら範囲マーキーへ。
            let area = LassoHitTesting.polygonArea(lassoPoints)
            if lassoPoints.count >= 3, area >= bounds.width * bounds.height * 0.2,
               let freeform = LassoHitTesting.polygon(from: lassoPoints) {
                return (freeform, bounds)
            }
            return (LassoHitTesting.polygon(from: bounds), bounds)
        }

        /// 投げ縄ドラッグの各段階を処理する。座標は objectLayer(コンテンツ空間)で読む。
        func handleLassoPan(_ gesture: UIPanGestureRecognizer, in container: CanvasContainerUIView) {
            let point = gesture.location(in: container.objectLayer)
            switch gesture.state {
            case .began:
                container.objectLayer.clearLassoSelection()
                lassoSelection = SelectionSession()
                lassoPoints = [point]
            case .changed:
                lassoPoints.append(point)
                container.objectLayer.updateLassoDrawing(points: lassoPoints)
            case .ended:
                lassoPoints.append(point)
                finishLasso(in: container)
            case .cancelled, .failed:
                container.objectLayer.lassoView.clear()
            default:
                break
            }
        }

        /// 範囲を確定してインクストローク + オブジェクトを一括選択し、統一枠を表示する。
        private func finishLasso(in container: CanvasContainerUIView) {
            guard let (polygon, rect) = lassoPolygon() else {
                container.objectLayer.lassoView.clear(); return
            }

            // インク: サンプル点の6割以上が内側のストロークを選ぶ(renderBounds で早期除外)
            var indices: Set<Int> = []
            var strokeBounds: [CGRect] = []
            for (i, stroke) in container.canvasView.drawing.strokes.enumerated() {
                let rb = stroke.renderBounds
                guard LassoHitTesting.canIntersect(rb, lassoBounds: rect) else { continue }
                if LassoHitTesting.strokeIsSelected(samplePoints: sampledPoints(of: stroke), inside: polygon) {
                    indices.insert(i); strokeBounds.append(rb)
                }
            }

            // オブジェクト: 中心が内側のものを選ぶ(コネクタは位置が派生値のため除外)
            var objectIDs: Set<NSManagedObjectID> = []
            var objectFrames: [CGRect] = []
            for object in parent.objects
            where !object.isDeleted && object.managedObjectContext != nil && object.objectKind != .connector {
                let frame = object.contentFrame
                if LassoHitTesting.rectIsSelected(frame, inside: polygon) {
                    objectIDs.insert(object.objectID); objectFrames.append(frame)
                }
            }

            guard let box = SelectionSession.combinedBoundingBox(strokeBounds: strokeBounds, objectFrames: objectFrames) else {
                container.objectLayer.lassoView.clear(); return
            }
            lassoSelection = SelectionSession(strokeIndices: indices, objectIDs: objectIDs)
            container.objectLayer.beginLassoSelection(objectIDs: objectIDs, box: box)
        }

        /// PKStroke の描画点をコンテンツ座標のサンプル点列にする(stroke.transform 適用)。
        private func sampledPoints(of stroke: PKStroke) -> [CGPoint] {
            var points: [CGPoint] = []
            for point in stroke.path.interpolatedPoints(by: .distance(8)) {
                points.append(point.location.applying(stroke.transform))
            }
            return points
        }

        /// 選択ストロークを平行移動した描画を作る。
        private func translatedDrawing(_ drawing: PKDrawing, by t: CGVector) -> PKDrawing {
            var strokes = drawing.strokes
            let tf = CGAffineTransform(translationX: t.dx, y: t.dy)
            for i in lassoSelection.strokeIndices where strokes.indices.contains(i) {
                strokes[i].transform = strokes[i].transform.concatenating(tf)
            }
            var out = drawing
            out.strokes = strokes
            return out
        }

        /// 統一枠ドラッグ中の選択ストロークの移動(.changed はプレビュー、.ended で1手 Undo 登録)。
        func moveLassoStrokes(_ t: CGVector, state: UIGestureRecognizer.State, in container: CanvasContainerUIView) {
            guard !lassoSelection.strokeIndices.isEmpty else { return }
            switch state {
            case .began:
                lassoMoveStartDrawing = container.canvasView.drawing
            case .changed:
                guard let start = lassoMoveStartDrawing else { return }
                // プレビュー: canvasView のみ差し替え(Undo 登録しない)
                isReplacingDrawing = true
                container.canvasView.drawing = translatedDrawing(start, by: t)
                isReplacingDrawing = false
            case .ended:
                guard let start = lassoMoveStartDrawing else { return }
                replaceDrawingWithUndoSupport(container.canvasView, to: translatedDrawing(start, by: t), from: start)
                lassoMoveStartDrawing = nil
            case .cancelled, .failed:
                if let start = lassoMoveStartDrawing {
                    isReplacingDrawing = true
                    container.canvasView.drawing = start
                    isReplacingDrawing = false
                }
                lassoMoveStartDrawing = nil
            default:
                break
            }
        }

        /// 統一枠の削除ボタンで選択ストロークを削除する(オブジェクト削除と同一イベント=1 Undo グループ)。
        func deleteLassoStrokes(in container: CanvasContainerUIView) {
            guard !lassoSelection.strokeIndices.isEmpty else { return }
            let old = container.canvasView.drawing
            var next = old
            next.strokes = old.strokes.enumerated()
                .filter { !lassoSelection.strokeIndices.contains($0.offset) }
                .map(\.element)
            replaceDrawingWithUndoSupport(container.canvasView, to: next, from: old)
            lassoSelection.strokeIndices = []
        }

        // MARK: - オブジェクト同期(要件③)

        @MainActor
        func syncObjects(into layer: ObjectLayerUIView) {
            let activeObjects = parent.objects.filter { !$0.isDeleted && $0.managedObjectContext != nil }
            // コネクタは枠付きビューではなく線として別描画するため、通常オブジェクトから分離する。
            let framedObjects = activeObjects.filter { $0.objectKind != .connector }
            syncConnectorLines(from: activeObjects, into: layer)
            let items = framedObjects
                .sorted { $0.zOrder < $1.zOrder }
                .map { object -> CanvasObjectItem in
                    var image: UIImage?
                    var linkTitle = ""
                    if object.objectKind == .noteLink {
                        // リンク先タイトルを毎回引き直す(リネーム等に追従)。
                        // アイコンはリンク先の中身の有無に関わらず固定(ドキュメントアイコン)にするため、
                        // サムネイルは渡さない(image は nil のまま)。
                        linkTitle = object.resolvedLinkedNote?.displayTitle ?? ""
                    } else if object.objectKind != .text && object.objectKind != .todo
                                && object.objectKind != .shape && object.objectKind != .table
                                && object.objectKind != .stickyNote {
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
                        rotation: object.rotation,
                        image: image,
                        isLocked: object.isLocked,
                        isUserLocked: object.isUserLocked,
                        parentGroupID: object.parentGroupID,
                        linkTitle: linkTitle,
                        todoItems: object.objectKind == .todo ? object.todoItems : [],
                        shapePayload: object.objectKind == .shape ? object.shapePayload : nil,
                        tablePayload: object.objectKind == .table ? object.tablePayload : nil,
                        stickyNotePayload: object.objectKind == .stickyNote ? object.stickyNotePayload : nil
                    )
                }
            layer.sync(items: items)

            // 削除済みオブジェクトの画像キャッシュを解放する(imageCache がメモリリークしないように)
            let activeIDs = Set(activeObjects.map(\.objectID))
            imageCache = imageCache.filter { activeIDs.contains($0.key) }
        }

        /// コネクタ線を接続元/先の現在位置から算出してレイヤーへ渡す。
        /// 接続元/先の UUID を frame に解決し、`ConnectorGeometry` で端点を求める。
        /// どちらかの端点が欠けているコネクタは描かない(移動追従・削除追従はこれで成立する)。
        @MainActor
        private func syncConnectorLines(from objects: [CanvasObject], into layer: ObjectLayerUIView) {
            var frameByUUID: [String: CGRect] = [:]
            var objectByUUID: [String: NSManagedObjectID] = [:]
            for object in objects where object.objectKind != .connector {
                if let uuid = object.id?.uuidString {
                    frameByUUID[uuid] = object.contentFrame
                    objectByUUID[uuid] = object.objectID
                }
            }
            var specs: [ConnectorLineSpec] = []
            for object in objects where object.objectKind == .connector {
                guard let payload = object.connectorPayload,
                      let source = frameByUUID[payload.sourceID],
                      let target = frameByUUID[payload.targetID] else { continue }
                guard let sourceObj = objectByUUID[payload.sourceID],
                      let targetObj = objectByUUID[payload.targetID] else { continue }
                let (start, end) = ConnectorGeometry.endpoints(source: source, target: target)
                specs.append(ConnectorLineSpec(
                    id: object.objectID, sourceObjectID: sourceObj, targetObjectID: targetObj,
                    start: start, end: end, hasArrow: payload.hasArrow
                ))
            }
            layer.syncConnectors(specs)
        }

        /// 挿入直後のオブジェクトを選択し、テキストなら編集を開始する(1回だけ)
        @MainActor
        func handleAutoFocus(in layer: ObjectLayerUIView) {
            guard let id = parent.autoFocusObjectID, id != autoFocusHandledID else { return }
            // ビュー生成前(挿入直後の @FetchRequest 未反映)は false。処理済みにせず次の更新で再試行。
            if layer.focus(on: id) { autoFocusHandledID = id }
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
/// 無限キャンバスのインク専用 PKCanvasView。スクロール/ズームは外側の UIScrollView が担うため
/// 自身のスクロールは無効化する(paged の PageCanvasView と同じ役割)。contentView の最前面に
/// 置き、hitTest でオブジェクト上のタッチを objectLayer へ通す(選択・移動は指、Pencil は上から描画)。
final class FreeformInkCanvasView: PKCanvasView {
    weak var objectLayer: ObjectLayerUIView?
    weak var containerScrollView: UIScrollView?

    override var isAccessibilityElement: Bool { get { false } set {} }
    override var accessibilityElements: [Any]? { get { nil } set {} }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // ① オブジェクト(付箋・テキスト・ボタン等)のタッチは objectLayer へ通す(最優先)。
        //    単指のタップ選択・ドラッグ移動のため。2本指ピンチはここでオブジェクトへ吸われても
        //    別途 CanvasContainerUIView 側のピンチ補完(handleZoomPinch)がズームを効かせる。
        if let objectLayer {
            let converted = convert(point, to: objectLayer)
            if let hit = objectLayer.hitTest(converted, with: event), hit !== objectLayer {
                return hit
            }
        }

        let hitView = super.hitTest(point, with: event)
        // インク領域内(自身 or PKCanvasView 内部サブビュー=描画層/タイル層)のタッチのうち、
        // 「確実に指のみ(Pencil を含まない)」と判定できたときだけ外側 scrollView へ転送し、
        // 2本指ピンチ/1本指パンを外側へ一本化する(入れ子インクがピンチを奪うのを防ぐ=Bの修正)。
        // それ以外(Pencil を含む / タッチ種別が取れず判定不能)は通常の hitView を返し、インクの
        // drawingGestureRecognizer(pencilOnly)に手書きさせる。hitTest 時のタッチ種別は不確実なため、
        // 迷ったら必ず描画側へ倒す(スクロール側へ倒すと Pencil が描けなくなる=直前の不具合の原因)。
        // 指の確定は scrollView 側の allowedTouchTypes=.direct でも二重に担保している。
        let hitInsideInk = (hitView?.isDescendant(of: self) ?? false)
        if drawingPolicy == .pencilOnly, hitInsideInk, containerScrollView != nil,
           let touches = event?.allTouches, !touches.isEmpty,
           !touches.contains(where: { $0.type == .pencil || $0.type == .stylus }) {
            return containerScrollView  // 確実に指のみ → 外側スクロール/ズーム
        }
        return hitView
    }
}

/// 無限キャンバスのコンテナ(Apple フリーボード完全同一アーキテクチャ)。
/// 素の `UIScrollView`(ズーム対象 = `contentView`)の中に、worldSize サイズで
///   背景(patternView) < オブジェクト層(objectLayer) < インク(canvasView, スクロール無効)
/// を同サイズ・同座標で100%完全に重ねる。
/// 外側 scrollView の単一トランスフォームで全レイヤーが 120Hz 完全1:1同期して動くため、
/// インクと背景の動きのズレや白紙領域の露出が 100% 物理的に解消される。
final class CanvasContainerUIView: UIView, UIGestureRecognizerDelegate {
    let scrollView = UIScrollView()
    /// ズーム対象。bounds はコンテンツ(世界)座標(非ズーム)。ズームは transform で掛かる。
    let contentView = UIView()
    /// インク(PKDrawing の正本)。scroll 無効・contentView 最前面。
    let canvasView = FreeformInkCanvasView()
    let patternView = BackgroundPatternUIView()
    let objectLayer = ObjectLayerUIView()
    /// 描画ジェスチャに差し込むゲート(「開く」ボタン上・指×オブジェクト上ではインクを始めない)
    let drawingTouchGate = DrawingTouchGate()

    /// タップ位置配置モードのツール(.text / .todo)。nil のとき通常のタップ(選択解除)。
    var placementTool: CanvasTool?
    /// 配置モードでキャンバスをタップしたとき(ツール, コンテンツ座標)。オブジェクトを同期生成する。
    var onPlaceObject: ((CanvasTool, CGPoint) -> CanvasObjectItem?)?

    /// 画面回転・Split View 等で bounds が変わったとき呼ぶ(スクロール制限の再計算用)。
    var onBoundsChange: (() -> Void)?
    private var lastLayoutBoundsSize: CGSize = .zero

    // MARK: - 自前ピンチによる焦点ズーム
    // UIScrollView 組み込みのピンチは「hitTest がオブジェクト(objectLayer 配下)を返す領域で
    // 始まると、pinchGestureRecognizer は発火するのにズームを適用しない」ため、オブジェクトの上で
    // 拡大縮小できない。組み込みピンチは無効化し(init 参照)、コンテナ最上位に付けた自前の
    // ピンチ認識器で全ズームを焦点ズームとして統一駆動する(空き領域/オブジェクト上を問わず一貫)。
    /// ピンチ開始時のズーム倍率(このピンチの相対 scale を掛ける基準)。
    private var pinchStartZoom: CGFloat = 1
    /// 自前ピンチによるズームが進行中か(スクロールのクランプ/ワールド再計算をこの間は保留する)。
    private(set) var isSupplementalZooming = false
    /// ズームが確定したとき(ピンチ終了)に呼ぶ。無限ワールドの再計算に使う。
    var onSupplementalZoomEnded: (() -> Void)?

    /// 選択モード: 選択中の単指ドラッグはオブジェクト移動に使うため、スクロールは2本指に限定。
    var isSelectMode = false {
        didSet {
            guard isSelectMode != oldValue else { return }
            objectLayer.isSelectMode = isSelectMode
            updateScrollTouchRequirement()
        }
    }
    /// 投げ縄選択モード(`.lasso` ツール中)。単指=自前投げ縄、2指=スクロール。
    var isLassoMode = false {
        didSet {
            guard isLassoMode != oldValue else { return }
            lassoPan.isEnabled = isLassoMode
            updateScrollTouchRequirement()
            if !isLassoMode { objectLayer.clearLassoSelection() }
        }
    }
    private func updateScrollTouchRequirement() {
        scrollView.panGestureRecognizer.minimumNumberOfTouches = (isSelectMode || isLassoMode) ? 2 : 1
    }

    /// 自前投げ縄の描画ジェスチャ(指・Pencil 両対応、単指)。isLassoMode 中のみ有効。
    private lazy var lassoPan: UIPanGestureRecognizer = {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleLassoPan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        pan.isEnabled = false
        return pan
    }()
    var onLassoPan: ((UIPanGestureRecognizer) -> Void)?
    @objc private func handleLassoPan(_ gesture: UIPanGestureRecognizer) { onLassoPan?(gesture) }

    override init(frame: CGRect) {
        super.init(frame: frame)
        overrideUserInterfaceStyle = .light
        let size = DynamicCanvasBounds.initialWorldSize
        let content = CGRect(x: 0, y: 0, width: size, height: size)

        // 外側スクロールビュー(画面全面)
        scrollView.isScrollEnabled = true
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.minimumZoomScale = 0.1
        scrollView.maximumZoomScale = 4.0  // Freeform に合わせて 400%
        // ピンチで上限(400%)/下限(10%)を超えて弾く挙動を無効化し、範囲外の倍率へ一時的にも
        // 到達させない(Freeform 準拠のハードクランプ)。
        scrollView.bouncesZoom = false
        scrollView.delaysContentTouches = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.backgroundColor = .clear
        // スクロール/ズームは指(.direct)のみ。Apple Pencil は手書き専用にして、Pencil が
        // 領域移動(パン)やズームに使われないようにする(Pencil=描画 / 指=スクロール&ズーム)。
        let directOnly = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        scrollView.panGestureRecognizer.allowedTouchTypes = directOnly
        scrollView.pinchGestureRecognizer?.allowedTouchTypes = directOnly

        // 背景(patternView)は「画面固定」で最背面へ。ズーム transform で拡大しないので
        // タイル継ぎ目の格子線が出ない(draw(_:) がオフセット/ズームから世界固定ドットを直描き)。
        patternView.frame = bounds
        patternView.isUserInteractionEnabled = false
        addSubview(patternView)   // scrollView より先 = 最背面
        addSubview(scrollView)

        // ズーム対象 contentView(世界座標サイズ、透過)
        contentView.frame = content
        contentView.backgroundColor = .clear
        scrollView.addSubview(contentView)
        scrollView.contentSize = content.size  // 初期ズーム 1.0

        // オブジェクト層は contentView(ズーム対象)へ内包(背景の上・インクの下)。
        objectLayer.frame = content
        contentView.addSubview(objectLayer)

        let allowFingerDrawing = ProcessInfo.processInfo.environment["ALLOW_FINGER_DRAWING"] == "1"
        // インク面は contentView の外(scrollView 直下・最前面)へ、ビューポートサイズで置く。
        // worldSize のインクを contentView 直下に置くと PencilKit が巨大テクスチャにライブ描画を
        // 出せないため、インクは「ビューポートの窓」として外側の offset/zoom をミラーする(updateInkWindow)。
        canvasView.frame = CGRect(origin: .zero,
                                  size: bounds.size == .zero ? CGSize(width: 1400, height: 1000) : bounds.size)
        canvasView.isScrollEnabled = false
        canvasView.drawingPolicy = allowFingerDrawing ? .anyInput : .pencilOnly
        canvasView.contentInsetAdjustmentBehavior = .never
        // ズーム倍率は外側にミラーするため 0.1〜4.0 を許可(自身の pan/pinch は無効化済み)。
        canvasView.minimumZoomScale = 0.1
        canvasView.maximumZoomScale = 4.0
        canvasView.bounces = false
        canvasView.bouncesZoom = false
        canvasView.showsHorizontalScrollIndicator = false
        canvasView.showsVerticalScrollIndicator = false
        canvasView.panGestureRecognizer.isEnabled = false
        canvasView.pinchGestureRecognizer?.isEnabled = false
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false

        drawingTouchGate.forward = canvasView.drawingGestureRecognizer.delegate
        canvasView.drawingGestureRecognizer.delegate = drawingTouchGate
        canvasView.objectLayer = objectLayer
        canvasView.containerScrollView = scrollView
        canvasView.addGestureRecognizer(lassoPan)
        // ズームは自前のピンチ認識器で焦点ズームを統一駆動する。
        // UIScrollView 組み込みのピンチは (1) hitTest がオブジェクトを返す領域では発火しても
        // ズームを適用しない (2) `scale` を内部で書き換えるため相乗り制御が破綻する、の2点で
        // オブジェクト上ピンチに使えない。組み込みピンチは無効化し、コンテナ最上位に付けた
        // 認識器(=どのビュー上のタッチも受け取れる)で scrollView.zoomScale を直接動かす。
        scrollView.pinchGestureRecognizer?.isEnabled = false
        let zoomPinch = UIPinchGestureRecognizer(target: self, action: #selector(handleZoomPinch(_:)))
        zoomPinch.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]  // 指のみ(Pencil=描画)
        zoomPinch.delegate = self
        addGestureRecognizer(zoomPinch)

        scrollView.addSubview(canvasView)  // contentView より後 = 最前面(scrollView 直下)

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
        patternView.frame = bounds   // 背景は画面固定(全面)
        if bounds.size != lastLayoutBoundsSize {
            lastLayoutBoundsSize = bounds.size
            onBoundsChange?()
        }
    }

    /// 自前ピンチによる焦点ズーム。2本指の中点(pivot)を画面上に固定したまま、開始時倍率 ×
    /// このピンチの相対 scale を目標倍率にする。オブジェクト上でも空き領域でも一貫して動く。
    @objc private func handleZoomPinch(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began:
            pinchStartZoom = scrollView.zoomScale
            isSupplementalZooming = true
        case .changed:
            guard g.numberOfTouches >= 2, g.scale.isFinite, g.scale > 0 else { return }
            let target = max(scrollView.minimumZoomScale,
                             min(scrollView.maximumZoomScale, pinchStartZoom * g.scale))
            applyFocalZoom(to: target, pivot: g.location(in: scrollView))
        case .ended, .cancelled, .failed:
            if isSupplementalZooming {
                isSupplementalZooming = false
                onSupplementalZoomEnded?()
            }
        default:
            break
        }
    }

    /// 2本指の中点を画面上で固定したまま zoomScale を target にする(焦点ズーム)。
    /// - pivot: `location(in: scrollView)` の点。scrollView 座標系 = スケール済みコンテンツ座標で、
    ///   可視域は `[contentOffset, contentOffset + viewport]`(pivot は既に contentOffset を含む)。
    private func applyFocalZoom(to target: CGFloat, pivot: CGPoint) {
        let old = scrollView.zoomScale
        guard old > 0, target.isFinite, abs(target - old) > 0.0001 else { return }
        let off0 = scrollView.contentOffset
        // 指の「画面(ビューポート)上の位置」と、その直下の「非ズームのコンテンツ点」。
        let screen = CGPoint(x: pivot.x - off0.x, y: pivot.y - off0.y)
        let unscaled = CGPoint(x: pivot.x / old, y: pivot.y / old)
        scrollView.zoomScale = target   // scrollViewDidZoom が発火しミラー(背景/ink/オブジェクト)追従
        // ズーム後も同じコンテンツ点が同じ画面位置に来るよう offset を決める。
        let newOffset = CGPoint(x: unscaled.x * target - screen.x,
                                y: unscaled.y * target - screen.y)
        guard newOffset.x.isFinite, newOffset.y.isFinite else { return }
        scrollView.contentOffset = newOffset
    }

    @objc private func handleBackgroundTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: objectLayer)
        if let tool = placementTool {
            if drawingTouchGate.isTouchAllowed?(point) ?? true,
               let item = onPlaceObject?(tool, point) {
                objectLayer.placeAndFocus(item: item)
            }
            return
        }
        if objectLayer.hasLassoSelection, !objectLayer.lassoViewContains(contentPoint: point) {
            objectLayer.clearLassoSelection()
        }
        objectLayer.handleBackgroundTap(at: point)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        return true
    }

    /// 自前投げ縄は「空き領域(オブジェクト・投げ縄枠の上でない)」から始まったときだけ開始する。
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === lassoPan {
            let point = lassoPan.location(in: objectLayer)
            return !objectLayer.lassoShouldYield(atContentPoint: point)
        }
        return true
    }
}

/// PKCanvasView の描画ジェスチャに差し込む delegate。ノートリンクの「開く」ボタン上で
/// 始まるタッチだけストロークを拒否し、それ以外は PencilKit 本来の delegate へ透過する。
/// (forwardingTarget で未実装メソッドを元 delegate に委譲し、描画挙動を壊さない)
final class DrawingTouchGate: NSObject, UIGestureRecognizerDelegate {
    weak var forward: UIGestureRecognizerDelegate?

    /// タッチ位置(コンテンツ座標=ズーム非依存の用紙座標)が有効な描画領域かを判定する。
    /// nil の場合は制限しない。通常ノートでは用紙(ページ矩形)内のみ true にして、
    /// 用紙外(グレー背景)の描画を防ぐ。
    var isTouchAllowed: ((CGPoint) -> Bool)?

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldReceive touch: UITouch) -> Bool {
        if touch.view is NoteLinkOpenButton { return false }

        // Apple Pencil または Stylus のタッチは 100% 無条件で描画を許可する！
        // スクロール移動になることは物理的に 100% あり得ない！
        if touch.type == .pencil || touch.type == .stylus {
            return true
        }

        let allowFinger = ProcessInfo.processInfo.environment["ALLOW_FINGER_DRAWING"] == "1"
        // 指(direct)のタッチは、pencilOnly モード(通常使用)では描画ジェスチャが受ける必要がない。
        // false を返すことで描画ジェスチャが指タッチを横取りして握り潰すのを完全に防ぎ、
        // 背後の outer scrollView の pan/pinch ジェスチャへ 100% 確実に透過させる！
        if !allowFinger && touch.type == .direct {
            return false
        }
        if touch.type == .direct, touchBeganOnObject(touch) { return false }
        // 用紙外(通常ノートのグレー余白)など、描画を許可しない領域ではストロークを始めない。
        if let isTouchAllowed, let view = gestureRecognizer.view {
            let zoomScale = (view as? UIScrollView)?.zoomScale ?? 1
            let rawPoint = touch.location(in: view)
            let contentPoint = Self.contentPoint(fromRaw: rawPoint, zoomScale: zoomScale)
            if !isTouchAllowed(contentPoint) { return false }
        }
        if touch.type != .direct { return true }
        return forward?.gestureRecognizer?(gestureRecognizer, shouldReceive: touch) ?? true
    }

    /// キャンバス(UIScrollView)自身の bounds 座標系にある生タッチ座標を、
    /// zoomScale 非依存のコンテンツ座標(pageRects と同じ座標系)へ変換する。
    /// UIKit 非依存の純ロジックなのでユニットテストで担保する。
    static func contentPoint(fromRaw raw: CGPoint, zoomScale: CGFloat) -> CGPoint {
        CGPoint(x: raw.x / zoomScale, y: raw.y / zoomScale)
    }

    /// タッチがオブジェクト(CanvasObjectUIView)の上で始まったか。
    /// hitTest が指タッチをオブジェクトへ通すため、touch.view から親を辿って判定できる。
    private func touchBeganOnObject(_ touch: UITouch) -> Bool {
        var view = touch.view
        while let current = view {
            if current is CanvasObjectUIView { return true }
            view = current.superview
        }
        return false
    }

    // shouldReceive 以外の UIGestureRecognizerDelegate 呼び出しは元 delegate へ丸ごと安全にプロキシ委譲する
    override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) { return true }
        return forward?.responds(to: aSelector) ?? false
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let forward = forward, forward.responds(to: aSelector) {
            return forward
        }
        return super.forwardingTarget(for: aSelector)
    }

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
    private var pagedLayout = PagedLayoutCalculator(pageCount: 1, isTwoPageLayout: false, isHorizontalScroll: false)
    /// configure() 中は didSet の逐次 rebuild を抑止し、最後に一度だけ再構築する
    private var isConfiguring = false
    /// タイルのレンダリング解像度。ズームインで拡大されても線がボケないよう倍率を上げる
    private var tileScale: CGFloat = UIScreen.main.scale
    /// 現在のズーム倍率(無限キャンバスのダイナミックグリッド用)
    private var currentZoom: CGFloat = 1.0
    /// 現在のコンテンツオフセット(無限キャンバスの画面固定背景描画用)
    private var currentOffset: CGPoint = .zero
    /// paged 用のページビュー(1枚 = 1ページ)
    private var pageViews: [UIView] = []

    /// 無限キャンバスのドット間隔はコンテンツ(世界)空間で **固定**(base=40pt)。
    /// パターンはズーム合成で拡縮されるため、拡大すると画面内のドット数は減り(1つ1つは大きくなる)、
    /// 縮小すると増える = 背景を世界に固定する Freeform 同等の挙動。純ロジック(テスト対象)。
    static func infiniteSpacing(base: CGFloat = spacing) -> CGFloat { base }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false  // タッチはインク/オブジェクトへ通す
        clipsToBounds = false              // ページの影がすき間へ落ちるように
        rebuild()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// ノート形式・ページ配置・スタイル・用紙色をまとめて反映(変化時のみ再構築)。
    func configure(noteType: CanvasNoteType, layout: PagedLayoutCalculator, style: CanvasBackgroundStyle, pageColor: CanvasPageColor) {
        let changed = noteType != self.noteType || layout != self.pagedLayout
            || style != self.style || pageColor != self.pageColor
        guard changed else { return }
        isConfiguring = true
        self.noteType = noteType
        self.pagedLayout = layout
        self.style = style
        self.pageColor = pageColor
        isConfiguring = false
        rebuild()
    }

    /// ズーム時に呼ばれ、タイルのレンダリング解像度と表示帯(密度レベル)を更新して焼き直す。
    /// タイル間隔はコンテンツ空間で固定(Freeform 準拠)。画面上の見かけの拡縮は
    /// スクロールビューのズーム合成が担うため、ここでは間隔を動かさない。
    func applyZoom(_ zoom: CGFloat) {
        // 無限キャンバスの背景は画面固定のベクター描画。ズーム時は tileScale ではなく
        // currentZoom を更新して draw(_:) を焼き直す(間隔・ドット径はズームに比例=世界固定)。
        guard noteType == .infinite else { return }
        if currentZoom != zoom {
            currentZoom = zoom
            setNeedsDisplay()
        }
    }

    /// 無限キャンバス(Freeform)の板の色。白紙は Freeform 風の淡いグレー板、黒紙はそのまま黒。
    private var infiniteBoardColor: UIColor {
        switch pageColor {
        case .white: UIColor(white: 0.949, alpha: 1)  // ≈ systemGray6 相当の淡いグレー
        case .black: pageColor.backgroundUIColor
        }
    }

    private func rebuild() {
        switch noteType {
        case .infinite:
            pageViews.forEach { $0.removeFromSuperview() }
            pageViews.removeAll()
            // 無限キャンバスの背景は「画面固定のベクター描画」(draw(_:))で描く。
            // patternImage をズーム transform で拡大すると、タイル境界が格子線として現れる
            // (非整数倍のリサンプリングによる継ぎ目)。ベクター直描きなら継ぎ目が出ない。
            backgroundColor = infiniteBoardColor
            isOpaque = true
            contentMode = .redraw
            setNeedsDisplay()
        case .paged:
            backgroundColor = .systemGray5  // 机(背景)のグレー
            rebuildPages()
        }
    }

    /// スクロール/ズームのたびに呼ばれ、画面固定のドット/罫線を再描画するための
    /// ビューポート(コンテンツオフセット・ズーム)を受け取る(無限キャンバスのみ)。
    func updateViewport(contentOffset: CGPoint, zoomScale: CGFloat) {
        guard noteType == .infinite else { return }
        guard currentOffset != contentOffset || currentZoom != zoomScale else { return }
        currentOffset = contentOffset
        currentZoom = zoomScale
        setNeedsDisplay()
    }

    /// 無限キャンバスの背景を画面座標で直接描く(タイル継ぎ目のない世界固定ドット/罫線)。
    /// 世界座標 W の画面位置は screen = W * zoom - contentOffset。間隔・ドット径はズームに比例
    /// させて世界に固定する(拡大するとドット数は減り1つが大きくなる = Freeform 準拠)。
    override func draw(_ rect: CGRect) {
        guard noteType == .infinite, let c = UIGraphicsGetCurrentContext() else { return }
        infiniteBoardColor.setFill()
        c.fill(rect)
        guard style != .blank else { return }
        let zoom = max(currentZoom, 0.0001)
        let s = Self.spacing * zoom            // 画面上のマス間隔
        guard s >= 6 else { return }           // 密すぎる(ズームアウト)ときは描かない
        let ox = currentOffset.x, oy = currentOffset.y
        let color = pageColor.patternUIColor

        // 世界の格子境界(W = 40k)の画面 X = k*s - ox。画面内に来る最初の境界位置。
        func firstLine(_ o: CGFloat) -> CGFloat {
            let v = (-o).truncatingRemainder(dividingBy: s)
            return v < 0 ? v + s : v
        }
        let baseX = firstLine(ox), baseY = firstLine(oy)

        switch style {
        case .dots:
            // ドット中心は各マス中央(W = 40k + 20)→ 画面 = 境界 + s/2
            let d = max(1.0, 2.6 * zoom)
            color.setFill()
            var x = baseX + s / 2 - s
            while x < rect.width + s {
                var y = baseY + s / 2 - s
                while y < rect.height + s {
                    c.fillEllipse(in: CGRect(x: x - d / 2, y: y - d / 2, width: d, height: d))
                    y += s
                }
                x += s
            }
        case .grid:
            color.setStroke()
            c.setLineWidth(max(0.5, 0.5 * zoom))
            var x = baseX
            while x < rect.width + s { c.move(to: CGPoint(x: x, y: 0)); c.addLine(to: CGPoint(x: x, y: rect.height)); x += s }
            var y = baseY
            while y < rect.height + s { c.move(to: CGPoint(x: 0, y: y)); c.addLine(to: CGPoint(x: rect.width, y: y)); y += s }
            c.strokePath()
        case .lines:
            color.setStroke()
            c.setLineWidth(max(0.5, 0.5 * zoom))
            var y = baseY
            while y < rect.height + s { c.move(to: CGPoint(x: 0, y: y)); c.addLine(to: CGPoint(x: rect.width, y: y)); y += s }
            c.strokePath()
        case .blank:
            break
        }
    }

    /// paged: ページ矩形を用紙色 + 影 + 内側パターンのサブビューとして並べ直す。
    private func rebuildPages() {
        pageViews.forEach { $0.removeFromSuperview() }
        pageViews.removeAll()

        let pageBackground: UIColor = (style == .blank)
            ? pageColor.backgroundUIColor
            : UIColor(patternImage: makeTile())

        // 横スクロールは影を横方向へ、縦スクロールは下方向へ落として奥行きを出す
        let shadowOffset = pagedLayout.scrollsHorizontally
            ? CGSize(width: 2, height: 0) : CGSize(width: 0, height: 2)

        for index in 0..<max(1, pagedLayout.pageCount) {
            let page = UIView(frame: pagedLayout.pageRect(index))
            page.backgroundColor = pageBackground
            // 用紙らしい影とはっきりした境界線(ページの縁が分かるように)
            page.layer.shadowColor = UIColor.black.cgColor
            page.layer.shadowOpacity = 0.18
            page.layer.shadowRadius = 6
            page.layer.shadowOffset = shadowOffset
            page.layer.shadowPath = UIBezierPath(rect: page.bounds).cgPath
            page.layer.borderColor = UIColor.black.withAlphaComponent(0.14).cgColor
            page.layer.borderWidth = 1
            addSubview(page)
            pageViews.append(page)
        }

        // 横スクロールの見開き(2枚密着)は、ページ間の綴じ目(境界)を分かりやすく仕切る。
        if pagedLayout.isTwoPageLayout, pagedLayout.scrollsHorizontally {
            let w = PageMetrics.width, h = PageMetrics.height, gap = PageMetrics.gap
            let unitCount = (max(1, pagedLayout.pageCount) + 1) / 2
            for unit in 0..<unitCount {
                let seamX = CGFloat(unit) * (2 * w + gap) + w
                let divider = UIView(frame: CGRect(x: seamX - 1, y: 0, width: 2, height: h))
                divider.backgroundColor = UIColor.black.withAlphaComponent(0.22)
                divider.isUserInteractionEnabled = false
                addSubview(divider)
                pageViews.append(divider)
            }
        }
    }

    /// 1マス分のタイル画像。タイルには用紙色の下地も含めるので、これ一枚で全面を塗れる。
    /// 通常ノート(paged)は用紙固定の 40pt。無限キャンバスは `infiniteSpacing` で画面上の間隔が
    /// ほぼ一定になるようコンテンツ間隔を選び、ドット径・線幅も間隔に比例させて画面上一定に保つ
    /// (ズームインで肥大化しない = Freeform 準拠)。
    private func makeTile() -> UIImage {
        // 無限・paged とも間隔は固定 40pt(コンテンツ空間)。ズームで拡縮される。
        let spacing = Self.spacing  // = 40
        // Freeform 風の小さく控えめなドット/細い罫線(固定サイズ)。
        let dotSize: CGFloat = 2.6
        let lineWidth: CGFloat = 0.5

        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = tileScale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: spacing, height: spacing), format: format
        )
        // 無限キャンバスは Freeform 風の淡いグレー板、paged は用紙色(白/黒)を下地にする。
        let boardColor = (noteType == .infinite) ? infiniteBoardColor : pageColor.backgroundUIColor
        return renderer.image { ctx in
            let c = ctx.cgContext
            boardColor.setFill()
            c.fill(CGRect(x: 0, y: 0, width: spacing, height: spacing))

            switch style {
            case .grid:
                pageColor.patternUIColor.setStroke()
                c.setLineWidth(lineWidth)
                c.stroke(CGRect(x: 0, y: 0, width: spacing, height: spacing))
            case .dots:
                pageColor.patternUIColor.setFill()
                c.fillEllipse(in: CGRect(x: spacing / 2 - dotSize / 2, y: spacing / 2 - dotSize / 2,
                                         width: dotSize, height: dotSize))
            case .lines:
                pageColor.patternUIColor.setStroke()
                c.setLineWidth(lineWidth)
                c.move(to: CGPoint(x: 0, y: 0))
                c.addLine(to: CGPoint(x: spacing, y: 0))
                c.strokePath()
            case .blank:
                break
            }
        }
    }
}
