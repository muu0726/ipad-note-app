import SwiftUI
import PencilKit
import CoreData

/// 1つのノートの無限キャンバス。
/// 描画変更を自動保存(0.8秒デバウンス)し、サムネイルも更新する(要件②の Auto-save)。
struct NoteCanvasView: View {
    @ObservedObject var note: NoteFile
    @ObservedObject var toolState: PenToolState
    @EnvironmentObject private var session: OpenNotesSession
    @Environment(\.managedObjectContext) private var context

    @State private var drawing: PKDrawing
    @State private var saveTask: Task<Void, Never>?

    init(note: NoteFile, toolState: PenToolState) {
        _note = ObservedObject(wrappedValue: note)
        _toolState = ObservedObject(wrappedValue: toolState)
        if let data = note.canvasData, let loaded = try? PKDrawing(data: data) {
            _drawing = State(initialValue: loaded)
        } else {
            _drawing = State(initialValue: PKDrawing())
        }
    }

    var body: some View {
        CanvasRepresentable(
            drawing: $drawing,
            pkTool: toolState.pkTool,
            backgroundStyle: CanvasBackgroundStyle(rawValue: note.backgroundStyle ?? "") ?? .blank,
            initialViewport: session.viewports[note.objectID],
            onDrawingChanged: scheduleAutoSave,
            onViewportChanged: { session.viewports[note.objectID] = $0 }
        )
        .onDisappear {
            // タブ切替・ライブラリ復帰時は即時保存
            saveTask?.cancel()
            persist()
        }
    }

    private func scheduleAutoSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            persist()
        }
    }

    @MainActor
    private func persist() {
        guard !note.isDeleted else { return }
        let data = drawing.dataRepresentation()
        guard data != note.canvasData else { return }
        note.canvasData = data
        note.updatedAt = .now
        note.thumbnailData = makeThumbnail()
        do {
            try context.save()
        } catch {
            assertionFailure("キャンバスの自動保存に失敗: \(error)")
        }
    }

    /// 描画範囲からライブラリグリッド用サムネイルを生成
    private func makeThumbnail() -> Data? {
        let bounds = drawing.bounds
        guard !bounds.isEmpty else { return nil }
        let target = bounds.insetBy(dx: -24, dy: -24)
        let scale = min(1, 480 / max(target.width, target.height))
        let image = drawing.image(from: target, scale: scale)
        return image.jpegData(compressionQuality: 0.7)
    }
}
