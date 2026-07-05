import PencilKit
import UIKit

/// 手書きストロークを幾何学図形(直線 / 楕円 / 矩形)として認識し、
/// きれいなストロークへ置き換えるためのヘルパー(図形認識アシスト)。
///
/// 判定は PKStrokePath を一定間隔でサンプリングした点列に対して行う:
/// - **直線**: 始点→終点の直線距離が、点列の総経路長とほぼ等しい(ほぼ一直線)。
/// - **楕円**: 閉じており、各点をバウンディングボックスに正規化した楕円方程式の値
///   `((x-cx)/rx)² + ((y-cy)/ry)²` がどの点でも ≒1(ばらつきが小さい)。
/// - **矩形**: 閉じており、急な角がほぼ4つあり、バウンディングボックスをよく充填する。
///
/// 生成するストロークは元ストロークの `ink`(色・種類)と代表的な太さを引き継ぐ。
enum ShapeRecognizer {

    /// 認識された図形の種類と、生成に必要な幾何情報。
    enum Shape: Equatable {
        case line(from: CGPoint, to: CGPoint)
        case ellipse(in: CGRect)
        case rectangle(in: CGRect)
    }

    // MARK: - 公開 API

    /// ストロークが図形に近ければ、きれいな図形ストロークを返す。近くなければ nil。
    static func cleanShape(from stroke: PKStroke) -> PKStroke? {
        guard let shape = recognize(from: stroke) else { return nil }
        let template = StrokeTemplate(from: stroke)
        switch shape {
        case .line(let a, let b): return makeLine(from: a, to: b, template: template)
        case .ellipse(let box): return makeEllipse(box, template: template)
        case .rectangle(let box): return makeRectangle(box, template: template)
        }
    }

    /// ストロークを幾何学的に判定して図形の種類を返す(生成はしない)。
    static func recognize(from stroke: PKStroke) -> Shape? {
        recognize(points: sampledPoints(from: stroke))
    }

    /// サンプリング済み点列からの判定本体(テスト用に点列を直接受け取れる)。
    static func recognize(points: [CGPoint]) -> Shape? {
        guard points.count >= 8 else { return nil }

        let box = boundingBox(points)
        let diagonal = hypot(box.width, box.height)
        // 点・ごく小さなマークは対象外(誤爆防止)
        guard diagonal > 40 else { return nil }

        let total = pathLength(points)
        guard total > 1 else { return nil }

        let gap = distance(points.first!, points.last!)

        // ① 直線: ほぼ一直線
        if gap / total >= 0.90 {
            return .line(from: points.first!, to: points.last!)
        }

        // 以降は閉じた図形のみ扱う。閉じ具合は図形サイズ(対角長)を基準に見る
        // (総経路長で見ると、長い走り書きが誤って「閉じている」と判定されてしまう)
        let isClosed = gap <= 0.25 * diagonal
        guard isClosed else { return nil }

        let fill = polygonArea(points) / max(box.width * box.height, 1)
        let corners = cornerCount(points)

        // ② 矩形: 角が4つ & 箱をよく充填
        if corners == 4, fill > 0.62 {
            return .rectangle(in: box)
        }
        // ③ 楕円: 正規化半径のばらつきが小さい
        if isEllipse(points, box: box) {
            return .ellipse(in: box)
        }
        // フォールバック: 充填率で最終判定(矩形≒1.0 / 楕円≒0.785)
        if fill > 0.80 { return .rectangle(in: box) }
        if fill > 0.60 { return .ellipse(in: box) }
        return nil
    }

    // MARK: - 点列の取得

    /// パスを一定距離間隔でサンプリングし、ストローク変換を適用したキャンバス座標の点列を返す。
    private static func sampledPoints(from stroke: PKStroke) -> [CGPoint] {
        let transform = stroke.transform
        let interpolated = stroke.path.interpolatedPoints(by: .distance(2))
        return interpolated.map { $0.location.applying(transform) }
    }

    // MARK: - 幾何判定

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    private static func pathLength(_ points: [CGPoint]) -> CGFloat {
        var length: CGFloat = 0
        for i in 1..<points.count {
            length += distance(points[i - 1], points[i])
        }
        return length
    }

    private static func boundingBox(_ points: [CGPoint]) -> CGRect {
        var minX = CGFloat.greatestFiniteMagnitude, minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        for p in points {
            minX = min(minX, p.x); minY = min(minY, p.y)
            maxX = max(maxX, p.x); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// 閉じた点列を多角形とみなした面積(シューレース公式)。
    private static func polygonArea(_ points: [CGPoint]) -> CGFloat {
        var sum: CGFloat = 0
        for i in 0..<points.count {
            let a = points[i]
            let b = points[(i + 1) % points.count]
            sum += a.x * b.y - b.x * a.y
        }
        return abs(sum) / 2
    }

    /// 楕円らしさ: 各点を正規化した楕円方程式の値が平均 ≒1・ばらつき小。
    private static func isEllipse(_ points: [CGPoint], box: CGRect) -> Bool {
        let cx = box.midX, cy = box.midY
        let rx = box.width / 2, ry = box.height / 2
        guard rx > 1, ry > 1 else { return false }  // 極端に細い → 直線扱い

        let values = points.map { p -> CGFloat in
            let nx = (p.x - cx) / rx
            let ny = (p.y - cy) / ry
            return nx * nx + ny * ny
        }
        let mean = values.reduce(0, +) / CGFloat(values.count)
        let variance = values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / CGFloat(values.count)
        return abs(mean - 1) < 0.35 && sqrt(variance) < 0.35
    }

    /// 進行方向が急変する「角」のクラスタ数を数える(閉じた点列を周回して判定)。
    private static func cornerCount(_ points: [CGPoint]) -> Int {
        let n = points.count
        guard n >= 8 else { return 0 }
        let step = max(2, n / 24)
        let threshold = 60 * CGFloat.pi / 180  // 60°以上の折れを角とみなす

        var isCorner = [Bool](repeating: false, count: n)
        for i in 0..<n {
            let a = points[(i - step + n) % n]
            let b = points[i]
            let c = points[(i + step) % n]
            let v1 = CGVector(dx: b.x - a.x, dy: b.y - a.y)
            let v2 = CGVector(dx: c.x - b.x, dy: c.y - b.y)
            if turnAngle(v1, v2) > threshold { isCorner[i] = true }
        }

        // すべて角 = 判定不能(退化)。円などでは角ゼロ。
        guard isCorner.contains(false) else { return n }

        // 角でない位置から周回し、連続した角を1クラスタとして数える
        var start = 0
        while isCorner[start] { start = (start + 1) % n }
        var count = 0
        var inCluster = false
        var i = start
        for _ in 0..<n {
            if isCorner[i] {
                if !inCluster { count += 1; inCluster = true }
            } else {
                inCluster = false
            }
            i = (i + 1) % n
        }
        return count
    }

    /// 2つの進行ベクトルのなす「曲がり角」(0 = 直進, π = 反転)。
    private static func turnAngle(_ v1: CGVector, _ v2: CGVector) -> CGFloat {
        let cross = v1.dx * v2.dy - v1.dy * v2.dx
        let dot = v1.dx * v2.dx + v1.dy * v2.dy
        return abs(atan2(cross, dot))
    }

    // MARK: - きれいなストロークの生成

    /// 元ストロークから引き継ぐインクと太さ。
    private struct StrokeTemplate {
        let ink: PKInk
        let size: CGSize

        init(from stroke: PKStroke) {
            ink = stroke.ink
            let widths = stroke.path.map { $0.size.width }.sorted()
            let median = widths.isEmpty ? 3 : widths[widths.count / 2]
            size = CGSize(width: median, height: median)
        }
    }

    private static func strokePoint(_ location: CGPoint, time: TimeInterval, size: CGSize) -> PKStrokePoint {
        PKStrokePoint(
            location: location,
            timeOffset: time,
            size: size,
            opacity: 1,
            force: 1,
            azimuth: 0,
            altitude: .pi / 2
        )
    }

    private static func makeStroke(from locations: [CGPoint], template: StrokeTemplate) -> PKStroke {
        let dt = 1.0 / 120.0
        let controlPoints = locations.enumerated().map { index, location in
            strokePoint(location, time: TimeInterval(index) * dt, size: template.size)
        }
        let path = PKStrokePath(controlPoints: controlPoints, creationDate: Date())
        return PKStroke(ink: template.ink, path: path)
    }

    private static func makeLine(from a: CGPoint, to b: CGPoint, template: StrokeTemplate) -> PKStroke {
        let segments = 24
        let locations = (0...segments).map { i -> CGPoint in
            let t = CGFloat(i) / CGFloat(segments)
            return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
        return makeStroke(from: locations, template: template)
    }

    private static func makeEllipse(_ box: CGRect, template: StrokeTemplate) -> PKStroke {
        let cx = box.midX, cy = box.midY
        let rx = box.width / 2, ry = box.height / 2
        let segments = 64
        let locations = (0...segments).map { i -> CGPoint in
            let theta = 2 * CGFloat.pi * CGFloat(i) / CGFloat(segments)
            return CGPoint(x: cx + rx * cos(theta), y: cy + ry * sin(theta))
        }
        return makeStroke(from: locations, template: template)
    }

    private static func makeRectangle(_ box: CGRect, template: StrokeTemplate) -> PKStroke {
        let corners = [
            CGPoint(x: box.minX, y: box.minY),
            CGPoint(x: box.maxX, y: box.minY),
            CGPoint(x: box.maxX, y: box.maxY),
            CGPoint(x: box.minX, y: box.maxY),
            CGPoint(x: box.minX, y: box.minY),  // 閉じる
        ]
        let perEdge = 16
        var locations: [CGPoint] = []
        for edge in 0..<(corners.count - 1) {
            let a = corners[edge], b = corners[edge + 1]
            for i in 0..<perEdge {
                let t = CGFloat(i) / CGFloat(perEdge)
                locations.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }
        locations.append(corners.last!)
        return makeStroke(from: locations, template: template)
    }
}
