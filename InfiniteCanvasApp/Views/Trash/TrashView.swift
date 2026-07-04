import SwiftUI
import CoreData

/// ゴミ箱: トップレベルの削除済みアイテムを一覧し、復元 / 完全削除できる。
/// (フォルダごと削除された中身はフォルダ復元・削除に追従する)
struct TrashView: View {
    @Environment(\.managedObjectContext) private var context

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(key: "trashedAt", ascending: false)],
        predicate: NSPredicate(format: "isTrashed == YES AND (parent == nil OR parent.isTrashed == NO)"),
        animation: .default
    )
    private var folders: FetchedResults<Folder>

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(key: "trashedAt", ascending: false)],
        predicate: NSPredicate(format: "isTrashed == YES AND (folder == nil OR folder.isTrashed == NO)"),
        animation: .default
    )
    private var notes: FetchedResults<NoteFile>

    @State private var permanentDeleteTarget: LibraryItem?
    @State private var isConfirmingEmptyTrash = false

    var body: some View {
        Group {
            if folders.isEmpty && notes.isEmpty {
                ContentUnavailableView("ゴミ箱は空です", systemImage: "trash")
            } else {
                list
            }
        }
        .navigationTitle("ゴミ箱")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("ゴミ箱を空にする", role: .destructive) {
                    isConfirmingEmptyTrash = true
                }
                .disabled(folders.isEmpty && notes.isEmpty)
            }
        }
        .confirmationDialog(
            "ゴミ箱を空にしますか？",
            isPresented: $isConfirmingEmptyTrash,
            titleVisibility: .visible
        ) {
            Button("すべて完全に削除", role: .destructive) {
                LibraryService.emptyTrash(in: context)
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("この操作は取り消せません。")
        }
        .confirmationDialog(
            "「\(permanentDeleteTarget?.displayName ?? "")」を完全に削除しますか？",
            isPresented: Binding(
                get: { permanentDeleteTarget != nil },
                set: { if !$0 { permanentDeleteTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("完全に削除", role: .destructive) {
                if let target = permanentDeleteTarget {
                    LibraryService.deletePermanently(target, in: context)
                }
                permanentDeleteTarget = nil
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("この操作は取り消せません。")
        }
    }

    private var list: some View {
        List {
            ForEach(folders) { folder in
                TrashRow(
                    title: folder.displayName,
                    subtitle: "フォルダ(中身ごと)",
                    icon: "folder",
                    trashedAt: folder.trashedAt,
                    onRestore: { LibraryService.restore(.folder(folder), in: context) },
                    onDelete: { permanentDeleteTarget = .folder(folder) }
                )
            }
            ForEach(notes) { note in
                TrashRow(
                    title: note.displayTitle,
                    subtitle: "ノート",
                    icon: "doc.richtext",
                    trashedAt: note.trashedAt,
                    onRestore: { LibraryService.restore(.note(note), in: context) },
                    onDelete: { permanentDeleteTarget = .note(note) }
                )
            }
        }
    }
}

private struct TrashRow: View {
    let title: String
    let subtitle: String
    let icon: String
    let trashedAt: Date?
    let onRestore: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(subtitle + (trashedAt.map { " ・ " + $0.formatted(date: .abbreviated, time: .shortened) } ?? ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: icon)
            }
            Spacer()
            Button("復元", action: onRestore)
                .buttonStyle(.bordered)
        }
        .swipeActions(edge: .trailing) {
            Button("完全に削除", role: .destructive, action: onDelete)
        }
        .contextMenu {
            Button("復元", action: onRestore)
            Button("完全に削除", role: .destructive, action: onDelete)
        }
    }
}
