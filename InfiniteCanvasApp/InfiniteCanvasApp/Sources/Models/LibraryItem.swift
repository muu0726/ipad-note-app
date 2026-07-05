import CoreData

/// フォルダとノートを同一に扱うためのラッパー。
/// コンテキストメニューやダイアログの対象指定に使う。
enum LibraryItem: Identifiable, Hashable {
    case folder(Folder)
    case note(NoteFile)

    var id: NSManagedObjectID {
        switch self {
        case .folder(let folder): folder.objectID
        case .note(let note): note.objectID
        }
    }

    var displayName: String {
        switch self {
        case .folder(let folder): folder.displayName
        case .note(let note): note.displayTitle
        }
    }

    var isFolder: Bool {
        if case .folder = self { true } else { false }
    }
}
