import Testing
import CoreGraphics
@testable import InfiniteCanvasApp

// MARK: - 投げ縄選択の内包判定(統一選択エンジンの土台)

@Suite("LassoHitTesting 内包判定")
struct LassoHitTestingTests {

    /// 中央(40,40)〜(60,60)を囲む単純な正方形の投げ縄
    private let squareLasso: CGPath = {
        LassoHitTesting.polygon(from: [
            CGPoint(x: 30, y: 30), CGPoint(x: 70, y: 30),
            CGPoint(x: 70, y: 70), CGPoint(x: 30, y: 70)
        ])!
    }()

    @Test("頂点が3点未満なら投げ縄パスは作れない")
    func polygonNeedsThreePoints() {
        #expect(LassoHitTesting.polygon(from: []) == nil)
        #expect(LassoHitTesting.polygon(from: [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)]) == nil)
        #expect(LassoHitTesting.polygon(from: [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1)]) != nil)
    }

    @Test("中心が投げ縄内なら矩形は選択される")
    func rectCenterInsideIsSelected() {
        let rect = CGRect(x: 45, y: 45, width: 10, height: 10)  // center (50,50) 内側
        #expect(LassoHitTesting.rectIsSelected(rect, inside: squareLasso))
    }

    @Test("中心が投げ縄外なら矩形は選択されない(端がかすっても中心で判定)")
    func rectCenterOutsideNotSelected() {
        let rect = CGRect(x: 65, y: 65, width: 20, height: 20)  // center (75,75) 外側
        #expect(!LassoHitTesting.rectIsSelected(rect, inside: squareLasso))
    }

    @Test("サンプル点の6割以上が内側ならストロークは選択される")
    func strokeMostlyInsideIsSelected() {
        // 5点中4点(80%)が内側
        let points = [
            CGPoint(x: 40, y: 40), CGPoint(x: 50, y: 50),
            CGPoint(x: 60, y: 60), CGPoint(x: 45, y: 55),
            CGPoint(x: 90, y: 90)  // 1点だけ外
        ]
        #expect(LassoHitTesting.strokeIsSelected(samplePoints: points, inside: squareLasso))
    }

    @Test("サンプル点の内側割合が6割未満ならストロークは選択されない")
    func strokeMostlyOutsideNotSelected() {
        // 5点中2点(40%)だけ内側
        let points = [
            CGPoint(x: 50, y: 50), CGPoint(x: 55, y: 55),
            CGPoint(x: 90, y: 90), CGPoint(x: 95, y: 20),
            CGPoint(x: 10, y: 10)
        ]
        #expect(!LassoHitTesting.strokeIsSelected(samplePoints: points, inside: squareLasso))
    }

    @Test("空のサンプル点は選択されない")
    func emptyStrokeNotSelected() {
        #expect(!LassoHitTesting.strokeIsSelected(samplePoints: [], inside: squareLasso))
    }

    @Test("ちょうど6割の内包は選択される(境界の閾値挙動)")
    func exactThresholdIsSelected() {
        // 5点中3点(60%)が内側 → しきい値 0.6 以上で選択
        let points = [
            CGPoint(x: 40, y: 40), CGPoint(x: 50, y: 50), CGPoint(x: 60, y: 60),
            CGPoint(x: 90, y: 90), CGPoint(x: 10, y: 10)
        ]
        #expect(LassoHitTesting.strokeIsSelected(samplePoints: points, inside: squareLasso))
    }

    @Test("矩形マーキーからも投げ縄パスを作れる")
    func rectMarqueePolygon() {
        let marquee = LassoHitTesting.polygon(from: CGRect(x: 30, y: 30, width: 40, height: 40))
        let rect = CGRect(x: 45, y: 45, width: 10, height: 10)
        #expect(LassoHitTesting.rectIsSelected(rect, inside: marquee))
    }

    @Test("外接矩形が交差しなければ早期除外できる")
    func earlyRejectByBounds() {
        let lassoBounds = CGRect(x: 30, y: 30, width: 40, height: 40)
        #expect(LassoHitTesting.canIntersect(CGRect(x: 50, y: 50, width: 5, height: 5), lassoBounds: lassoBounds))
        #expect(!LassoHitTesting.canIntersect(CGRect(x: 200, y: 200, width: 5, height: 5), lassoBounds: lassoBounds))
        #expect(!LassoHitTesting.canIntersect(.null, lassoBounds: lassoBounds))
    }
}
