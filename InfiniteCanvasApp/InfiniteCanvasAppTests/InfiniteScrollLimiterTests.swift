import Testing
import UIKit
@testable import InfiniteCanvasApp

// MARK: - 無限キャンバスのスクロール範囲制限(Freeform 風)

@Suite("InfiniteScrollLimiter スクロール範囲")
struct InfiniteScrollLimiterTests {

    private let canvasSize: CGFloat = 100_000
    private let viewport = CGSize(width: 1000, height: 800)

    @Test("空ノートはキャンバス中央の1画面+余白1画面分に制限される")
    func emptyNoteIsCenteredAroundCanvasCenter() {
        let allowed = InfiniteScrollLimiter.allowedRect(
            contentUnion: nil, viewportSize: viewport, zoomScale: 1, canvasSize: canvasSize
        )
        #expect(allowed.midX == canvasSize / 2)
        #expect(allowed.midY == canvasSize / 2)
        // 中央1画面 + 両側に1画面ずつ = 3画面分
        #expect(allowed.width == viewport.width * 3)
        #expect(allowed.height == viewport.height * 3)
    }

    @Test("コンテンツがあると外接矩形+余白1画面分が許可範囲になる")
    func contentUnionGetsOneScreenMargin() {
        let union = CGRect(x: 49_000, y: 49_500, width: 2_000, height: 1_000)
        let allowed = InfiniteScrollLimiter.allowedRect(
            contentUnion: union, viewportSize: viewport, zoomScale: 1, canvasSize: canvasSize
        )
        #expect(allowed == union.insetBy(dx: -viewport.width, dy: -viewport.height))
    }

    @Test("ズームアウト時は余白がコンテンツ座標で拡大する(画面1枚分を維持)")
    func marginScalesWithZoom() {
        let union = CGRect(x: 50_000, y: 50_000, width: 100, height: 100)
        let zoom: CGFloat = 0.5
        let allowed = InfiniteScrollLimiter.allowedRect(
            contentUnion: union, viewportSize: viewport, zoomScale: zoom, canvasSize: canvasSize
        )
        // 0.5倍ズームでは画面1枚分 = 2倍のコンテンツ幅
        #expect(allowed == union.insetBy(dx: -viewport.width / zoom, dy: -viewport.height / zoom))
    }

    @Test("小さいコンテンツでも許可範囲は最低1画面分を保つ")
    func allowedRectNeverSmallerThanViewport() {
        let union = CGRect(x: 50_000, y: 50_000, width: 1, height: 1)
        let zoom: CGFloat = 2
        let allowed = InfiniteScrollLimiter.allowedRect(
            contentUnion: union, viewportSize: viewport, zoomScale: zoom, canvasSize: canvasSize
        )
        #expect(allowed.width * zoom >= viewport.width)
        #expect(allowed.height * zoom >= viewport.height)
    }

    @Test("キャンバス端のコンテンツでも許可範囲はキャンバス外へ出ない")
    func allowedRectStaysInsideCanvas() {
        let union = CGRect(x: 100, y: 100, width: 500, height: 500)
        let allowed = InfiniteScrollLimiter.allowedRect(
            contentUnion: union, viewportSize: viewport, zoomScale: 1, canvasSize: canvasSize
        )
        #expect(allowed.minX >= 0)
        #expect(allowed.minY >= 0)
        #expect(allowed.maxX <= canvasSize)
        #expect(allowed.maxY <= canvasSize)
    }

    @Test("負の contentInset が許可範囲の外周をちょうど塞ぐ")
    func insetsBlockOutsideAllowedRect() {
        let allowed = CGRect(x: 48_000, y: 48_500, width: 4_000, height: 3_000)
        let zoom: CGFloat = 2
        let insets = InfiniteScrollLimiter.insets(
            allowedRect: allowed, zoomScale: zoom, canvasSize: canvasSize
        )
        // スクロール下限 = -inset.left / -inset.top(スクリーン座標)
        #expect(-insets.left == allowed.minX * zoom)
        #expect(-insets.top == allowed.minY * zoom)
        // スクロール上限 = contentSize*zoom - viewport + inset.right
        let maxOffsetX = canvasSize * zoom - viewport.width + insets.right
        let maxOffsetY = canvasSize * zoom - viewport.height + insets.bottom
        #expect(maxOffsetX == allowed.maxX * zoom - viewport.width)
        #expect(maxOffsetY == allowed.maxY * zoom - viewport.height)
    }

    @Test("contentOffset のクランプが許可範囲内へ収める")
    func clampedOffsetStaysInAllowedRange() {
        let allowed = CGRect(x: 48_000, y: 48_000, width: 4_000, height: 4_000)
        let zoom: CGFloat = 1

        // 範囲より左上すぎる → 下限へ
        let low = InfiniteScrollLimiter.clampedOffset(
            CGPoint(x: 0, y: 0), allowedRect: allowed, zoomScale: zoom, viewportSize: viewport
        )
        #expect(low == CGPoint(x: 48_000, y: 48_000))

        // 範囲より右下すぎる → 上限へ
        let high = InfiniteScrollLimiter.clampedOffset(
            CGPoint(x: 99_000, y: 99_000), allowedRect: allowed, zoomScale: zoom, viewportSize: viewport
        )
        #expect(high == CGPoint(x: 52_000 - viewport.width, y: 52_000 - viewport.height))

        // 範囲内はそのまま
        let inside = CGPoint(x: 49_000, y: 49_000)
        #expect(InfiniteScrollLimiter.clampedOffset(
            inside, allowedRect: allowed, zoomScale: zoom, viewportSize: viewport
        ) == inside)
    }
}

// MARK: - 背景タイルの間隔(ズーム非連動・Freeform 準拠)

@Suite("BackgroundPattern タイル間隔")
struct BackgroundPatternTileSpacingTests {

    @Test("ズーム帯の切り替わりは 0.5 / 0.15")
    func zoomBands() {
        #expect(BackgroundPatternUIView.zoomBand(4.0) == 2)
        #expect(BackgroundPatternUIView.zoomBand(1.0) == 2)
        #expect(BackgroundPatternUIView.zoomBand(0.5) == 2)
        #expect(BackgroundPatternUIView.zoomBand(0.49) == 1)
        #expect(BackgroundPatternUIView.zoomBand(0.15) == 1)
        #expect(BackgroundPatternUIView.zoomBand(0.14) == 0)
    }

    @Test("タイル間隔はコンテンツ空間で固定(帯2=基本、帯1=2倍、帯0=非表示)")
    func tileSpacingIsFixedPerBand() {
        let base: CGFloat = 40
        #expect(BackgroundPatternUIView.tileSpacing(forBand: 2, base: base) == 40)
        #expect(BackgroundPatternUIView.tileSpacing(forBand: 1, base: base) == 80)
        #expect(BackgroundPatternUIView.tileSpacing(forBand: 0, base: base) == nil)
    }
}
