import SwiftUI

/// ノートを開いたときのディテール領域。
/// 承認済みレイアウト: ナビバー → ペンツールバー(上) → タブバー(下) → キャンバス。
struct CanvasTabsView: View {
    @EnvironmentObject private var session: OpenNotesSession

    var body: some View {
        VStack(spacing: 0) {
            PenToolbarPlaceholder()
            Divider()
            NoteTabBar()
            canvasArea
        }
        .navigationTitle(session.selectedNote?.displayTitle ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    session.showLibrary()
                } label: {
                    Label("書類", systemImage: "chevron.backward")
                        .labelStyle(.titleAndIcon)
                }
            }
        }
    }

    @ViewBuilder
    private var canvasArea: some View {
        if let note = session.selectedNote {
            ContentUnavailableView {
                Label("無限キャンバス", systemImage: "scribble.variable")
            } description: {
                Text("「\(note.displayTitle)」のキャンバスは ② 無限キャンバス機能で実装予定")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemBackground))
        }
    }
}

/// ③ で実装するカスタムペンツールバーのプレースホルダ(レイアウト確認用・操作不可)
struct PenToolbarPlaceholder: View {
    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "pencil.tip")
                Image(systemName: "highlighter")
                Image(systemName: "eraser")
            }
            Divider().frame(height: 20)
            HStack(spacing: 10) {
                Circle().frame(width: 6, height: 6)
                Circle().frame(width: 9, height: 9)
                Circle().frame(width: 12, height: 12)
            }
            Divider().frame(height: 20)
            HStack(spacing: 8) {
                Circle().fill(.red).frame(width: 16, height: 16)
                Circle().fill(.blue).frame(width: 16, height: 16)
                Circle().fill(.black).frame(width: 16, height: 16)
                Image(systemName: "plus.circle")
            }
            Spacer()
            Text("ツールバーは ③ で実装")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .font(.body)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .allowsHitTesting(false)
    }
}

/// キャンバス直上のタブバー(選択中タブはキャンバスと同色で一体化)
struct NoteTabBar: View {
    @EnvironmentObject private var session: OpenNotesSession

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    ForEach(session.openNotes) { note in
                        NoteTabChip(
                            note: note,
                            isSelected: note == session.selectedNote,
                            onSelect: { session.selectedNote = note },
                            onClose: { session.close(note) }
                        )
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 6)
            }
            // ライブラリから別のノートを選んで開く
            Button {
                session.showLibrary()
            } label: {
                Image(systemName: "plus")
                    .padding(10)
            }
        }
        .background(Color(.secondarySystemBackground))
    }
}

private struct NoteTabChip: View {
    @ObservedObject var note: NoteFile
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.richtext")
                .font(.caption)
            Text(note.displayTitle)
                .font(.callout)
                .lineLimit(1)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minWidth: 90, maxWidth: 200)
        .background(
            isSelected ? Color(.systemBackground) : Color(.tertiarySystemBackground),
            in: UnevenRoundedRectangle(cornerRadii: .init(topLeading: 8, topTrailing: 8))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .contextMenu {
            Button("このタブを閉じる", action: onClose)
            Button("ライブラリで表示") {
                // TODO: サイドバー選択との連携は後続フェーズで実装
            }
            .disabled(true)
        }
    }
}
