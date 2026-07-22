import PencilKit
import Combine

/// ツールバーの「一つ戻る / やり直し」ボタンと PKCanvasView の undoManager の橋渡し。
/// PencilKit は描画操作を undoManager へ自動登録するので、それを外から叩くだけでよい。
/// タブ切替でキャンバスが差し替わるため、常に現在のキャンバスを attach し直す。
@MainActor
final class CanvasUndoBridge: ObservableObject {
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    private weak var canvasView: PKCanvasView?

    /// オブジェクト操作(CanvasObjectUndo)の登録先。描画と同じ履歴に混在させる
    var activeUndoManager: UndoManager? { canvasView?.undoManager }

    /// 現在のキャンバスの描画(ページ削除・Undo でストロークを差し替えるのに使う)
    var currentDrawing: PKDrawing? { canvasView?.drawing }

    /// merged 描画の差し替え先の上書き(通常ノート用)。通常ノートはキャンバスがページ分割
    /// されているため、merged をキャンバスへ直接書けない。設定時は canvasView への書き込みの
    /// 代わりにこれを呼ぶ(NoteCanvasView が @State drawing へ書き戻し、配布経路へ流す)。
    var onReplaceDrawing: ((PKDrawing) -> Void)?

    /// 描画を差し替える。canvasViewDrawingDidChange 経由で @State と保存へ伝播する。
    func replaceDrawing(_ drawing: PKDrawing) {
        if let onReplaceDrawing {
            onReplaceDrawing(drawing)
        } else {
            canvasView?.drawing = drawing
        }
        refresh()
    }

    func attach(_ canvas: PKCanvasView) {
        canvasView = canvas
        refresh()
    }

    /// 描画変更のたびに呼び、ボタンの有効状態を更新する。
    /// undoManager への登録は delegate 呼び出しの後に完了することがあるため1サイクル遅らせる
    func refresh() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            canUndo = canvasView?.undoManager?.canUndo ?? false
            canRedo = canvasView?.undoManager?.canRedo ?? false
        }
    }

    func undo() {
        canvasView?.undoManager?.undo()
        syncNow()
    }

    func redo() {
        canvasView?.undoManager?.redo()
        syncNow()
    }

    /// undo()/redo() 直後は状態が確定しているので同期で反映する。
    /// (async refresh だけだと、描画デリゲート由来の stale な更新が後勝ちして
    ///  ボタンが実際の canUndo/canRedo と食い違うことがあるため)
    private func syncNow() {
        canUndo = canvasView?.undoManager?.canUndo ?? false
        canRedo = canvasView?.undoManager?.canRedo ?? false
    }
}
