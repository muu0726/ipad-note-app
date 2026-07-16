import Testing
import CoreGraphics
@testable import InfiniteCanvasApp

// MARK: - 用紙内外描画ゲートの座標変換(ズーム対応)

@Suite("DrawingTouchGate 座標変換")
struct DrawingTouchGateTests {

    private let w = PageMetrics.width   // 800
    private let h = PageMetrics.height  // 1130

    @Test("zoomScale=1 では生座標とコンテンツ座標が一致する")
    func noZoomIsIdentity() {
        let raw = CGPoint(x: 400, y: 500)
        let content = DrawingTouchGate.contentPoint(fromRaw: raw, zoomScale: 1)
        #expect(content == raw)
    }

    @Test("ズーム中、用紙内の生座標(zoomScale倍済み)は正しくページ矩形内と判定される")
    func zoomedTouchInsidePageIsAllowed() {
        // ページ0(0,0,800,1130)の右下寄り(内側)の点をコンテンツ座標 (750, 1100) とする。
        // zoomScale=2 のとき、canvasView bounds 上の生座標はその2倍 (1500, 2200) になる。
        let zoomScale: CGFloat = 2
        let raw = CGPoint(x: 750 * zoomScale, y: 1100 * zoomScale)
        let content = DrawingTouchGate.contentPoint(fromRaw: raw, zoomScale: zoomScale)

        let pageRects = [PageMetrics.pageRect(0)]
        #expect(pageRects.contains { $0.contains(content) })

        // 修正前の実装(生座標をそのままページ矩形と比較)なら、この点はページ幅800を
        // 大きく超えており誤って「用紙外」判定されていたことを確認する(回帰防止)。
        #expect(!pageRects.contains { $0.contains(raw) })
    }

    @Test("ズーム中、用紙外の生座標は正しく用紙外と判定される")
    func zoomedTouchOutsidePageIsRejected() {
        let zoomScale: CGFloat = 2
        // コンテンツ座標で (900, 500) はページ0(幅800)の外側
        let raw = CGPoint(x: 900 * zoomScale, y: 500 * zoomScale)
        let content = DrawingTouchGate.contentPoint(fromRaw: raw, zoomScale: zoomScale)

        let pageRects = [PageMetrics.pageRect(0)]
        #expect(!pageRects.contains { $0.contains(content) })
    }
}
