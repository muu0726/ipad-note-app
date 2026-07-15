import CoreData
import PDFKit
import UIKit

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
        noteType: CanvasNoteType = .infinite,
        in context: NSManagedObjectContext
    ) -> NoteFile {
        let note = NoteFile(context: context)
        note.id = UUID()
        note.title = title.isEmpty ? "無題ノート" : title
        note.createdAt = .now
        note.updatedAt = .now
        note.folder = folder
        note.pageColor = pageColor.rawValue
        note.noteType = noteType.rawValue
        note.pageCount = 1  // 通常ノートは1ページから開始
        note.isHorizontalScroll = (noteType == .paged)  // 通常ノートは横スクロール固定
        save(context)
        return note
    }

    /// PDF の全ページを背景に展開した「通常ノート」を新規作成する。
    /// 各ページのレンダリング画像を、移動・編集・削除不可(isLocked)の背景画像として
    /// ページ矩形へロック配置する。手書き注釈はその上に描ける。
    @discardableResult
    static func createPagedNoteFromPDF(
        data: Data,
        titled title: String,
        folder: Folder?,
        in context: NSManagedObjectContext
    ) -> NoteFile? {
        guard let document = PDFDocument(data: data), document.pageCount > 0 else { return nil }

        let note = NoteFile(context: context)
        note.id = UUID()
        note.title = title.isEmpty ? "PDF ノート" : title
        note.createdAt = .now
        note.updatedAt = .now
        note.folder = folder
        note.pageColor = CanvasPageColor.white.rawValue
        note.noteType = CanvasNoteType.paged.rawValue
        note.pageCount = Int16(document.pageCount)
        note.isHorizontalScroll = true  // 通常ノートは横スクロール固定

        // ページ背景は表示レイアウト(横スクロール・1ページ)と同じ位置へ置く
        let layout = PagedLayoutCalculator(
            pageCount: document.pageCount, isTwoPageLayout: false, isHorizontalScroll: true
        )
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let rect = layout.pageRect(index)
            let object = CanvasObject(context: context)
            object.id = UUID()
            object.createdAt = .now
            object.updatedAt = .now
            object.note = note
            object.kind = CanvasObjectKind.image.rawValue
            object.payload = renderPageImage(page, size: rect.size)?.jpegData(compressionQuality: 0.8)
            object.contentFrame = rect
            object.zOrder = Int64(index)  // 背景として最背面(先に追加=低 zOrder)
            object.isLocked = true         // 移動・リサイズ・削除・選択を禁止
        }
        save(context)
        return note
    }

    /// PDF ページを指定サイズへ全面フィットでレンダリングする(用紙は白地)。
    private static func renderPageImage(_ page: PDFPage, size: CGSize) -> UIImage? {
        let box = page.bounds(for: .mediaBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 2  // Retina 相当で書き込み時もにじまない
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let cg = ctx.cgContext
            cg.saveGState()
            // PDF は左下原点。上下反転しつつページ矩形へスケール
            cg.translateBy(x: 0, y: size.height)
            cg.scaleBy(x: size.width / box.width, y: -size.height / box.height)
            cg.translateBy(x: -box.minX, y: -box.minY)
            page.draw(with: .mediaBox, to: cg)
            cg.restoreGState()
        }
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
