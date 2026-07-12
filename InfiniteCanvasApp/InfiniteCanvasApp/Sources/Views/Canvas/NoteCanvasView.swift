import SwiftUI
import PencilKit
import CoreData
import PDFKit

/// ツールバーからキャンバスへのオブジェクト挿入リクエスト(要件③)
enum ObjectInsertion: Equatable {
    case text
    case image(Data)
    case pdf(Data)
    case noteLink(UUID)  // 他のノートへのリンクカード
    case todo            // チェックリスト
}

/// 1つのノートの無限キャンバス。
/// 描画・オブジェクトの変更を自動保存(0.8秒デバウンス)し、サムネイルも更新する(要件②③)。
struct NoteCanvasView: View {
    @ObservedObject var note: NoteFile
    @ObservedObject var toolState: PenToolState
    let undoBridge: CanvasUndoBridge
    @Binding var insertion: ObjectInsertion?
    /// 分割表示でこのキャンバスが操作されたら呼ぶ(アクティブ側の切替に使う)
    var onActivate: () -> Void = {}
    @EnvironmentObject private var session: OpenNotesSession
    @Environment(\.managedObjectContext) private var context

    @FetchRequest private var objects: FetchedResults<CanvasObject>
    @State private var drawing: PKDrawing
    @State private var saveTask: Task<Void, Never>?
    @State private var autoFocusObjectID: NSManagedObjectID?
    @State private var showDeletePageConfirm = false
    @State private var showNoteSettings = false

    init(
        note: NoteFile,
        toolState: PenToolState,
        undoBridge: CanvasUndoBridge,
        insertion: Binding<ObjectInsertion?>,
        onActivate: @escaping () -> Void = {}
    ) {
        _note = ObservedObject(wrappedValue: note)
        _toolState = ObservedObject(wrappedValue: toolState)
        self.undoBridge = undoBridge
        _insertion = insertion
        self.onActivate = onActivate
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
                isShapeAssistEnabled: toolState.isShapeAssistEnabled,
                backgroundStyle: CanvasBackgroundStyle(rawValue: note.backgroundStyle ?? "") ?? .blank,
                pageColor: note.canvasPageColor,
                noteType: note.canvasNoteType,
                pageCount: note.resolvedPageCount,
                isTwoPageLayout: note.isTwoPageLayout,
                isHorizontalScroll: note.isHorizontalScroll,
                objects: Array(objects),
                autoFocusObjectID: autoFocusObjectID,
                initialViewport: session.viewports[note.objectID],
                onDrawingChanged: {
                    onActivate()          // 描いた側を分割のアクティブ側にする
                    scheduleAutoSave()
                    undoBridge.refresh()  // 描画のたびに戻る/やり直しボタンの状態を更新
                },
                onViewportChanged: { session.updateViewport($0, for: note.objectID) },
                onObjectFrameChanged: { id, frame in
                    withObject(id) { object in
                        let previous = object.contentFrame
                        object.contentFrame = frame
                        if previous != frame, let uuid = object.id {
                            CanvasObjectUndo.registerFrameChange(
                                objectUUID: uuid, previousFrame: previous,
                                in: undoBridge.activeUndoManager,
                                context: context, bridge: undoBridge
                            )
                        }
                    }
                },
                onObjectTextChanged: { id, text in
                    withObject(id) { object in
                        let previous = object.text ?? ""
                        object.text = text
                        if previous != text, let uuid = object.id {
                            CanvasObjectUndo.registerTextChange(
                                objectUUID: uuid, previousText: previous,
                                in: undoBridge.activeUndoManager,
                                context: context, bridge: undoBridge
                            )
                        }
                    }
                },
                onObjectTodoChanged: { id, items in
                    withObject(id) { object in
                        let previous = object.payload
                        object.todoItems = items
                        if previous != object.payload, let uuid = object.id {
                            CanvasObjectUndo.registerPayloadChange(
                                objectUUID: uuid, previousPayload: previous,
                                in: undoBridge.activeUndoManager,
                                context: context, bridge: undoBridge
                            )
                        }
                    }
                },
                onObjectDeleted: { id in
                    withObject(id) { object in
                        if let snapshot = CanvasObjectSnapshot(object: object) {
                            CanvasObjectUndo.registerDelete(
                                snapshot: snapshot,
                                in: undoBridge.activeUndoManager,
                                context: context, bridge: undoBridge
                            )
                        }
                        context.delete(object)
                    }
                },
                onObjectAutoHeightChanged: { id, height in
                    // フォント変更に伴う高さ調整は Undo を積まずに保存(フォント変更 Undo に追従)
                    withObject(id) { $0.contentFrame.size.height = height }
                },
                onTextSelectionChanged: { info in
                    if let info {
                        toolState.selectedTextObject = SelectedTextObject(
                            objectID: info.objectID, fontSize: info.fontSize
                        )
                    } else {
                        toolState.selectedTextObject = nil
                    }
                },
                onLassoObjectsMoved: { region, delta in
                    moveObjectsWithLasso(in: region, by: delta)
                },
                onLassoObjectsDeleted: { region in
                    deleteObjectsWithLasso(in: region)
                },
                onNoteLinkActivated: { id in
                    openLinkedNote(objectID: id)
                },
                onCanvasReady: { undoBridge.attach($0) }
            )
            .onChange(of: insertion) { _, request in
                guard let request else { return }
                insert(request, viewSize: geo.size)
                insertion = nil
            }
            // ページ追加/削除ボタン(通常ノートのみ・右下フローティング)
            .overlay(alignment: .bottomTrailing) {
                if note.canvasNoteType == .paged {
                    HStack(spacing: 12) {
                        if note.resolvedPageCount > 1 { deletePageButton }
                        addPageButton
                    }
                    .padding(24)
                }
            }
            .alert("最後のページを削除しますか？", isPresented: $showDeletePageConfirm) {
                Button("削除", role: .destructive) { deleteLastPage() }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("このページ上の手書きとオブジェクトも削除されますがよろしいですか？")
            }
        }
        // 通常ノートのレイアウト設定(見開き / 横スクロール)
        .toolbar {
            if note.canvasNoteType == .paged {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showNoteSettings.toggle()
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .accessibilityIdentifier("paged-settings-button")
                    .popover(isPresented: $showNoteSettings) {
                        pagedSettingsPopover
                    }
                }
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
            session.flushViewports()  // 保留中のスクロール位置も確定
            toolState.selectedTextObject = nil  // 別タブへ選択を持ち越さない
        }
    }

    // MARK: - ノートのレイアウト設定(見開き / 横スクロール)

    private var pagedSettingsPopover: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ページ表示")
                .font(.headline)
                .padding(.bottom, 4)
            Toggle("見開き2ページ表示", isOn: Binding(
                get: { note.isTwoPageLayout },
                set: { setLayout(twoPage: $0, horizontal: note.isHorizontalScroll) }
            ))
            .accessibilityIdentifier("toggle-two-page")
            Toggle("横スクロール (ページめくり)", isOn: Binding(
                get: { note.isHorizontalScroll },
                set: { setLayout(twoPage: note.isTwoPageLayout, horizontal: $0) }
            ))
            .accessibilityIdentifier("toggle-horizontal-scroll")
        }
        .padding(20)
        .frame(width: 300)
    }

    /// レイアウト設定を更新して保存する(キャンバスは note の変化を検知して即時に組み替わる)。
    private func setLayout(twoPage: Bool, horizontal: Bool) {
        note.isTwoPageLayout = twoPage
        note.isHorizontalScroll = horizontal
        note.updatedAt = .now
        do {
            try context.save()
        } catch {
            assertionFailure("レイアウト設定の保存に失敗: \(error)")
        }
    }

    // MARK: - ページ追加(通常ノート)

    private var addPageButton: some View {
        Button(action: addPage) {
            pageButtonLabel("ページを追加", systemImage: "plus")
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("canvas-add-page")
    }

    private var deletePageButton: some View {
        Button { showDeletePageConfirm = true } label: {
            pageButtonLabel("ページを削除", systemImage: "trash")
                .foregroundStyle(.red)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("canvas-delete-page")
    }

    private func pageButtonLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .labelStyle(.titleAndIcon)
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.thinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color(.separator), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
    }

    /// ページ数を1増やして保存する。CanvasRepresentable が高さを拡張し、新ページへスクロールする。
    private func addPage() {
        note.pageCount += 1
        note.updatedAt = .now
        do {
            try context.save()
        } catch {
            assertionFailure("ページ追加の保存に失敗: \(error)")
        }
    }

    /// 最後のページを削除し、そのページ領域(Y範囲)に重なる手書きインクとオブジェクトも消す。
    /// ページ数・描画・オブジェクト削除は1つの Undo グループにまとまる。
    private func deleteLastPage() {
        guard note.canvasNoteType == .paged, note.resolvedPageCount > 1 else { return }
        let oldCount = Int(note.pageCount)
        // 削除対象は「最後のページ」の矩形。レイアウト(見開き/スクロール方向)に応じて位置が変わる。
        let layout = PagedLayoutCalculator(
            pageCount: oldCount,
            isTwoPageLayout: note.isTwoPageLayout,
            isHorizontalScroll: note.isHorizontalScroll
        )
        let lastRect = layout.pageRect(oldCount - 1)
        func isOnLastPage(_ rect: CGRect) -> Bool {
            lastRect.contains(CGPoint(x: rect.midX, y: rect.midY))
        }
        let manager = undoBridge.activeUndoManager

        // 1) オブジェクト: contentFrame の中心が削除ページにあるものを削除(Undo 登録付き)
        for object in objects where !object.isDeleted && isOnLastPage(object.contentFrame) {
            if let snapshot = CanvasObjectSnapshot(object: object) {
                CanvasObjectUndo.registerDelete(
                    snapshot: snapshot, in: manager, context: context, bridge: undoBridge
                )
            }
            context.delete(object)
        }

        // 2) 手書き: ストロークの描画範囲の中心が削除ページにあるものを除去
        let drawingBefore = drawing
        var drawingAfter = drawing
        drawingAfter.strokes.removeAll { isOnLastPage($0.renderBounds) }

        // 3) ページ数と描画の一括変更を Undo に積む(上のオブジェクト削除と同一グループ)
        CanvasObjectUndo.registerPageStructureChange(
            noteID: note.objectID,
            drawingToRestore: drawingBefore, pageCountToRestore: Int16(oldCount),
            drawingToReapply: drawingAfter, pageCountToReapply: Int16(oldCount - 1),
            in: manager, context: context, bridge: undoBridge
        )

        // 適用
        drawing = drawingAfter
        note.pageCount = Int16(oldCount - 1)
        note.updatedAt = .now
        persist()
    }

    // MARK: - ノートリンクのジャンプ

    /// ノートリンクのダブルタップ → リンク先ノートをタブで開く(既存タブなら切替)。
    private func openLinkedNote(objectID: NSManagedObjectID) {
        guard let object = (try? context.existingObject(with: objectID)) as? CanvasObject,
              let linked = object.resolvedLinkedNote else { return }
        // 開く前に現在ノートの保留分を保存(タブ切替で消えないように)
        persist()
        session.open(linked)
    }

    // MARK: - 投げ縄でのインクとオブジェクトの連動

    /// 投げ縄で移動したインク領域に中心があるオブジェクトを、同じ差分だけ平行移動する。
    /// ロック(PDF背景など)は対象外。Undo はインク移動と同一グループにまとまる。
    private func moveObjectsWithLasso(in region: CGRect, by delta: CGVector) {
        for object in objects where !object.isDeleted && !object.isLocked
        && region.contains(CGPoint(x: object.contentFrame.midX, y: object.contentFrame.midY)) {
            let previous = object.contentFrame
            object.contentFrame = previous.offsetBy(dx: delta.dx, dy: delta.dy)
            object.updatedAt = .now
            if let uuid = object.id {
                CanvasObjectUndo.registerFrameChange(
                    objectUUID: uuid, previousFrame: previous,
                    in: undoBridge.activeUndoManager, context: context, bridge: undoBridge
                )
            }
        }
        scheduleAutoSave()
    }

    /// 投げ縄で削除したインク領域に中心があるオブジェクトも削除する(ロックは対象外)。
    private func deleteObjectsWithLasso(in region: CGRect) {
        for object in objects where !object.isDeleted && !object.isLocked
        && region.contains(CGPoint(x: object.contentFrame.midX, y: object.contentFrame.midY)) {
            if let snapshot = CanvasObjectSnapshot(object: object) {
                CanvasObjectUndo.registerDelete(
                    snapshot: snapshot, in: undoBridge.activeUndoManager,
                    context: context, bridge: undoBridge
                )
            }
            context.delete(object)
        }
        scheduleAutoSave()
    }

    // MARK: - オブジェクト操作の書き戻し

    private func withObject(_ id: NSManagedObjectID, _ mutate: (CanvasObject) -> Void) {
        guard let object = (try? context.existingObject(with: id)) as? CanvasObject else { return }
        onActivate()  // オブジェクトを操作した側をアクティブにする
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
        case .noteLink(let linkedID):
            object.kind = CanvasObjectKind.noteLink.rawValue
            object.linkedNoteUUID = linkedID.uuidString
            object.contentFrame = CGRect(x: center.x - 130, y: center.y - 40, width: 260, height: 80)
        case .todo:
            object.kind = CanvasObjectKind.todo.rawValue
            object.todoItems = [TodoItem(text: "", done: false)]
            object.contentFrame = CGRect(x: center.x - 130, y: center.y - 60, width: 260, height: 120)
        }

        // 保存前後で objectID が変わるとレイヤーのビューが作り直されるため先に確定させる
        try? context.obtainPermanentIDs(for: [object])
        toolState.tool = .selector  // 配置直後にそのまま移動・編集できるよう選択モードへ
        autoFocusObjectID = object.objectID
        persist()
        if let uuid = object.id {
            CanvasObjectUndo.registerInsert(
                objectUUID: uuid,
                in: undoBridge.activeUndoManager,
                context: context, bridge: undoBridge
            )
        }
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
                case .todo:
                    // サムネイルでは項目テキストを角丸カード上に簡易描画
                    let path = UIBezierPath(roundedRect: object.contentFrame, cornerRadius: 10)
                    UIColor.secondarySystemBackground.setFill()
                    path.fill()
                    let lines = object.todoItems
                        .map { ($0.done ? "☑ " : "☐ ") + $0.text }
                        .joined(separator: "\n")
                    (lines as NSString).draw(
                        in: object.contentFrame.insetBy(dx: 10, dy: 8),
                        withAttributes: [
                            .font: UIFont.systemFont(ofSize: 15),
                            .foregroundColor: pageColor.contentUIColor,
                        ]
                    )
                case .noteLink:
                    // サムネイルではリンクカードを角丸の淡い矩形として簡易描画
                    let path = UIBezierPath(roundedRect: object.contentFrame, cornerRadius: 10)
                    UIColor.secondarySystemBackground.setFill()
                    path.fill()
                    ((object.resolvedLinkedNote?.displayTitle ?? "ノート") as NSString).draw(
                        in: object.contentFrame.insetBy(dx: 10, dy: 10),
                        withAttributes: [
                            .font: UIFont.systemFont(ofSize: 16, weight: .medium),
                            .foregroundColor: pageColor.contentUIColor,
                        ]
                    )
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
