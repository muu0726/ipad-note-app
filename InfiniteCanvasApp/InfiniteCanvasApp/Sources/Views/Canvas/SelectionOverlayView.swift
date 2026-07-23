import UIKit

/// 複数オブジェクト選択(2個以上)に重ねる統一バウンディングボックス + 8方向リサイズハンドル。
/// `ObjectLayerUIView` のサブビューとしてコンテンツ空間に置かれ、スクロール/ズーム追従は
/// スクロールビューの合成が担う(オブジェクトと同じ座標系)。枠の内部・外部のタッチは下へ透過し、
/// ハンドル付近のタッチだけを受ける(内部ドラッグは既存の一括移動へ委ねる)。
/// 回転ハンドルの席は用意するが、本増分では非表示(回転は後続増分)。
final class SelectionOverlayView: UIView {
    /// リサイズハンドルをドラッグしたとき(ハンドル, ドラッグ開始からの累積移動量, 状態)。
    var onResize: ((SelectionHandle, CGVector, UIGestureRecognizer.State) -> Void)?

    /// 現在の選択枠(コンテンツ空間)。
    private(set) var box: CGRect = .zero
    /// 現在のズーム倍率(枠線幅・ハンドルの見かけ調整用)。
    private var zoom: CGFloat = 1

    /// コンテンツ空間でのハンドル一辺(既存の単体リサイズハンドル22ptに合わせる)。
    private static let handleSide: CGFloat = 22

    private let boxLayer = CAShapeLayer()
    private var handleViews: [SelectionHandle: UIView] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        isHidden = true
        backgroundColor = .clear

        boxLayer.fillColor = nil
        boxLayer.strokeColor = UIColor.systemBlue.cgColor
        boxLayer.lineWidth = 1.5
        layer.addSublayer(boxLayer)

        // 指のみ操作(Apple Pencil は描画に使うため、選択枠の操作は指に限定)
        let fingerOnly = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        for handle in SelectionHandle.allCases {
            let view = UIView()
            view.backgroundColor = .systemBackground
            view.layer.borderWidth = 2
            view.layer.borderColor = UIColor.systemBlue.cgColor
            view.layer.cornerRadius = Self.handleSide / 2
            view.isAccessibilityElement = true  // XCUITest から掴めるように
            view.accessibilityIdentifier = "selection-resize-handle-\(handle.identifierSuffix)"
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            pan.allowedTouchTypes = fingerOnly
            pan.maximumNumberOfTouches = 1
            view.addGestureRecognizer(pan)
            addSubview(view)
            handleViews[handle] = view
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// 選択枠とズームを反映し、枠線・ハンドルを再配置する。
    func update(box: CGRect, zoom: CGFloat) {
        self.box = box
        self.zoom = zoom
        layoutChrome()
    }

    /// 表示/非表示を切り替える(2個以上選択で表示、1個以下で非表示)。
    func setActive(_ active: Bool) {
        isHidden = !active
    }

    /// 枠線とハンドルの位置・見かけサイズを現在の box / zoom から更新する。
    private func layoutChrome() {
        guard !isHidden else { return }
        boxLayer.path = UIBezierPath(rect: box).cgPath
        boxLayer.lineWidth = 1.5 / max(zoom, 0.01)  // 画面上で一定の太さに見せる
        let side = Self.handleSide / max(zoom, 0.01)  // 画面上で一定サイズに見せる
        for (handle, view) in handleViews {
            let center = handle.point(in: box)
            view.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            view.center = center
            view.layer.cornerRadius = side / 2
            view.layer.borderWidth = 2 / max(zoom, 0.01)
        }
    }

    /// ハンドル付近のタッチだけを受ける(内部/外部のタッチは下のオブジェクト・背景へ透過)。
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard !isHidden else { return false }
        let margin = (Self.handleSide / max(zoom, 0.01)) / 2
        return handleViews.values.contains { view in
            view.frame.insetBy(dx: -margin, dy: -margin).contains(point)
        }
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let handle = handleViews.first(where: { $0.value === gesture.view })?.key else { return }
        // layerView(スーパービュー)はコンテンツ空間なので translation はコンテンツ空間の移動量
        let t = gesture.translation(in: superview)
        onResize?(handle, CGVector(dx: t.x, dy: t.y), gesture.state)
    }
}

private extension SelectionHandle {
    /// アクセシビリティ識別子の接尾辞。
    var identifierSuffix: String {
        switch self {
        case .topLeft: "topLeft"
        case .top: "top"
        case .topRight: "topRight"
        case .right: "right"
        case .bottomRight: "bottomRight"
        case .bottom: "bottom"
        case .bottomLeft: "bottomLeft"
        case .left: "left"
        }
    }

    /// 選択枠 box におけるこのハンドルの中心座標(コンテンツ空間)。
    func point(in box: CGRect) -> CGPoint {
        let xs: CGFloat, ys: CGFloat
        switch self {
        case .topLeft, .left, .bottomLeft: xs = box.minX
        case .top, .bottom: xs = box.midX
        case .topRight, .right, .bottomRight: xs = box.maxX
        }
        switch self {
        case .topLeft, .top, .topRight: ys = box.minY
        case .left, .right: ys = box.midY
        case .bottomLeft, .bottom, .bottomRight: ys = box.maxY
        }
        return CGPoint(x: xs, y: ys)
    }
}
