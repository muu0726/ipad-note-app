import PencilKit
import UIKit

/// 投げ縄(PKLassoTool)によるインクの「移動」または「削除」を、描画の差分から推定した結果。
enum LassoChange: Equatable {
    case moved(region: CGRect, delta: CGVector)
    case deleted(region: CGRect)
}

/// PencilKit の投げ縄操作は内部的に閉じているため、`canvasViewDrawingDidChange` の前後で
/// 描画を突き合わせ、消えた/現れたストロークの領域から移動量・削除領域を推定する。
/// これにより、囲まれた領域に重なるオブジェクトへ同じ操作を連動させられる。
enum LassoObjectSync {

    static func detect(from old: PKDrawing, to new: PKDrawing) -> LassoChange? {
        // ストローク境界を丸めたキーで「変化していないストローク」を突き合わせる
        func key(_ rect: CGRect) -> String {
            "\(Int(rect.minX))_\(Int(rect.minY))_\(Int(rect.width))_\(Int(rect.height))"
        }
        let newKeys = Set(new.strokes.map { key($0.renderBounds) })
        let oldKeys = Set(old.strokes.map { key($0.renderBounds) })
        // old にしか無い = 移動元 or 削除 / new にしか無い = 移動先 or 追加
        let removed = old.strokes.filter { !newKeys.contains(key($0.renderBounds)) }
        let added = new.strokes.filter { !oldKeys.contains(key($0.renderBounds)) }
        guard !removed.isEmpty else { return nil }

        let removedRegion = removed.reduce(CGRect.null) { $0.union($1.renderBounds) }

        // 移動: 移動元と移動先が同数・同サイズなら平行移動とみなす
        if added.count == removed.count {
            let addedRegion = added.reduce(CGRect.null) { $0.union($1.renderBounds) }
            let delta = CGVector(dx: addedRegion.midX - removedRegion.midX,
                                 dy: addedRegion.midY - removedRegion.midY)
            let sizeMatches = abs(addedRegion.width - removedRegion.width) < 4
                && abs(addedRegion.height - removedRegion.height) < 4
            if sizeMatches, hypot(delta.dx, delta.dy) > 1 {
                return .moved(region: removedRegion, delta: delta)
            }
        }
        // 削除: 移動先が無い = ストロークが消えた
        if added.isEmpty {
            return .deleted(region: removedRegion)
        }
        return nil
    }
}
