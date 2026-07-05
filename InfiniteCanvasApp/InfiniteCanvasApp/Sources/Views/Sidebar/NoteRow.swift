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
            Label(note.displayTitle, systemImage: "doc.richtext")
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

    var body: some View {
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
