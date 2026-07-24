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

@Suite("BackgroundPattern タイル間隔(画面上一定・Freeform 準拠)")
struct BackgroundPatternTileSpacingTests {

    /// 画面上の間隔 = コンテンツ間隔 × zoom。どのズームでも target(36)の √2 倍以内に収まる
    /// = 肥大化しない。
    @Test("画面上の間隔はどのズームでも一定域に収まる")
    func screenSpacingStaysBounded() {
        let base: CGFloat = 40, target: CGFloat = 36
        for zoom in [CGFloat(0.1), 0.25, 0.5, 1.0, 2.0, 3.0, 5.0] {
            let content = BackgroundPatternUIView.infiniteSpacing(forZoom: zoom, base: base, targetScreen: target)
            let screen = content * zoom
            // base×2^k 丸めのため、target の [1/√2, √2] 倍の帯に入る
            #expect(screen >= target / 1.4143 - 0.001)
            #expect(screen <= target * 1.4143 + 0.001)
        }
    }

    @Test("間隔は base×2^k の値を取る(段階的で焼き直しが安定)")
    func spacingIsPowerOfTwoMultiple() {
        let base: CGFloat = 40
        for zoom in [CGFloat(0.3), 1.0, 2.5, 4.0] {
            let s = BackgroundPatternUIView.infiniteSpacing(forZoom: zoom, base: base)
            let ratio = s / base
            let log2r = (log2(ratio)).rounded()
            #expect(abs(base * pow(2, log2r) - s) < 0.001)
        }
    }

    @Test("100%(zoom=1)では基本間隔 40 になる")
    func spacingAtUnityIsBase() {
        #expect(BackgroundPatternUIView.infiniteSpacing(forZoom: 1.0, base: 40, targetScreen: 36) == 40)
    }

    @Test("ズームインしてもコンテンツ間隔は肥大化せず縮む(細分化)")
    func zoomingInSubdivides() {
        let s1 = BackgroundPatternUIView.infiniteSpacing(forZoom: 1.0)
        let s5 = BackgroundPatternUIView.infiniteSpacing(forZoom: 5.0)
        #expect(s5 < s1)  // 拡大時はコンテンツ間隔を細かくする
    }
}
