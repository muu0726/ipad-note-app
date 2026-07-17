import UIKit
import PencilKit
import CoreData

/// 通常ノート(paged)の1ページ分のサムネイル画像を生成する。
/// キャンバスと同じ重なり順(オブジェクト → 蛍光ペン → 前面インク)で合成する。
enum PageThumbnailRenderer {
    /// - pageRect: 対象ページのコンテンツ座標矩形(`PagedLayoutCalculator.pageRect`)
    /// - 戻り値: 用紙色の下地にコンテンツを焼いた画像(長辺 maxDimension pt)
    static func render(
        pageRect: CGRect,
        drawing: PKDrawing,
        objects: [CanvasObject],
        pageColor: CanvasPageColor,
        maxDimension: CGFloat = 320
    ) -> UIImage {
        let longest = max(pageRect.width, pageRect.height, 1)
        let scale = min(1, maxDimension / longest)
        let size = CGSize(width: pageRect.width * scale, height: pageRect.height * scale)
        // 蛍光ペンは前面 drawing では不可視(alpha 0)なのでミラーを復元し、オブジェクトの上・前面インクの下に敷く
        let markerDrawing = MarkerLayer.backingDrawing(from: drawing)

        // 手書きは drawing 全体を実座標で描き、コンテキストをページ矩形にクリップして
        // ページ外へはみ出させない(image(from:) の切り出し挙動に依存しない)。
        let inkBounds = drawing.bounds
        let markerBounds = markerDrawing.bounds

        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = true   // 用紙は不透明。透明な縁を作らない
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext
            pageColor.backgroundUIColor.setFill()
            cg.fill(CGRect(origin: .zero, size: size))
            cg.scaleBy(x: scale, y: scale)
            cg.translateBy(x: -pageRect.minX, y: -pageRect.minY)
            cg.clip(to: pageRect)   // ページ矩形の外は一切描かない

            // 1) このページに掛かるオブジェクト
            for object in objects where !object.isDeleted && object.contentFrame.intersects(pageRect) {
                object.drawInThumbnail(pageColor: pageColor)
            }
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                // 2) 蛍光ペン(オブジェクトの上。全体を実座標で描き、クリップでこのページ分だけ残す)
                if !markerDrawing.strokes.isEmpty, !markerBounds.isEmpty {
                    markerDrawing.image(from: markerBounds, scale: scale).draw(in: markerBounds)
                }
            }
            // 3) 前面インク(ペン等。不可視マーカーは何も描かない)
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                if !inkBounds.isEmpty {
                    drawing.image(from: inkBounds, scale: scale).draw(in: inkBounds)
                }
            }
        }
    }
}
