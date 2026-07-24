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
        let canvas = container.canvasView

        // 通常ノートのみ、ここで contentSize を確定する(ページ数・レイアウトから決定論的に計算できる)。
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
        let horizontal = noteType == .paged && isHorizontalScroll
        canvas.alwaysBounceHorizontal = horizontal
        canvas.alwaysBounceVertical = noteType != .paged || !isHorizontalScroll
        canvas.isPagingEnabled = false

        // ズーム倍率: 通常ノートは Goodnotes 風に控えめ、無限キャンバスは広めに許容する
        if isZoomLocked {
            // ズームロック中は min/max を現在値に固定してピンチズームを禁止
            let locked = canvas.zoomScale
            canvas.minimumZoomScale = locked
            canvas.maximumZoomScale = locked
        } else {
            switch noteType {
            case .paged:
                // 最小ズームは「用紙1枚がスクロール横断方向に画面へフィットする倍率」。
                // これ未満に縮小すると隣ページや余白が露出するため下限にする(固定 0.5 を廃止)。
                canvas.maximumZoomScale = 3.0
                canvas.minimumZoomScale = min(pagedMinimumZoom(for: canvas), canvas.maximumZoomScale)
            case .infinite:
                canvas.minimumZoomScale = 0.1
                // Freeform に合わせて上限 400%(背景の定常密度化で"広すぎ"体感は解消)
                canvas.maximumZoomScale = 4.0
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
        canvas.delegate = context.coordinator
        // はみ出し領域の色: 無限は用紙色、通常ノートは机のグレー
        container.backgroundColor = containerBackgroundColor
        container.objectLayer.pageColor = pageColor
        applyLayout(to: container)
        if noteType == .infinite {
            // bounds 未確定でもコンテンツ量だけでワールドサイズの初期値を確保しておく
            // (bounds 確定後に async ブロックで正確に計算し直す)。
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

        // 初期ビューポート(保存がなければ形式ごとの初期位置)
        DispatchQueue.main.async {
            if let viewport = initialViewport {
                canvas.zoomScale = viewport.zoomScale
                if noteType == .paged {
                    // 画面サイズの変化(回転/Split View)に耐えるため、横断方向(センタリング側)は
                    // 中央寄せに任せ、復元するのはズームとスクロール方向の位置のみ。
                    canvas.contentOffset = isHorizontalScroll
                        ? CGPoint(x: viewport.contentOffset.x, y: 0)
                        : CGPoint(x: 0, y: viewport.contentOffset.y)
                } else {
                    canvas.contentOffset = viewport.contentOffset
                }
            } else if noteType == .paged {
                fitPaged(canvas)  // ページを画面にフィット + 先頭ページへ
            } else {
                let size = context.coordinator.worldSize
                canvas.contentOffset = CGPoint(
                    x: (size - canvas.bounds.width) / 2,
                    y: (size - canvas.bounds.height) / 2
                )
            }
            if noteType == .paged { centerPagedContent(canvas) }
            if noteType == .infinite {
                // bounds 確定後にワールドサイズ・スクロール制限を計算し直し、復元位置も範囲内へ収める
                context.coordinator.refreshInfiniteWorld(in: container)
                canvas.contentOffset = context.coordinator.clampedInfiniteOffset(canvas.contentOffset, for: canvas)
            }
            // 復元したズームをスナップ閾値・背景タイル解像度へ反映
            container.objectLayer.applyZoom(canvas.zoomScale)
            container.patternView.applyZoom(canvas.zoomScale)
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
    private func pagedMinimumZoom(for canvas: PKCanvasView) -> CGFloat {
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
    private func fitPaged(_ canvas: PKCanvasView) {
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
    private func centerPagedContent(_ canvas: PKCanvasView) {
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
                fitPaged(canvas)
                centerPagedContent(canvas)
                container.patternView.applyZoom(canvas.zoomScale)
            }
        } else if noteType == .paged, pageCount > context.coordinator.lastPageCount {
            // ページが増えたら、新しいページへスクロール方向に沿って滑らかに移動(中央寄せ)
            centerPagedContent(canvas)
            let lastRect = layout.pageRect(pageCount - 1)
            let target: CGPoint = isHorizontalScroll
                ? CGPoint(x: PagePlanner.scrollOffsetX(toPage: pageCount - 1, zoomScale: canvas.zoomScale,
                                                       layout: layout, margin: PageMetrics.margin,
                                                       viewWidth: canvas.bounds.width),
                          y: canvas.contentOffset.y)
                : CGPoint(x: canvas.contentOffset.x, y: lastRect.minY * canvas.zoomScale - PageMetrics.margin)
            canvas.setContentOffset(target, animated: true)
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
                    toPage: target, zoomScale: canvas.zoomScale,
                    layout: targetLayout, margin: PageMetrics.margin,
                    viewWidth: canvas.bounds.width
                )
                let destination = CGPoint(x: offsetX, y: canvas.contentOffset.y)
                // 矢印タップ由来のプログラムスクロール中は、PencilKit が座標移動を「長押し」と
                // 誤検知して手書きメニュー(Select All / Insert Space)を暴発させることがある。
                // アニメーション中は画面全体の入力を遮断し、完了後に戻す。
                canvas.isUserInteractionEnabled = false
                UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseInOut]) {
                    canvas.contentOffset = destination
                } completion: { _ in
                    canvas.isUserInteractionEnabled = true
                    self.onScrollHandled()
                    context.coordinator.isScrollPending = false
                }
            }
        }

        // ズームを 100% に戻して表示を中央へ寄せる(左上バッジのメニューから)
        if resetZoomRequested {
            DispatchQueue.main.async {
                UIView.animate(withDuration: 0.25) {
                    canvas.zoomScale = 1.0
                    if noteType == .paged {
                        self.centerPagedContent(canvas)
                        let offsetX = PagePlanner.scrollOffsetX(
                            toPage: 0, zoomScale: 1.0, layout: self.layout,
                            margin: PageMetrics.margin, viewWidth: canvas.bounds.width
                        )
                        canvas.contentOffset = CGPoint(x: offsetX, y: -PageMetrics.margin)
                    } else {
                        // ワールドサイズ・スクロール制限を新ズームで計算し直し、中央がコンテンツから
                        // 遠い場合は許可範囲(コンテンツ+余白)内へクランプする
                        context.coordinator.refreshInfiniteWorld(in: container)
                        let size = context.coordinator.worldSize
                        canvas.contentOffset = context.coordinator.clampedInfiniteOffset(
                            CGPoint(
                                x: (size - canvas.bounds.width) / 2,
                                y: (size - canvas.bounds.height) / 2
                            ),
                            for: canvas
                        )
                    }
                }
                container.objectLayer.applyZoom(1.0)
                container.patternView.applyZoom(1.0)
                self.onZoomResetHandled()
            }
        }

        // コンテンツ全体を画面に収める(Zoom to Fit、infinite のみ)
        if zoomToFitRequested, noteType == .infinite {
            DispatchQueue.main.async {
                context.coordinator.refreshInfiniteWorld(in: container)
                if let fit = ZoomToFit.fit(
                    contentUnion: infiniteContentUnion, viewportSize: canvas.bounds.size,
                    minZoom: canvas.minimumZoomScale, maxZoom: canvas.maximumZoomScale
                ) {
                    UIView.animate(withDuration: 0.3) {
                        canvas.zoomScale = fit.zoomScale
                        context.coordinator.refreshInfiniteWorld(in: container)
                        canvas.contentOffset = context.coordinator.clampedInfiniteOffset(fit.contentOffset, for: canvas)
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

        /// 無限キャンバスのワールドサイズ(= contentSize の一辺)を、現在のコンテンツに合わせて
        /// 更新する。右・下方向は worldSize を伸ばすだけ、左・上方向は端に近づいたら
        /// 原点リベース(ストローク・オブジェクト座標・contentOffset を一括平行移動)で対応する。
        /// applyLayout 相当の反映(contentSize/フレーム/スクロール制限)もここでまとめて行う。
        /// 描画・オブジェクトの変化、ズーム、bounds 変化のたびに呼び直す(冪等)。
        func refreshInfiniteWorld(in container: CanvasContainerUIView) {
            guard parent.noteType == .infinite else { return }
            // ピンチズーム中は contentSize/contentInset/原点リベースを一切触らない。
            // スクロール制限の負の contentInset はズーム倍率に比例するため、ズーム中に毎フレーム
            // 書き換えるとピンチのアンカーが原点方向へずれ、オブジェクトが右下/左上へドリフトする。
            // ズーム確定後(scrollViewDidEndZooming)にまとめて適用する。
            guard !container.canvasView.isZooming else { return }
            if let delta = DynamicCanvasBounds.rebaseDelta(contentUnion: parent.infiniteContentUnion) {
                rebaseOrigin(by: delta, in: container)
            }
            worldSize = DynamicCanvasBounds.expandedWorldSize(
                contentUnion: parent.infiniteContentUnion, currentWorldSize: worldSize
            )
            applyWorldSize(to: container)
        }

        /// worldSize をキャンバスの contentSize・背景/オブジェクトレイヤーのフレーム・
        /// スクロール制限(InfiniteScrollLimiter)へ反映する。
        private func applyWorldSize(to container: CanvasContainerUIView) {
            let canvas = container.canvasView
            let size = CGSize(width: worldSize, height: worldSize)
            if canvas.contentSize != size {
                canvas.contentSize = size
                container.patternView.frame = CGRect(origin: .zero, size: size)
                container.objectLayer.frame = CGRect(origin: .zero, size: size)
            }
            guard canvas.bounds.width > 0, canvas.bounds.height > 0 else { return }
            let allowed = InfiniteScrollLimiter.allowedRect(
                contentUnion: parent.infiniteContentUnion,
                viewportSize: canvas.bounds.size, zoomScale: canvas.zoomScale, canvasSize: worldSize
            )
            canvas.contentInset = InfiniteScrollLimiter.insets(
                allowedRect: allowed, zoomScale: canvas.zoomScale, canvasSize: worldSize
            )
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

        /// 原点リベース: コンテンツが左・上端の余白を切ったら、ストローク・オブジェクト座標・
        /// contentOffset を delta だけ一括平行移動し、見た目を変えずに原点を再定義する
        /// (座標を負にできない PKCanvasView の制約下で、左・上方向への無限拡張を可能にする)。
        /// 内部座標系の実装詳細でありユーザー操作ではないため、Undo には登録しない。
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

        /// スクロール中の追従はスクロールビューが行うため、ここではビューポート保存だけ(軽量)。
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            parent.onViewportChanged(
                CanvasViewport(contentOffset: scrollView.contentOffset, zoomScale: scrollView.zoomScale)
            )
        }

        /// 通常ノート(横スクロール)で、スクロール限界より右へバウンス(オーバースクロール)した量(pt)。
        /// ページを増やせない状況(無限/縦)や末尾でないときは 0。
        /// コンテンツが画面より狭い場合でも「限界を超えて引っ張った量」だけを測る。
        private func rightOverscroll(_ scrollView: UIScrollView) -> CGFloat {
            guard parent.noteType == .paged, parent.isHorizontalScroll else { return 0 }
            let contentW = parent.layout.contentSize.width * scrollView.zoomScale
            // 右端の通常スクロール限界(バウンスしていない最大 contentOffset.x)
            let maxOffsetX = max(-scrollView.contentInset.left,
                                 contentW - scrollView.bounds.width + scrollView.contentInset.right)
            return scrollView.contentOffset.x - maxOffsetX
        }

        /// 末尾を超えて一定量めくったら、指を離した時点でページを1枚追加する(GoodNotes 風)。
        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            // しきい値: 画面幅の15%(上限140pt)を超えて引っ張ったら追加
            let threshold = min(scrollView.bounds.width * 0.15, 140)
            if !didRequestPageAppend, rightOverscroll(scrollView) > threshold {
                didRequestPageAppend = true   // updateUIView でページ数増加を検知したら解除
                parent.onAppendPage()
            }
        }

        /// カスタムページスナップ: ドラッグ終了時にフリック速度とズームを考慮して
        /// 最寄りのページ左端へスクロールをスナップさせる。
        /// isPagingEnabled(bounds.width 単位)では通常ノートのページ実幅とズレるため、
        /// PagePlanner.scrollOffsetX で正確なスナップ先を算出する。
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

            // 現在ビューポート中心に最も近いページを取得
            let currentPage = PagePlanner.currentPage(
                contentOffsetX: scrollView.contentOffset.x,
                viewWidth: scrollView.bounds.width,
                zoomScale: zoomScale,
                layout: layout
            )

            // フリック速度に応じて遷移先ページを決定
            var targetPage = currentPage
            let velocityThreshold: CGFloat = 0.2
            if velocity.x > velocityThreshold {
                targetPage = min(pageCount - 1, currentPage + 1)
            } else if velocity.x < -velocityThreshold {
                targetPage = max(0, currentPage - 1)
            }

            // 目的ページを中央(収まる場合)/左マージン(超える場合)へスナップ
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

        /// ズーム時のみ、スナップ閾値用の倍率更新と背景タイルの高解像度化を行う(スクロールには不干渉)。
        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            container?.objectLayer.applyZoom(scrollView.zoomScale)
            container?.patternView.applyZoom(scrollView.zoomScale)
            // 通常ノートはズームしてもページを横断方向の中央に保つ(グレー余白を調整)
            if parent.noteType == .paged, let canvas = container?.canvasView,
               let inset = parent.pagedContentInset(for: canvas) {
                canvas.contentInset = inset
            }
            // 無限キャンバスのワールドサイズ/スクロール制限の再計算はズーム中は行わない
            // (refreshInfiniteWorld は isZooming 中は no-op)。確定後に scrollViewDidEndZooming で適用する。
            parent.onViewportChanged(
                CanvasViewport(contentOffset: scrollView.contentOffset, zoomScale: scrollView.zoomScale)
            )
        }

        /// ピンチズーム確定後に、無限キャンバスのワールドサイズ/スクロール制限をまとめて適用する
        /// (ズーム中に触るとアンカーがずれるため、ここで一度だけ)。
        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            guard parent.noteType == .infinite, let container else { return }
            refreshInfiniteWorld(in: container)
            scrollView.contentOffset = clampedInfiniteOffset(scrollView.contentOffset, for: scrollView)
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
    /// オブジェクトに当たったタッチは(入力の種類に関係なく)常にオブジェクトへ通す。
    /// 指とペンの振り分けはここではなく、それぞれのジェスチャ側で行う:
    /// - オブジェクトの選択・移動・長押しジェスチャは allowedTouchTypes=.direct(指のみ)。
    /// - Apple Pencil のタッチはオブジェクト上でも、祖先の PKCanvasView の描画ジェスチャが
    ///   受け取ってそのまま描ける(DrawingTouchGate が指のオブジェクト上描画だけ弾く)。
    /// 空き領域(objectLayer 自身)や用紙外は super に委ね、単指スクロールを維持する。
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

final class CanvasContainerUIView: UIView, UIGestureRecognizerDelegate {
    let canvasView = ObjectAccessibleCanvasView()
    let patternView = BackgroundPatternUIView()
    let objectLayer = ObjectLayerUIView()
    /// 描画ジェスチャに差し込むゲート(「開く」ボタン上・用紙外ではインクを始めない)
    let drawingTouchGate = DrawingTouchGate()

    /// タップ位置配置モードのツール(.text / .todo)。nil のとき通常のタップ(選択解除)。
    var placementTool: CanvasTool?
    /// 配置モードでキャンバスをタップしたとき(ツール, コンテンツ座標)。
    /// オブジェクトを同期生成し、生成したビューを作るための item を返す(nil で配置なし)。
    /// タップのタッチ文脈内で beginTextEditing まで行うため、ここでオブジェクトを確定させる。
    var onPlaceObject: ((CanvasTool, CGPoint) -> CanvasObjectItem?)?

    /// 画面回転・Split View のリサイズ等で bounds のサイズが変わったときに呼ばれる。
    /// 通常ノートの横断方向センタリング(contentInset)はズーム時にしか再計算されないため、
    /// bounds 変化にも追従させて呼び出し側から再計算させる。
    var onBoundsChange: (() -> Void)?
    private var lastLayoutBoundsSize: CGSize = .zero

    /// 選択モード(オブジェクトを1つ選択している状態)。
    /// オブジェクトがスクロールビュー内部にあるため、選択中の単指ドラッグが誤スクロールに
    /// ならないよう、選択中のスクロールは2本指に限定する(選択物は単指ドラッグで移動)。
    /// 描画ジェスチャは常に有効のまま(Pencil は選択中でも描ける)。指がインクを引かないのは
    /// pencilOnly と DrawingTouchGate(指×オブジェクトの除外)が担う。
    /// ※ ここで drawingGestureRecognizer を無効化しないこと。長押し等で選択が発生した瞬間に
    ///   ジェスチャ設定を変えると、進行中の長押し/メニュー提示がキャンセルされてしまう。
    var isSelectMode = false {
        didSet {
            guard isSelectMode != oldValue else { return }
            objectLayer.isSelectMode = isSelectMode
            updateScrollTouchRequirement()
        }
    }

    /// 投げ縄選択モード(`.lasso` ツール中、infinite のみ)。単指=自前投げ縄、2指=スクロール。
    var isLassoMode = false {
        didSet {
            guard isLassoMode != oldValue else { return }
            lassoPan.isEnabled = isLassoMode
            updateScrollTouchRequirement()
            if !isLassoMode { objectLayer.clearLassoSelection() }
        }
    }

    /// 選択/投げ縄中は単指ドラッグをオブジェクト操作・投げ縄に使うため、スクロールは2指に限定する。
    private func updateScrollTouchRequirement() {
        canvasView.panGestureRecognizer.minimumNumberOfTouches = (isSelectMode || isLassoMode) ? 2 : 1
    }

    /// 自前投げ縄の描画ジェスチャ(指・Pencil 両対応、単指)。isLassoMode 中のみ有効。
    private lazy var lassoPan: UIPanGestureRecognizer = {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleLassoPan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        pan.isEnabled = false
        return pan
    }()
    /// 投げ縄ジェスチャの各段階を Coordinator へ渡す(Coordinator が objectLayer 空間で座標を読む)。
    var onLassoPan: ((UIPanGestureRecognizer) -> Void)?

    @objc private func handleLassoPan(_ gesture: UIPanGestureRecognizer) {
        onLassoPan?(gesture)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        // 初期サイズはプレースホルダ(makeUIView が直後に applyLayout/refreshInfiniteWorld で
        // 実際のノート形式・コンテンツに応じたサイズへ上書きする)。
        let canvasSize = DynamicCanvasBounds.initialWorldSize

        // PencilKit はダークモード時にインク色を自動反転する(黒⇄白)が、
        // 用紙色(白/黒)はアプリ側で管理しているため反転を止め、選んだ色のまま描く
        overrideUserInterfaceStyle = .light

        // Apple Pencil でのみ描画する(Pencil Only)。指のタッチは描画に使わず、
        // スクロール(1本指)・ピンチズーム(2本指)として機能させる。
        // ※ allowsFingerDrawing は iOS14 以降非推奨のため、モダンな drawingPolicy を使う。
        // ※ XCUITest は Pencil 入力を模倣できないため、ALLOW_FINGER_DRAWING=1 のときだけ
        //   指描画を許可する(自動テストの描画検証用。製品では常に pencilOnly)。
        let allowFingerDrawing = ProcessInfo.processInfo.environment["ALLOW_FINGER_DRAWING"] == "1"
        canvasView.drawingPolicy = allowFingerDrawing ? .anyInput : .pencilOnly
        // 描画面を透過にして、最背面へ差し込む背景・オブジェクトを見せる(インクは常に上)。
        // 用紙色はコンテナ側で塗る(はみ出し/バウンス領域もこれで埋まる)。
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        canvasView.contentSize = CGSize(width: canvasSize, height: canvasSize)
        // contentInset はアプリ側で管理する(paged のセンタリング / infinite のスクロール制限)。
        // セーフエリアによる自動加算が混ざると負の inset の計算が狂うため無効化する。
        canvasView.contentInsetAdjustmentBehavior = .never
        canvasView.minimumZoomScale = 0.1
        canvasView.maximumZoomScale = 5.0
        canvasView.bouncesZoom = true
        // オブジェクトがスクロールビュー内部にあるため、長押し等のジェスチャが
        // スクロールの遅延タッチに邪魔されないよう、タッチを即座に子ビューへ渡す
        canvasView.delaysContentTouches = false
        // 描画ジェスチャの delegate を差し込む(元 delegate へは透過)。
        // ノートリンクの「開く」ボタン上のタッチではストロークを始めさせない。
        drawingTouchGate.forward = canvasView.drawingGestureRecognizer.delegate
        canvasView.drawingGestureRecognizer.delegate = drawingTouchGate
        canvasView.addGestureRecognizer(lassoPan)  // 自前投げ縄(isLassoMode 中のみ有効)
        addSubview(canvasView)

        // 背景 → オブジェクトの順でキャンバス最背面へ差し込む。
        // 前面の手書きインク(ペン・マーカー等)は PKCanvasView 自身が最前面に載せる。
        // 蛍光ペンは標準 PencilKit マーカーとして前面へ直接描く(背面ミラーは廃止)。
        // z順: 背景(patternView) < オブジェクト(objectLayer) < 前面インク(canvasView 本体)
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
        if bounds.size != lastLayoutBoundsSize {
            lastLayoutBoundsSize = bounds.size
            onBoundsChange?()
        }
    }

    @objc private func handleBackgroundTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: objectLayer)
        // 配置モード(テキスト/Todo): 用紙内(paged)を検証してオブジェクト作成コールバックを発火。
        // 用紙判定は描画ゲートと同じ isTouchAllowed を再利用する(無限は常に true)。
        if let tool = placementTool {
            if drawingTouchGate.isTouchAllowed?(point) ?? true,
               let item = onPlaceObject?(tool, point) {
                // タップのタッチ文脈内で生成・編集開始する。
                // render 経由の autoFocus では becomeFirstResponder がタッチ文脈外になり
                // ソフトキーボードが表示されないため、ここで同期的に focus する。
                objectLayer.placeAndFocus(item: item)
            }
            return
        }
        // 投げ縄選択中に「枠の外」をタップしたら選択解除(枠内・削除ボタンのタップは潰さない)
        if objectLayer.hasLassoSelection, !objectLayer.lassoViewContains(contentPoint: point) {
            objectLayer.clearLassoSelection()
        }
        objectLayer.handleBackgroundTap(at: point)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool { true }

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
        // 指(direct)のタッチがオブジェクトの上で始まったら描画しない(選択・移動へ回す)。
        // Apple Pencil のタッチはオブジェクトの上でもそのまま描ける(用紙に注釈できる)。
        if touch.type == .direct, touchBeganOnObject(touch) { return false }
        // 用紙外(通常ノートのグレー余白)など、描画を許可しない領域ではストロークを始めない。
        // touch.location(in: view) はキャンバス(UIScrollView)自身の bounds 座標系であり、
        // ズーム中は contentOffset 同様 zoomScale 倍されているため、pageRects(ズーム非依存の
        // コンテンツ座標)と比較する前に zoomScale で割ってコンテンツ座標へ戻す必要がある。
        if let isTouchAllowed, let view = gestureRecognizer.view {
            let zoomScale = (view as? UIScrollView)?.zoomScale ?? 1
            let rawPoint = touch.location(in: view)
            let contentPoint = Self.contentPoint(fromRaw: rawPoint, zoomScale: zoomScale)
            if !isTouchAllowed(contentPoint) { return false }
        }
        // Apple Pencil(=非 direct)は、オブジェクトの上・近傍でも常に描けるようにする。
        // PencilKit 既定 delegate(forward)は hitTest がオブジェクト(サブビュー)に当たる
        // タッチを弾くことがあり、オブジェクト周辺に「描き始められない領域」が生じるため、
        // Pencil は forward に委ねず許可する(注釈を上から描ける = Freeform 同等)。
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

    // shouldReceive 以外の UIGestureRecognizerDelegate 呼び出しは元 delegate へ丸ごと委譲する
    override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) { return true }
        return forward?.responds(to: aSelector) ?? false
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        forward
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
        // 無限キャンバスのドット間隔は固定(世界に固定)。ズームでは間隔は変えず、
        // 拡大時に線がボケないようレンダリング解像度(tileScale)だけ上げて焼き直す。
        currentZoom = zoom
        let target = min(max(UIScreen.main.scale * zoom, UIScreen.main.scale), 12)
        let scaleChanged = abs(target - tileScale) > 0.5
        if scaleChanged { tileScale = target; rebuild() }
    }

    /// 無限キャンバス(Freeform)の板の色。白紙は Freeform 風の淡いグレー板、黒紙はそのまま黒。
    /// (Freeform のボードは純白ではなく、うっすらグレーがかった中立色)
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
            backgroundColor = (style == .blank)
                ? infiniteBoardColor
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
