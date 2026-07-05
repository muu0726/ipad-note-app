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
        refresh()
    }

    func redo() {
        canvasView?.undoManager?.redo()
        refresh()
    }
}
