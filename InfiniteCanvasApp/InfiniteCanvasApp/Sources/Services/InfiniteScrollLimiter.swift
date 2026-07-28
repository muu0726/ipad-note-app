import UIKit

/// 無限キャンバスのスクロール可能範囲を「コンテンツ(描画+オブジェクト)の外接矩形 + 余白(画面4枚分)」へ
/// 制限する計算(Freeform 風)。ワールドサイズは固定ではなく `DynamicCanvasBounds` が
/// コンテンツに応じて動的に伸ばす(`canvasSize` 引数で受け取る)。制限は負の contentInset ではなく
/// `scrollViewDidScroll` での `clampedOffset`(contentOffset のクランプ)で行い、ズームと非結合にして
/// ドリフトを防ぐ。余白を画面4枚分と広めに取るため、コンテンツから離れても数画面ぶん自由に
/// スクロールでき(borderless に近い体感)、遠くの空白はゆるくコンテンツ側へバウンスして戻る。
/// ビュー階層に依存しない純ロジックなのでユニットテストで担保する。
enum InfiniteScrollLimiter {
    /// スクロールを許可する領域(コンテンツ座標)。
    /// - Parameters:
    ///   - contentUnion: 描画とオブジェクトの外接矩形。コンテンツが無ければ nil。
    ///   - viewportSize: スクロールビュー bounds のサイズ(スクリーン座標)
    ///   - zoomScale: 現在のズーム倍率
    ///   - canvasSize: キャンバス一辺(100,000)
    static func allowedRect(
        contentUnion: CGRect?,
        viewportSize: CGSize,
        zoomScale: CGFloat,
        canvasSize: CGFloat
    ) -> CGRect {
        let zoom = max(zoomScale, 0.01)
        // 余白: 現在のズームで画面4枚分(コンテンツ座標)を常に確保し、自由なピンチ/パンをクランプで邪魔しない
        let marginW = viewportSize.width / zoom * 4
        let marginH = viewportSize.height / zoom * 4

        var allowed: CGRect
        if let union = contentUnion, !union.isNull, !union.isEmpty {
            allowed = union.insetBy(dx: -marginW, dy: -marginH)
        } else {
            // 空ノート: キャンバス中央を中心として十分広い可動域を確保
            let center = canvasSize / 2
            allowed = CGRect(
                x: center - marginW, y: center - marginH,
                width: marginW * 2, height: marginH * 2
            )
        }

        // ビューポートより狭いと contentOffset の可動域が負になるため、最低1画面分を対称に保証
        if allowed.width < marginW {
            allowed = allowed.insetBy(dx: -(marginW - allowed.width) / 2, dy: 0)
        }
        if allowed.height < marginH {
            allowed = allowed.insetBy(dx: 0, dy: -(marginH - allowed.height) / 2)
        }

        // キャンバスの外へは出さない(サイズ保証を優先して origin を内側へ寄せる)
        let side = CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize)
        allowed.size.width = min(allowed.width, side.width)
        allowed.size.height = min(allowed.height, side.height)
        allowed.origin.x = min(max(allowed.origin.x, 0), side.maxX - allowed.width)
        allowed.origin.y = min(max(allowed.origin.y, 0), side.maxY - allowed.height)
        return allowed
    }

    /// allowedRect の外へスクロールできなくする負の contentInset(スクリーン座標)
    static func insets(allowedRect: CGRect, zoomScale: CGFloat, canvasSize: CGFloat) -> UIEdgeInsets {
        UIEdgeInsets(
            top: -allowedRect.minY * zoomScale,
            left: -allowedRect.minX * zoomScale,
            bottom: -(canvasSize - allowedRect.maxY) * zoomScale,
            right: -(canvasSize - allowedRect.maxX) * zoomScale
        )
    }

    /// 復元・プログラム設定する contentOffset を許可範囲内へクランプ(スクリーン座標)
    static func clampedOffset(
        _ offset: CGPoint,
        allowedRect: CGRect,
        zoomScale: CGFloat,
        viewportSize: CGSize
    ) -> CGPoint {
        let minX = allowedRect.minX * zoomScale
        let minY = allowedRect.minY * zoomScale
        let maxX = max(minX, allowedRect.maxX * zoomScale - viewportSize.width)
        let maxY = max(minY, allowedRect.maxY * zoomScale - viewportSize.height)
        return CGPoint(
            x: min(max(offset.x, minX), maxX),
            y: min(max(offset.y, minY), maxY)
        )
    }
}
