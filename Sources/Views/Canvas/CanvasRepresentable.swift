import SwiftUI
import PencilKit
import UIKit

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
    let backgroundStyle: CanvasBackgroundStyle
    let initialViewport: CanvasViewport?
    let onDrawingChanged: () -> Void
    let onViewportChanged: (CanvasViewport) -> Void

    func makeUIView(context: Context) -> CanvasContainerUIView {
        let container = CanvasContainerUIView()
        let canvas = container.canvasView
        canvas.drawing = drawing
        canvas.tool = pkTool
        canvas.delegate = context.coordinator
        container.patternView.style = backgroundStyle
        context.coordinator.attach(to: container)

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

        init(_ parent: CanvasRepresentable) {
            self.parent = parent
        }

        /// contentOffset / zoomScale を監視して背景パターンとビューポート保存を更新
        func attach(to container: CanvasContainerUIView) {
            let canvas = container.canvasView
            let update: (PKCanvasView) -> Void = { [weak self, weak container] canvas in
                guard let self, let container else { return }
                container.patternView.update(offset: canvas.contentOffset, zoom: canvas.zoomScale)
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
    }
}

/// 背景パターン(下) + PKCanvasView(上・透明背景) を重ねたコンテナ
final class CanvasContainerUIView: UIView {
    let canvasView = PKCanvasView()
    let patternView = BackgroundPatternUIView()

    override init(frame: CGRect) {
        super.init(frame: frame)

        patternView.contentMode = .redraw
        addSubview(patternView)

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
        canvasView.frame = bounds
    }
}

/// スクリーン空間で方眼 / ドットを描く背景ビュー。
/// キャンバスの contentOffset / zoomScale に追従し、ズームで拡大縮小して見える。
final class BackgroundPatternUIView: UIView {
    var style: CanvasBackgroundStyle = .blank {
        didSet { if style != oldValue { setNeedsDisplay() } }
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
        UIColor.systemBackground.setFill()
        ctx.fill(bounds)
        guard style != .blank else { return }

        // コンテンツ空間で 40pt 間隔。ズームアウト時は間隔を倍にして密集を防ぐ
        var spacing = 40 * zoom
        while spacing < 14 { spacing *= 2 }
        let phaseX = -offset.x.truncatingRemainder(dividingBy: spacing)
        let phaseY = -offset.y.truncatingRemainder(dividingBy: spacing)

        switch style {
        case .grid:
            ctx.setStrokeColor(UIColor.separator.withAlphaComponent(0.6).cgColor)
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
            ctx.setFillColor(UIColor.separator.cgColor)
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
