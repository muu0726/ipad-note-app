import SwiftUI
import CoreData

/// 「移動…」で表示する移動先フォルダ選択シート。
/// 移動対象フォルダ自身とその子孫は循環参照になるため表示しない。
struct MoveDestinationPicker: View {
    let item: LibraryItem
    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(key: "name", ascending: true,
                                           selector: #selector(NSString.localizedStandardCompare(_:)))],
        predicate: NSPredicate(format: "parent == nil AND isTrashed == NO"),
        animation: .default
    )
    private var rootFolders: FetchedResults<Folder>

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        move(to: nil)
                    } label: {
                        Label("トップ階層(ルート)", systemImage: "tray")
                    }
                }
                Section("フォルダ") {
                    ForEach(rootFolders) { folder in
                        FolderPickerRows(folder: folder, depth: 0, item: item, onSelect: move(to:))
                    }
                }
            }
            .navigationTitle("「\(item.displayName)」の移動先")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
            }
        }
    }

    private func move(to destination: Folder?) {
        LibraryService.move(item, to: destination, in: context)
        dismiss()
    }
}

/// インデント付きの再帰フォルダ行
private struct FolderPickerRows: View {
    @ObservedObject var folder: Folder
    let depth: Int
    let item: LibraryItem
    let onSelect: (Folder) -> Void

    /// 移動対象フォルダ自身(子孫は表示自体を打ち切る)
    private var isMovingItem: Bool {
        if case .folder(let moving) = item { return folder == moving }
        return false
    }

    var body: some View {
        if !isMovingItem {
            Button {
                onSelect(folder)
            } label: {
                Label(folder.displayName, systemImage: "folder")
                    .padding(.leading, CGFloat(depth) * 24)
            }
            ForEach(folder.visibleChildFolders) { child in
                FolderPickerRows(folder: child, depth: depth + 1, item: item, onSelect: onSelect)
            }
        }
    }
}
