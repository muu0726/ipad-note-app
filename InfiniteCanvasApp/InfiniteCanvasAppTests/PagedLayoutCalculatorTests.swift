import Testing
import CoreGraphics
@testable import InfiniteCanvasApp

// MARK: - 通常ノートのページ配置(見開き × スクロール方向)

@Suite("ページ配置計算")
struct PagedLayoutCalculatorTests {

    private let w = PageMetrics.width      // 800
    private let h = PageMetrics.height     // 1130
    private let gap = PageMetrics.gap      // 20

    private func calc(_ pages: Int, twoPage: Bool, horizontal: Bool) -> PagedLayoutCalculator {
        PagedLayoutCalculator(pageCount: pages, isTwoPageLayout: twoPage, isHorizontalScroll: horizontal)
    }

    @Test("縦スクロール・1ページ: 縦一列(X=0固定、Y方向へ展開)")
    func verticalSingle() {
        let c = calc(3, twoPage: false, horizontal: false)
        #expect(c.pageRect(0) == CGRect(x: 0, y: 0, width: w, height: h))
        #expect(c.pageRect(1) == CGRect(x: 0, y: h + gap, width: w, height: h))
        #expect(c.pageRect(2) == CGRect(x: 0, y: 2 * (h + gap), width: w, height: h))
        #expect(c.contentSize == CGSize(width: w, height: 3 * h + 2 * gap))
    }

    @Test("縦スクロール・2ページ: 横に2枚、下へ段送り")
    func verticalTwoPage() {
        let c = calc(3, twoPage: true, horizontal: false)
        #expect(c.pageRect(0) == CGRect(x: 0, y: 0, width: w, height: h))               // 左上
        #expect(c.pageRect(1) == CGRect(x: w + gap, y: 0, width: w, height: h))         // 右上
        #expect(c.pageRect(2) == CGRect(x: 0, y: h + gap, width: w, height: h))         // 左下(段送り)
        // 2列 x 2段
        #expect(c.contentSize == CGSize(width: 2 * w + gap, height: 2 * h + gap))
    }

    @Test("横スクロール・1ページ: 横一列(Y=0固定、X方向へ展開)")
    func horizontalSingle() {
        let c = calc(3, twoPage: false, horizontal: true)
        #expect(c.pageRect(0) == CGRect(x: 0, y: 0, width: w, height: h))
        #expect(c.pageRect(1) == CGRect(x: w + gap, y: 0, width: w, height: h))
        #expect(c.pageRect(2) == CGRect(x: 2 * (w + gap), y: 0, width: w, height: h))
        #expect(c.contentSize == CGSize(width: 3 * w + 2 * gap, height: h))
    }

    @Test("横スクロール・2ページ: 見開き(左右密着)を1ユニットとして右へ展開")
    func horizontalTwoPage() {
        let c = calc(4, twoPage: true, horizontal: true)
        // ユニット0: 左右が隙間なく密着
        #expect(c.pageRect(0) == CGRect(x: 0, y: 0, width: w, height: h))
        #expect(c.pageRect(1) == CGRect(x: w, y: 0, width: w, height: h))
        // ユニット1: ユニット間に gap を挟んで次の見開き
        #expect(c.pageRect(2) == CGRect(x: 2 * w + gap, y: 0, width: w, height: h))
        #expect(c.pageRect(3) == CGRect(x: 3 * w + gap, y: 0, width: w, height: h))
        // 2ユニット分の幅・高さは1ページ
        #expect(c.contentSize == CGSize(width: 4 * w + gap, height: h))
    }

    @Test("横スクロール・2ページで奇数ページ: 最後は片側だけの見開き")
    func horizontalTwoPageOdd() {
        let c = calc(3, twoPage: true, horizontal: true)
        #expect(c.pageRect(2) == CGRect(x: 2 * w + gap, y: 0, width: w, height: h))
        #expect(c.contentSize == CGSize(width: 3 * w + gap, height: h))
    }

    @Test("scrollsHorizontally はスクロール方向を反映する")
    func scrollDirectionFlag() {
        #expect(calc(1, twoPage: false, horizontal: true).scrollsHorizontally)
        #expect(!calc(1, twoPage: false, horizontal: false).scrollsHorizontally)
    }

    @Test("1ページのときは見開き・方向に関わらず単一ページサイズ")
    func singlePageAllModes() {
        for twoPage in [false, true] {
            for horizontal in [false, true] {
                let c = calc(1, twoPage: twoPage, horizontal: horizontal)
                #expect(c.pageRect(0) == CGRect(x: 0, y: 0, width: w, height: h))
                #expect(c.contentSize == CGSize(width: w, height: h))
            }
        }
    }
}
