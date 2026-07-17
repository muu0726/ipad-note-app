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

/// 蛍光ペン(マーカー)の前面/背面表現を橋渡しするユーティリティ。
/// 前面キャンバス(全ストロークの正)ではマーカーを alpha 0 で不可視にして持ち、
/// オブジェクト背面の描画ミラーへは元の不透明度で描き直す。
enum MarkerLayer {
    /// 前面 drawing からマーカー種別のストロークだけを抜き出し、不透明度を戻した背面用 drawing。
    /// 前面での消しゴム(マスク)や移動はストロークごと反映されるので、mask/path はそのまま引き継ぐ。
    static func backingDrawing(from full: PKDrawing) -> PKDrawing {
        let markers = full.strokes.compactMap { stroke -> PKStroke? in
            guard stroke.ink.inkType == .marker else { return nil }
            var restored = stroke
            restored.ink = PKInk(.marker, color: stroke.ink.color.withAlphaComponent(PenToolState.markerAlpha))
            return restored
        }
        return PKDrawing(strokes: markers)
    }

    /// マーカーストロークを前面で不可視化(alpha 0)したコピー。inkType は marker のまま保つ。
    static func hidden(_ stroke: PKStroke) -> PKStroke {
        var hidden = stroke
        hidden.ink = PKInk(.marker, color: stroke.ink.color.withAlphaComponent(0))
        return hidden
    }

    /// ストロークが「まだ前面で可視のマーカー」(=描き終えた直後で背面へ回す必要がある)か。
    static func isVisibleMarker(_ stroke: PKStroke) -> Bool {
        stroke.ink.inkType == .marker && stroke.ink.color.cgColor.alpha > 0.01
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
    /// ノートリンクのダブルタップでリンク先ノートを開く要求
    let onNoteLinkActivated: (NSManagedObjectID) -> Void
    /// オブジェクトのユーザーロックをトグルする要求
    let onToggleUserLock: (NSManagedObjectID) -> Void
    /// 選択中の複数オブジェクトをグループ化する要求
    let onGroupObjects: ([NSManagedObjectID]) -> Void
    /// グループを解除する要求
    let onUngroupObjects: ([NSManagedObjectID]) -> Void
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

    /// 通常ノートのページ配置電卓(見開き × スクロール方向)
    private var layout: PagedLayoutCalculator {
        PagedLayoutCalculator(
            pageCount: pageCount,
            isTwoPageLayout: isTwoPageLayout,
            isHorizontalScroll: isHorizontalScroll
        )
    }

    /// ノート形式に応じたキャンバスのコンテンツサイズ
    private var contentSize: CGSize {
        switch noteType {
        case .infinite:
            return CGSize(width: Self.canvasSize, height: Self.canvasSize)
        case .paged:
            return layout.contentSize
        }
    }

    /// コンテンツサイズ・背景レイヤーのフレーム・ページ描画・スクロール方向を現在の形式へ合わせる。
    /// make と update の両方から呼ぶ(冪等)。
    private func applyLayout(to container: CanvasContainerUIView) {
        let size = contentSize
        let canvas = container.canvasView
        canvas.contentSize = size
        container.patternView.frame = CGRect(origin: .zero, size: size)
        container.markerBackView.frame = CGRect(origin: .zero, size: size)
        container.objectLayer.frame = CGRect(origin: .zero, size: size)

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
                canvas.minimumZoomScale = 0.5
                canvas.maximumZoomScale = 3.0
            case .infinite:
                canvas.minimumZoomScale = 0.1
                canvas.maximumZoomScale = 5.0
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

    func makeUIView(context: Context) -> CanvasContainerUIView {
        let container = CanvasContainerUIView()
        let canvas = container.canvasView
        canvas.drawing = drawing
        // 保存済み drawing に含まれるマーカー(前面では alpha 0)を背面ミラーへ復元描画する
        container.markerBackView.drawing = MarkerLayer.backingDrawing(from: drawing)
        context.coordinator.lastStrokeCount = drawing.strokes.count
        context.coordinator.seedPreviousDrawing(drawing)
        canvas.tool = pkTool
        canvas.delegate = context.coordinator
        // はみ出し領域の色: 無限は用紙色、通常ノートは机のグレー
        container.backgroundColor = containerBackgroundColor
        container.objectLayer.pageColor = pageColor
        applyLayout(to: container)
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
        container.objectLayer.onToggleUserLock = { [weak coordinator] id in
            coordinator?.parent.onToggleUserLock(id)
        }
        container.objectLayer.onGroupObjects = { [weak coordinator] ids in
            coordinator?.parent.onGroupObjects(ids)
        }
        container.objectLayer.onUngroupObjects = { [weak coordinator] ids in
            coordinator?.parent.onUngroupObjects(ids)
        }
        // 選択状態の変化を SwiftUI(PenToolState.isSelectMode)へ伝える。
        // これが選択モード(描画停止・単指操作)の真実のソースになる。
        container.objectLayer.onSelectionChanged = { [weak coordinator] hasSelection in
            coordinator?.parent.onSelectionChanged(hasSelection)
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
            container.markerBackView.applyZoom(canvas.zoomScale)
        }
        return container
    }

    /// 通常ノートの机(背景)色。無限は用紙色
    private var containerBackgroundColor: UIColor {
        noteType == .paged ? .systemGray5 : pageColor.backgroundUIColor
    }

    /// ページを画面に収まるようズームフィットし、先頭ページへ寄せる。
    /// 縦スクロール: 横断=幅をフィット。横スクロール: 横断=高さ(1ページ分)をフィット。
    private func fitPaged(_ canvas: PKCanvasView) {
        let bounds = canvas.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        let size = contentSize
        if isHorizontalScroll {
            let fit = min(canvas.maximumZoomScale,
                          max(canvas.minimumZoomScale, bounds.height * 0.94 / size.height))
            canvas.zoomScale = fit
            canvas.contentOffset = CGPoint(x: -PageMetrics.margin, y: canvas.contentOffset.y)
        } else {
            let fit = min(canvas.maximumZoomScale,
                          max(canvas.minimumZoomScale, bounds.width * 0.94 / size.width))
            canvas.zoomScale = fit
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
        let size = contentSize
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
        container.objectLayer.backgroundStyle = backgroundStyle
        container.objectLayer.pageColor = pageColor
        applyLayout(to: container)  // 背景スタイル・用紙色・ページ数・レイアウトの変化を反映

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
            // ページが増えたら、新しいページへスクロール方向に沿って滑らかに移動
            centerPagedContent(canvas)
            let lastRect = layout.pageRect(pageCount - 1)
            let target: CGPoint = isHorizontalScroll
                ? CGPoint(x: lastRect.minX * canvas.zoomScale - PageMetrics.margin, y: canvas.contentOffset.y)
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
                    layout: targetLayout, margin: PageMetrics.margin
                )
                canvas.setContentOffset(CGPoint(x: offsetX, y: canvas.contentOffset.y), animated: true)
                self.onScrollHandled()
                context.coordinator.isScrollPending = false
            }
        }

        context.coordinator.syncObjects(into: container.objectLayer)
        context.coordinator.handleAutoFocus(in: container.objectLayer)
        // モデル側から描画が差し替わった場合のみ反映(描画中の上書きを防ぐ)
        if !context.coordinator.isCanvasSourceOfTruth, canvas.drawing != drawing {
            canvas.drawing = drawing
            // 前面の差し替えに合わせて背面マーカーミラーも作り直す
            container.markerBackView.drawing = MarkerLayer.backingDrawing(from: drawing)
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
        /// 図形置換・マーカー背面化で drawing を差し替える間の再入を無視するフラグ(無限再描画ループ防止)
        private var isReplacingDrawing = false
        /// 投げ縄でのインク移動・削除を差分検知するための直前の描画
        private var previousDrawing = PKDrawing()
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
            guard parent.noteType == .paged, let canvas = container?.canvasView,
                  let inset = parent.pagedContentInset(for: canvas) else { return }
            canvas.contentInset = inset
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

            // 目的ページの左端オフセットへスナップ
            let targetX = PagePlanner.scrollOffsetX(
                toPage: targetPage,
                zoomScale: zoomScale,
                layout: layout,
                margin: margin
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
            container?.markerBackView.applyZoom(scrollView.zoomScale)
            // 通常ノートはズームしてもページを横断方向の中央に保つ(グレー余白を調整)
            if parent.noteType == .paged, let canvas = container?.canvasView,
               let inset = parent.pagedContentInset(for: canvas) {
                canvas.contentInset = inset
            }
            parent.onViewportChanged(
                CanvasViewport(contentOffset: scrollView.contentOffset, zoomScale: scrollView.zoomScale)
            )
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            // プログラムによる置換実行中の再入(drawing 差し替え/undo による通知)は完全にスキップ。
            if isReplacingDrawing { return }

            // 蛍光ペンの背面化: 描き終えた「1本だけ増えた」マーカーを前面では不可視(alpha 0)にし、
            // オブジェクトレイヤー下の背面ミラーへ回す。図形アシストより先に判定する
            // (マーカーは図形置換の対象にしない)。Undo で完全に消え、Redo で復元する。
            if canvasView.drawing.strokes.count == lastStrokeCount + 1,
               let last = canvasView.drawing.strokes.last,
               MarkerLayer.isVisibleMarker(last) {
                let oldDrawing = previousDrawing  // マーカーが追加される前の描画
                var newDrawing = canvasView.drawing
                newDrawing.strokes[newDrawing.strokes.count - 1] = MarkerLayer.hidden(last)

                // PencilKit が自動登録した「マーカー追加」の Undo を取り消し、置換のみを1手にする。
                isReplacingDrawing = true
                canvasView.undoManager?.undo()
                isReplacingDrawing = false

                // 前面は不可視マーカー入り、背面ミラーは可視で、双方向 Undo/Redo を成立させて置換。
                replaceDrawingWithUndoSupport(canvasView, to: newDrawing, from: oldDrawing)
                return
            }

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
            // 消しゴム・投げ縄などで前面マーカーが変化した可能性があるので背面ミラーを追従させる
            updateMarkerBackLayer(canvasView.drawing)

            isCanvasSourceOfTruth = true
            parent.drawing = canvasView.drawing
            parent.onDrawingChanged()
            isCanvasSourceOfTruth = false
        }

        /// 前面 drawing のマーカー種別だけを抽出し、不透明度を戻して背面ミラーへ反映する。
        private func updateMarkerBackLayer(_ full: PKDrawing) {
            container?.markerBackView.drawing = MarkerLayer.backingDrawing(from: full)
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
            // 前面の置換(マーカー背面化・図形置換・その Undo/Redo)に合わせて背面ミラーも更新
            updateMarkerBackLayer(nextDrawing)

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

        // MARK: - オブジェクト同期(要件③)

        @MainActor
        func syncObjects(into layer: ObjectLayerUIView) {
            let activeObjects = parent.objects.filter { !$0.isDeleted && $0.managedObjectContext != nil }
            let items = activeObjects
                .sorted { $0.zOrder < $1.zOrder }
                .map { object -> CanvasObjectItem in
                    var image: UIImage?
                    var linkTitle = ""
                    if object.objectKind == .noteLink {
                        // リンク先タイトルを毎回引き直す(リネーム等に追従)。
                        // アイコンはリンク先の中身の有無に関わらず固定(ドキュメントアイコン)にするため、
                        // サムネイルは渡さない(image は nil のまま)。
                        linkTitle = object.resolvedLinkedNote?.displayTitle ?? ""
                    } else if object.objectKind != .text && object.objectKind != .todo {
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
                        image: image,
                        isLocked: object.isLocked,
                        isUserLocked: object.isUserLocked,
                        parentGroupID: object.parentGroupID,
                        linkTitle: linkTitle,
                        todoItems: object.objectKind == .todo ? object.todoItems : []
                    )
                }
            layer.sync(items: items)

            // 削除済みオブジェクトの画像キャッシュを解放する(imageCache がメモリリークしないように)
            let activeIDs = Set(activeObjects.map(\.objectID))
            imageCache = imageCache.filter { activeIDs.contains($0.key) }
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

/// フェードのちらつきを抑えた CATiledLayer。
final class NonFadingTiledLayer: CATiledLayer {
    override class func fadeDuration() -> CFTimeInterval { 0 }
}

/// 蛍光ペン(マーカー)を「オブジェクトの上・前面インクの下」に描くための非対話ビュー。
/// 前面の対話キャンバス(全ストロークの正)からマーカー種別だけを抽出したミラーを
/// `drawing` として受け取り、`ObjectLayerUIView` の上・前面手書きインクの下に敷く。
///
/// コンテンツ全体(最大 100,000²)を1枚では描けないため CATiledLayer で「表示中のタイルだけ」を
/// 遅延描画する。親スクロールビューがスクロール/ズームで露出させた領域のみ draw(_:) が呼ばれるので、
/// 巨大キャンバスでも破綻せず、スクロール同期のラグも生じない(背景パターンと同じくコンテンツ座標に固定)。
final class MarkerBackingView: UIView {
    override class var layerClass: AnyClass { NonFadingTiledLayer.self }

    /// 背面に描くマーカー(不透明度は復元済み)。変更で再描画する。
    var drawing = PKDrawing() {
        didSet { setNeedsDisplay() }
    }

    /// ズームに応じたタイルの描画解像度(拡大時に線がボケないよう倍率を上げる)。
    private var renderScale: CGFloat = UIScreen.main.scale

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false   // 入力は前面キャンバスが受ける(ここは描画専用)
        backgroundColor = .clear
        isOpaque = false
        if let tiled = layer as? CATiledLayer {
            tiled.tileSize = CGSize(width: 1024, height: 1024)
            tiled.levelsOfDetail = 1
            tiled.levelsOfDetailBias = 0
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// ズーム時に呼ばれ、拡大率に見合う解像度でタイルを焼き直す(背景パターンと同方針)。
    func applyZoom(_ zoom: CGFloat) {
        let target = min(max(UIScreen.main.scale * zoom, UIScreen.main.scale), 12)
        guard abs(target - renderScale) > 0.5 else { return }
        renderScale = target
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard !drawing.strokes.isEmpty else { return }
        // rect は今から描くタイル(コンテンツ座標)。その部分のマーカーだけを焼いて置く。
        // ダークモードでのインク色自動反転を避けて描き出す(前面キャンバスと同方針)。
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            drawing.image(from: rect, scale: renderScale).draw(in: rect)
        }
    }
}

final class CanvasContainerUIView: UIView, UIGestureRecognizerDelegate {
    let canvasView = ObjectAccessibleCanvasView()
    let patternView = BackgroundPatternUIView()
    /// 蛍光ペンのミラー(オブジェクトレイヤーの上・前面インクの下)
    let markerBackView = MarkerBackingView()
    let objectLayer = ObjectLayerUIView()
    /// 描画ジェスチャに差し込むゲート(「開く」ボタン上・用紙外ではインクを始めない)
    let drawingTouchGate = DrawingTouchGate()

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
            canvasView.panGestureRecognizer.minimumNumberOfTouches = isSelectMode ? 2 : 1
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        let canvasSize = CanvasRepresentable.canvasSize

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
        addSubview(canvasView)

        // 背景 → オブジェクト → 蛍光ペンの順でキャンバス最背面へ差し込む。
        // 前面の手書きインク(ペン等)は PKCanvasView 自身が最前面に載せるため、注釈は常に最上。
        // 蛍光ペン(markerBackView)はオブジェクトの「上」・前面インクの「下」に敷く。こうすると
        // PDF・画像(isLocked オブジェクト)の上に引いても消えず、かつ手書き文字の下に回るため
        // 文字はくっきり保たれる(実際の蛍光ペンと同じ挙動)。描画中(前面キャンバス)と指を離した後
        // (このミラー)で重なり順が変わらないので「離すと消える」現象も起きない。
        // z順: 背景(patternView) < オブジェクト(objectLayer) < 蛍光ペン(markerBackView) < 前面インク(canvasView 本体)
        let contentFrame = CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize)
        patternView.frame = contentFrame
        markerBackView.frame = contentFrame
        objectLayer.frame = contentFrame
        canvasView.insertSubview(patternView, at: 0)
        canvasView.insertSubview(objectLayer, aboveSubview: patternView)
        canvasView.insertSubview(markerBackView, aboveSubview: objectLayer)
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
        objectLayer.handleBackgroundTap(at: gesture.location(in: objectLayer))
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool { true }
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

        // 横スクロールは影を横方向へ、縦スクロールは下方向へ落として奥行きを出す
        let shadowOffset = pagedLayout.scrollsHorizontally
            ? CGSize(width: 2, height: 0) : CGSize(width: 0, height: 2)

        for index in 0..<max(1, pagedLayout.pageCount) {
            let page = UIView(frame: pagedLayout.pageRect(index))
            page.backgroundColor = pageBackground
            // 用紙らしい影と薄い境界線
            page.layer.shadowColor = UIColor.black.cgColor
            page.layer.shadowOpacity = 0.18
            page.layer.shadowRadius = 6
            page.layer.shadowOffset = shadowOffset
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
            case .lines:
                // 上辺に横線を引くと、タイリングで 40pt 間隔の横罫線になる
                pageColor.patternUIColor.setStroke()
                c.setLineWidth(0.5)
                c.move(to: CGPoint(x: 0, y: 0))
                c.addLine(to: CGPoint(x: spacing, y: 0))
                c.strokePath()
            case .blank:
                break
            }
        }
    }
}
