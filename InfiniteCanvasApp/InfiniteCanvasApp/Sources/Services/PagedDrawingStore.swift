import PencilKit
import CoreGraphics

/// 通常ノート(paged)の描画データ変換。正本は従来どおり単一の merged PKDrawing
/// (全ページのストロークがコンテンツ座標に混在、NoteFile.canvasData に保存)のまま、
/// 表示・編集はページごとの独立した PKCanvasView が担う。そのための
/// split(merged → ページローカル)と merge(ページローカル → merged)の相互変換。
/// ラウンドトリップで座標が変わらないことをユニットテストで保証する。
/// UIKit のビュー階層に依存しない純ロジック。
enum PagedDrawingStore {
    /// merged 描画をページローカル座標の描画配列へ分割する。
    /// 各ストロークは renderBounds の中心が属するページへ割り当てる。どのページにも
    /// 属さない(ページ間の gap・グレー上に残った旧データ)は最近傍ページへ割り当て、
    /// オフセットは保持する(ページ外部分は表示上クリップされるがデータは失われず、
    /// merge すれば元の座標に戻る)。
    static func split(_ merged: PKDrawing, layout: PagedLayoutCalculator) -> [PKDrawing] {
        let count = max(1, layout.pageCount)
        var strokesPerPage: [[PKStroke]] = Array(repeating: [], count: count)
        for stroke in merged.strokes {
            let bounds = stroke.renderBounds
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            let page = nearestPageIndex(of: center, layout: layout)
            let origin = layout.pageRect(page).origin
            strokesPerPage[page].append(translated(stroke, dx: -origin.x, dy: -origin.y))
        }
        return strokesPerPage.map { PKDrawing(strokes: $0) }
    }

    /// ページローカル描画配列を merged(コンテンツ座標)へ結合する。
    /// ページ数と配列数が食い違う場合は、あるだけ結合する(不足ページは空とみなす)。
    static func merge(_ pages: [PKDrawing], layout: PagedLayoutCalculator) -> PKDrawing {
        var strokes: [PKStroke] = []
        for (index, page) in pages.enumerated() where index < max(1, layout.pageCount) {
            let origin = layout.pageRect(index).origin
            strokes.append(contentsOf: page.strokes.map { translated($0, dx: origin.x, dy: origin.y) })
        }
        return PKDrawing(strokes: strokes)
    }

    /// 点(コンテンツ座標)が属するページ index。どのページにも含まれなければ
    /// ページ矩形への距離が最小のページ(最近傍)を返す。
    static func nearestPageIndex(of point: CGPoint, layout: PagedLayoutCalculator) -> Int {
        if let exact = PagePlanner.pageIndex(of: point, layout: layout) { return exact }
        var best = 0
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for index in 0..<max(1, layout.pageCount) {
            let rect = layout.pageRect(index)
            let dx = point.x - min(max(point.x, rect.minX), rect.maxX)
            let dy = point.y - min(max(point.y, rect.minY), rect.maxY)
            let distance = dx * dx + dy * dy
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return best
    }

    /// ストロークを平行移動した複製(mask も引き継ぐ)
    private static func translated(_ stroke: PKStroke, dx: CGFloat, dy: CGFloat) -> PKStroke {
        PKStroke(
            ink: stroke.ink, path: stroke.path,
            transform: stroke.transform.concatenating(CGAffineTransform(translationX: dx, y: dy)),
            mask: stroke.mask
        )
    }
}
