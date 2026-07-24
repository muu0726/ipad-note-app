import Testing
import CoreGraphics
@testable import InfiniteCanvasApp

@Suite("ConnectorGeometry コネクタ端点")
struct ConnectorGeometryTests {

    @Test("水平に並ぶ2矩形は、右辺と左辺で接続される")
    func horizontalBoxesTouchInnerEdges() {
        let source = CGRect(x: 0, y: 0, width: 100, height: 100)     // center (50,50)
        let target = CGRect(x: 300, y: 0, width: 100, height: 100)   // center (350,50)
        let (start, end) = ConnectorGeometry.endpoints(source: source, target: target)
        // source 右辺中央 → target 左辺中央
        #expect(abs(start.x - 100) < 1e-6)
        #expect(abs(start.y - 50) < 1e-6)
        #expect(abs(end.x - 300) < 1e-6)
        #expect(abs(end.y - 50) < 1e-6)
    }

    @Test("垂直に並ぶ2矩形は、下辺と上辺で接続される")
    func verticalBoxesTouchInnerEdges() {
        let source = CGRect(x: 0, y: 0, width: 100, height: 100)     // center (50,50)
        let target = CGRect(x: 0, y: 300, width: 100, height: 100)   // center (50,350)
        let (start, end) = ConnectorGeometry.endpoints(source: source, target: target)
        #expect(abs(start.x - 50) < 1e-6)
        #expect(abs(start.y - 100) < 1e-6)
        #expect(abs(end.x - 50) < 1e-6)
        #expect(abs(end.y - 300) < 1e-6)
    }

    @Test("端点は必ず矩形の境界上にある")
    func edgePointOnBoundary() {
        let rect = CGRect(x: 10, y: 20, width: 80, height: 40)
        let p = ConnectorGeometry.edgePoint(of: rect, toward: CGPoint(x: 500, y: 300))
        // 境界のいずれか(x==maxX or minX or y==maxY or minY)に乗る
        let onVertical = abs(p.x - rect.minX) < 1e-6 || abs(p.x - rect.maxX) < 1e-6
        let onHorizontal = abs(p.y - rect.minY) < 1e-6 || abs(p.y - rect.maxY) < 1e-6
        #expect(onVertical || onHorizontal)
        #expect(p.x >= rect.minX - 1e-6 && p.x <= rect.maxX + 1e-6)
        #expect(p.y >= rect.minY - 1e-6 && p.y <= rect.maxY + 1e-6)
    }

    @Test("移動に追従: target が動くと端点も動く")
    func endpointsFollowMove() {
        let source = CGRect(x: 0, y: 0, width: 100, height: 100)
        let target1 = CGRect(x: 300, y: 0, width: 100, height: 100)
        let target2 = CGRect(x: 300, y: 400, width: 100, height: 100)
        let e1 = ConnectorGeometry.endpoints(source: source, target: target1).end
        let e2 = ConnectorGeometry.endpoints(source: source, target: target2).end
        #expect(e1 != e2)
    }

    @Test("矢印ヘッドは end を頂点に2点へ開く")
    func arrowHeadSpreads() {
        let (l, r) = ConnectorGeometry.arrowHead(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 100, y: 0))
        // 右向きの線 → 羽は end より左(x<100)で上下に開く
        #expect(l.x < 100 && r.x < 100)
        #expect((l.y < 0 && r.y > 0) || (l.y > 0 && r.y < 0))
    }
}
