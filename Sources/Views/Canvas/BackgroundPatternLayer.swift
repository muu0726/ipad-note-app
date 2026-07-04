import SwiftUI

/// 方眼 / ドット背景(SwiftUI Canvas)。
/// ビューポートに追従し、ズームで拡大縮小して見える。最下層に置く。
struct BackgroundPatternLayer: View {
    @ObservedObject var viewportState: CanvasViewportState
    let style: CanvasBackgroundStyle

    var body: some View {
        SwiftUI.Canvas { context, size in
            guard style != .blank else { return }

            // コンテンツ空間で 40pt 間隔。ズームアウト時は間隔を倍にして密集を防ぐ
            var spacing = 40 * viewportState.zoom
            while spacing < 14 { spacing *= 2 }
            let phaseX = -viewportState.offset.x.truncatingRemainder(dividingBy: spacing)
            let phaseY = -viewportState.offset.y.truncatingRemainder(dividingBy: spacing)

            switch style {
            case .grid:
                var path = Path()
                var x = phaseX
                while x < size.width {
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    x += spacing
                }
                var y = phaseY
                while y < size.height {
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                    y += spacing
                }
                context.stroke(path, with: .color(Color(.separator).opacity(0.6)), lineWidth: 0.5)
            case .dots:
                var path = Path()
                var x = phaseX
                while x < size.width {
                    var y = phaseY
                    while y < size.height {
                        path.addEllipse(in: CGRect(x: x - 1.5, y: y - 1.5, width: 3, height: 3))
                        y += spacing
                    }
                    x += spacing
                }
                context.fill(path, with: .color(Color(.separator)))
            case .blank:
                break
            }
        }
        .background(Color(.systemBackground))
        .allowsHitTesting(false)
    }
}
