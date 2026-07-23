import CoreGraphics

/// 無限キャンバスの「全体表示(Zoom to Fit)」計算(純ロジック)。
/// コンテンツの外接矩形を、余白付きでビューポートへ収める最適なズーム倍率と
/// contentOffset(スクリーン座標)を求める。UIKit 非依存でユニットテスト可能。
enum ZoomToFit {
    /// コンテンツをビューポートへ収めるズーム倍率と contentOffset を計算する。
    /// - Parameters:
    ///   - contentUnion: 描画+オブジェクトの外接矩形(コンテンツ座標)。空なら nil。
    ///   - viewportSize: スクロールビュー bounds のサイズ(スクリーン座標)。
    ///   - minZoom/maxZoom: ズーム倍率のクランプ範囲。
    ///   - padding: コンテンツ周囲に確保する余白(スクリーン座標、片側)。
    /// - Returns: (zoomScale, contentOffset)。コンテンツやビューポートが無ければ nil。
    static func fit(
        contentUnion: CGRect?,
        viewportSize: CGSize,
        minZoom: CGFloat,
        maxZoom: CGFloat,
        padding: CGFloat = 40
    ) -> (zoomScale: CGFloat, contentOffset: CGPoint)? {
        guard let union = contentUnion, !union.isNull, !union.isEmpty,
              viewportSize.width > 0, viewportSize.height > 0 else { return nil }

        let availW = max(1, viewportSize.width - padding * 2)
        let availH = max(1, viewportSize.height - padding * 2)
        let rawZoom = min(availW / union.width, availH / union.height)
        let zoom = min(maxZoom, max(minZoom, rawZoom))

        // コンテンツ中心をビューポート中心へ合わせる contentOffset(スクリーン座標)
        let offset = CGPoint(
            x: union.midX * zoom - viewportSize.width / 2,
            y: union.midY * zoom - viewportSize.height / 2
        )
        return (zoom, offset)
    }
}
