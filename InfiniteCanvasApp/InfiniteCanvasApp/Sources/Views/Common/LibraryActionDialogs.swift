import SwiftUI
import CoreData

extension View {
    /// 作成 / 名前変更 / 削除確認 / 移動シートをまとめて取り付ける
    func libraryActionDialogs(_ coordinator: LibraryActionCoordinator) -> some View {
        modifier(LibraryActionDialogs(coordinator: coordinator))
    }
}

struct LibraryActionDialogs: ViewModifier {
    @ObservedObject var coordinator: LibraryActionCoordinator
    @Environment(\.managedObjectContext) private var context
    @EnvironmentObject private var session: OpenNotesSession

    func body(content: Content) -> some View {
        content
            .alert("新規フォルダ", isPresented: isCreateFolderPresented) {
                TextField("名前", text: $coordinator.nameText)
                Button("作成") { performCreateFolder() }
                Button("キャンセル", role: .cancel) {}
            }
            // ノートは名前に加えて用紙の色(白 / 黒)を選ぶためシートで作成する
            .sheet(item: noteCreateRequest) { request in
                NoteCreateSheet(parent: request.parent)
                    .presentationDetents([.medium])
            }
            .alert("名前を変更", isPresented: isRenamePresented) {
                TextField("名前", text: $coordinator.nameText)
                Button("変更") { performRename() }
                Button("キャンセル", role: .cancel) {}
            }
            .confirmationDialog(trashTitle, isPresented: isTrashPresented, titleVisibility: .visible) {
                Button("ゴミ箱に移動", role: .destructive) { performTrash() }
                Button("キャンセル", role: .cancel) {}
            } message: {
                if coordinator.trashTarget?.isFolder == true {
                    Text("中のフォルダ・ノートもすべてゴミ箱に移動されます。")
                }
            }
            .sheet(item: $coordinator.moveTarget) { item in
                MoveDestinationPicker(item: item)
                    .presentationDetents([.medium, .large])
            }
    }

    // MARK: - 表示状態のバインディング

    private var isCreateFolderPresented: Binding<Bool> {
        Binding(
            get: { coordinator.createRequest?.kind == .folder },
            // createRequest はノート作成シートと共有している。自分(フォルダ)の提示が
            // 閉じたときだけクリアする。kind を確認しないと、ノート作成に切り替わった
            // 瞬間にこの set(false) がノートの createRequest まで消し、作成シートの
            // 表示を取りこぼす競合になる。
            set: { if !$0, coordinator.createRequest?.kind == .folder { coordinator.createRequest = nil } }
        )
    }

    private var noteCreateRequest: Binding<LibraryActionCoordinator.CreateRequest?> {
        Binding(
            get: { coordinator.createRequest?.kind == .note ? coordinator.createRequest : nil },
            // 同様に、自分(ノート)の提示が閉じたときだけクリアする(フォルダ作成を巻き込まない)。
            set: { if $0 == nil, coordinator.createRequest?.kind == .note { coordinator.createRequest = nil } }
        )
    }

    private var isRenamePresented: Binding<Bool> {
        Binding(
            get: { coordinator.renameTarget != nil },
            set: { if !$0 { coordinator.renameTarget = nil } }
        )
    }

    private var isTrashPresented: Binding<Bool> {
        Binding(
            get: { coordinator.trashTarget != nil },
            set: { if !$0 { coordinator.trashTarget = nil } }
        )
    }

    // MARK: - タイトル

    private var trashTitle: String {
        guard let target = coordinator.trashTarget else { return "" }
        return "「\(target.displayName)」をゴミ箱に移動しますか？"
    }

    // MARK: - 実行

    private func performCreateFolder() {
        guard let request = coordinator.createRequest, request.kind == .folder else { return }
        LibraryService.createFolder(named: coordinator.nameText, parent: request.parent, in: context)
        coordinator.createRequest = nil
    }

    private func performRename() {
        guard let target = coordinator.renameTarget else { return }
        LibraryService.rename(target, to: coordinator.nameText, in: context)
        coordinator.renameTarget = nil
    }

    private func performTrash() {
        guard let target = coordinator.trashTarget else { return }
        LibraryService.moveToTrash(target, in: context)
        // ゴミ箱行きになったノートが開いていたらタブも閉じる
        session.closeTrashedNotes()
        coordinator.trashTarget = nil
    }
}

/// 新規ノート作成シート。名前と用紙の色(白 / 黒)を選ぶ(自由ノート風)。
/// 白は黒い罫線・ドット、黒は白い罫線・ドットになる。
private struct NoteCreateSheet: View {
    let parent: Folder?
    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: OpenNotesSession
    @State private var name = ""
    @State private var pageColor: CanvasPageColor = .white
    @State private var noteType: CanvasNoteType = .infinite

    var body: some View {
        NavigationStack {
            Form {
                TextField("名前", text: $name)
                Section("ノートの種類") {
                    Picker("ノートの種類", selection: $noteType) {
                        ForEach(CanvasNoteType.allCases, id: \.self) { type in
                            Text(type.label)
                                .tag(type)
                                .accessibilityIdentifier("note-type-\(type.rawValue)")
                        }
                    }
                    .pickerStyle(.segmented)
                }
                Section("用紙の色") {
                    HStack(spacing: 20) {
                        ForEach(CanvasPageColor.allCases, id: \.self) { color in
                            pageColorSwatch(color)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("新規ノート")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("作成") {
                        // 作成後そのままタブで開く
                        let note = LibraryService.createNote(
                            titled: name,
                            folder: parent,
                            pageColor: pageColor,
                            noteType: noteType,
                            in: context
                        )
                        session.open(note)
                        dismiss()
                    }
                    .accessibilityIdentifier("dialog-create-button")
                }
            }
        }
    }

    private func pageColorSwatch(_ color: CanvasPageColor) -> some View {
        Button {
            pageColor = color
        } label: {
            VStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(uiColor: color.backgroundUIColor))
                    .frame(width: 64, height: 84)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8).strokeBorder(
                            pageColor == color ? Color.accentColor : Color(.separator),
                            lineWidth: pageColor == color ? 3 : 1
                        )
                    )
                Text(color.label)
                    .font(.caption)
                    .foregroundStyle(pageColor == color ? Color.accentColor : .secondary)
            }
        }
        .buttonStyle(.plain)
    }
}
