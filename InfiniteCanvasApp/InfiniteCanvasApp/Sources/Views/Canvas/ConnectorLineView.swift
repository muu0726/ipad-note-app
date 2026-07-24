import UIKit
import CoreData

/// コネクタ1本の描画仕様(コンテンツ座標)。接続元・先の位置から Coordinator が算出する。
/// source/target のオブジェクト ID も持ち、ドラッグ中はレイヤー側が端点をライブ再計算する。
struct ConnectorLineSpec {
    let id: NSManagedObjectID
    let sourceObjectID: NSManagedObjectID
    let targetObjectID: NSManagedObjectID
    let start: CGPoint
    let end: CGPoint
    let hasArrow: Bool
}

/// 2オブジェクトを結ぶコネクタ線1本を描く軽量ビュー。オブジェクトの下・背景の上に置かれ、
/// 接続元/先の移動・リサイズに追従して端点が更新される。タッチは受けず(オブジェクト/インクへ透過)、
/// XCUITest から追従を観測できるようアクセシビリティ要素にする。
final class ConnectorLineView: UIView {
    private let lineLayer = CAShapeLayer()
    private var start: CGPoint = .zero   // コンテンツ座標
    private var end: CGPoint = .zero
    private var hasArrow = true
    private var zoom: CGFloat = 1
    /// 端点の外接矩形に足す余白(線幅・矢印がクリップされないように)。
    private static let pad: CGFloat = 24

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        isAccessibilityElement = true
        accessibilityIdentifier = "canvas-connector"
        lineLayer.strokeColor = UIColor.label.withAlphaComponent(0.55).cgColor
        lineLayer.fillColor = nil
        lineLayer.lineCap = .round
        lineLayer.lineJoin = .round
        layer.addSublayer(lineLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// 端点(コンテンツ座標)と矢印有無・ズームを反映して再描画する。
    func update(start: CGPoint, end: CGPoint, hasArrow: Bool, zoom: CGFloat) {
        self.start = start
        self.end = end
        self.hasArrow = hasArrow
        self.zoom = zoom
        redraw()
    }

    func applyZoom(_ zoom: CGFloat) {
        self.zoom = zoom
        redraw()
    }

    private func redraw() {
        let rect = CGRect(
            x: min(start.x, end.x), y: min(start.y, end.y),
            width: abs(end.x - start.x), height: abs(end.y - start.y)
        ).insetBy(dx: -Self.pad, dy: -Self.pad)
        frame = rect

        // ローカル座標へ変換して線+矢印を引く
        let s = CGPoint(x: start.x - rect.minX, y: start.y - rect.minY)
        let e = CGPoint(x: end.x - rect.minX, y: end.y - rect.minY)
        let path = UIBezierPath()
        path.move(to: s)
        path.addLine(to: e)
        if hasArrow {
            let (l, r) = ConnectorGeometry.arrowHead(start: s, end: e, length: 12 / max(zoom, 0.01))
            path.move(to: l)
            path.addLine(to: e)
            path.addLine(to: r)
        }
        lineLayer.lineWidth = 2 / max(zoom, 0.01)
        lineLayer.path = path.cgPath
    }
}
