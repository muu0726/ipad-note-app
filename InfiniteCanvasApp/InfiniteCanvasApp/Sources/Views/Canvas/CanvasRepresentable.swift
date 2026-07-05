import SwiftUI
import PencilKit
import UIKit
import CoreData

/// タブごとのビューポート(スクロール位置・ズーム)。OpenNotesSession が保持する。
struct CanvasViewport {
    var contentOffset: CGPoint
    var zoomScale: CGFloat
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
    let backgroundStyle: CanvasBackgroundStyle
    let pageColor: CanvasPageColor
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

    func makeUIView(context: Context) -> CanvasContainerUIView {
        let container = CanvasContainerUIView()
        let canvas = container.canvasView
        canvas.drawing = drawing
        canvas.tool = pkTool
        canvas.delegate = context.coordinator
        container.patternView.style = backgroundStyle
        container.patternView.pageColor = pageColor
        container.objectLayer.pageColor = pageColor
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

        // 初期ビューポート(保存がなければキャンバス中央)
        DispatchQueue.main.async {
            if let viewport = initialViewport {
                canvas.zoomScale = viewport.zoomScale
                canvas.contentOffset = viewport.contentOffset
            } else {
                let size = Self.canvasSize
                canvas.contentOffset = CGPoint(
                    x: (size - canvas.bounds.width) / 2,
                    y: (size - canvas.bounds.height) / 2
                )
            }
        }
        return container
    }

    func updateUIView(_ container: CanvasContainerUIView, context: Context) {
        context.coordinator.parent = self
        let canvas = container.canvasView
        canvas.tool = pkTool
        container.patternView.style = backgroundStyle
        container.patternView.pageColor = pageColor
        container.isSelectMode = isSelectMode
        container.objectLayer.backgroundStyle = backgroundStyle
        container.objectLayer.pageColor = pageColor
        context.coordinator.syncObjects(into: container.objectLayer)
        context.coordinator.handleAutoFocus(in: container.objectLayer)
        // モデル側から描画が差し替わった場合のみ反映(描画中の上書きを防ぐ)
        if !context.coordinator.isCanvasSourceOfTruth, canvas.drawing != drawing {
            canvas.drawing = drawing
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var parent: CanvasRepresentable
        var isCanvasSourceOfTruth = false
        private var observations: [NSKeyValueObservation] = []
        /// image / pdf のレンダリング結果キャッシュ(payload のデコードは1回だけ)
        private var imageCache: [NSManagedObjectID: UIImage] = [:]
        private var autoFocusHandledID: NSManagedObjectID?

        init(_ parent: CanvasRepresentable) {
            self.parent = parent
        }

        /// contentOffset / zoomScale を監視して背景・オブジェクトレイヤーとビューポート保存を更新
        func attach(to container: CanvasContainerUIView) {
            let canvas = container.canvasView
            let update: (PKCanvasView) -> Void = { [weak self, weak container] canvas in
                guard let self, let container else { return }
                container.patternView.update(offset: canvas.contentOffset, zoom: canvas.zoomScale)
                container.objectLayer.update(offset: canvas.contentOffset, zoom: canvas.zoomScale)
                self.parent.onViewportChanged(
                    CanvasViewport(contentOffset: canvas.contentOffset, zoomScale: canvas.zoomScale)
                )
            }
            observations = [
                canvas.observe(\.contentOffset, options: [.new]) { canvas, _ in update(canvas) },
                canvas.observe(\.zoomScale, options: [.new]) { canvas, _ in update(canvas) },
            ]
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
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

/// 背景パターン(下) + オブジェクトレイヤー(中) + PKCanvasView(上・透明背景) を重ねたコンテナ。
/// インクは常にオブジェクトの上に描かれる(画像や PDF の上に手書き注釈できる)。
final class CanvasContainerUIView: UIView, UIGestureRecognizerDelegate {
    let canvasView = PKCanvasView()
    let patternView = BackgroundPatternUIView()
    let objectLayer = ObjectLayerUIView()

    /// 選択モード(要件③)。描画ジェスチャを無効化し、タッチをオブジェクトレイヤーへ転送する
    var isSelectMode = false {
        didSet {
            guard isSelectMode != oldValue else { return }
            objectLayer.isSelectMode = isSelectMode
            canvasView.drawingGestureRecognizer.isEnabled = !isSelectMode
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)

        // PencilKit はダークモード時にインク色を自動反転する(黒⇄白)が、
        // 用紙色(白/黒)はアプリ側で管理しているため反転を止め、選んだ色のまま描く
        overrideUserInterfaceStyle = .light

        patternView.contentMode = .redraw
        addSubview(patternView)
        addSubview(objectLayer)

        // オブジェクトのない場所のタップで選択解除(スクロール等の邪魔はしない)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleBackgroundTap(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        addGestureRecognizer(tap)

        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        canvasView.drawingPolicy = .anyInput  // Apple Pencil + 指の両方で描画(要件③)
        canvasView.contentSize = CGSize(
            width: CanvasRepresentable.canvasSize,
            height: CanvasRepresentable.canvasSize
        )
        canvasView.minimumZoomScale = 0.1
        canvasView.maximumZoomScale = 5.0
        canvasView.bouncesZoom = true
        addSubview(canvasView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        patternView.frame = bounds
        objectLayer.frame = bounds
        canvasView.frame = bounds
    }

    /// オブジェクトレイヤーは PKCanvasView の下にあり通常はタッチが届かないため、
    /// 選択モード中はここでオブジェクトへのヒットを優先して転送する
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if isSelectMode {
            let converted = convert(point, to: objectLayer)
            if let hit = objectLayer.hitTest(converted, with: event), hit !== objectLayer {
                return hit
            }
        }
        return super.hitTest(point, with: event)
    }

    @objc private func handleBackgroundTap(_ gesture: UITapGestureRecognizer) {
        objectLayer.handleBackgroundTap(at: gesture.location(in: objectLayer))
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool { true }
}

/// スクリーン空間で方眼 / ドットを描く背景ビュー。
/// キャンバスの contentOffset / zoomScale に追従し、ズームで拡大縮小して見える。
final class BackgroundPatternUIView: UIView {
    var style: CanvasBackgroundStyle = .blank {
        didSet { if style != oldValue { setNeedsDisplay() } }
    }
    /// 用紙の色。白紙は黒い罫線・ドット、黒紙は白(要件: ノート作成時に選択)
    var pageColor: CanvasPageColor = .white {
        didSet { if pageColor != oldValue { setNeedsDisplay() } }
    }
    private var offset: CGPoint = .zero
    private var zoom: CGFloat = 1

    func update(offset: CGPoint, zoom: CGFloat) {
        self.offset = offset
        self.zoom = zoom
        if style != .blank { setNeedsDisplay() }
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        pageColor.backgroundUIColor.setFill()
        ctx.fill(bounds)
        guard style != .blank else { return }

        // コンテンツ空間で 40pt 間隔。ズームアウト時は間隔を倍にして密集を防ぐ
        var spacing = 40 * zoom
        while spacing < 14 { spacing *= 2 }
        let phaseX = -offset.x.truncatingRemainder(dividingBy: spacing)
        let phaseY = -offset.y.truncatingRemainder(dividingBy: spacing)

        switch style {
        case .grid:
            ctx.setStrokeColor(pageColor.patternUIColor.cgColor)
            ctx.setLineWidth(0.5)
            var x = phaseX
            while x < bounds.width {
                ctx.move(to: CGPoint(x: x, y: 0))
                ctx.addLine(to: CGPoint(x: x, y: bounds.height))
                x += spacing
            }
            var y = phaseY
            while y < bounds.height {
                ctx.move(to: CGPoint(x: 0, y: y))
                ctx.addLine(to: CGPoint(x: bounds.width, y: y))
                y += spacing
            }
            ctx.strokePath()
        case .dots:
            ctx.setFillColor(pageColor.patternUIColor.cgColor)
            var x = phaseX
            while x < bounds.width {
                var y = phaseY
                while y < bounds.height {
                    ctx.fillEllipse(in: CGRect(x: x - 1.5, y: y - 1.5, width: 3, height: 3))
                    y += spacing
                }
                x += spacing
            }
        case .blank:
            break
        }
    }
}
