import CoreGraphics

/// 統一選択枠(`SelectionOverlayView`)の8方向リサイズハンドル。
enum SelectionHandle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
}

/// 統一選択枠の幾何計算(純ロジック)。バウンディングボックス算出・ハンドルリサイズ・
/// 枠内フレームの比例スケール・回転角の計算を担う。UIKit / CoreData 非依存でユニットテスト可能。
/// インク(ストローク)もオブジェクトも「コンテンツ座標の矩形/点」として同一に扱えるため、
/// この計算だけで両者を1つの選択枠で一括変形できる。
enum SelectionGeometry {
    /// 複数フレームの外接矩形(= 選択枠)。空なら nil。
    static func boundingBox(of frames: [CGRect]) -> CGRect? {
        guard let first = frames.first else { return nil }
        return frames.dropFirst().reduce(first) { $0.union($1) }
    }

    /// ハンドルをドラッグしたときの新しい選択枠。
    /// ハンドルは水平・垂直それぞれ最大1辺だけを動かし、反対側の辺をアンカーとして固定する。
    /// `minSize` 未満に潰れない(辺が反転しない)ようクランプする。
    static func resizedBox(
        _ box: CGRect, handle: SelectionHandle, translation t: CGVector, minSize: CGFloat = 20
    ) -> CGRect {
        var minX = box.minX, minY = box.minY, maxX = box.maxX, maxY = box.maxY
        let movesLeft = handle == .topLeft || handle == .left || handle == .bottomLeft
        let movesRight = handle == .topRight || handle == .right || handle == .bottomRight
        let movesTop = handle == .topLeft || handle == .top || handle == .topRight
        let movesBottom = handle == .bottomLeft || handle == .bottom || handle == .bottomRight
        if movesLeft { minX = min(box.minX + t.dx, maxX - minSize) }
        if movesRight { maxX = max(box.maxX + t.dx, minX + minSize) }
        if movesTop { minY = min(box.minY + t.dy, maxY - minSize) }
        if movesBottom { maxY = max(box.maxY + t.dy, minY + minSize) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// 選択枠 old から new への変形を、枠内のフレーム rect へ比例的に適用する。
    /// 相対位置とサイズを保ったまま、枠全体と一緒に拡大縮小・移動する。
    static func rescale(_ rect: CGRect, from old: CGRect, to new: CGRect) -> CGRect {
        guard old.width > 0, old.height > 0 else { return rect }
        let sx = new.width / old.width
        let sy = new.height / old.height
        return CGRect(
            x: new.minX + (rect.minX - old.minX) * sx,
            y: new.minY + (rect.minY - old.minY) * sy,
            width: rect.width * sx,
            height: rect.height * sy
        )
    }

    /// 中心から点への角度(ラジアン)。回転ハンドルのドラッグ角度算出に使う。
    static func angle(from center: CGPoint, to point: CGPoint) -> CGFloat {
        atan2(point.y - center.y, point.x - center.x)
    }
}
