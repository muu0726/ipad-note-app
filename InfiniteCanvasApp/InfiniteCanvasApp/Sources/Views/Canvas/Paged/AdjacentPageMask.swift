import CoreGraphics

/// 「隣のページを隠す(完全独立表示モード)」の左右マスク矩形を計算する純ロジック。
/// 横スクロールの通常ノート(paged)で、アクティブページ(見開き時はそのユニット2枚)の
/// 外側(左右)をコンテンツ座標で覆う矩形を返す。UIKit 非依存なのでユニットテストで担保する。
enum AdjacentPageMask {

    /// アクティブページ周辺以外を覆う左右マスク矩形(コンテンツ座標)を返す。
    /// - 1ページ表示: 残すのは `activePage` の1枚。
    /// - 見開き2ページ表示: 残すのは `activePage` の属するユニット `[unit*2, unit*2+1]`
    ///   (末尾の半端ユニットは範囲内へクランプ)。
    /// 覆う必要のない側(先頭/末尾で外側にページが無い)は幅 0 の矩形を返す。
    static func maskRects(activePage: Int, layout: PagedLayoutCalculator)
        -> (left: CGRect, right: CGRect) {
        let count = max(1, layout.pageCount)
        let active = min(max(0, activePage), count - 1)

        // 残す(=マスクしない)ページ範囲を求め、その外接矩形を作る。
        let keep: [Int]
        if layout.isTwoPageLayout {
            let unit = active / 2
            keep = [unit * 2, min(unit * 2 + 1, count - 1)]
        } else {
            keep = [active]
        }
        let unitRect = keep.reduce(CGRect.null) { $0.union(layout.pageRect($1)) }

        let content = layout.contentSize
        let left = CGRect(
            x: 0, y: 0,
            width: max(0, unitRect.minX),
            height: content.height
        )
        let right = CGRect(
            x: unitRect.maxX, y: 0,
            width: max(0, content.width - unitRect.maxX),
            height: content.height
        )
        return (left, right)
    }
}
