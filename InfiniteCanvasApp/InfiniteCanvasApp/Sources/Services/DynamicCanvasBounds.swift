import CoreGraphics

/// 無限キャンバス(`.infinite`)のワールド座標空間を動的に管理する純ロジック。
/// PKCanvasView(UIScrollView)は原点(0,0)を起点にした正方向のみの座標系のため、
/// 右・下方向は contentSize を伸ばすだけで拡張できるが、左・上方向は座標を負にできない。
/// そのため、コンテンツが左・上端の余白を切ったらコンテンツ全体を右・下へ平行移動して
/// 原点を空ける「リベース」を行うことで、実質的にどの方向へも無限に拡張できるようにする。
/// UIKit 非依存でユニットテストできるようにする。
enum DynamicCanvasBounds {
    /// 端に近づいたと判定する余白(コンテンツ座標)。コンテンツの外接矩形がこの余白を
    /// 切ったら、ワールドサイズの拡張(右・下)または原点リベース(左・上)を行う。
    /// Freeform 同様にコンテンツの周囲へ広めの空き余白を確保する。
    static let edgeMargin: CGFloat = 2_000

    /// 初期ワールドサイズ(コンテンツ座標、正方形の一辺)。
    /// Apple フリーボード同様、開いた直後から全方向へ数画面ぶん自由にスクロールできるだけの
    /// 広さを確保する。コンテンツは中央付近から始まるため、原点リベース(左・上補正)は
    /// 通常操作ではほぼ発火せず、実質的にどの方向へも境界レスに感じられる。
    /// ※ インク面(PKCanvasView)はこのサイズで確保されるため、ライブ描画が GPU 上限を
    ///   超えない範囲に抑える(過去に 20000 でライブ描画不可を確認)。
    static let initialWorldSize: CGFloat = 8_000

    /// 右・下方向へ必要なワールドサイズを計算する(縮小はしない)。
    /// - Parameters:
    ///   - contentUnion: 描画+オブジェクトの外接矩形(コンテンツ座標)。コンテンツが無ければ nil。
    ///   - currentWorldSize: 現在のワールドサイズ。
    static func expandedWorldSize(contentUnion: CGRect?, currentWorldSize: CGFloat) -> CGFloat {
        guard let union = contentUnion, !union.isNull else { return currentWorldSize }
        let required = max(union.maxX, union.maxY) + edgeMargin
        return max(currentWorldSize, required)
    }

    /// コンテンツが左・上端の余白を切っていたら、原点リベースの平行移動量
    /// (正の値 = コンテンツを右・下へ動かす)を返す。不要なら nil。
    static func rebaseDelta(contentUnion: CGRect?) -> CGVector? {
        guard let union = contentUnion, !union.isNull else { return nil }
        let dx = union.minX < edgeMargin ? (edgeMargin - union.minX) : 0
        let dy = union.minY < edgeMargin ? (edgeMargin - union.minY) : 0
        guard dx > 0 || dy > 0 else { return nil }
        return CGVector(dx: dx, dy: dy)
    }
}
