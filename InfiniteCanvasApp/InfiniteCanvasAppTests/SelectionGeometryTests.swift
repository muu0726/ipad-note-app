import Testing
import CoreGraphics
@testable import InfiniteCanvasApp

// MARK: - 統一選択枠の幾何計算(バウンディングボックス・リサイズ・回転)

@Suite("SelectionGeometry 選択枠の幾何")
struct SelectionGeometryTests {

    @Test("空のフレーム集合はバウンディングボックスを持たない")
    func emptyHasNoBox() {
        #expect(SelectionGeometry.boundingBox(of: []) == nil)
    }

    @Test("複数フレームの外接矩形が選択枠になる")
    func boundingBoxUnionsFrames() {
        let frames = [
            CGRect(x: 10, y: 10, width: 20, height: 20),
            CGRect(x: 50, y: 40, width: 10, height: 30)
        ]
        let box = SelectionGeometry.boundingBox(of: frames)
        #expect(box == CGRect(x: 10, y: 10, width: 50, height: 60))
    }

    @Test("右下ハンドルのドラッグで右下角だけが動く")
    func bottomRightHandleMovesMaxCorner() {
        let box = CGRect(x: 0, y: 0, width: 100, height: 100)
        let resized = SelectionGeometry.resizedBox(box, handle: .bottomRight, translation: CGVector(dx: 20, dy: 40))
        #expect(resized == CGRect(x: 0, y: 0, width: 120, height: 140))
    }

    @Test("左上ハンドルのドラッグで原点が動きサイズが縮む")
    func topLeftHandleMovesOrigin() {
        let box = CGRect(x: 0, y: 0, width: 100, height: 100)
        let resized = SelectionGeometry.resizedBox(box, handle: .topLeft, translation: CGVector(dx: 30, dy: 20))
        #expect(resized == CGRect(x: 30, y: 20, width: 70, height: 80))
    }

    @Test("上辺ハンドルは縦だけ変え、横は変えない")
    func topHandleOnlyVertical() {
        let box = CGRect(x: 10, y: 10, width: 100, height: 100)
        let resized = SelectionGeometry.resizedBox(box, handle: .top, translation: CGVector(dx: 50, dy: 25))
        #expect(resized == CGRect(x: 10, y: 35, width: 100, height: 75))
    }

    @Test("最小サイズ以下には潰れない(辺が反転しない)")
    func clampsToMinSize() {
        let box = CGRect(x: 0, y: 0, width: 100, height: 100)
        // 右下ハンドルを大きく左上へドラッグ → 反転せず minSize(20)で止まる
        let resized = SelectionGeometry.resizedBox(box, handle: .bottomRight, translation: CGVector(dx: -200, dy: -200), minSize: 20)
        #expect(resized.width == 20)
        #expect(resized.height == 20)
        #expect(resized.minX == 0)  // 左上アンカーは固定
        #expect(resized.minY == 0)
    }

    @Test("枠の拡大に合わせて内部フレームが比例スケールする")
    func rescaleScalesInnerFrame() {
        let old = CGRect(x: 0, y: 0, width: 100, height: 100)
        let new = CGRect(x: 0, y: 0, width: 200, height: 200)  // 2倍
        let inner = CGRect(x: 25, y: 25, width: 50, height: 50)
        let scaled = SelectionGeometry.rescale(inner, from: old, to: new)
        #expect(scaled == CGRect(x: 50, y: 50, width: 100, height: 100))
    }

    @Test("枠の移動に合わせて内部フレームが平行移動する")
    func rescaleTranslatesInnerFrame() {
        let old = CGRect(x: 0, y: 0, width: 100, height: 100)
        let new = CGRect(x: 30, y: 20, width: 100, height: 100)  // サイズ不変・移動のみ
        let inner = CGRect(x: 10, y: 10, width: 20, height: 20)
        let scaled = SelectionGeometry.rescale(inner, from: old, to: new)
        #expect(scaled == CGRect(x: 40, y: 30, width: 20, height: 20))
    }

    @Test("退化した枠(幅0)ではスケールせず元のフレームを返す")
    func rescaleGuardsDegenerateBox() {
        let old = CGRect(x: 0, y: 0, width: 0, height: 100)
        let inner = CGRect(x: 5, y: 5, width: 10, height: 10)
        #expect(SelectionGeometry.rescale(inner, from: old, to: old) == inner)
    }

    @Test("回転ハンドルの角度は中心から点への atan2")
    func rotationAngle() {
        let center = CGPoint(x: 0, y: 0)
        // 真右(+x) → 0, 真下(+y) → π/2
        #expect(abs(SelectionGeometry.angle(from: center, to: CGPoint(x: 10, y: 0))) < 1e-9)
        #expect(abs(SelectionGeometry.angle(from: center, to: CGPoint(x: 0, y: 10)) - .pi / 2) < 1e-9)
    }
}
