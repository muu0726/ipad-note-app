import SwiftUI
import CoreData

/// しおり(ブックマーク)と目次(アウトライン)の一覧。項目タップで該当ページへジャンプする。
/// 通常ノートのツールバーからポップオーバーで開く。
struct PageNavigatorView: View {
    @ObservedObject var note: NoteFile
    let currentPage: Int
    let onJump: (Int) -> Void

    @Environment(\.managedObjectContext) private var context
    @FetchRequest private var outlines: FetchedResults<NoteOutline>
    @State private var newOutlineTitle = ""

    init(note: NoteFile, currentPage: Int, onJump: @escaping (Int) -> Void) {
        _note = ObservedObject(wrappedValue: note)
        self.currentPage = currentPage
        self.onJump = onJump
        _outlines = FetchRequest(
            entity: NoteOutline.entity(),
            sortDescriptors: [
                NSSortDescriptor(keyPath: \NoteOutline.pageIndex, ascending: true),
                NSSortDescriptor(keyPath: \NoteOutline.createdAt, ascending: true),
            ],
            predicate: NSPredicate(format: "note == %@", note)
        )
    }

    var body: some View {
        NavigationStack {
            List {
                Section("しおり") {
                    let bookmarks = note.bookmarkedPageList
                    if bookmarks.isEmpty {
                        Text("しおりはありません")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(bookmarks, id: \.self) { page in
                            Button {
                                onJump(page)
                            } label: {
                                Label("ページ \(page + 1)", systemImage: "bookmark.fill")
                            }
                            .accessibilityIdentifier("bookmark-row-\(page)")
                        }
                    }
                }

                Section("目次") {
                    HStack {
                        TextField("現在のページ(\(currentPage + 1))のタイトル", text: $newOutlineTitle)
                            .accessibilityIdentifier("outline-title-field")
                        Button {
                            addOutline()
                        } label: {
                            Image(systemName: "plus.circle.fill")
                        }
                        .accessibilityIdentifier("outline-add-confirm")
                    }

                    ForEach(outlines) { outline in
                        Button {
                            onJump(Int(outline.pageIndex))
                        } label: {
                            HStack {
                                Text(outline.title ?? "(無題)")
                                Spacer()
                                Text("p.\(Int(outline.pageIndex) + 1)")
                                    .foregroundStyle(.secondary)
                                    .font(.subheadline)
                            }
                        }
                        .accessibilityIdentifier("outline-row-\(Int(outline.pageIndex))")
                    }
                    .onDelete(perform: deleteOutlines)
                }
            }
            .navigationTitle("ナビゲーション")
            .navigationBarTitleDisplayMode(.inline)
        }
        .frame(minWidth: 320, minHeight: 420)
    }

    /// 現在ページを目次へ追加する(タイトル未入力なら「ページ N」)
    private func addOutline() {
        let trimmed = newOutlineTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let outline = NoteOutline(context: context)
        outline.id = UUID()
        outline.title = trimmed.isEmpty ? "ページ \(currentPage + 1)" : trimmed
        outline.pageIndex = Int16(currentPage)
        outline.createdAt = .now
        outline.note = note
        note.updatedAt = .now
        do {
            try context.save()
            newOutlineTitle = ""
        } catch {
            assertionFailure("目次の保存に失敗: \(error)")
        }
    }

    private func deleteOutlines(_ offsets: IndexSet) {
        for index in offsets { context.delete(outlines[index]) }
        do {
            try context.save()
        } catch {
            assertionFailure("目次の削除に失敗: \(error)")
        }
    }
}
