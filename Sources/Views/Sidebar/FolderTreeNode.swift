import SwiftUI
import CoreData

/// サイドバーの再帰的なフォルダツリーノード。
/// 子フォルダ・子ノートは Core Data リレーションから取得し、
/// @ObservedObject 経由で変更が自動反映される。
struct FolderTreeNode: View {
    @ObservedObject var folder: Folder
    @ObservedObject var actions: LibraryActionCoordinator
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(folder.visibleChildFolders) { child in
                FolderTreeNode(folder: child, actions: actions)
            }
            ForEach(folder.visibleNotes) { note in
                NoteRow(note: note, actions: actions)
            }
        } label: {
            Label(folder.displayName, systemImage: "folder")
                .tag(SidebarSelection.folder(folder))
                .contextMenu {
                    ItemContextMenu(item: .folder(folder), actions: actions)
                }
        }
    }
}
