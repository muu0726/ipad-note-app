import SwiftUI
import CoreData

struct SidebarView: View {
    @Binding var selection: SidebarSelection?
    @ObservedObject var actions: LibraryActionCoordinator

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
                Label("すべてのノート", systemImage: "square.grid.2x2")
                    .tag(SidebarSelection.allNotes)
            }
            Section("ライブラリ") {
                ForEach(rootFolders) { folder in
                    FolderTreeNode(folder: folder, actions: actions)
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
