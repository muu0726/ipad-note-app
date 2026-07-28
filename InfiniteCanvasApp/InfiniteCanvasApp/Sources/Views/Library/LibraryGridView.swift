import SwiftUI
import CoreData

/// ディテール領域: 選択中フォルダの中身(サブフォルダ + ノート)のグリッド表示。
/// folder == nil のときは「すべてのノート」(フォルダ横断でノートのみ)。
struct LibraryGridView: View {
    let folder: Folder?
    @ObservedObject var actions: LibraryActionCoordinator
    let onOpenFolder: (Folder) -> Void

    @EnvironmentObject private var session: OpenNotesSession
    @Environment(\.managedObjectContext) private var context

    @FetchRequest private var folders: FetchedResults<Folder>
    @FetchRequest private var notes: FetchedResults<NoteFile>

    @State private var isSelectMode = false
    @State private var selectedFolderIDs: Set<NSManagedObjectID> = []
    @State private var selectedNoteIDs: Set<NSManagedObjectID> = []
    @State private var showBulkDeleteConfirm = false

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
            _folders = FetchRequest(
                sortDescriptors: nameSort,
                predicate: NSPredicate(format: "parent == nil AND isTrashed == NO"),
                animation: .default)
            _notes = FetchRequest(
                sortDescriptors: titleSort,
                predicate: NSPredicate(format: "folder == nil AND isTrashed == NO"),
                animation: .default)
        }
    }

    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 24)]

    private var selectedCount: Int {
        selectedFolderIDs.count + selectedNoteIDs.count
    }

    private var totalSelectableCount: Int {
        folders.count + notes.count
    }

    private var isAllSelected: Bool {
        totalSelectableCount > 0 && selectedCount == totalSelectableCount
    }

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
        .navigationTitle(
            isSelectMode ? (selectedCount > 0 ? "\(selectedCount) 件を選択中" : "項目を選択") : (folder?.displayName ?? "すべてのノート")
        )
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(isSelectMode ? "完了" : "選択") {
                    withAnimation {
                        isSelectMode.toggle()
                        if !isSelectMode {
                            clearSelection()
                        }
                    }
                }
                .bold(isSelectMode)
                .accessibilityIdentifier("library-select-toggle")
            }

            if isSelectMode {
                ToolbarItem(placement: .primaryAction) {
                    Button(isAllSelected ? "選択解除" : "全選択") {
                        if isAllSelected {
                            clearSelection()
                        } else {
                            selectAll()
                        }
                    }
                }
            }

            if !isSelectMode {
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
                    .accessibilityIdentifier("library-add-menu")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if isSelectMode, selectedCount > 0 {
                    bulkActionBar
                }
                openNotesPill
            }
        }
        .alert("選択した \(selectedCount) 件の項目を削除しますか？", isPresented: $showBulkDeleteConfirm) {
            Button("ゴミ箱へ移動", role: .destructive) {
                performBulkDelete()
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("削除されたノートおよびフォルダはゴミ箱へ移動し、後から復元できます。")
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 24) {
                ForEach(folders) { subfolder in
                    FolderCell(
                        folder: subfolder,
                        actions: actions,
                        isSelectMode: isSelectMode,
                        isSelected: selectedFolderIDs.contains(subfolder.objectID)
                    ) {
                        if isSelectMode {
                            toggleFolderSelection(subfolder.objectID)
                        } else {
                            onOpenFolder(subfolder)
                        }
                    }
                }
                ForEach(notes) { note in
                    NoteCell(
                        note: note,
                        actions: actions,
                        isSelectMode: isSelectMode,
                        isSelected: selectedNoteIDs.contains(note.objectID)
                    ) {
                        if isSelectMode {
                            toggleNoteSelection(note.objectID)
                        } else {
                            session.open(note)
                        }
                    }
                }
                if !isSelectMode {
                    AddNoteTile {
                        actions.beginCreateNote(in: folder)
                    }
                    AddPDFTile {
                        actions.beginImportPDF(in: folder)
                    }
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

    private var bulkActionBar: some View {
        HStack(spacing: 16) {
            Button(role: .destructive) {
                showBulkDeleteConfirm = true
            } label: {
                Label("選択項目を削除 (\(selectedCount))", systemImage: "trash")
                    .font(.callout.weight(.bold))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Color.red.opacity(0.15), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.red.opacity(0.4), lineWidth: 1))
            }

            Button {
                clearSelection()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 4)
        .transition(.move(edge: .bottom).combined(with: .opacity))
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

    // MARK: - 一括選択ロジック

    private func toggleFolderSelection(_ id: NSManagedObjectID) {
        if selectedFolderIDs.contains(id) {
            selectedFolderIDs.remove(id)
        } else {
            selectedFolderIDs.insert(id)
        }
    }

    private func toggleNoteSelection(_ id: NSManagedObjectID) {
        if selectedNoteIDs.contains(id) {
            selectedNoteIDs.remove(id)
        } else {
            selectedNoteIDs.insert(id)
        }
    }

    private func selectAll() {
        selectedFolderIDs = Set(folders.map { $0.objectID })
        selectedNoteIDs = Set(notes.map { $0.objectID })
    }

    private func clearSelection() {
        selectedFolderIDs.removeAll()
        selectedNoteIDs.removeAll()
    }

    private func performBulkDelete() {
        let targetFolders = folders.filter { selectedFolderIDs.contains($0.objectID) }
        let targetNotes = notes.filter { selectedNoteIDs.contains($0.objectID) }
        LibraryService.bulkMoveToTrash(folders: Array(targetFolders), notes: Array(targetNotes), in: context)
        session.closeTrashedNotes()
        withAnimation {
            clearSelection()
            isSelectMode = false
        }
    }
}
