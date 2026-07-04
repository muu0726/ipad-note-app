import Foundation

/// 開いているノート(タブ)の状態を管理するセッションオブジェクト。
/// タブの並び・選択中タブ・キャンバス表示状態を保持する。
final class OpenNotesSession: ObservableObject {
    @Published private(set) var openNotes: [NoteFile] = []
    @Published var selectedNote: NoteFile?
    /// true のときディテール領域にキャンバス(タブ)を表示する
    @Published var isCanvasVisible = false

    /// ノートをタブで開く。既に開いていればそのタブへ切り替える(重複タブは作らない)
    func open(_ note: NoteFile) {
        if !openNotes.contains(note) {
            openNotes.append(note)
        }
        selectedNote = note
        isCanvasVisible = true
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

    // TODO: タブ状態の永続化(アプリ再起動後の復元)と
    //       タブごとのビューポート(ズーム/位置)保持は ② キャンバス実装時に追加
}
