import Testing
import CoreGraphics
@testable import InfiniteCanvasApp

// MARK: - 無限キャンバスの動的ワールドサイズ(拡張・原点リベース)

@Suite("DynamicCanvasBounds ワールドサイズ")
struct DynamicCanvasBoundsTests {

    @Test("コンテンツが無ければワールドサイズは変化しない")
    func noContentKeepsCurrentSize() {
        let size = DynamicCanvasBounds.expandedWorldSize(contentUnion: nil, currentWorldSize: 20_000)
        #expect(size == 20_000)
    }

    @Test("コンテンツが余白の内側なら拡張しない")
    func contentWellInsideDoesNotExpand() {
        let union = CGRect(x: 5_000, y: 5_000, width: 100, height: 100)
        let size = DynamicCanvasBounds.expandedWorldSize(contentUnion: union, currentWorldSize: 20_000)
        #expect(size == 20_000)
    }

    @Test("コンテンツが右下の余白を切ったらワールドサイズを拡張する")
    func contentNearRightBottomEdgeExpands() {
        let union = CGRect(x: 0, y: 0, width: 19_000, height: 500)  // maxX = 19_000, edgeMargin = 4_000
        let size = DynamicCanvasBounds.expandedWorldSize(contentUnion: union, currentWorldSize: 20_000)
        #expect(size == 19_000 + DynamicCanvasBounds.edgeMargin)
    }

    @Test("ワールドサイズは縮小しない(コンテンツが縮小/削除されても currentWorldSize を下回らない)")
    func worldSizeNeverShrinks() {
        let smallUnion = CGRect(x: 100, y: 100, width: 10, height: 10)
        let size = DynamicCanvasBounds.expandedWorldSize(contentUnion: smallUnion, currentWorldSize: 50_000)
        #expect(size == 50_000)
    }

    @Test("コンテンツが原点付近(左上)にあれば原点リベースが必要")
    func rebaseNeededNearOrigin() {
        let union = CGRect(x: 100, y: 8_000, width: 200, height: 200)  // minX が margin(4_000) を下回る
        let delta = DynamicCanvasBounds.rebaseDelta(contentUnion: union)
        #expect(delta != nil)
        #expect(delta?.dx == DynamicCanvasBounds.edgeMargin - 100)
        #expect(delta?.dy == 0)  // y は余白内なので動かさない
    }

    @Test("左右上下とも余白内ならリベース不要")
    func noRebaseWhenWellInsideMargins() {
        let union = CGRect(x: 10_000, y: 10_000, width: 200, height: 200)
        #expect(DynamicCanvasBounds.rebaseDelta(contentUnion: union) == nil)
    }

    @Test("コンテンツが無ければリベース不要")
    func noRebaseWithoutContent() {
        #expect(DynamicCanvasBounds.rebaseDelta(contentUnion: nil) == nil)
    }

    @Test("左上とも余白を切っていれば dx・dy 両方が算出される")
    func rebaseHandlesBothAxes() {
        let union = CGRect(x: 500, y: 1_000, width: 50, height: 50)
        let delta = DynamicCanvasBounds.rebaseDelta(contentUnion: union)
        #expect(delta?.dx == DynamicCanvasBounds.edgeMargin - 500)
        #expect(delta?.dy == DynamicCanvasBounds.edgeMargin - 1_000)
    }

    @Test("リベース後の座標(delta 適用後)は再度リベース不要になる")
    func rebasedContentNoLongerNeedsRebase() {
        let union = CGRect(x: 100, y: 100, width: 50, height: 50)
        guard let delta = DynamicCanvasBounds.rebaseDelta(contentUnion: union) else {
            Issue.record("delta が算出されるはず")
            return
        }
        let shifted = union.offsetBy(dx: delta.dx, dy: delta.dy)
        #expect(DynamicCanvasBounds.rebaseDelta(contentUnion: shifted) == nil)
    }
}
