import SwiftUI
import CoreData

/// サイドバー内のノート行。タップでタブとして開く(選択状態にはしない)。
struct NoteRow: View {
    @ObservedObject var note: NoteFile
    @ObservedObject var actions: LibraryActionCoordinator
    @EnvironmentObject private var session: OpenNotesSession

    var body: some View {
        Button {
            session.open(note)
        } label: {
            Label(note.displayTitle, systemImage: note.canvasNoteType.icon)
        }
        .buttonStyle(.plain)
        .contextMenu {
            ItemContextMenu(item: .note(note), actions: actions)
        }
        .draggable(LibraryItemTransfer(item: .note(note)))
    }
}

/// フォルダ・ノート共通の長押しコンテキストメニュー
struct ItemContextMenu: View {
    let item: LibraryItem
    @ObservedObject var actions: LibraryActionCoordinator

    /// 「この中に作成」する対象フォルダ。フォルダなら自身、ノートならその所属フォルダ(ルートは nil)
    private var containerFolder: Folder? {
        switch item {
        case .folder(let folder): return folder
        case .note(let note): return note.folder
        }
    }

    /// 作成アクションの見出し(フォルダは「この中に」、ノートは「同じ場所に」)
    private var createTitleSuffix: String {
        if case .folder = item { return "この中に" }
        return "同じ場所に"
    }

    var body: some View {
        // IDE 風に、右クリック(長押し)からその場に新規作成できる
        Button {
            actions.beginCreateNote(in: containerFolder)
        } label: {
            Label("新規ノート(\(createTitleSuffix))", systemImage: "square.and.pencil")
        }
        Button {
            actions.beginCreateFolder(in: containerFolder)
        } label: {
            Label("新規フォルダ(\(createTitleSuffix))", systemImage: "folder.badge.plus")
        }
        Button {
            actions.beginImportPDF(in: containerFolder)
        } label: {
            Label("PDFから作成(\(createTitleSuffix))", systemImage: "doc.badge.plus")
        }
        Divider()
        Button {
            actions.beginRename(item)
        } label: {
            Label("名前を変更", systemImage: "pencil")
        }
        Button {
            actions.beginMove(item)
        } label: {
            Label("移動…", systemImage: "folder")
        }
        Divider()
        Button(role: .destructive) {
            actions.beginTrash(item)
        } label: {
            Label("削除", systemImage: "trash")
        }
    }
}
