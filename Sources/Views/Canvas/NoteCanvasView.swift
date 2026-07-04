import SwiftUI
import PencilKit
import CoreData
import PhotosUI
import UIKit

/// 1つのノートの無限キャンバス。
/// レイヤー構成(下から): 背景パターン → オブジェクト → 手書き(PKCanvasView)。
/// 描画変更は自動保存(0.8秒デバウンス)し、サムネイルも更新する(要件②の Auto-save)。
struct NoteCanvasView: View {
    @ObservedObject var note: NoteFile
    @ObservedObject var toolState: PenToolState
    @EnvironmentObject private var session: OpenNotesSession
    @Environment(\.managedObjectContext) private var context

    @StateObject private var viewportState = CanvasViewportState()
    @State private var drawing: PKDrawing
    @State private var drawingVersion = 0
    @State private var saveTask: Task<Void, Never>?

    // オブジェクト操作の状態
    @State private var selectedObjectID: NSManagedObjectID?
    @State private var editingObjectID: NSManagedObjectID?
    @State private var isPhotoPickerPresented = false
    @State private var photoItem: PhotosPickerItem?
    @State private var isPDFImporterPresented = false

    init(note: NoteFile, toolState: PenToolState) {
        _note = ObservedObject(wrappedValue: note)
        _toolState = ObservedObject(wrappedValue: toolState)
        if let data = note.canvasData, let loaded = try? PKDrawing(data: data) {
            _drawing = State(initialValue: loaded)
        } else {
            _drawing = State(initialValue: PKDrawing())
        }
    }

    private var isSelectMode: Bool { toolState.tool == .selector }

    private var backgroundStyle: CanvasBackgroundStyle {
        CanvasBackgroundStyle(rawValue: note.backgroundStyle ?? "") ?? .blank
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                BackgroundPatternLayer(viewportState: viewportState, style: backgroundStyle)
                CanvasObjectsOverlay(
                    note: note,
                    viewportState: viewportState,
                    selectedObjectID: $selectedObjectID,
                    editingObjectID: $editingObjectID,
                    isSelectMode: isSelectMode,
                    gridSnapEnabled: backgroundStyle != .blank,
                    onMoveCommitted: handleObjectMoved
                )
                CanvasRepresentable(
                    drawing: $drawing,
                    drawingVersion: drawingVersion,
                    pkTool: toolState.pkTool,
                    isSelectMode: isSelectMode,
                    viewportState: viewportState,
                    initialViewport: session.viewports[note.objectID],
                    onDrawingChanged: scheduleAutoSave,
                    onViewportChanged: { session.viewports[note.objectID] = $0 }
                )
            }
            .onAppear { viewportState.viewSize = geometry.size }
            .onChange(of: geometry.size) { _, newSize in
                viewportState.viewSize = newSize
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { insertMenu }
        }
        .photosPicker(isPresented: $isPhotoPickerPresented, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            handlePickedPhoto(item)
        }
        .fileImporter(
            isPresented: $isPDFImporterPresented,
            allowedContentTypes: [.pdf],
            onCompletion: handlePDFImport
        )
        .onChange(of: toolState.tool) { _, newTool in
            // 選択モードを抜けたら選択・編集状態も解除
            if newTool != .selector {
                selectedObjectID = nil
                editingObjectID = nil
            }
        }
        .onDisappear {
            // タブ切替・ライブラリ復帰時は即時保存
            saveTask?.cancel()
            persist()
        }
    }

    // MARK: - オブジェクト挿入(要件③)

    private var insertMenu: some View {
        Menu {
            Button {
                insertText()
            } label: {
                Label("テキスト", systemImage: "textformat")
            }
            Button {
                isPhotoPickerPresented = true
            } label: {
                Label("写真", systemImage: "photo")
            }
            Button {
                isPDFImporterPresented = true
            } label: {
                Label("PDF", systemImage: "doc.text")
            }
        } label: {
            Image(systemName: "plus")
        }
    }

    private func insertText() {
        let object = CanvasObjectService.createText(
            in: note, at: viewportState.visibleContentCenter, context: context)
        toolState.tool = .selector
        selectedObjectID = object.objectID
        editingObjectID = object.objectID
    }

    private func handlePickedPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task { @MainActor in
            defer { photoItem = nil }
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else { return }
            let object = CanvasObjectService.createImage(
                image, in: note, at: viewportState.visibleContentCenter, context: context)
            toolState.tool = .selector
            selectedObjectID = object.objectID
        }
    }

    private func handlePDFImport(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        let object = CanvasObjectService.createPDF(
            data: data, in: note, at: viewportState.visibleContentCenter, context: context)
        toolState.tool = .selector
        selectedObjectID = object.objectID
    }

    /// オブジェクト移動後、旧フレーム内のストロークを追従させる(単一レイヤー要件)
    private func handleObjectMoved(oldFrame: CGRect, delta: CGPoint) {
        let result = CanvasObjectService.translateStrokes(in: drawing, within: oldFrame, by: delta)
        if result.didMove {
            drawing = result.drawing
            drawingVersion += 1
            scheduleAutoSave()
        }
    }

    // MARK: - 自動保存

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
