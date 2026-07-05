import CoreData

/// フォルダ・ノートに対する操作(作成 / 名前変更 / 移動 / ゴミ箱 / 完全削除)を集約。
/// すべて viewContext 上で同期実行し、最後に保存する。
enum LibraryService {

    // MARK: - 作成

    @discardableResult
    static func createFolder(named name: String, parent: Folder?, in context: NSManagedObjectContext) -> Folder {
        let folder = Folder(context: context)
        folder.id = UUID()
        folder.name = name.isEmpty ? "新規フォルダ" : name
        folder.createdAt = .now
        folder.updatedAt = .now
        folder.parent = parent
        save(context)
        return folder
    }

    @discardableResult
    static func createNote(
        titled title: String,
        folder: Folder?,
        pageColor: CanvasPageColor = .white,
        in context: NSManagedObjectContext
    ) -> NoteFile {
        let note = NoteFile(context: context)
        note.id = UUID()
        note.title = title.isEmpty ? "無題ノート" : title
        note.createdAt = .now
        note.updatedAt = .now
        note.folder = folder
        note.pageColor = pageColor.rawValue
        save(context)
        return note
    }

    // MARK: - 名前変更

    static func rename(_ item: LibraryItem, to newName: String, in context: NSManagedObjectContext) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        switch item {
        case .folder(let folder):
            folder.name = trimmed
            folder.updatedAt = .now
        case .note(let note):
            note.title = trimmed
            note.updatedAt = .now
        }
        save(context)
    }

    // MARK: - 移動

    static func move(_ item: LibraryItem, to destination: Folder?, in context: NSManagedObjectContext) {
        switch item {
        case .folder(let folder):
            // 自分自身・自分の子孫への移動は循環参照になるため禁止
            if let destination, destination == folder || destination.isDescendant(of: folder) { return }
            folder.parent = destination
            folder.updatedAt = .now
        case .note(let note):
            note.folder = destination
            note.updatedAt = .now
        }
        save(context)
    }

    // MARK: - ゴミ箱

    /// サブツリー全体に isTrashed フラグを立ててゴミ箱へ移動する
    static func moveToTrash(_ item: LibraryItem, in context: NSManagedObjectContext) {
        switch item {
        case .folder(let folder): setTrashed(true, folder: folder)
        case .note(let note): setTrashed(true, note: note)
        }
        save(context)
    }

    /// フラグを外して復元。元の親がゴミ箱内・消失している場合はルートへ戻す
    static func restore(_ item: LibraryItem, in context: NSManagedObjectContext) {
        switch item {
        case .folder(let folder):
            setTrashed(false, folder: folder)
            if let parent = folder.parent, parent.isTrashed { folder.parent = nil }
        case .note(let note):
            setTrashed(false, note: note)
            if let parent = note.folder, parent.isTrashed { note.folder = nil }
        }
        save(context)
    }

    /// 完全削除。フォルダは Cascade ルールで中身ごと削除される
    static func deletePermanently(_ item: LibraryItem, in context: NSManagedObjectContext) {
        switch item {
        case .folder(let folder): context.delete(folder)
        case .note(let note): context.delete(note)
        }
        save(context)
    }

    static func emptyTrash(in context: NSManagedObjectContext) {
        // ゴミ箱のトップレベル項目を消せば Cascade で子孫も消える
        for folder in fetchTopLevelTrashedFolders(in: context) { context.delete(folder) }
        for note in fetchTopLevelTrashedNotes(in: context) { context.delete(note) }
        save(context)
    }

    // MARK: - ゴミ箱のトップレベル取得
    // (親ごとゴミ箱に入った子はトップレベルに含めない)

    static func fetchTopLevelTrashedFolders(in context: NSManagedObjectContext) -> [Folder] {
        let request = Folder.fetchRequest()
        request.predicate = NSPredicate(format: "isTrashed == YES AND (parent == nil OR parent.isTrashed == NO)")
        return (try? context.fetch(request)) ?? []
    }

    static func fetchTopLevelTrashedNotes(in context: NSManagedObjectContext) -> [NoteFile] {
        let request = NoteFile.fetchRequest()
        request.predicate = NSPredicate(format: "isTrashed == YES AND (folder == nil OR folder.isTrashed == NO)")
        return (try? context.fetch(request)) ?? []
    }

    // MARK: - private

    private static func setTrashed(_ trashed: Bool, folder: Folder) {
        folder.isTrashed = trashed
        folder.trashedAt = trashed ? .now : nil
        for child in (folder.children as? Set<Folder>) ?? [] where child.isTrashed != trashed {
            setTrashed(trashed, folder: child)
        }
        for note in (folder.notes as? Set<NoteFile>) ?? [] where note.isTrashed != trashed {
            setTrashed(trashed, note: note)
        }
    }

    private static func setTrashed(_ trashed: Bool, note: NoteFile) {
        note.isTrashed = trashed
        note.trashedAt = trashed ? .now : nil
    }

    private static func save(_ context: NSManagedObjectContext) {
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            context.rollback()
            assertionFailure("Core Data の保存に失敗: \(error)")
        }
    }
}
