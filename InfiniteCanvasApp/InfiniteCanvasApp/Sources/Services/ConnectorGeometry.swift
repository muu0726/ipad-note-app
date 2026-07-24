import CoreGraphics

/// コネクタ線の端点計算(純ロジック)。接続元・接続先オブジェクトの矩形から、
/// 線が各矩形の「辺」に接する端点を求める(中心同士ではなく箱の縁で止める)。
/// 接続元/先の移動・リサイズに追従して端点が伸縮する。UIKit 非依存でユニットテスト可能。
enum ConnectorGeometry {
    /// source から target へ結ぶコネクタ線の端点(start=source 側の辺, end=target 側の辺)。
    static func endpoints(source: CGRect, target: CGRect) -> (start: CGPoint, end: CGPoint) {
        let sc = CGPoint(x: source.midX, y: source.midY)
        let tc = CGPoint(x: target.midX, y: target.midY)
        return (edgePoint(of: source, toward: tc), edgePoint(of: target, toward: sc))
    }

    /// 矩形の中心から `toward` 方向へ伸ばした半直線が、矩形の辺と交わる点。
    /// 中心が一致するなど方向が定まらないときは中心を返す。
    static func edgePoint(of rect: CGRect, toward point: CGPoint) -> CGPoint {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let dx = point.x - c.x
        let dy = point.y - c.y
        if dx == 0 && dy == 0 { return c }
        let halfW = rect.width / 2
        let halfH = rect.height / 2
        // 中心からの方向ベクトルを、矩形の縁に当たるまでスケールする係数 t を求める。
        var t = CGFloat.greatestFiniteMagnitude
        if dx != 0 { t = min(t, halfW / abs(dx)) }
        if dy != 0 { t = min(t, halfH / abs(dy)) }
        return CGPoint(x: c.x + dx * t, y: c.y + dy * t)
    }

    /// 矢印ヘッドの2つの羽の点(end を頂点として、start→end の向きに対して開く)。
    static func arrowHead(start: CGPoint, end: CGPoint, length: CGFloat = 12, spread: CGFloat = .pi / 7)
        -> (CGPoint, CGPoint) {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let left = CGPoint(x: end.x - length * cos(angle - spread),
                           y: end.y - length * sin(angle - spread))
        let right = CGPoint(x: end.x - length * cos(angle + spread),
                            y: end.y - length * sin(angle + spread))
        return (left, right)
    }
}
