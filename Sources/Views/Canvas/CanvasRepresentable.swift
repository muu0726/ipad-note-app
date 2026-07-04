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
/// ズーム設定だけで疑似無限キャンバス(100,000 x 100,000 pt)を実現する(要件②)。
/// 背景・オブジェクトは SwiftUI 側のレイヤーが CanvasViewportState 経由で追従する。
struct CanvasRepresentable: UIViewRepresentable {
    static let canvasSize: CGFloat = 100_000

    @Binding var drawing: PKDrawing
    /// プログラム側から drawing を差し替えたときにインクリメントする(外部変更の検知用)
    let drawingVersion: Int
    let pkTool: PKTool
    /// 選択モード中は描画・スクロールを止めてオブジェクト操作に譲る
    let isSelectMode: Bool
    @ObservedObject var viewportState: CanvasViewportState
    let initialViewport: CanvasViewport?
    let onDrawingChanged: () -> Void
    let onViewportChanged: (CanvasViewport) -> Void

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawingPolicy = .anyInput  // Apple Pencil + 指の両方で描画(要件③)
        canvas.contentSize = CGSize(width: Self.canvasSize, height: Self.canvasSize)
        canvas.minimumZoomScale = 0.1
        canvas.maximumZoomScale = 5.0
        canvas.bouncesZoom = true
        canvas.drawing = drawing
        canvas.tool = pkTool
        canvas.delegate = context.coordinator
        context.coordinator.lastAppliedVersion = drawingVersion
        context.coordinator.attach(to: canvas)

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
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        context.coordinator.parent = self
        canvas.tool = pkTool
        canvas.isUserInteractionEnabled = !isSelectMode

        // 選択モードで空白ドラッグされたときのスクロール要求を反映
        if let request = viewportState.externalOffsetRequest {
            canvas.contentOffset = request
            let state = viewportState
            DispatchQueue.main.async { state.externalOffsetRequest = nil }
        }

        // プログラム側から drawing が差し替わった場合のみ反映(描画中の上書きを防ぐ)
        if context.coordinator.lastAppliedVersion != drawingVersion {
            context.coordinator.lastAppliedVersion = drawingVersion
            canvas.drawing = drawing
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var parent: CanvasRepresentable
        var lastAppliedVersion = 0
        private var observations: [NSKeyValueObservation] = []

        init(_ parent: CanvasRepresentable) {
            self.parent = parent
        }

        /// contentOffset / zoomScale を監視して SwiftUI 側レイヤーとビューポート保存を更新
        func attach(to canvas: PKCanvasView) {
            let update: (PKCanvasView) -> Void = { [weak self] canvas in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.parent.viewportState.offset = canvas.contentOffset
                    self.parent.viewportState.zoom = canvas.zoomScale
                    self.parent.onViewportChanged(
                        CanvasViewport(contentOffset: canvas.contentOffset, zoomScale: canvas.zoomScale)
                    )
                }
            }
            observations = [
                canvas.observe(\.contentOffset, options: [.new]) { canvas, _ in update(canvas) },
                canvas.observe(\.zoomScale, options: [.new]) { canvas, _ in update(canvas) },
            ]
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            // キャンバス発の変更: バージョンは進めない(自分自身への再適用を防ぐ)
            parent.drawing = canvasView.drawing
            parent.onDrawingChanged()
        }
    }
}
