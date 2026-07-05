import Foundation
import Combine
import CoreData

/// 開いているノート(タブ)の状態を管理するセッションオブジェクト。
/// タブの並び・選択中タブ・キャンバス表示状態を保持し、UserDefaults に永続化する。
final class OpenNotesSession: ObservableObject {
    @Published private(set) var openNotes: [NoteFile] = []
    @Published var selectedNote: NoteFile? {
        didSet { persistState() }
    }
    /// true のときディテール領域にキャンバス(タブ)を表示する
    @Published var isCanvasVisible = false {
        didSet { persistState() }
    }
    /// タブごとのビューポート(スクロール位置・ズーム)。
    /// 描画のたびに更新されるため @Published にはしない(再描画ループ防止)
    var viewports: [NSManagedObjectID: CanvasViewport] = [:]

    // MARK: - タブ操作

    /// ノートをタブで開く。既に開いていればそのタブへ切り替える(重複タブは作らない)
    func open(_ note: NoteFile) {
        if !openNotes.contains(note) {
            openNotes.append(note)
        }
        selectedNote = note
        isCanvasVisible = true
        persistState()
    }

    func close(_ note: NoteFile) {
        guard let index = openNotes.firstIndex(of: note) else { return }
        openNotes.remove(at: index)
        if selectedNote == note {
            // 閉じたタブの右隣(なければ末尾)を選択
            selectedNote = openNotes.indices.contains(index) ? openNotes[index] : openNotes.last
        }
        if openNotes.isEmpty {
            isCanvasVisible = false
        }
        persistState()
    }

    /// ゴミ箱行き・削除されたノートのタブを閉じる
    func closeTrashedNotes() {
        for note in openNotes.filter({ $0.isTrashed || $0.isDeleted }) {
            close(note)
        }
    }

    /// タブを維持したままライブラリへ戻る
    func showLibrary() {
        isCanvasVisible = false
    }

    /// ライブラリから最後に開いていたタブへ復帰
    func returnToCanvas() {
        if selectedNote != nil {
            isCanvasVisible = true
        }
    }

    // MARK: - 永続化(アプリ再起動後のタブ復元)

    private enum DefaultsKey {
        static let openNoteURIs = "session.openNoteURIs"
        static let selectedNoteURI = "session.selectedNoteURI"
        static let isCanvasVisible = "session.isCanvasVisible"
    }

    /// 復元前に persistState が走って保存済みデータを消さないようにするフラグ
    private var isRestored = false

    /// 起動時に前回のタブ状態を復元する(RootView.onAppear から一度だけ呼ぶ)
    func restore(in context: NSManagedObjectContext) {
        guard !isRestored else { return }
        isRestored = true

        let defaults = UserDefaults.standard
        guard let uris = defaults.stringArray(forKey: DefaultsKey.openNoteURIs),
              !uris.isEmpty else { return }

        // selectedNote の didSet → persistState が保存値を上書きする前に全て読み切る
        let selectedURI = defaults.string(forKey: DefaultsKey.selectedNoteURI)
        let wasCanvasVisible = defaults.bool(forKey: DefaultsKey.isCanvasVisible)

        let notes = uris.compactMap { note(forURI: $0, in: context) }
        guard !notes.isEmpty else { return }

        openNotes = notes
        if let selectedURI, let selected = note(forURI: selectedURI, in: context) {
            selectedNote = selected
        } else {
            selectedNote = notes.last
        }
        isCanvasVisible = wasCanvasVisible && selectedNote != nil
    }

    /// URI 表現からノートを引き当てる(削除済み・ゴミ箱内は復元しない)
    private func note(forURI uri: String, in context: NSManagedObjectContext) -> NoteFile? {
        guard let url = URL(string: uri),
              let coordinator = context.persistentStoreCoordinator,
              let objectID = coordinator.managedObjectID(forURIRepresentation: url),
              let note = (try? context.existingObject(with: objectID)) as? NoteFile,
              !note.isTrashed, !note.isDeleted else { return nil }
        return note
    }

    private func persistState() {
        guard isRestored else { return }
        let defaults = UserDefaults.standard
        let uris = openNotes
            .filter { !$0.objectID.isTemporaryID }
            .map { $0.objectID.uriRepresentation().absoluteString }
        defaults.set(uris, forKey: DefaultsKey.openNoteURIs)
        defaults.set(
            selectedNote?.objectID.uriRepresentation().absoluteString,
            forKey: DefaultsKey.selectedNoteURI
        )
        defaults.set(isCanvasVisible, forKey: DefaultsKey.isCanvasVisible)
    }
}
