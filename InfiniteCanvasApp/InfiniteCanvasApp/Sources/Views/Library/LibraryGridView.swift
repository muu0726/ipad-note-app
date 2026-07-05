import SwiftUI
import CoreData

/// ディテール領域: 選択中フォルダの中身(サブフォルダ + ノート)のグリッド表示。
/// folder == nil のときは「すべてのノート」(フォルダ横断でノートのみ)。
struct LibraryGridView: View {
    let folder: Folder?
    @ObservedObject var actions: LibraryActionCoordinator
    let onOpenFolder: (Folder) -> Void

    @EnvironmentObject private var session: OpenNotesSession

    @FetchRequest private var folders: FetchedResults<Folder>
    @FetchRequest private var notes: FetchedResults<NoteFile>

    init(folder: Folder?, actions: LibraryActionCoordinator, onOpenFolder: @escaping (Folder) -> Void) {
        self.folder = folder
        self.actions = actions
        self.onOpenFolder = onOpenFolder

        let nameSort = [NSSortDescriptor(key: "name", ascending: true,
                                         selector: #selector(NSString.localizedStandardCompare(_:)))]
        let titleSort = [NSSortDescriptor(key: "title", ascending: true,
                                          selector: #selector(NSString.localizedStandardCompare(_:)))]
        if let folder {
            _folders = FetchRequest(
                sortDescriptors: nameSort,
                predicate: NSPredicate(format: "parent == %@ AND isTrashed == NO", folder),
                animation: .default)
            _notes = FetchRequest(
                sortDescriptors: titleSort,
                predicate: NSPredicate(format: "folder == %@ AND isTrashed == NO", folder),
                animation: .default)
        } else {
            // すべてのノート: フォルダは表示しない
            _folders = FetchRequest(sortDescriptors: nameSort, predicate: NSPredicate(value: false))
            _notes = FetchRequest(
                sortDescriptors: titleSort,
                predicate: NSPredicate(format: "isTrashed == NO"),
                animation: .default)
        }
    }

    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 24)]

    var body: some View {
        Group {
            if let folder, folder.isDeleted || folder.isTrashed {
                ContentUnavailableView("このフォルダは削除されました", systemImage: "folder.badge.questionmark")
            } else if folders.isEmpty && notes.isEmpty {
                emptyState
            } else {
                grid
            }
        }
        .navigationTitle(folder?.displayName ?? "すべてのノート")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        actions.beginCreateNote(in: folder)
                    } label: {
                        Label("新規ノート", systemImage: "square.and.pencil")
                    }
                    Button {
                        actions.beginCreateFolder(in: folder)
                    } label: {
                        Label("新規フォルダ", systemImage: "folder.badge.plus")
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            openNotesPill
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 24) {
                ForEach(folders) { subfolder in
                    FolderCell(folder: subfolder, actions: actions) {
                        onOpenFolder(subfolder)
                    }
                }
                ForEach(notes) { note in
                    NoteCell(note: note, actions: actions) {
                        session.open(note)
                    }
                }
                AddNoteTile {
                    actions.beginCreateNote(in: folder)
                }
            }
            .padding(24)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("ノートがありません", systemImage: "square.grid.2x2")
        } description: {
            Text("右上の ＋ から新規ノート・フォルダを作成できます")
        } actions: {
            Button("新規ノート") {
                actions.beginCreateNote(in: folder)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    /// タブを維持したままライブラリに戻っているとき、キャンバスへ復帰するピル
    @ViewBuilder
    private var openNotesPill: some View {
        if !session.openNotes.isEmpty {
            Button {
                session.returnToCanvas()
            } label: {
                Label("開いているノート(\(session.openNotes.count))", systemImage: "rectangle.stack")
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.thinMaterial, in: Capsule())
            }
            .padding(.bottom, 8)
        }
    }
}
