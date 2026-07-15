import SwiftUI
import CoreData

/// サイドバーの再帰的なフォルダツリーノード。
/// 子フォルダ・子ノートは Core Data リレーションから取得し、
/// @ObservedObject 経由で変更が自動反映される。
struct FolderTreeNode: View {
    @ObservedObject var folder: Folder
    @Binding var selection: SidebarSelection?
    @ObservedObject var actions: LibraryActionCoordinator
    @Environment(\.managedObjectContext) private var context
    @State private var isExpanded = false
    @State private var isDropTargeted = false

    private var isSelected: Bool { selection == .folder(folder) }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(folder.visibleChildFolders) { child in
                FolderTreeNode(folder: child, selection: $selection, actions: actions)
            }
            ForEach(folder.visibleNotes) { note in
                NoteRow(note: note, actions: actions)
            }
        } label: {
            // DisclosureGroup のラベルでは List(selection:) の .tag が効かないため、
            // Button で選択を直接セットする(ここで選んだフォルダが新規作成先になる)
            Button {
                selection = .folder(folder)
            } label: {
                Label(folder.displayName, systemImage: isSelected ? "folder.fill" : "folder")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            }
            .buttonStyle(.plain)
            .contextMenu {
                ItemContextMenu(item: .folder(folder), actions: actions)
            }
            .draggable(LibraryItemTransfer(item: .folder(folder)))
            .dropDestination(for: LibraryItemTransfer.self) { items, _ in
                let moved = handleLibraryDrop(items, into: folder, context: context)
                if moved { isExpanded = true }  // ドロップ先を開いて結果を見せる
                return moved
            } isTargeted: { isDropTargeted = $0 }
            .accessibilityIdentifier("sidebar-folder-\(folder.displayName)")
            .listRowBackground(
                isDropTargeted ? Color.accentColor.opacity(0.18) : nil
            )
        }
        // ドロップダウンを開いたら、そのフォルダを作成先(選択)にする
        // (IDE のように「開いているフォルダ」の中に新規作成される)
        .onChange(of: isExpanded) { _, expanded in
            if expanded { selection = .folder(folder) }
        }
    }
}
