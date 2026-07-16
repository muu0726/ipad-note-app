import CoreGraphics

/// 通常ノート(paged)のページ並び替え・複製・削除に伴う、ページ内コンテンツ
/// (手書きストローク・オブジェクト)の座標再割り当てを計算する純ロジック。
///
/// ページ幾何は `PagedLayoutCalculator.pageRect(_:)` から引くので、縦/横スクロールや
/// 見開きレイアウトに依存しない(ピッチ 1150/820 等を直接ハードコードしない)。
/// UIKit 非依存なのでユニットテストで担保する。
struct PagePlan: Equatable {
    let oldCount: Int
    let newCount: Int
    /// 旧ページ index → 新ページ index。nil は「そのページが削除される」。
    let oldToNew: [Int?]
    /// 複製時に複製元となる旧ページ index(複製でなければ nil)
    let duplicatedSource: Int?
    /// 複製されたコピーが入る新ページ index(複製でなければ nil)
    let duplicatedNewIndex: Int?

    // MARK: - 生成

    /// ページ `from` を `to` の位置へ移動する並び替え(ページ数は不変)。
    static func reorder(count: Int, from: Int, to: Int) -> PagePlan {
        guard count > 0, from >= 0, from < count, to >= 0, to < count else {
            return identity(count: count)
        }
        var order = Array(0..<count)                 // order[newIndex] = oldIndex
        let moved = order.remove(at: from)
        order.insert(moved, at: to)
        var oldToNew = [Int?](repeating: nil, count: count)
        for (newIndex, oldIndex) in order.enumerated() { oldToNew[oldIndex] = newIndex }
        return PagePlan(oldCount: count, newCount: count,
                        oldToNew: oldToNew, duplicatedSource: nil, duplicatedNewIndex: nil)
    }

    /// ページ `at` の直後にそのページの複製を1枚挿入する(ページ数 +1)。
    static func duplicate(count: Int, at src: Int) -> PagePlan {
        guard count > 0, src >= 0, src < count else { return identity(count: count) }
        var oldToNew = [Int?](repeating: nil, count: count)
        for i in 0..<count { oldToNew[i] = i <= src ? i : i + 1 }   // src より後ろは1つ後ろへ
        return PagePlan(oldCount: count, newCount: count + 1,
                        oldToNew: oldToNew, duplicatedSource: src, duplicatedNewIndex: src + 1)
    }

    /// ページ `at` を削除する(ページ数 -1)。そのページ上のコンテンツは破棄される。
    static func delete(count: Int, at del: Int) -> PagePlan {
        guard count > 1, del >= 0, del < count else { return identity(count: count) }
        var oldToNew = [Int?](repeating: nil, count: count)
        for i in 0..<count where i != del { oldToNew[i] = i < del ? i : i - 1 }
        return PagePlan(oldCount: count, newCount: count - 1,
                        oldToNew: oldToNew, duplicatedSource: nil, duplicatedNewIndex: nil)
    }

    /// 変化なし(不正入力時のフォールバック)
    static func identity(count: Int) -> PagePlan {
        PagePlan(oldCount: count, newCount: count,
                 oldToNew: Array(0..<count).map { Optional($0) },
                 duplicatedSource: nil, duplicatedNewIndex: nil)
    }

    // MARK: - 平行移動の計算

    /// 旧ページ `oldIndex` 上のコンテンツに適用する平行移動。nil ならそのページは削除
    /// (= コンテンツを破棄する)。
    func translation(
        forOldPage oldIndex: Int,
        oldLayout: PagedLayoutCalculator,
        newLayout: PagedLayoutCalculator
    ) -> CGVector? {
        guard oldIndex >= 0, oldIndex < oldToNew.count, let newIndex = oldToNew[oldIndex] else { return nil }
        let o = oldLayout.pageRect(oldIndex).origin
        let n = newLayout.pageRect(newIndex).origin
        return CGVector(dx: n.x - o.x, dy: n.y - o.y)
    }

    /// 複製されたコピーに適用する平行移動(複製元ページの内容を複製先ページへ移す)。
    /// 複製でなければ nil。
    func duplicateTranslation(
        oldLayout: PagedLayoutCalculator,
        newLayout: PagedLayoutCalculator
    ) -> CGVector? {
        guard let src = duplicatedSource, let dst = duplicatedNewIndex else { return nil }
        let o = oldLayout.pageRect(src).origin
        let n = newLayout.pageRect(dst).origin
        return CGVector(dx: n.x - o.x, dy: n.y - o.y)
    }
}

/// ページと座標の対応づけヘルパー(純ロジック)。
enum PagePlanner {
    /// 点(コンテンツ座標)が属するページ index。どのページ矩形にも含まれなければ nil。
    static func pageIndex(of point: CGPoint, layout: PagedLayoutCalculator) -> Int? {
        for i in 0..<max(1, layout.pageCount) where layout.pageRect(i).contains(point) {
            return i
        }
        return nil
    }

    /// 現在ビューポートの中心が最も近いページ index(しおり付与の対象ページ判定に使う)。
    /// 横スクロール前提で X 方向の中心とページ中心の距離が最小のページを返す。
    /// contentOffset はスクロールビュー座標(ズーム込み)なので zoomScale で割ってコンテンツ座標へ戻す。
    static func currentPage(
        contentOffsetX: CGFloat, viewWidth: CGFloat, zoomScale: CGFloat,
        layout: PagedLayoutCalculator
    ) -> Int {
        guard zoomScale > 0 else { return 0 }
        let centerX = (contentOffsetX + viewWidth / 2) / zoomScale
        var best = 0
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for i in 0..<max(1, layout.pageCount) {
            let distance = abs(layout.pageRect(i).midX - centerX)
            if distance < bestDistance { bestDistance = distance; best = i }
        }
        return best
    }

    /// ページ index の先頭へスクロールするための contentOffset.x(横スクロール)。
    /// margin はスクロール方向端のグレー余白(`PageMetrics.margin`)。
    static func scrollOffsetX(toPage index: Int, zoomScale: CGFloat, layout: PagedLayoutCalculator, margin: CGFloat) -> CGFloat {
        layout.pageRect(index).minX * zoomScale - margin
    }
}
