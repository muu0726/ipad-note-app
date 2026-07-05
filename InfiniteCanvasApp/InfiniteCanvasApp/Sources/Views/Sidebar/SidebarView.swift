import SwiftUI
import CoreData

struct SidebarView: View {
    @Binding var selection: SidebarSelection?
    @ObservedObject var actions: LibraryActionCoordinator
    @Environment(\.managedObjectContext) private var context
    @State private var isRootDropTargeted = false

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(key: "name", ascending: true,
                                           selector: #selector(NSString.localizedStandardCompare(_:)))],
        predicate: NSPredicate(format: "parent == nil AND isTrashed == NO"),
        animation: .default
    )
    private var rootFolders: FetchedResults<Folder>

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(key: "title", ascending: true,
                                           selector: #selector(NSString.localizedStandardCompare(_:)))],
        predicate: NSPredicate(format: "folder == nil AND isTrashed == NO"),
        animation: .default
    )
    private var rootNotes: FetchedResults<NoteFile>

    var body: some View {
        List(selection: $selection) {
            Section {
                // ここへドロップするとルート直下へ移動
                Label("すべてのノート", systemImage: "square.grid.2x2")
                    .tag(SidebarSelection.allNotes)
                    .dropDestination(for: LibraryItemTransfer.self) { items, _ in
                        handleLibraryDrop(items, into: nil, context: context)
                    } isTargeted: { isRootDropTargeted = $0 }
                    .accessibilityIdentifier("sidebar-all-notes")
                    .listRowBackground(
                        isRootDropTargeted ? Color.accentColor.opacity(0.18) : nil
                    )
            }
            Section("ライブラリ") {
                ForEach(rootFolders) { folder in
                    FolderTreeNode(folder: folder, selection: $selection, actions: actions)
                }
                ForEach(rootNotes) { note in
                    NoteRow(note: note, actions: actions)
                }
            }
            Section {
                Label("ゴミ箱", systemImage: "trash")
                    .tag(SidebarSelection.trash)
            }
        }
        .navigationTitle("ノート")
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 20) {
                Button {
                    actions.beginCreateFolder(in: currentFolder)
                } label: {
                    Label("フォルダ", systemImage: "folder.badge.plus")
                }
                Button {
                    actions.beginCreateNote(in: currentFolder)
                } label: {
                    Label("ノート", systemImage: "square.and.pencil")
                }
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }

    /// 新規作成先: サイドバーで選択中のフォルダ、なければルート
    private var currentFolder: Folder? {
        if case .folder(let folder) = selection { return folder }
        return nil
    }
}
