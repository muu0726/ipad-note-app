import SwiftUI
import CoreData
import PencilKit
import PhotosUI
import UniformTypeIdentifiers

/// ノートを開いたときのディテール領域。
/// 承認済みレイアウト: ナビバー → ペンツールバー(上) → タブバー(下) → キャンバス。
struct CanvasTabsView: View {
    @EnvironmentObject private var session: OpenNotesSession
    @Environment(\.managedObjectContext) private var context
    @StateObject private var toolState = PenToolState()
    @StateObject private var undoBridge = CanvasUndoBridge()
    @State private var isToolbarCollapsed = false

    // オブジェクト挿入(要件③): ピッカーで読み込んだデータをキャンバスへ渡す
    @State private var pendingInsertion: ObjectInsertion?
    @State private var isPhotoPickerPresented = false
    @State private var photoSelection: PhotosPickerItem?
    @State private var isPDFImporterPresented = false

    var body: some View {
        VStack(spacing: 0) {
            PenToolbarView(
                toolState: toolState,
                undoBridge: undoBridge,
                isCollapsed: $isToolbarCollapsed,
                onInsertText: { pendingInsertion = .text },
                onInsertImage: { isPhotoPickerPresented = true },
                onInsertPDF: { isPDFImporterPresented = true },
                onFontSizeChange: changeSelectedTextFontSize
            )
            Divider()
            NoteTabBar()
            canvasArea
        }
        .navigationTitle(session.selectedNote?.displayTitle ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .photosPicker(
            isPresented: $isPhotoPickerPresented,
            selection: $photoSelection,
            matching: .images
        )
        .onChange(of: photoSelection) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    pendingInsertion = .image(data)
                }
                photoSelection = nil
            }
        }
        .fileImporter(
            isPresented: $isPDFImporterPresented,
            allowedContentTypes: [.pdf]
        ) { result in
            guard case .success(let url) = result else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url) {
                pendingInsertion = .pdf(data)
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    session.showLibrary()
                } label: {
                    Label("書類", systemImage: "chevron.backward")
                        .labelStyle(.titleAndIcon)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                backgroundMenu
            }
        }
    }

    @ViewBuilder
    private var canvasArea: some View {
        if let note = session.selectedNote {
            NoteCanvasView(
                note: note,
                toolState: toolState,
                undoBridge: undoBridge,
                insertion: $pendingInsertion
            )
                // タブ切替時はビューを作り直す(ビューポートは session から復元される)
                .id(note.objectID)
        }
    }

    // MARK: - 背景テンプレート切替(要件④)

    private var backgroundMenu: some View {
        Menu {
            ForEach(CanvasBackgroundStyle.allCases, id: \.self) { style in
                Button {
                    setBackground(style)
                } label: {
                    if currentBackground == style {
                        Label(style.label, systemImage: "checkmark")
                    } else {
                        Text(style.label)
                    }
                }
            }
        } label: {
            Label("背景", systemImage: "squareshape.split.3x3")
        }
        .disabled(session.selectedNote == nil)
    }

    private var currentBackground: CanvasBackgroundStyle {
        CanvasBackgroundStyle(rawValue: session.selectedNote?.backgroundStyle ?? "") ?? .blank
    }

    private func setBackground(_ style: CanvasBackgroundStyle) {
        guard let note = session.selectedNote else { return }
        note.backgroundStyle = style.rawValue
        note.updatedAt = .now
        try? context.save()
    }

    /// 選択中テキストのフォントサイズを変更し、Core Data 保存 + Undo 登録する。
    /// 高さの自動調整はオブジェクトビューが検知して追従・保存する。
    private func changeSelectedTextFontSize(to newSize: CGFloat) {
        guard var selection = toolState.selectedTextObject,
              let object = (try? context.existingObject(with: selection.objectID)) as? CanvasObject,
              let uuid = object.id else { return }
        let clamped = min(max(newSize, PenToolState.fontSizeRange.lowerBound),
                          PenToolState.fontSizeRange.upperBound)
        guard abs(clamped - object.fontSize) > 0.01 else { return }

        CanvasObjectUndo.registerFontSizeChange(
            objectUUID: uuid, previousFontSize: object.fontSize,
            in: undoBridge.activeUndoManager, context: context, bridge: undoBridge
        )
        object.fontSize = clamped
        object.updatedAt = .now
        try? context.save()

        // ツールバー表示を即時更新
        selection.fontSize = clamped
        toolState.selectedTextObject = selection
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
        }
    }
}
