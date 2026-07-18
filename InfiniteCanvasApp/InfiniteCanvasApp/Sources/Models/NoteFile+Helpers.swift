import CoreData

/// ノートの形式。無限キャンバス or 固定サイズページが縦に並ぶ通常ノート。
enum CanvasNoteType: String, CaseIterable {
    case infinite   // 無限キャンバス
    case paged      // 通常ノート(A4 固定ページ)

    var label: String {
        switch self {
        case .infinite: "無限キャンバス"
        case .paged: "通常ノート"
        }
    }

    /// 一覧などで種別を見分けるためのアイコン(SF Symbols)
    var icon: String {
        switch self {
        case .infinite: "square.dashed"    // 無限に広がるキャンバス
        case .paged: "doc.richtext"        // 紙のページ(通常ノート)
        }
    }
}

extension NoteFile {
    var displayTitle: String { title ?? "無題ノート" }

    /// 作成時に選んだ用紙の色(白 / 黒)
    var canvasPageColor: CanvasPageColor {
        CanvasPageColor(rawValue: pageColor ?? "") ?? .white
    }

    /// ノート形式。既存ノート(未設定)は無限キャンバス扱い
    var canvasNoteType: CanvasNoteType {
        CanvasNoteType(rawValue: noteType ?? "") ?? .infinite
    }

    /// ページ数(通常ノート用)。最低1ページを保証する
    var resolvedPageCount: Int {
        max(1, Int(pageCount))
    }

    // MARK: - しおり(ブックマーク)

    /// しおりを付けたページ index の集合。`bookmarkedPages`(JSON文字列)に保存する。
    var bookmarkedPageSet: Set<Int> {
        get {
            guard let json = bookmarkedPages, let data = json.data(using: .utf8),
                  let list = try? JSONDecoder().decode([Int].self, from: data) else { return [] }
            return Set(list)
        }
        set {
            let list = newValue.sorted()
            bookmarkedPages = (try? JSONEncoder().encode(list)).flatMap { String(data: $0, encoding: .utf8) }
        }
    }

    /// 昇順のしおりページ一覧(存在するページのみ)
    var bookmarkedPageList: [Int] {
        bookmarkedPageSet.filter { $0 >= 0 && $0 < resolvedPageCount }.sorted()
    }

    func isBookmarked(page: Int) -> Bool { bookmarkedPageSet.contains(page) }

    /// 指定ページのしおりをトグルする(付与/解除)
    func toggleBookmark(page: Int) {
        var set = bookmarkedPageSet
        if set.contains(page) { set.remove(page) } else { set.insert(page) }
        bookmarkedPageSet = set
    }

    /// 目次(アウトライン)を pageIndex 昇順・同ページ内は作成日時順で返す
    var sortedOutlines: [NoteOutline] {
        let all = (outlines as? Set<NoteOutline>) ?? []
        return all.sorted {
            if $0.pageIndex != $1.pageIndex { return $0.pageIndex < $1.pageIndex }
            return ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast)
        }
    }
}
