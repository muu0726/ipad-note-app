import SwiftUI
import PencilKit
import CoreData
import PDFKit

/// ツールバーからキャンバスへのオブジェクト挿入リクエスト(要件③)
enum ObjectInsertion: Equatable {
    case text
    case image(Data)
    case pdf(Data)
}

/// 1つのノートの無限キャンバス。
/// 描画・オブジェクトの変更を自動保存(0.8秒デバウンス)し、サムネイルも更新する(要件②③)。
struct NoteCanvasView: View {
    @ObservedObject var note: NoteFile
    @ObservedObject var toolState: PenToolState
    let undoBridge: CanvasUndoBridge
    @Binding var insertion: ObjectInsertion?
    @EnvironmentObject private var session: OpenNotesSession
    @Environment(\.managedObjectContext) private var context

    @FetchRequest private var objects: FetchedResults<CanvasObject>
    @State private var drawing: PKDrawing
    @State private var saveTask: Task<Void, Never>?
    @State private var autoFocusObjectID: NSManagedObjectID?

    init(
        note: NoteFile,
        toolState: PenToolState,
        undoBridge: CanvasUndoBridge,
        insertion: Binding<ObjectInsertion?>
    ) {
        _note = ObservedObject(wrappedValue: note)
        _toolState = ObservedObject(wrappedValue: toolState)
        self.undoBridge = undoBridge
        _insertion = insertion
        _objects = FetchRequest(
            entity: CanvasObject.entity(),
            sortDescriptors: [NSSortDescriptor(keyPath: \CanvasObject.zOrder, ascending: true)],
            predicate: NSPredicate(format: "note == %@", note)
        )
        if let data = note.canvasData, let loaded = try? PKDrawing(data: data) {
            _drawing = State(initialValue: loaded)
        } else {
            _drawing = State(initialValue: PKDrawing())
        }
    }

    var body: some View {
        GeometryReader { geo in
            CanvasRepresentable(
                drawing: $drawing,
                pkTool: toolState.pkTool,
                isSelectMode: toolState.isSelectMode,
                backgroundStyle: CanvasBackgroundStyle(rawValue: note.backgroundStyle ?? "") ?? .blank,
                pageColor: note.canvasPageColor,
                objects: Array(objects),
                autoFocusObjectID: autoFocusObjectID,
                initialViewport: session.viewports[note.objectID],
                onDrawingChanged: {
                    scheduleAutoSave()
                    undoBridge.refresh()  // 描画のたびに戻る/やり直しボタンの状態を更新
                },
                onViewportChanged: { session.viewports[note.objectID] = $0 },
                onObjectFrameChanged: { id, frame in
                    withObject(id) { $0.contentFrame = frame }
                },
                onObjectTextChanged: { id, text in
                    withObject(id) { $0.text = text }
                },
                onObjectDeleted: { id in
                    withObject(id) { context.delete($0) }
                },
                onCanvasReady: { undoBridge.attach($0) }
            )
            .onChange(of: insertion) { _, request in
                guard let request else { return }
                insert(request, viewSize: geo.size)
                insertion = nil
            }
        }
        .onAppear {
            // 用紙と同色で見えないペン色になっていたら反転色へ(黒紙で黒ペン等)
            let page = note.canvasPageColor
            if toolState.penColor == page.backgroundUIColor {
                toolState.penColor = page.contentUIColor
            }
        }
        .onDisappear {
            // タブ切替・ライブラリ復帰時は即時保存
            saveTask?.cancel()
            persist()
        }
    }

    // MARK: - オブジェクト操作の書き戻し

    private func withObject(_ id: NSManagedObjectID, _ mutate: (CanvasObject) -> Void) {
        guard let object = (try? context.existingObject(with: id)) as? CanvasObject else { return }
        mutate(object)
        if !object.isDeleted {
            object.updatedAt = .now
        }
        scheduleAutoSave()
    }

    // MARK: - オブジェクト挿入(要件③)

    private func insert(_ request: ObjectInsertion, viewSize: CGSize) {
        let center = insertionCenter(viewSize: viewSize)
        let object = CanvasObject(context: context)
        object.id = UUID()
        object.createdAt = .now
        object.updatedAt = .now
        object.note = note
        object.zOrder = (objects.last?.zOrder ?? 0) + 1

        switch request {
        case .text:
            object.kind = CanvasObjectKind.text.rawValue
            object.text = ""
            object.fontSize = 24
            object.contentFrame = CGRect(x: center.x - 120, y: center.y - 30, width: 240, height: 60)
        case .image(let data):
            object.kind = CanvasObjectKind.image.rawValue
            object.payload = data
            let size = fitted(UIImage(data: data)?.size ?? CGSize(width: 300, height: 300), maxSide: 400)
            object.contentFrame = centered(size, at: center)
        case .pdf(let data):
            object.kind = CanvasObjectKind.pdf.rawValue
            object.payload = data
            let pageSize = PDFDocument(data: data)?.page(at: 0)?
                .bounds(for: .mediaBox).size ?? CGSize(width: 300, height: 400)
            object.contentFrame = centered(fitted(pageSize, maxSide: 500), at: center)
        }

        // 保存前後で objectID が変わるとレイヤーのビューが作り直されるため先に確定させる
        try? context.obtainPermanentIDs(for: [object])
        toolState.tool = .selector  // 配置直後にそのまま移動・編集できるよう選択モードへ
        autoFocusObjectID = object.objectID
        persist()
    }

    /// 現在のビューポート中央(コンテンツ空間)。未スクロールならキャンバス中央
    private func insertionCenter(viewSize: CGSize) -> CGPoint {
        if let viewport = session.viewports[note.objectID], viewport.zoomScale > 0 {
            return CGPoint(
                x: (viewport.contentOffset.x + viewSize.width / 2) / viewport.zoomScale,
                y: (viewport.contentOffset.y + viewSize.height / 2) / viewport.zoomScale
            )
        }
        let half = CanvasRepresentable.canvasSize / 2
        return CGPoint(x: half, y: half)
    }

    private func fitted(_ size: CGSize, maxSide: CGFloat) -> CGSize {
        let longest = max(size.width, size.height, 1)
        let scale = min(1, maxSide / longest)
        return CGSize(width: max(40, size.width * scale), height: max(40, size.height * scale))
    }

    private func centered(_ size: CGSize, at center: CGPoint) -> CGRect {
        CGRect(
            origin: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2),
            size: size
        )
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
        if data != note.canvasData {
            note.canvasData = data
        }
        guard context.hasChanges else { return }
        note.updatedAt = .now
        note.thumbnailData = makeThumbnail()
        do {
            try context.save()
        } catch {
            assertionFailure("キャンバスの自動保存に失敗: \(error)")
        }
    }

    /// 描画とオブジェクトを合成してライブラリグリッド用サムネイルを生成
    private func makeThumbnail() -> Data? {
        var bounds = drawing.bounds
        for object in objects where !object.isDeleted {
            bounds = bounds.isEmpty ? object.contentFrame : bounds.union(object.contentFrame)
        }
        guard !bounds.isEmpty else { return nil }

        let target = bounds.insetBy(dx: -24, dy: -24)
        let scale = min(1, 480 / max(target.width, target.height))
        let size = CGSize(width: target.width * scale, height: target.height * scale)
        let pageColor = note.canvasPageColor
        let image = UIGraphicsImageRenderer(size: size).image { ctx in
            pageColor.backgroundUIColor.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            ctx.cgContext.scaleBy(x: scale, y: scale)
            ctx.cgContext.translateBy(x: -target.minX, y: -target.minY)
            for object in objects where !object.isDeleted {
                switch object.objectKind {
                case .text:
                    ((object.text ?? "") as NSString).draw(
                        in: object.contentFrame.insetBy(dx: 4, dy: 4),
                        withAttributes: [
                            .font: UIFont.systemFont(
                                ofSize: object.fontSize > 0 ? object.fontSize : 24
                            ),
                            .foregroundColor: pageColor.contentUIColor,
                        ]
                    )
                case .image, .pdf:
                    object.makeDisplayImage()?.draw(in: object.contentFrame)
                }
            }
            // キャンバスと同様、ダークモードでのインク色自動反転を避けて描き出す
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                drawing.image(from: target, scale: scale).draw(in: target)
            }
        }
        return image.jpegData(compressionQuality: 0.7)
    }
}
