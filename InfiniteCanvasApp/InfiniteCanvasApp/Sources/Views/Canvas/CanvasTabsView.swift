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
    // 分割時は左右それぞれ独立した Undo 履歴を持つ(互いに干渉しない)
    @StateObject private var leftUndoBridge = CanvasUndoBridge()
    @StateObject private var rightUndoBridge = CanvasUndoBridge()
    @State private var leftInsertion: ObjectInsertion?
    @State private var rightInsertion: ObjectInsertion?
    @State private var isToolbarCollapsed = false

    // オブジェクト挿入(要件③): ピッカーで読み込んだデータをキャンバスへ渡す
    @State private var pendingInsertion: ObjectInsertion?
    @State private var isPhotoPickerPresented = false
    @State private var photoSelection: PhotosPickerItem?
    @State private var isPDFImporterPresented = false
    // PDF 取り込み方法の選択(オブジェクト挿入 / 新規ノート背景)
    @State private var pendingPDFData: Data?
    @State private var showPDFImportChoice = false
    // ノートリンク挿入時のリンク先選択シート
    @State private var showNoteLinkPicker = false

    var body: some View {
        VStack(spacing: 0) {
            PenToolbarView(
                toolState: toolState,
                undoBridge: activeUndoBridge,
                isCollapsed: $isToolbarCollapsed,
                onInsertText: { setActiveInsertion(.text) },
                onInsertImage: { isPhotoPickerPresented = true },
                onInsertPDF: { isPDFImporterPresented = true },
                onInsertNoteLink: { showNoteLinkPicker = true },
                onInsertTodo: { setActiveInsertion(.todo) },
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
                    setActiveInsertion(.image(data))
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
                // 取り込み方法(オブジェクト挿入 / 新規ノート背景)を選ばせる
                pendingPDFData = data
                showPDFImportChoice = true
            }
        }
        .sheet(isPresented: $showNoteLinkPicker) {
            NoteLinkPickerView(excludingNoteID: session.selectedNote?.objectID) { selected in
                if let uuid = selected.id { setActiveInsertion(.noteLink(uuid)) }
                showNoteLinkPicker = false
            }
        }
        .confirmationDialog("PDF の取り込み方法", isPresented: $showPDFImportChoice, titleVisibility: .visible) {
            Button("オブジェクトとして挿入") {
                if let data = pendingPDFData { setActiveInsertion(.pdf(data)) }
                pendingPDFData = nil
            }
            Button("新規ノートとして背景インポート") {
                importPDFAsPagedNote()
            }
            Button("キャンセル", role: .cancel) { pendingPDFData = nil }
        } message: {
            Text("各ページを全画面の背景に展開して、その上に手書きできます。")
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
        if session.isSplitActive,
           let left = resolveNote(session.leftNoteID),
           let right = resolveNote(session.rightNoteID) {
            splitCanvas(left: left, right: right)
        } else if let note = session.selectedNote {
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

    // MARK: - アプリ内スプリットビュー(2画面分割)

    /// 左右2つの NoteCanvasView をドラッグ可能な間仕切りで並べる。
    /// 左右は別々の NoteFile・Undo 履歴・挿入先を持ち、独立して編集できる。
    private func splitCanvas(left: NoteFile, right: NoteFile) -> some View {
        GeometryReader { geo in
            let handleWidth: CGFloat = 12
            let available = max(0, geo.size.width - handleWidth)
            let leftWidth = available * session.splitDividerRatio
            HStack(spacing: 0) {
                splitPane(note: left, side: .left,
                          bridge: leftUndoBridge, insertion: $leftInsertion)
                    .frame(width: leftWidth)
                SplitDividerHandle(
                    ratio: $session.splitDividerRatio,
                    totalWidth: geo.size.width,
                    handleWidth: handleWidth
                )
                splitPane(note: right, side: .right,
                          bridge: rightUndoBridge, insertion: $rightInsertion)
                    .frame(width: max(0, available - leftWidth))
            }
        }
    }

    /// 分割の片側。アクティブ側は上端にアクセントバーを出し、タップでアクティブ切替。
    private func splitPane(
        note: NoteFile, side: SplitSide,
        bridge: CanvasUndoBridge, insertion: Binding<ObjectInsertion?>
    ) -> some View {
        let isActive = session.activeSide == side
        return NoteCanvasView(
            note: note,
            toolState: toolState,
            undoBridge: bridge,
            insertion: insertion,
            onActivate: { activate(side) }
        )
        .id(note.objectID)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.accentColor)
                .frame(height: 3)
                .opacity(isActive ? 1 : 0)
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        // タップした側をアクティブに(描画・オブジェクト編集は onActivate 側で拾う)
        .simultaneousGesture(TapGesture().onEnded { activate(side) })
        .accessibilityIdentifier(side == .left ? "split-pane-left" : "split-pane-right")
    }

    /// 指定側をアクティブにする(選択テキスト情報は持ち越さない)。
    private func activate(_ side: SplitSide) {
        guard session.isSplitActive else { return }
        if session.activeSide != side {
            toolState.selectedTextObject = nil
        }
        session.activateSide(side)
    }

    /// ツールバーが作用する Undo 履歴(分割時はアクティブ側)
    private var activeUndoBridge: CanvasUndoBridge {
        guard session.isSplitActive else { return undoBridge }
        return session.activeSide == .left ? leftUndoBridge : rightUndoBridge
    }

    /// オブジェクト挿入をアクティブ側のキャンバスへ振り分ける
    private func setActiveInsertion(_ insertion: ObjectInsertion?) {
        guard session.isSplitActive else { pendingInsertion = insertion; return }
        if session.activeSide == .left { leftInsertion = insertion }
        else { rightInsertion = insertion }
    }

    /// objectID から開いているノートを引く(分割の左右ノート解決に使う)
    private func resolveNote(_ id: NSManagedObjectID?) -> NoteFile? {
        guard let id else { return nil }
        if let note = session.openNotes.first(where: { $0.objectID == id }) { return note }
        return (try? context.existingObject(with: id)) as? NoteFile
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

    /// PDF の全ページを背景に展開した新規通常ノートを作成して開く。
    private func importPDFAsPagedNote() {
        defer { pendingPDFData = nil }
        guard let data = pendingPDFData,
              let note = LibraryService.createPagedNoteFromPDF(
                  data: data, titled: "", folder: nil, in: context
              )
        else { return }
        session.open(note)  // タブで開く(通常ノートとして全ページ縦並び)
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

        let bridge = activeUndoBridge
        CanvasObjectUndo.registerFontSizeChange(
            objectUUID: uuid, previousFontSize: object.fontSize,
            in: bridge.activeUndoManager, context: context, bridge: bridge
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
                            isSplitActive: session.isSplitActive,
                            onSelect: { session.open(note) },
                            onClose: { session.close(note) },
                            onOpenRight: { session.openRight(note) },
                            onCloseSplit: { session.closeSplit(keeping: note) }
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

/// ノートリンク挿入時に、リンク先のノートを一覧から選ぶシート。
/// ゴミ箱以外の全ノートを表示し、現在のノートは除外する。
struct NoteLinkPickerView: View {
    let excludingNoteID: NSManagedObjectID?
    let onSelect: (NoteFile) -> Void
    @Environment(\.dismiss) private var dismiss

    @FetchRequest(
        entity: NoteFile.entity(),
        sortDescriptors: [NSSortDescriptor(keyPath: \NoteFile.updatedAt, ascending: false)],
        predicate: NSPredicate(format: "isTrashed == NO")
    ) private var notes: FetchedResults<NoteFile>

    private var selectableNotes: [NoteFile] {
        notes.filter { $0.objectID != excludingNoteID }
    }

    var body: some View {
        NavigationStack {
            Group {
                if selectableNotes.isEmpty {
                    ContentUnavailableView("他のノートがありません", systemImage: "doc")
                } else {
                    List(selectableNotes, id: \.objectID) { note in
                        Button { onSelect(note) } label: {
                            Label(note.displayTitle, systemImage: "doc.text")
                                .foregroundStyle(.primary)
                        }
                        .accessibilityIdentifier("notelink-pick-\(note.displayTitle)")
                    }
                }
            }
            .navigationTitle("リンク先のノート")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
            }
        }
    }
}

private struct NoteTabChip: View {
    @ObservedObject var note: NoteFile
    let isSelected: Bool
    let isSplitActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onOpenRight: () -> Void
    let onCloseSplit: () -> Void

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
        .accessibilityIdentifier("note-tab-\(note.displayTitle)")
        .contextMenu {
            Button {
                onOpenRight()
            } label: {
                Label("右側で開く", systemImage: "rectangle.righthalf.inset.filled")
            }
            if isSplitActive {
                Button {
                    onCloseSplit()
                } label: {
                    Label("分割を解除", systemImage: "rectangle")
                }
            }
            Divider()
            Button("このタブを閉じる", action: onClose)
        }
    }
}

/// 分割の間仕切り。左右ドラッグで比率を 0.2〜0.8 に変える。
private struct SplitDividerHandle: View {
    @Binding var ratio: CGFloat
    let totalWidth: CGFloat
    let handleWidth: CGFloat
    /// ドラッグ開始時点の比率(移動量の二重加算を防ぐ)
    @State private var startRatio: CGFloat?

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color(.secondarySystemBackground))
            Capsule()
                .fill(Color(.separator))
                .frame(width: 3, height: 40)
        }
        .frame(width: handleWidth)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(
            DragGesture()
                .onChanged { value in
                    let usable = totalWidth - handleWidth
                    guard usable > 0 else { return }
                    let base = startRatio ?? ratio
                    if startRatio == nil { startRatio = ratio }
                    ratio = min(0.8, max(0.2, base + value.translation.width / usable))
                }
                .onEnded { _ in startRatio = nil }
        )
        .accessibilityIdentifier("split-divider")
    }
}
