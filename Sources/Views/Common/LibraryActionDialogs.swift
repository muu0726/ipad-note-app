import SwiftUI
import CoreData

extension View {
    /// 作成 / 名前変更 / 削除確認 / 移動シートをまとめて取り付ける
    func libraryActionDialogs(_ coordinator: LibraryActionCoordinator) -> some View {
        modifier(LibraryActionDialogs(coordinator: coordinator))
    }
}

struct LibraryActionDialogs: ViewModifier {
    @ObservedObject var coordinator: LibraryActionCoordinator
    @Environment(\.managedObjectContext) private var context
    @EnvironmentObject private var session: OpenNotesSession

    func body(content: Content) -> some View {
        content
            .alert(createTitle, isPresented: isCreatePresented) {
                TextField("名前", text: $coordinator.nameText)
                Button("作成") { performCreate() }
                Button("キャンセル", role: .cancel) {}
            }
            .alert("名前を変更", isPresented: isRenamePresented) {
                TextField("名前", text: $coordinator.nameText)
                Button("変更") { performRename() }
                Button("キャンセル", role: .cancel) {}
            }
            .confirmationDialog(trashTitle, isPresented: isTrashPresented, titleVisibility: .visible) {
                Button("ゴミ箱に移動", role: .destructive) { performTrash() }
                Button("キャンセル", role: .cancel) {}
            } message: {
                if coordinator.trashTarget?.isFolder == true {
                    Text("中のフォルダ・ノートもすべてゴミ箱に移動されます。")
                }
            }
            .sheet(item: $coordinator.moveTarget) { item in
                MoveDestinationPicker(item: item)
                    .presentationDetents([.medium, .large])
            }
    }

    // MARK: - 表示状態のバインディング

    private var isCreatePresented: Binding<Bool> {
        Binding(
            get: { coordinator.createRequest != nil },
            set: { if !$0 { coordinator.createRequest = nil } }
        )
    }

    private var isRenamePresented: Binding<Bool> {
        Binding(
            get: { coordinator.renameTarget != nil },
            set: { if !$0 { coordinator.renameTarget = nil } }
        )
    }

    private var isTrashPresented: Binding<Bool> {
        Binding(
            get: { coordinator.trashTarget != nil },
            set: { if !$0 { coordinator.trashTarget = nil } }
        )
    }

    // MARK: - タイトル

    private var createTitle: String {
        coordinator.createRequest?.kind == .note ? "新規ノート" : "新規フォルダ"
    }

    private var trashTitle: String {
        guard let target = coordinator.trashTarget else { return "" }
        return "「\(target.displayName)」をゴミ箱に移動しますか？"
    }

    // MARK: - 実行

    private func performCreate() {
        guard let request = coordinator.createRequest else { return }
        switch request.kind {
        case .folder:
            LibraryService.createFolder(named: coordinator.nameText, parent: request.parent, in: context)
        case .note:
            // ノートは作成後そのままタブで開く
            let note = LibraryService.createNote(titled: coordinator.nameText, folder: request.parent, in: context)
            session.open(note)
        }
        coordinator.createRequest = nil
    }

    private func performRename() {
        guard let target = coordinator.renameTarget else { return }
        LibraryService.rename(target, to: coordinator.nameText, in: context)
        coordinator.renameTarget = nil
    }

    private func performTrash() {
        guard let target = coordinator.trashTarget else { return }
        LibraryService.moveToTrash(target, in: context)
        // ゴミ箱行きになったノートが開いていたらタブも閉じる
        session.closeTrashedNotes()
        coordinator.trashTarget = nil
    }
}
