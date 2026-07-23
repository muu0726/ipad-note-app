import CoreGraphics

/// 投げ縄(または矩形マーキー)による選択の内包判定(純ロジック)。
/// PencilKit / UIKit 非依存。呼び出し側が `PKStrokePath` からサンプル点を、
/// `CanvasObject` からフレーム矩形を取り出してここへ渡す。
/// これにより「PencilKit の投げ縄がブラックボックス」であることに依存した後追い差分検知
/// (旧 `LassoObjectSync`)を廃し、選択セッションの中でリアルタイムに内包判定できる。
enum LassoHitTesting {
    /// ストロークが「選択された」とみなすサンプル点の内包割合のしきい値
    /// (Freeform / Notability 等が採る一般的な閾値方式)。
    static let strokeContainmentThreshold: Double = 0.6

    /// 投げ縄パス(閉多角形)を頂点列から作る。頂点が3点未満なら nil。
    static func polygon(from points: [CGPoint]) -> CGPath? {
        guard points.count >= 3 else { return nil }
        let path = CGMutablePath()
        path.addLines(between: points)
        path.closeSubpath()
        return path
    }

    /// 矩形マーキー選択用の投げ縄パス(閉矩形)。
    static func polygon(from rect: CGRect) -> CGPath {
        CGPath(rect: rect, transform: nil)
    }

    /// サンプル点列(= 1本のストローク)が投げ縄に選択されるか。
    /// 内包割合が `strokeContainmentThreshold` 以上で true。空の点列は false。
    static func strokeIsSelected(samplePoints: [CGPoint], inside polygon: CGPath) -> Bool {
        guard !samplePoints.isEmpty else { return false }
        let insideCount = samplePoints.reduce(0) { acc, point in
            acc + (polygon.contains(point, using: .winding) ? 1 : 0)
        }
        return Double(insideCount) / Double(samplePoints.count) >= strokeContainmentThreshold
    }

    /// 矩形(オブジェクトのフレーム)が投げ縄に選択されるか。
    /// 中心が内包されていれば true(Freeform 風の寛容な判定)。
    static func rectIsSelected(_ rect: CGRect, inside polygon: CGPath) -> Bool {
        polygon.contains(CGPoint(x: rect.midX, y: rect.midY), using: .winding)
    }

    /// 早期除外用: ある外接矩形が投げ縄の外接矩形と交差しなければ、内包され得ないので判定を省ける。
    static func canIntersect(_ bounds: CGRect, lassoBounds: CGRect) -> Bool {
        !bounds.isNull && bounds.intersects(lassoBounds)
    }
}
