import CoreData

extension Folder {
    var displayName: String { name ?? "無題フォルダ" }

    /// ゴミ箱に入っていない子フォルダ(名前順)
    var visibleChildFolders: [Folder] {
        let set = children as? Set<Folder> ?? []
        return set
            .filter { !$0.isTrashed }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    /// ゴミ箱に入っていない直下のノート(タイトル順)
    var visibleNotes: [NoteFile] {
        let set = notes as? Set<NoteFile> ?? []
        return set
            .filter { !$0.isTrashed }
            .sorted { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }
    }

    /// 直下の表示対象アイテム数(フォルダ + ノート)
    var visibleItemCount: Int { visibleChildFolders.count + visibleNotes.count }

    /// self が ancestor の子孫かどうか(フォルダ移動時の循環参照チェックに使用)
    func isDescendant(of ancestor: Folder) -> Bool {
        var current = parent
        while let folder = current {
            if folder == ancestor { return true }
            current = folder.parent
        }
        return false
    }
}
