import SwiftUI
import PencilKit
import CoreData

/// 通常ノート(paged)専用の SwiftUI ブリッジ。GoodNotes 型の PagedCanvasContainerUIView
/// (ページごと独立 PKCanvasView、ページ外に描画面が存在しない)をホストする。
/// 無限キャンバスは従来どおり CanvasRepresentable が担う。
///
/// データの正本は従来と同じ単一の merged PKDrawing(コンテンツ座標、NoteFile.canvasData)。
/// コンテナ内部ではページローカルの PKDrawing 配列で保持し、PagedDrawingStore の
/// split / merge で相互変換する。パラメータ・コールバックは CanvasRepresentable と
/// 同名・同型に揃えてあり、NoteCanvasView 側の分岐が機械的な書き分けで済む。
struct PagedCanvasRepresentable: UIViewRepresentable {
    @Binding var drawing: PKDrawing
    let pkTool: PKTool
    let isSelectMode: Bool
    /// タップ位置配置モードのツール(.text / .todo)。nil のときは通常(描画/選択)。
    let placementTool: CanvasTool?
    /// 配置モードでキャンバスをタップしたとき(ツール, コンテンツ座標)。
    let onPlaceObject: (CanvasTool, CGPoint) -> CanvasObjectItem?
    /// 図形認識アシスト: 描き終えたストロークを直線・楕円・矩形へ自動置換するか
    let isShapeAssistEnabled: Bool
    let backgroundStyle: CanvasBackgroundStyle
    let pageColor: CanvasPageColor
    let pageCount: Int
    /// 見開き2ページ表示か
    let isTwoPageLayout: Bool
    /// ズームロック: true のときピンチズームを禁止する(min/max を現在値に固定)
    let isZoomLocked: Bool
    /// 「隣のページを隠す(完全独立表示モード)」。ON でスクロール停止時にアクティブページ以外を遮蔽する。
    let hideAdjacentPages: Bool
    let objects: [CanvasObject]
    /// 挿入直後に選択(テキストなら編集開始)するオブジェクト
    let autoFocusObjectID: NSManagedObjectID?
    let initialViewport: CanvasViewport?
    let onDrawingChanged: () -> Void
    let onViewportChanged: (CanvasViewport) -> Void
    let onObjectFrameChanged: (NSManagedObjectID, CGRect) -> Void
    let onObjectTextChanged: (NSManagedObjectID, String) -> Void
    let onObjectTodoChanged: (NSManagedObjectID, [TodoItem]) -> Void
    let onObjectDeleted: (NSManagedObjectID) -> Void
    let onObjectAutoHeightChanged: (NSManagedObjectID, CGFloat) -> Void
    let onTextSelectionChanged: ((objectID: NSManagedObjectID, fontSize: CGFloat)?) -> Void
    /// 投げ縄でインクを移動したとき(元の領域, 移動量)。座標はコンテンツ座標。
    let onLassoObjectsMoved: (CGRect, CGVector) -> Void
    /// 投げ縄でインクを削除したとき(削除された領域)。座標はコンテンツ座標。
    let onLassoObjectsDeleted: (CGRect) -> Void
    let onNoteLinkActivated: (NSManagedObjectID) -> Void
    let onObjectShapeEditRequested: (NSManagedObjectID) -> Void
    let onObjectTableChanged: (NSManagedObjectID, TablePayload) -> Void
    let onObjectTableResized: (NSManagedObjectID, CGRect, TablePayload) -> Void
    let onToggleUserLock: (NSManagedObjectID) -> Void
    let onGroupObjects: ([NSManagedObjectID]) -> Void
    let onUngroupObjects: ([NSManagedObjectID]) -> Void
    /// 最後のページを超えて横に引っ張ったときにページを1枚追加する要求
    let onAppendPage: () -> Void
    let onSelectionChanged: (Bool) -> Void
    /// Undo/Redo ブリッジへ「現在ページの」キャンバスを渡す(ページ切替のたびに呼ばれる)
    let onCanvasReady: (PKCanvasView) -> Void
    /// 指定ページ先頭へスクロールする要求(しおり/目次のジャンプ)。nil で何もしない。
    let scrollToPage: Int?
    let onScrollHandled: () -> Void
    /// ズームを 100% に戻す要求(左上バッジのメニューから)。
    let resetZoomRequested: Bool
    let onZoomResetHandled: () -> Void

    /// 通常ノートは横スクロール(ページめくり)固定
    private var layout: PagedLayoutCalculator {
        PagedLayoutCalculator(
            pageCount: pageCount,
            isTwoPageLayout: isTwoPageLayout,
            isHorizontalScroll: true
        )
    }

    func makeUIView(context: Context) -> PagedCanvasContainerUIView {
        let container = PagedCanvasContainerUIView()
        let coordinator = context.coordinator
        coordinator.container = container
        coordinator.lastPageCount = pageCount
        coordinator.lastIsTwoPage = isTwoPageLayout

        container.layout = layout
        container.setPageCount(pageCount)
        container.pkTool = pkTool
        container.isSelectMode = isSelectMode
        container.placementTool = placementTool
        container.onPlaceObject = onPlaceObject
        container.isZoomLocked = isZoomLocked
        container.hideAdjacentPages = hideAdjacentPages
        container.pendingInitialViewport = initialViewport
        container.applyLayout(style: backgroundStyle, pageColor: pageColor)
        container.distribute(merged: drawing)

        // ページキャンバスの実体化時: delegate(図形認識・投げ縄・書き戻し)と差分基準を設定
        container.onPageCanvasCreated = { [weak coordinator] canvas in
            canvas.delegate = coordinator
            coordinator?.seedPageState(for: canvas)
        }
        // 現在ページの切替: Undo ブリッジの attach 先を追随させる。
        // オブジェクト操作の Undo も attach 中(現在ページ)の undoManager に積まれる。
        // ページから離れてキャンバスが回収されると、そのページで積んだ履歴は失われる
        // (GoodNotes 同等の割り切り)。
        container.onActiveCanvasChanged = { [weak coordinator] canvas in
            coordinator?.parent.onCanvasReady(canvas)
        }
        // ページローカル描画の変更 → merged を @State へ書き戻し(保存・Undo ボタン更新)
        container.onMergedDrawingChanged = { [weak coordinator] merged in
            guard let coordinator else { return }
            coordinator.isCanvasSourceOfTruth = true
            coordinator.parent.drawing = merged
            coordinator.parent.onDrawingChanged()
            coordinator.isCanvasSourceOfTruth = false
        }
        container.onViewportChanged = { [weak coordinator] viewport in
            coordinator?.parent.onViewportChanged(viewport)
        }
        container.onAppendPage = { [weak coordinator] in
            coordinator?.parent.onAppendPage()
        }

        // オブジェクト操作の書き戻し(常に最新の parent を経由させる)
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
        // 選択状態の変化を SwiftUI(PenToolState.isSelectMode)へ伝える
        container.objectLayer.onSelectionChanged = { [weak coordinator] hasSelection in
            coordinator?.parent.onSelectionChanged(hasSelection)
        }
        return container
    }

    func updateUIView(_ container: PagedCanvasContainerUIView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        container.pkTool = pkTool
        container.isSelectMode = isSelectMode
        container.placementTool = placementTool
        container.onPlaceObject = onPlaceObject
        container.isZoomLocked = isZoomLocked
        container.hideAdjacentPages = hideAdjacentPages

        let layoutModeChanged = isTwoPageLayout != coordinator.lastIsTwoPage
        let pageAppended = pageCount > coordinator.lastPageCount
        coordinator.lastIsTwoPage = isTwoPageLayout
        coordinator.lastPageCount = pageCount

        if container.layout != layout {
            container.layout = layout
            container.setPageCount(pageCount)
        }
        // 背景スタイル・用紙色・ページ矩形の変化を反映(冪等)
        container.applyLayout(style: backgroundStyle, pageColor: pageColor)

        if layoutModeChanged {
            // 見開きトグル: ページ矩形が動くが、正本はページローカルなのでインクはページに
            // 追従する。新レイアウトで merged を作り直して @State(保存)へ反映する。
            // (オブジェクトはコンテンツ座標のため追従しない=旧実装と同じ非追従)
            let merged = container.remergeAfterLayoutChange()
            DispatchQueue.main.async {
                coordinator.isCanvasSourceOfTruth = true
                coordinator.parent.drawing = merged
                coordinator.parent.onDrawingChanged()
                coordinator.isCanvasSourceOfTruth = false
                container.fitToPage(container.currentPageIndex(), animated: false)
            }
        } else if pageAppended {
            // ページが増えたら新しいページへスクロール(オーバースクロール追加のガードも解除)
            container.didRequestPageAppend = false
            container.scrollToPage(pageCount - 1) {}
        }

        // モデル側から drawing が差し替わった場合のみ全ページへ再配布する(描画中の上書き防止)。
        // ページ削除・ページ管理(並び替え/複製)・ページ構造 Undo はこの経路で反映される。
        // 見開きトグル直後は上の async 書き戻しが済むまで判定を保留する。
        if !layoutModeChanged, !coordinator.isCanvasSourceOfTruth,
           drawing != container.lastMergedDrawing {
            container.distribute(merged: drawing)
            coordinator.reseedAllPageStates(in: container)
        }

        // しおり/目次のジャンプ: 指定ページ先頭へアニメーションでスクロールする
        if let target = scrollToPage, !coordinator.isScrollPending {
            coordinator.isScrollPending = true
            DispatchQueue.main.async {
                container.scrollToPage(target) {
                    coordinator.parent.onScrollHandled()
                    coordinator.isScrollPending = false
                }
            }
        }

        // ズームを 100% に戻す(表示中のページ位置は保つ)
        if resetZoomRequested {
            DispatchQueue.main.async {
                container.resetZoomTo100(animated: true)
                coordinator.parent.onZoomResetHandled()
            }
        }

        coordinator.syncObjects(into: container.objectLayer)
        coordinator.handleAutoFocus(in: container.objectLayer)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// 全ページキャンバス共通の PKCanvasViewDelegate。
    /// 図形認識・投げ縄同期はページローカル座標で動き、差分基準(ストローク数・直前描画)を
    /// ページごとに保持する。
    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var parent: PagedCanvasRepresentable
        weak var container: PagedCanvasContainerUIView?
        var isCanvasSourceOfTruth = false
        /// 直近のページ数(増加=ページ追加スクロールの検知用)
        var lastPageCount = 1
        /// 直近の見開き設定(変化時のみ再フィット・merged 再構築)
        var lastIsTwoPage = false
        /// ジャンプ(プログラムスクロール)を処理中か(1要求につき1回に抑える)
        var isScrollPending = false
        /// 図形置換で drawing を差し替える間の再入を無視するフラグ
        private var isReplacingDrawing = false

        /// ページごとの差分検知の基準
        private struct PageState {
            var lastStrokeCount = 0
            var previousDrawing = PKDrawing()
        }
        private var pageStates: [Int: PageState] = [:]
        /// image / pdf のレンダリング結果キャッシュ(payload のデコードは1回だけ)
        private var imageCache: [NSManagedObjectID: UIImage] = [:]
        private var autoFocusHandledID: NSManagedObjectID?

        init(_ parent: PagedCanvasRepresentable) {
            self.parent = parent
        }

        /// ページキャンバスの実体化・描画配布後に差分基準を設定する
        func seedPageState(for canvas: PageCanvasView) {
            pageStates[canvas.pageIndex] = PageState(
                lastStrokeCount: canvas.drawing.strokes.count,
                previousDrawing: canvas.drawing
            )
        }

        /// distribute(全ページ差し替え)後に全ページの差分基準を取り直す。
        /// これを忘れると図形認識の「+1判定」や投げ縄差分が狂う。
        func reseedAllPageStates(in container: PagedCanvasContainerUIView) {
            pageStates.removeAll()
            for (_, canvas) in container.pageCanvases { seedPageState(for: canvas) }
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            // プログラムによる置換・配布中の再入(undo 通知含む)はスキップ
            if isReplacingDrawing { return }
            guard let container, !container.isDistributing,
                  let page = canvasView as? PageCanvasView else { return }
            let index = page.pageIndex
            var state = pageStates[index] ?? PageState()

            // 図形認識アシスト: 「1本だけ増えた」インクストロークを図形へ置換する。
            // 判定・置換はすべてページローカル座標のままで完結する(ShapeRecognizer は座標系非依存)。
            if parent.isShapeAssistEnabled,
               parent.pkTool is PKInkingTool,
               page.drawing.strokes.count == state.lastStrokeCount + 1,
               let last = page.drawing.strokes.last,
               last.ink.inkType != .marker,
               let cleanStroke = ShapeRecognizer.cleanShape(from: last) {
                let oldDrawing = state.previousDrawing
                var newDrawing = page.drawing
                newDrawing.strokes.removeLast()
                newDrawing.strokes.append(cleanStroke)

                // PencilKit が自動登録した「手書き追加」の Undo を取り消してから置換する
                isReplacingDrawing = true
                page.undoManager?.undo()
                isReplacingDrawing = false
                replaceDrawingWithUndoSupport(page, to: newDrawing, from: oldDrawing)
                return
            }

            // 投げ縄によるインクの移動/削除の差分検知。結果はページローカル座標なので、
            // オブジェクト(コンテンツ座標)へ適用する前にページ原点ぶんオフセットする。
            if parent.pkTool is PKLassoTool {
                let origin = container.layout.pageRect(index).origin
                switch LassoObjectSync.detect(from: state.previousDrawing, to: page.drawing) {
                case .moved(let region, let delta):
                    parent.onLassoObjectsMoved(region.offsetBy(dx: origin.x, dy: origin.y), delta)
                case .deleted(let region):
                    parent.onLassoObjectsDeleted(region.offsetBy(dx: origin.x, dy: origin.y))
                case nil:
                    break
                }
            }

            state.previousDrawing = page.drawing
            state.lastStrokeCount = page.drawing.strokes.count
            pageStates[index] = state

            // 正本(pageDrawings)へ書き戻し → merged を @State へ(onMergedDrawingChanged 経由)
            container.pageDrawingDidChange(page)
        }

        /// 双方向の Undo/Redo をサポートしながらページキャンバスの描画を置換する。
        /// Undo 登録先はそのページの undoManager(ページ回収時に履歴ごと破棄される)。
        private func replaceDrawingWithUndoSupport(
            _ canvas: PageCanvasView,
            to nextDrawing: PKDrawing,
            from currentDrawing: PKDrawing
        ) {
            isReplacingDrawing = true
            defer { isReplacingDrawing = false }

            canvas.drawing = nextDrawing
            pageStates[canvas.pageIndex] = PageState(
                lastStrokeCount: nextDrawing.strokes.count,
                previousDrawing: nextDrawing
            )
            container?.pageDrawingDidChange(canvas)

            canvas.undoManager?.registerUndo(withTarget: canvas) { [weak self] targetCanvas in
                self?.replaceDrawingWithUndoSupport(targetCanvas, to: currentDrawing, from: nextDrawing)
            }
        }

        // MARK: - オブジェクト同期(CanvasRepresentable.Coordinator と同一実装)

        @MainActor
        func syncObjects(into layer: ObjectLayerUIView) {
            let activeObjects = parent.objects.filter { !$0.isDeleted && $0.managedObjectContext != nil }
            let items = activeObjects
                .sorted { $0.zOrder < $1.zOrder }
                .map { object -> CanvasObjectItem in
                    var image: UIImage?
                    var linkTitle = ""
                    if object.objectKind == .noteLink {
                        linkTitle = object.resolvedLinkedNote?.displayTitle ?? ""
                    } else if object.objectKind != .text && object.objectKind != .todo
                                && object.objectKind != .shape && object.objectKind != .table {
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
                        todoItems: object.objectKind == .todo ? object.todoItems : [],
                        shapePayload: object.objectKind == .shape ? object.shapePayload : nil,
                        tablePayload: object.objectKind == .table ? object.tablePayload : nil
                    )
                }
            layer.sync(items: items)

            let activeIDs = Set(activeObjects.map(\.objectID))
            imageCache = imageCache.filter { activeIDs.contains($0.key) }
        }

        /// 挿入直後のオブジェクトを選択し、テキストなら編集を開始する(1回だけ)
        @MainActor
        func handleAutoFocus(in layer: ObjectLayerUIView) {
            guard let id = parent.autoFocusObjectID, id != autoFocusHandledID else { return }
            if layer.focus(on: id) { autoFocusHandledID = id }
        }
    }
}
