import Testing
import PencilKit
@testable import InfiniteCanvasApp

// MARK: - 通常ノートの描画 split / merge(ページローカル ⇄ merged コンテンツ座標)

@Suite("PagedDrawingStore 分割・結合")
struct PagedDrawingStoreTests {

    private let layout = PagedLayoutCalculator(
        pageCount: 3, isTwoPageLayout: false, isHorizontalScroll: true
    )

    /// (x, y) を中心とする短い横線ストローク
    private func stroke(centerX: CGFloat, centerY: CGFloat) -> PKStroke {
        let points = (0...10).map { i -> PKStrokePoint in
            PKStrokePoint(
                location: CGPoint(x: centerX - 50 + CGFloat(i) * 10, y: centerY),
                timeOffset: TimeInterval(i) * 0.01,
                size: CGSize(width: 4, height: 4),
                opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2
            )
        }
        return PKStroke(ink: PKInk(.pen, color: .black),
                        path: PKStrokePath(controlPoints: points, creationDate: Date()))
    }

    @Test("各ページのストロークがページローカル座標へ分割される")
    func splitAssignsStrokesToPages() {
        let page1Rect = layout.pageRect(1)
        let merged = PKDrawing(strokes: [
            stroke(centerX: 400, centerY: 500),                                  // ページ0
            stroke(centerX: page1Rect.midX, centerY: page1Rect.midY)             // ページ1
        ])
        let pages = PagedDrawingStore.split(merged, layout: layout)

        #expect(pages.count == 3)
        #expect(pages[0].strokes.count == 1)
        #expect(pages[1].strokes.count == 1)
        #expect(pages[2].strokes.isEmpty)
        // ページ1のストロークはローカル座標(ページ中央)になっている
        let localCenter = pages[1].strokes[0].renderBounds
        #expect(abs(localCenter.midX - PageMetrics.width / 2) < 5)
        #expect(abs(localCenter.midY - PageMetrics.height / 2) < 5)
    }

    @Test("ページ間の gap 上のストロークは最近傍ページへ割り当てられ、座標は保全される")
    func gapStrokeGoesToNearestPageAndRoundTrips() {
        // ページ0と1の間(横スクロールなので gap は X 方向)に中心を置く
        let gapX = layout.pageRect(0).maxX + PageMetrics.gap / 2
        let merged = PKDrawing(strokes: [stroke(centerX: gapX, centerY: 500)])

        let pages = PagedDrawingStore.split(merged, layout: layout)
        let total = pages.map(\.strokes.count).reduce(0, +)
        #expect(total == 1)  // 消えない

        // merge すれば元のコンテンツ座標へ戻る(データ保全)
        let roundTrip = PagedDrawingStore.merge(pages, layout: layout)
        #expect(roundTrip.strokes.count == 1)
        let original = merged.strokes[0].renderBounds
        let restored = roundTrip.strokes[0].renderBounds
        #expect(abs(original.midX - restored.midX) < 0.01)
        #expect(abs(original.midY - restored.midY) < 0.01)
    }

    @Test("split→merge のラウンドトリップで全ストロークの座標が不変")
    func splitMergeRoundTripPreservesCoordinates() {
        let rects = (0..<3).map { layout.pageRect($0) }
        let merged = PKDrawing(strokes: [
            stroke(centerX: rects[0].midX, centerY: 200),
            stroke(centerX: rects[1].midX, centerY: rects[1].midY),
            stroke(centerX: rects[2].midX, centerY: rects[2].maxY - 100)
        ])
        let roundTrip = PagedDrawingStore.merge(
            PagedDrawingStore.split(merged, layout: layout), layout: layout
        )
        #expect(roundTrip.strokes.count == merged.strokes.count)
        // ページ跨ぎで順序が入れ替わり得るため、中心座標の集合で比較する
        let originalCenters = Set(merged.strokes.map {
            "\(Int($0.renderBounds.midX.rounded())),\(Int($0.renderBounds.midY.rounded()))"
        })
        let restoredCenters = Set(roundTrip.strokes.map {
            "\(Int($0.renderBounds.midX.rounded())),\(Int($0.renderBounds.midY.rounded()))"
        })
        #expect(originalCenters == restoredCenters)
    }

    @Test("nearestPageIndex はページ内なら自身、ページ外なら最近傍を返す")
    func nearestPageIndex() {
        let inside = CGPoint(x: layout.pageRect(1).midX, y: layout.pageRect(1).midY)
        #expect(PagedDrawingStore.nearestPageIndex(of: inside, layout: layout) == 1)

        // ページ0の右端 + 少し(gap 内、ページ0側)
        let nearPage0 = CGPoint(x: layout.pageRect(0).maxX + 2, y: 500)
        #expect(PagedDrawingStore.nearestPageIndex(of: nearPage0, layout: layout) == 0)

        // ページ1の左端 - 少し(gap 内、ページ1側)
        let nearPage1 = CGPoint(x: layout.pageRect(1).minX - 2, y: 500)
        #expect(PagedDrawingStore.nearestPageIndex(of: nearPage1, layout: layout) == 1)
    }
}
