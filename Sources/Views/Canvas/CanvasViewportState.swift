import SwiftUI
import Combine

/// キャンバスのビューポート(スクロール位置・ズーム)を SwiftUI 側へ公開する状態。
/// PKCanvasView の KVO から更新され、背景パターンとオブジェクトレイヤーが追従する。
@MainActor
final class CanvasViewportState: ObservableObject {
    @Published var offset: CGPoint = .zero
    @Published var zoom: CGFloat = 1
    @Published var viewSize: CGSize = .zero
    /// 選択モードで空白部分をドラッグしたときのスクロール要求(SwiftUI → PKCanvasView)
    @Published var externalOffsetRequest: CGPoint?

    /// コンテンツ座標 → スクリーン座標
    func screenRect(fromContent rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX * zoom - offset.x,
            y: rect.minY * zoom - offset.y,
            width: rect.width * zoom,
            height: rect.height * zoom)
    }

    /// スクリーン座標 → コンテンツ座標
    func contentPoint(fromScreen point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x + offset.x) / zoom, y: (point.y + offset.y) / zoom)
    }

    /// 画面中央のコンテンツ座標(オブジェクトの挿入位置に使用)
    var visibleContentCenter: CGPoint {
        contentPoint(fromScreen: CGPoint(x: viewSize.width / 2, y: viewSize.height / 2))
    }
}
