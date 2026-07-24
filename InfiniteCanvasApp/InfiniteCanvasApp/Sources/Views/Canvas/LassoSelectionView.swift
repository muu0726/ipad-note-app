import UIKit

/// 自前投げ縄によるインク+オブジェクト一括選択のオーバーレイ。
/// `ObjectLayerUIView` のサブビュー(コンテンツ空間)として、
/// (1) ドラッグ中の投げ縄パス(破線)、(2) 確定後の統一選択ボックス + 削除ボタン を描く。
/// 選択ボックス内部のドラッグは一括移動、削除ボタンで一括削除する。
/// スクロール/ズーム追従はスクロールビューの合成が担う(オブジェクトと同じ座標系)。
final class LassoSelectionView: UIView {
    /// 選択ボックス内部をドラッグしたとき(累積移動量, 状態)。インク+オブジェクトを一括移動する。
    var onMove: ((CGVector, UIGestureRecognizer.State) -> Void)?
    /// 削除ボタンを押したとき。選択中のインク+オブジェクトを一括削除する。
    var onDelete: (() -> Void)?

    /// 確定した統一選択ボックス(コンテンツ空間)。nil のとき選択なし。
    private(set) var box: CGRect?
    private var zoom: CGFloat = 1

    private let lassoLayer = CAShapeLayer()
    private let boxLayer = CAShapeLayer()
    private let deleteButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isHidden = true
        backgroundColor = .clear

        // ドラッグ中の投げ縄(破線)
        lassoLayer.fillColor = UIColor.systemBlue.withAlphaComponent(0.08).cgColor
        lassoLayer.strokeColor = UIColor.systemBlue.cgColor
        lassoLayer.lineWidth = 1.5
        lassoLayer.lineDashPattern = [6, 4]
        layer.addSublayer(lassoLayer)

        // 確定後の選択ボックス(実線)
        boxLayer.fillColor = nil
        boxLayer.strokeColor = UIColor.systemBlue.cgColor
        boxLayer.lineWidth = 1.5
        layer.addSublayer(boxLayer)

        // 一括削除ボタン(ボックス右上)
        deleteButton.setImage(UIImage(systemName: "trash.circle.fill"), for: .normal)
        deleteButton.tintColor = .systemRed
        deleteButton.backgroundColor = .systemBackground
        deleteButton.layer.cornerRadius = 14
        deleteButton.isHidden = true
        deleteButton.accessibilityIdentifier = "lasso-delete-button"
        deleteButton.addTarget(self, action: #selector(handleDelete), for: .touchUpInside)
        addSubview(deleteButton)

        // 選択ボックス内部のドラッグ = 一括移動(指・Pencil 両対応)
        let move = UIPanGestureRecognizer(target: self, action: #selector(handleMove(_:)))
        move.maximumNumberOfTouches = 1
        addGestureRecognizer(move)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// ドラッグ中の投げ縄パス(コンテンツ空間の頂点列)を描画する。
    func updateLassoPath(_ points: [CGPoint]) {
        boxLayer.path = nil
        deleteButton.isHidden = true
        box = nil
        isHidden = points.isEmpty
        guard points.count >= 2 else { lassoLayer.path = nil; return }
        let path = UIBezierPath()
        path.move(to: points[0])
        for p in points.dropFirst() { path.addLine(to: p) }
        path.close()
        lassoLayer.lineWidth = 1.5 / max(zoom, 0.01)
        lassoLayer.lineDashPattern = [NSNumber(value: 6 / Double(max(zoom, 0.01))),
                                      NSNumber(value: 4 / Double(max(zoom, 0.01)))]
        lassoLayer.path = path.cgPath
    }

    /// 確定した統一選択ボックスを表示する(投げ縄パスは消す)。
    func showSelection(box: CGRect, zoom: CGFloat) {
        self.box = box
        self.zoom = zoom
        lassoLayer.path = nil
        isHidden = false
        layoutChrome()
        deleteButton.isHidden = false
    }

    /// 選択を解除して非表示にする。
    func clear() {
        box = nil
        lassoLayer.path = nil
        boxLayer.path = nil
        deleteButton.isHidden = true
        isHidden = true
    }

    func applyZoom(_ zoom: CGFloat) {
        self.zoom = zoom
        if box != nil { layoutChrome() }
    }

    private func layoutChrome() {
        guard let box else { return }
        boxLayer.path = UIBezierPath(rect: box).cgPath
        boxLayer.lineWidth = 1.5 / max(zoom, 0.01)
        let side = 28 / max(zoom, 0.01)
        deleteButton.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        deleteButton.center = CGPoint(x: box.maxX, y: box.minY)
        deleteButton.layer.cornerRadius = side / 2
    }

    /// 選択ボックス内部と削除ボタンだけタッチを受け、それ以外は下へ透過する。
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard !isHidden, let box else { return false }
        if !deleteButton.isHidden {
            let margin = (28 / max(zoom, 0.01)) / 2
            if deleteButton.frame.insetBy(dx: -margin, dy: -margin).contains(point) { return true }
        }
        return box.contains(point)
    }

    @objc private func handleDelete() { onDelete?() }

    @objc private func handleMove(_ gesture: UIPanGestureRecognizer) {
        let t = gesture.translation(in: superview)
        onMove?(CGVector(dx: t.x, dy: t.y), gesture.state)
    }
}
