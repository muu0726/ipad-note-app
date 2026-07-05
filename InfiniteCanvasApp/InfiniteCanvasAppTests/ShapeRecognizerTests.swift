import Testing
import PencilKit
import UIKit
@testable import InfiniteCanvasApp

// MARK: - 図形認識アシスト

@Suite("図形認識アシスト")
struct ShapeRecognizerTests {

    // MARK: 点列の生成ヘルパー

    /// わずかな手ぶれを加えつつ2点間を結ぶ点列(直線の手描き相当)
    private func linePoints(from a: CGPoint, to b: CGPoint, jitter: CGFloat = 0) -> [CGPoint] {
        (0...40).map { i -> CGPoint in
            let t = CGFloat(i) / 40
            let wobble = jitter * sin(t * .pi * 4)
            return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t + wobble)
        }
    }

    /// 中心 center・半径 (rx, ry) の楕円周上の点列(手ぶれ jitter)
    private func ellipsePoints(center: CGPoint, rx: CGFloat, ry: CGFloat, jitter: CGFloat = 0) -> [CGPoint] {
        (0...72).map { i -> CGPoint in
            let theta = 2 * CGFloat.pi * CGFloat(i) / 72
            let r = 1 + jitter * sin(theta * 5)
            return CGPoint(x: center.x + rx * r * cos(theta), y: center.y + ry * r * sin(theta))
        }
    }

    /// 矩形の周をたどる点列(角を含む)
    private func rectanglePoints(_ rect: CGRect) -> [CGPoint] {
        let corners = [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.minY),
        ]
        var points: [CGPoint] = []
        for edge in 0..<(corners.count - 1) {
            let a = corners[edge], b = corners[edge + 1]
            for i in 0..<20 {
                let t = CGFloat(i) / 20
                points.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }
        points.append(corners.last!)
        return points
    }

    // MARK: 判定

    @Test("ほぼ一直線は直線として認識される")
    func recognizesLine() {
        let shape = ShapeRecognizer.recognize(points: linePoints(from: .init(x: 20, y: 20), to: .init(x: 320, y: 90)))
        guard case .line(let a, let b) = shape else {
            Issue.record("直線として認識されなかった: \(String(describing: shape))")
            return
        }
        #expect(abs(a.x - 20) < 1 && abs(a.y - 20) < 1)
        #expect(abs(b.x - 320) < 1 && abs(b.y - 90) < 1)
    }

    @Test("手ぶれのある直線も直線として認識される")
    func recognizesWobblyLine() {
        let shape = ShapeRecognizer.recognize(points: linePoints(from: .init(x: 0, y: 0), to: .init(x: 400, y: 0), jitter: 6))
        if case .line = shape {} else {
            Issue.record("手ぶれ直線が直線として認識されなかった: \(String(describing: shape))")
        }
    }

    @Test("ほぼ真円は楕円(円)として認識される")
    func recognizesCircle() {
        let shape = ShapeRecognizer.recognize(points: ellipsePoints(center: .init(x: 200, y: 200), rx: 100, ry: 100))
        guard case .ellipse(let box) = shape else {
            Issue.record("円として認識されなかった: \(String(describing: shape))")
            return
        }
        #expect(abs(box.midX - 200) < 3 && abs(box.midY - 200) < 3)
        #expect(abs(box.width - 200) < 6 && abs(box.height - 200) < 6)
    }

    @Test("縦長の楕円も楕円として認識される")
    func recognizesEllipse() {
        let shape = ShapeRecognizer.recognize(points: ellipsePoints(center: .init(x: 150, y: 150), rx: 60, ry: 120, jitter: 0.04))
        if case .ellipse = shape {} else {
            Issue.record("楕円として認識されなかった: \(String(describing: shape))")
        }
    }

    @Test("四角形は矩形として認識される")
    func recognizesRectangle() {
        let rect = CGRect(x: 40, y: 60, width: 260, height: 180)
        let shape = ShapeRecognizer.recognize(points: rectanglePoints(rect))
        guard case .rectangle(let box) = shape else {
            Issue.record("矩形として認識されなかった: \(String(describing: shape))")
            return
        }
        #expect(abs(box.minX - rect.minX) < 3 && abs(box.minY - rect.minY) < 3)
        #expect(abs(box.width - rect.width) < 6 && abs(box.height - rect.height) < 6)
    }

    @Test("乱雑な走り書きは図形として認識されない")
    func rejectsScribble() {
        // ジグザグに往復する走り書き(閉じておらず一直線でもない)
        let scribble = (0...60).map { i -> CGPoint in
            let x = CGFloat(i) * 5
            let y = (i % 2 == 0) ? CGFloat(0) : CGFloat(80)
            return CGPoint(x: x, y: y)
        }
        #expect(ShapeRecognizer.recognize(points: scribble) == nil)
    }

    @Test("小さすぎるストロークは無視される(誤爆防止)")
    func ignoresTinyStroke() {
        let tiny = ellipsePoints(center: .init(x: 10, y: 10), rx: 8, ry: 8)
        #expect(ShapeRecognizer.recognize(points: tiny) == nil)
    }

    @Test("三角形(角3つ)は対応図形がなく認識されない")
    func rejectsTriangle() {
        let corners = [
            CGPoint(x: 100, y: 0), CGPoint(x: 200, y: 173), CGPoint(x: 0, y: 173), CGPoint(x: 100, y: 0),
        ]
        var points: [CGPoint] = []
        for edge in 0..<(corners.count - 1) {
            let a = corners[edge], b = corners[edge + 1]
            for i in 0..<24 {
                let t = CGFloat(i) / 24
                points.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }
        points.append(corners.last!)
        #expect(ShapeRecognizer.recognize(points: points) == nil)
    }

    // MARK: 生成(色・太さの引き継ぎ)

    @Test("生成された図形ストロークは元の色を引き継ぐ")
    func cleanShapeInheritsInk() {
        let ink = PKInk(.pen, color: .systemRed)
        let controlPoints = ellipsePoints(center: .init(x: 200, y: 200), rx: 100, ry: 100).map {
            PKStrokePoint(location: $0, timeOffset: 0, size: CGSize(width: 5, height: 5),
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        let path = PKStrokePath(controlPoints: controlPoints, creationDate: Date())
        let stroke = PKStroke(ink: ink, path: path)

        let clean = ShapeRecognizer.cleanShape(from: stroke)
        #expect(clean != nil)
        #expect(clean?.ink.color == ink.color)
        // 代表的な太さ(5pt)を引き継ぐ
        #expect(clean?.path.first.map { abs($0.size.width - 5) < 0.01 } == true)
    }
}
