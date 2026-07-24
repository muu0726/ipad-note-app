import Testing
import CoreGraphics
@testable import InfiniteCanvasApp

@Suite("ZoomToFit 全体表示")
struct ZoomToFitTests {
    private let viewport = CGSize(width: 1000, height: 800)

    @Test("コンテンツが無ければ nil")
    func noContent() {
        #expect(ZoomToFit.fit(contentUnion: nil, viewportSize: viewport, minZoom: 0.1, maxZoom: 5) == nil)
    }

    @Test("大きいコンテンツは縮小してビューポート+余白に収まる")
    func largeContentShrinks() {
        let union = CGRect(x: 0, y: 0, width: 4000, height: 2000)
        let result = ZoomToFit.fit(contentUnion: union, viewportSize: viewport, minZoom: 0.1, maxZoom: 5, padding: 40)
        let r = try! #require(result)
        // 幅制約: (1000-80)/4000 = 0.23, 高さ制約: (800-80)/2000 = 0.36 → 小さい方
        #expect(abs(r.zoomScale - 920.0 / 4000.0) < 1e-6)
        // 中心が画面中央に来る
        #expect(abs((union.midX * r.zoomScale - r.contentOffset.x) - viewport.width / 2) < 1e-6)
        #expect(abs((union.midY * r.zoomScale - r.contentOffset.y) - viewport.height / 2) < 1e-6)
    }

    @Test("小さいコンテンツは maxZoom を超えて拡大しない")
    func smallContentClampsToMaxZoom() {
        let union = CGRect(x: 100, y: 100, width: 10, height: 10)
        let r = try! #require(ZoomToFit.fit(contentUnion: union, viewportSize: viewport, minZoom: 0.1, maxZoom: 5))
        #expect(r.zoomScale == 5)
    }

    @Test("極端に広いコンテンツは minZoom で下げ止まる")
    func hugeContentClampsToMinZoom() {
        let union = CGRect(x: 0, y: 0, width: 1_000_000, height: 1_000_000)
        let r = try! #require(ZoomToFit.fit(contentUnion: union, viewportSize: viewport, minZoom: 0.1, maxZoom: 5))
        #expect(r.zoomScale == 0.1)
    }
}
