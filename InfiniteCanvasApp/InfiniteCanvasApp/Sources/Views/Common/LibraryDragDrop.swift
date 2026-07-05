import SwiftUI
import CoreData
import UniformTypeIdentifiers

extension UTType {
    /// アプリ内ドラッグ&ドロップ専用のカスタム型
    static let libraryItem = UTType(exportedAs: "com.muu0726.InfiniteCanvasApp.library-item")
}

/// ドラッグ&ドロップで運ぶフォルダ・ノートの識別情報(Core Data objectID の URI)。
/// オブジェクト本体ではなく URI を運び、ドロップ時に context から引き当てる。
struct LibraryItemTransfer: Codable, Transferable {
    enum Kind: String, Codable { case folder, note }
    let kind: Kind
    let uri: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .libraryItem)
    }

    init(item: LibraryItem) {
        switch item {
        case .folder(let folder):
            kind = .folder
            uri = folder.objectID.uriRepresentation().absoluteString
        case .note(let note):
            kind = .note
            uri = note.objectID.uriRepresentation().absoluteString
        }
    }

    /// URI から Core Data オブジェクトを引き当てる(削除済みなら nil)
    func resolve(in context: NSManagedObjectContext) -> LibraryItem? {
        guard let url = URL(string: uri),
              let coordinator = context.persistentStoreCoordinator,
              let objectID = coordinator.managedObjectID(forURIRepresentation: url),
              let object = try? context.existingObject(with: objectID) else { return nil }
        switch kind {
        case .folder: return (object as? Folder).map(LibraryItem.folder)
        case .note: return (object as? NoteFile).map(LibraryItem.note)
        }
    }
}

/// ドロップされた項目を destination(nil はルート)へ移動する。
/// 1件でも移動できたら true。同じ場所への移動や循環参照になる移動はスキップされる。
@MainActor
@discardableResult
func handleLibraryDrop(
    _ transfers: [LibraryItemTransfer],
    into destination: Folder?,
    context: NSManagedObjectContext
) -> Bool {
    var moved = false
    for transfer in transfers {
        guard let item = transfer.resolve(in: context) else { continue }
        switch item {
        case .folder(let folder):
            if folder.parent == destination { continue }
            // 自分自身・自分の子孫へのドロップは移動不可(LibraryService と同じ判定)
            if let destination, destination == folder || destination.isDescendant(of: folder) { continue }
        case .note(let note):
            if note.folder == destination { continue }
        }
        LibraryService.move(item, to: destination, in: context)
        moved = true
    }
    return moved
}
