import Testing
import CoreGraphics
@testable import InfiniteCanvasApp

// MARK: - 「隣のページを隠す」左右マスク矩形の計算

@Suite("隣ページ遮蔽マスク")
struct AdjacentPageMaskTests {

    private let w = PageMetrics.width      // 800
    private let h = PageMetrics.height     // 1130
    private let gap = PageMetrics.gap      // 20

    private func calc(_ pages: Int, twoPage: Bool) -> PagedLayoutCalculator {
        // paged は横スクロール固定
        PagedLayoutCalculator(pageCount: pages, isTwoPageLayout: twoPage, isHorizontalScroll: true)
    }

    @Test("1ページ・中央: アクティブページの左右をちょうど覆う")
    func singleMiddle() {
        let c = calc(3, twoPage: false)
        let (left, right) = AdjacentPageMask.maskRects(activePage: 1, layout: c)
        let page = c.pageRect(1)
        // 左マスクはページ左端まで、右マスクはページ右端から
        #expect(left.width > 0 && right.width > 0)
        #expect(left.maxX == page.minX)
        #expect(right.minX == page.maxX)
        // 全高を覆う
        #expect(left.height == c.contentSize.height)
        #expect(right.height == c.contentSize.height)
        // 右端はコンテンツ端まで
        #expect(right.maxX == c.contentSize.width)
    }

    @Test("1ページ・先頭: 左に覆う対象が無いので left は幅0")
    func singleFirst() {
        let c = calc(3, twoPage: false)
        let (left, right) = AdjacentPageMask.maskRects(activePage: 0, layout: c)
        #expect(left.width == 0)
        #expect(right.width > 0)
        #expect(right.minX == c.pageRect(0).maxX)
    }

    @Test("1ページ・末尾: 右に覆う対象が無いので right は幅0")
    func singleLast() {
        let c = calc(3, twoPage: false)
        let (left, right) = AdjacentPageMask.maskRects(activePage: 2, layout: c)
        #expect(right.width == 0)
        #expect(left.width > 0)
        #expect(left.maxX == c.pageRect(2).minX)
    }

    @Test("見開き: アクティブがユニットの左右どちらでも同ユニット2枚を残す")
    func twoPageUnitKept() {
        let c = calc(4, twoPage: true)
        // ユニット1 = ページ2,3。左右どちらを active にしても同じマスクになる
        let fromLeft = AdjacentPageMask.maskRects(activePage: 2, layout: c)
        let fromRight = AdjacentPageMask.maskRects(activePage: 3, layout: c)
        #expect(fromLeft.left == fromRight.left)
        #expect(fromLeft.right == fromRight.right)
        // 残すユニットの外接: pageRect(2).minX 〜 pageRect(3).maxX
        #expect(fromLeft.left.maxX == c.pageRect(2).minX)
        #expect(fromLeft.right.minX == c.pageRect(3).maxX)
    }

    @Test("見開き・末尾の半端ユニット(1枚)はクランプして落ちない")
    func twoPageOddTail() {
        let c = calc(3, twoPage: true)  // ユニット1はページ2の1枚のみ
        let (left, right) = AdjacentPageMask.maskRects(activePage: 2, layout: c)
        #expect(left.maxX == c.pageRect(2).minX)
        #expect(right.width == 0)  // 末尾なので右は無し
    }
}
