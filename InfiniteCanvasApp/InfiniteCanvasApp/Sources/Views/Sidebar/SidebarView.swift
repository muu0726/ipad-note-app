import SwiftUI
import CoreData

struct SidebarView: View {
    @Binding var selection: SidebarSelection?
    @ObservedObject var actions: LibraryActionCoordinator
    @Environment(\.managedObjectContext) private var context
    @EnvironmentObject private var session: OpenNotesSession
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
                Label("グラフビュー", systemImage: "point.3.connected.trianglepath.dotted")
                    .tag(SidebarSelection.graph)
                    .accessibilityIdentifier("sidebar-graph")
                Label("ゴミ箱", systemImage: "trash")
                    .tag(SidebarSelection.trash)
            }
        }
        .navigationTitle("Sproutnote ver25.0 (Auto Tab Cleanup Engine)")
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                // 作成先を明示(IDE のように「今どこに作るか」が分かるように)
                Label("作成先: \(currentFolderName)", systemImage: "arrow.down.right.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityIdentifier("sidebar-create-target")
                HStack(spacing: 20) {
                    Button {
                        actions.beginCreateFolder(in: currentFolder)
                    } label: {
                        Label("フォルダ", systemImage: "folder.badge.plus")
                    }
                    .accessibilityIdentifier("sidebar-create-folder")
                    Button {
                        actions.beginCreateNote(in: currentFolder)
                    } label: {
                        Label("ノート", systemImage: "square.and.pencil")
                    }
                    .accessibilityIdentifier("sidebar-create-note")
                    Button {
                        actions.beginImportPDF(in: currentFolder)
                    } label: {
                        Label("PDF", systemImage: "doc.badge.plus")
                    }
                    .accessibilityIdentifier("sidebar-import-pdf")
                    Spacer()
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }

    /// 新規作成先のフォルダ。
    /// 作業中(ノートを開いてキャンバス表示中)は、その作業ファイルのフォルダに作る。
    /// それ以外はサイドバーで選択中(またはドロップダウンを開いた)のフォルダ、なければルート。
    private var currentFolder: Folder? {
        if session.isCanvasVisible, let note = session.selectedNote,
           !note.isDeleted, !note.isTrashed {
            return note.folder
        }
        if case .folder(let folder) = selection { return folder }
        return nil
    }

    /// 作成先の表示名(ルートは「すべてのノート」)
    private var currentFolderName: String {
        currentFolder?.displayName ?? "すべてのノート"
    }
}
