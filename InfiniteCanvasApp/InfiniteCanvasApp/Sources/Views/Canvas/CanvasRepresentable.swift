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
    let objects: [CanvasObject]
    /// 挿入直後に選択(テキストなら編集開始)するオブジェクト
    let autoFocusObjectID: NSManagedObjectID?
    let initialViewport: CanvasViewport?
    let onDrawingChanged: () -> Void
    let onViewportChanged: (CanvasViewport) -> Void
    let onObjectFrameChanged: (NSManagedObjectID, CGRect) -> Void
    let onObjectTextChanged: (NSManagedObjectID, String) -> Void
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
    /// Undo/Redo ブリッジなどにキャンバスを渡す
    let onCanvasReady: (PKCanvasView) -> Void

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
        container.objectLayer.frame = CGRect(origin: .zero, size: size)

        // スクロール方向: 横スクロール時のみ横バウンス + ページング、縦スクロール時は縦バウンス
        let horizontal = noteType == .paged && isHorizontalScroll
        canvas.alwaysBounceHorizontal = horizontal
        canvas.alwaysBounceVertical = noteType != .paged || !isHorizontalScroll
        canvas.isPagingEnabled = horizontal

        container.patternView.configure(
            noteType: noteType, layout: layout,
            style: backgroundStyle, pageColor: pageColor
        )
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
        /// 直近のレイアウト設定(見開き/スクロール方向)。変化時のみフィット/センタリングし直す。
        /// ページ数はここに含めない(ページ追加はスクロール処理側で扱う)
        var lastIsTwoPage = false
        var lastIsHorizontal = false
        /// 図形置換で drawing を差し替える間の再入を無視するフラグ(無限再描画ループ防止)
        private var isReplacingShape = false
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
            let items = parent.objects
                .filter { !$0.isDeleted && $0.managedObjectContext != nil }
                .sorted { $0.zOrder < $1.zOrder }
                .map { object -> CanvasObjectItem in
                    var image: UIImage?
                    var linkTitle = ""
                    if object.objectKind == .noteLink {
                        // リンク先タイトルとサムネイルを毎回引き直す(リネーム等に追従)
                        let linked = object.resolvedLinkedNote
                        linkTitle = linked?.displayTitle ?? ""
                        image = linked?.thumbnailData.flatMap { UIImage(data: $0) }
                    } else if object.objectKind != .text {
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
                        linkTitle: linkTitle
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
            case .blank:
                break
            }
        }
    }
}
