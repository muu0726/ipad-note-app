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
    case shape(ShapeType)  // 図形(矩形・楕円・三角・直線・矢印・星)
    case table(rows: Int, cols: Int)  // 表(Excel風)
    case stickyNote(StickyNoteColor)  // 付箋(カラー付き)
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
    @State private var showPageManager = false
    @State private var showNavigator = false
    /// 現在ビューポート中心のページ index(しおりトグル・目次追加の対象)
    @State private var currentPageIndex = 0
    /// しおり/目次からのジャンプ要求(CanvasRepresentable が処理後 nil へ戻す)
    @State private var scrollToPage: Int?
    /// ズームを 100% に戻す要求(左上バッジのメニューから)
    @State private var resetZoomRequested = false
    /// コンテンツ全体を画面に収める(Zoom to Fit)要求(左上バッジのメニューから)
    @State private var zoomToFitRequested = false
    /// 現在のズーム倍率(表示用)
    @State private var currentZoomScale: CGFloat = 1.0
    /// ズームロック: true のときピンチズームを禁止する
    @State private var isZoomLocked = false
    /// 編集ポップオーバーを開いている図形(ダブルタップで開く)。nil で閉じる。
    @State private var editingShape: EditingShape?

    /// 図形編集ポップオーバーの対象。開いた時点の payload を控え、閉じるときに 1つの Undo として登録する。
    private struct EditingShape: Identifiable {
        let id: NSManagedObjectID
        let previousPayload: Data?
    }

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
            canvasContent(geo: geo)
            .onChange(of: insertion) { _, request in
                guard let request else { return }
                insert(request, viewSize: geo.size)
                insertion = nil
            }
            // ページ削除ボタン(通常ノートのみ・右下フローティング)。
            // ページ追加は「末尾を超えて横に引っ張る」オーバースクロールで自動化した。
            .overlay(alignment: .bottomTrailing) {
                if note.canvasNoteType == .paged, note.resolvedPageCount > 1 {
                    deletePageButton
                        .padding(24)
                }
            }
            // ズーム倍率表示 + ロック(左上フローティング)
            .overlay(alignment: .topLeading) {
                zoomIndicator
                    .padding(.leading, 16)
                    .padding(.top, 12)
            }
            // ページナビゲーション(右上フローティング・通常ノートのみ)
            .overlay(alignment: .topTrailing) {
                if note.canvasNoteType == .paged {
                    pageIndicator
                        .padding(.trailing, 16)
                        .padding(.top, 12)
                }
            }
            .alert("最後のページを削除しますか？", isPresented: $showDeletePageConfirm) {
                Button("削除", role: .destructive) { deleteLastPage() }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("このページ上の手書きとオブジェクトも削除されますがよろしいですか？")
            }
            // 図形編集ポップオーバー(線色 / 塗り / 太さ)。閉じるときに 1つの Undo を積む。
            // 全画面ビューをアンカーにすると高さが潰れて内容が切れるため、中央の極小ビューへ出す。
            .overlay(alignment: .center) {
                Color.clear
                    .frame(width: 1, height: 1)
                    .popover(item: Binding(
                        get: { editingShape },
                        set: { newValue in
                            if newValue == nil, let editing = editingShape { commitShapeEdit(editing) }
                            editingShape = newValue
                        }
                    )) { editing in
                        if let object = (try? context.existingObject(with: editing.id)) as? CanvasObject,
                           let payload = object.shapePayload {
                            ShapeEditPopover(
                                initial: payload,
                                palette: toolState.palette,
                                onUpdate: { updated in updateShapePayload(editing.id, updated) }
                            )
                        }
                    }
            }
        }
        // 通常ノートのレイアウト設定(見開き / 横スクロール)
        .toolbar {
            if note.canvasNoteType == .paged {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        note.toggleBookmark(page: currentPageIndex)
                        note.updatedAt = .now
                        try? context.save()
                    } label: {
                        Image(systemName: note.isBookmarked(page: currentPageIndex) ? "bookmark.fill" : "bookmark")
                    }
                    .accessibilityIdentifier("bookmark-toggle-button")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showNavigator = true
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                    .accessibilityIdentifier("navigator-button")
                    .popover(isPresented: $showNavigator) {
                        PageNavigatorView(
                            note: note,
                            currentPage: currentPageIndex,
                            onJump: { page in showNavigator = false; scrollToPage = page }
                        )
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showPageManager = true
                    } label: {
                        Image(systemName: "square.grid.2x2")
                    }
                    .accessibilityIdentifier("page-manager-button")
                }
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
        .sheet(isPresented: $showPageManager) {
            PageManagerView(
                note: note,
                drawing: { drawing },
                objects: { Array(objects) },
                onReorder: { from, to in applyPagePlan(.reorder(count: note.resolvedPageCount, from: from, to: to)) },
                onDuplicate: { index in applyPagePlan(.duplicate(count: note.resolvedPageCount, at: index)) },
                onDelete: { index in applyPagePlan(.delete(count: note.resolvedPageCount, at: index)) }
            )
        }
        .onAppear {
            // 用紙と同色で見えないペン色になっていたら反転色へ(黒紙で黒ペン等)
            let page = note.canvasPageColor
            if toolState.penColor == page.backgroundUIColor {
                toolState.penColor = page.contentUIColor
            }
            // 通常ノート: ページ構造 Undo(ページ削除/並び替えの復元)の merged 差し替えは
            // ページ分割キャンバスへ直接書けないため、@State 経由で配布経路へ流す
            if note.canvasNoteType == .paged {
                undoBridge.onReplaceDrawing = { merged in
                    drawing = merged
                    scheduleAutoSave()
                }
            }
        }
        .onDisappear {
            // タブ切替・ライブラリ復帰時は即時保存
            saveTask?.cancel()
            persist()
            session.flushViewports()  // 保留中のスクロール位置も確定
            toolState.selectedTextObject = nil  // 別タブへ選択を持ち越さない
            undoBridge.onReplaceDrawing = nil   // 差し替え先をこのノートに残さない
        }
    }

    // MARK: - キャンバス本体(ノート形式で実装を分岐)

    /// 通常ノートは GoodNotes 型のページ分割キャンバス(ページ外に描画面が存在しない)、
    /// 無限キャンバスは従来の単一巨大キャンバス。パラメータ・コールバックは同名で揃えてあり、
    /// ハンドラ(handle〜 / 既存メソッド)を両者で共有する。
    @ViewBuilder
    private func canvasContent(geo: GeometryProxy) -> some View {
        if note.canvasNoteType == .paged {
            PagedCanvasRepresentable(
                drawing: $drawing,
                pkTool: toolState.pkTool,
                isSelectMode: toolState.isSelectMode,
                placementTool: toolState.tool.isPlacementTool ? toolState.tool : nil,
                onPlaceObject: { tool, point in placeObjectItem(tool, at: point) },
                isShapeAssistEnabled: toolState.isShapeAssistEnabled,
                backgroundStyle: CanvasBackgroundStyle(rawValue: note.backgroundStyle ?? "") ?? .blank,
                pageColor: note.canvasPageColor,
                pageCount: note.resolvedPageCount,
                isTwoPageLayout: note.isTwoPageLayout,
                isHorizontalScroll: note.isHorizontalScroll,
                isZoomLocked: isZoomLocked,
                hideAdjacentPages: note.hideAdjacentPages,
                objects: Array(objects),
                autoFocusObjectID: autoFocusObjectID,
                initialViewport: session.viewports[note.objectID],
                onDrawingChanged: { handleDrawingChanged() },
                onViewportChanged: { handleViewportChanged($0, viewSize: geo.size) },
                onObjectFrameChanged: { handleObjectFrameChanged($0, frame: $1) },
                onObjectRotationChanged: { handleObjectRotationChanged($0, rotation: $1) },
                onObjectTextChanged: { handleObjectTextChanged($0, text: $1) },
                onObjectTodoChanged: { handleObjectTodoChanged($0, items: $1) },
                onObjectDeleted: { handleObjectDeleted($0) },
                onObjectAutoHeightChanged: { handleObjectAutoHeightChanged($0, height: $1) },
                onTextSelectionChanged: { handleTextSelectionChanged($0) },
                onLassoObjectsMoved: { region, delta in moveObjectsWithLasso(in: region, by: delta) },
                onLassoObjectsDeleted: { region in deleteObjectsWithLasso(in: region) },
                onNoteLinkActivated: { id in openLinkedNote(objectID: id) },
                onObjectShapeEditRequested: { id in requestShapeEdit(id) },
                onObjectTableChanged: { id, payload in handleObjectTableChanged(id, payload: payload) },
                onObjectTableResized: { id, frame, payload in handleObjectTableResized(id, frame: frame, payload: payload) },
                onToggleUserLock: { id in toggleUserLock(objectID: id) },
                onGroupObjects: { ids in groupObjects(ids) },
                onUngroupObjects: { ids in ungroupObjects(ids) },
                onAppendPage: { addPage() },
                onSelectionChanged: { handleSelectionChanged($0) },
                onCanvasReady: { undoBridge.attach($0) },
                scrollToPage: scrollToPage,
                onScrollHandled: { scrollToPage = nil },
                resetZoomRequested: resetZoomRequested,
                onZoomResetHandled: { resetZoomRequested = false }
            )
        } else {
            CanvasRepresentable(
                drawing: $drawing,
                pkTool: toolState.pkTool,
                isSelectMode: toolState.isSelectMode,
                isLassoSelectionMode: toolState.tool == .lasso,
                placementTool: toolState.tool.isPlacementTool ? toolState.tool : nil,
                onPlaceObject: { tool, point in placeObjectItem(tool, at: point) },
                isShapeAssistEnabled: toolState.isShapeAssistEnabled,
                backgroundStyle: CanvasBackgroundStyle(rawValue: note.backgroundStyle ?? "") ?? .blank,
                pageColor: note.canvasPageColor,
                noteType: note.canvasNoteType,
                pageCount: note.resolvedPageCount,
                isTwoPageLayout: note.isTwoPageLayout,
                isHorizontalScroll: note.isHorizontalScroll,
                isZoomLocked: isZoomLocked,
                objects: Array(objects),
                autoFocusObjectID: autoFocusObjectID,
                initialViewport: session.viewports[note.objectID],
                onDrawingChanged: { handleDrawingChanged() },
                onViewportChanged: { handleViewportChanged($0, viewSize: geo.size) },
                onObjectFrameChanged: { handleObjectFrameChanged($0, frame: $1) },
                onObjectRotationChanged: { handleObjectRotationChanged($0, rotation: $1) },
                onObjectTextChanged: { handleObjectTextChanged($0, text: $1) },
                onObjectTodoChanged: { handleObjectTodoChanged($0, items: $1) },
                onObjectDeleted: { handleObjectDeleted($0) },
                onObjectAutoHeightChanged: { handleObjectAutoHeightChanged($0, height: $1) },
                onTextSelectionChanged: { handleTextSelectionChanged($0) },
                onLassoObjectsMoved: { region, delta in moveObjectsWithLasso(in: region, by: delta) },
                onLassoObjectsDeleted: { region in deleteObjectsWithLasso(in: region) },
                onCanvasRebased: { delta in rebaseCanvas(by: delta) },
                onNoteLinkActivated: { id in openLinkedNote(objectID: id) },
                onObjectShapeEditRequested: { id in requestShapeEdit(id) },
                onObjectTableChanged: { id, payload in handleObjectTableChanged(id, payload: payload) },
                onObjectTableResized: { id, frame, payload in handleObjectTableResized(id, frame: frame, payload: payload) },
                onToggleUserLock: { id in toggleUserLock(objectID: id) },
                onGroupObjects: { ids in groupObjects(ids) },
                onUngroupObjects: { ids in ungroupObjects(ids) },
                onConnectObjects: { ids in connectObjects(ids) },
                onAppendPage: { addPage() },
                onSelectionChanged: { handleSelectionChanged($0) },
                onCanvasReady: { undoBridge.attach($0) },
                scrollToPage: scrollToPage,
                onScrollHandled: { scrollToPage = nil },
                resetZoomRequested: resetZoomRequested,
                onZoomResetHandled: { resetZoomRequested = false },
                zoomToFitRequested: zoomToFitRequested,
                onZoomToFitHandled: { zoomToFitRequested = false }
            )
        }
    }

    // MARK: - キャンバス共有ハンドラ(両ノート形式で同一)

    private func handleDrawingChanged() {
        onActivate()          // 描いた側を分割のアクティブ側にする
        scheduleAutoSave()
        undoBridge.refresh()  // 描画のたびに戻る/やり直しボタンの状態を更新
    }

    private func handleViewportChanged(_ viewport: CanvasViewport, viewSize: CGSize) {
        session.updateViewport(viewport, for: note.objectID)
        // ズーム倍率を追跡(左上の倍率表示用)
        if viewport.zoomScale > 0 {
            let rounded = (viewport.zoomScale * 100).rounded()
            let current = (currentZoomScale * 100).rounded()
            if rounded != current { currentZoomScale = viewport.zoomScale }
        }
        // 通常ノートは現在ページを追跡(しおりトグル/目次追加の対象・変化時のみ更新)
        if note.canvasNoteType == .paged, viewSize.width > 0 {
            let layout = PagedLayoutCalculator(pageCount: note.resolvedPageCount,
                                               isTwoPageLayout: note.isTwoPageLayout,
                                               isHorizontalScroll: note.isHorizontalScroll)
            let page: Int
            if layout.scrollsHorizontally {
                page = PagePlanner.currentPage(
                    contentOffsetX: viewport.contentOffset.x, viewWidth: viewSize.width,
                    zoomScale: viewport.zoomScale, layout: layout
                )
            } else {
                // 縦連続スクロール: ビューポート中心Yに最も近いページ
                let centerY = (viewport.contentOffset.y + viewSize.height / 2)
                    / max(0.0001, viewport.zoomScale)
                page = (0..<max(1, layout.pageCount))
                    .min(by: { abs(layout.pageRect($0).midY - centerY) < abs(layout.pageRect($1).midY - centerY) }) ?? 0
            }
            if page != currentPageIndex { currentPageIndex = page }
        }
    }

    private func handleObjectFrameChanged(_ id: NSManagedObjectID, frame: CGRect) {
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
    }

    private func handleObjectRotationChanged(_ id: NSManagedObjectID, rotation: CGFloat) {
        withObject(id) { object in
            let previous = object.rotation
            object.rotation = rotation
            if previous != rotation, let uuid = object.id {
                CanvasObjectUndo.registerRotationChange(
                    objectUUID: uuid, previousRotation: previous,
                    in: undoBridge.activeUndoManager,
                    context: context, bridge: undoBridge
                )
            }
        }
    }

    private func handleObjectTextChanged(_ id: NSManagedObjectID, text: String) {
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
    }

    private func handleObjectTodoChanged(_ id: NSManagedObjectID, items: [TodoItem]) {
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
    }

    private func handleObjectDeleted(_ id: NSManagedObjectID) {
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
    }

    private func handleObjectAutoHeightChanged(_ id: NSManagedObjectID, height: CGFloat) {
        // フォント変更に伴う高さ調整は Undo を積まずに保存(フォント変更 Undo に追従)
        withObject(id) { $0.contentFrame.size.height = height }
    }

    private func handleTextSelectionChanged(_ info: (objectID: NSManagedObjectID, fontSize: CGFloat)?) {
        if let info {
            toolState.selectedTextObject = SelectedTextObject(
                objectID: info.objectID, fontSize: info.fontSize
            )
        } else {
            toolState.selectedTextObject = nil
        }
    }

    private func handleSelectionChanged(_ hasSelection: Bool) {
        // オブジェクトの選択有無を選択モードへ反映(描画停止・単指操作の切替)
        toolState.isSelectMode = hasSelection
    }

    // MARK: - ノートのレイアウト設定(見開き / 横スクロール)

    private var pagedSettingsPopover: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ページ表示")
                .font(.headline)
                .padding(.bottom, 4)
            // スクロール方向: 横=ページめくり(既定) / 縦=GoodNotes 型の縦連続スクロール
            Picker("スクロール方向", selection: Binding(
                get: { note.isHorizontalScroll },
                set: { setLayout(twoPage: note.isTwoPageLayout, horizontal: $0) }
            )) {
                Text("横めくり").tag(true)
                Text("縦スクロール").tag(false)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("picker-scroll-direction")
            Toggle("見開き2ページ表示", isOn: Binding(
                get: { note.isTwoPageLayout },
                set: { setLayout(twoPage: $0, horizontal: note.isHorizontalScroll) }
            ))
            .accessibilityIdentifier("toggle-two-page")
            // 隣のページを隠すは横めくり専用(縦連続では意味を成さない)
            Toggle("隣のページを隠す", isOn: Binding(
                get: { note.hideAdjacentPages },
                set: { setHideAdjacentPages($0) }
            ))
            .accessibilityIdentifier("toggle-hide-adjacent")
            .disabled(!note.isHorizontalScroll)
            Text(note.isHorizontalScroll
                 ? "横スクロール(ページめくり)。最後のページの先へ引っ張るとページが追加されます。"
                 : "縦スクロール(連続)。用紙幅にフィットし、いちばん下の先へ引っ張るとページが追加されます。")
                .font(.caption)
                .foregroundStyle(.secondary)
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

    /// 「隣のページを隠す(完全独立表示モード)」を更新して保存する(キャンバスは note 変化で即反映)。
    private func setHideAdjacentPages(_ value: Bool) {
        note.hideAdjacentPages = value
        note.updatedAt = .now
        do {
            try context.save()
        } catch {
            assertionFailure("設定の保存に失敗: \(error)")
        }
    }

    // MARK: - ページ追加(通常ノート)

    // MARK: - ズーム倍率表示 + ロック(左上フローティング)

    /// 現在のズーム倍率をパーセント表示し、鍵アイコンでロック/解除を切り替える。
    private var zoomIndicator: some View {
        HStack(spacing: 6) {
            Menu {
                Button {
                    resetZoomRequested = true
                } label: {
                    Label("100%に戻す", systemImage: "1.magnifyingglass")
                }
                if note.canvasNoteType == .infinite {
                    Button {
                        zoomToFitRequested = true
                    } label: {
                        Label("全体表示", systemImage: "arrow.up.left.and.down.right.magnifyingglass")
                    }
                    .accessibilityIdentifier("canvas-zoom-fit")
                }
            } label: {
                Text("\(Int((currentZoomScale * 100).rounded()))%")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("canvas-zoom-percent")
            Button {
                isZoomLocked.toggle()
            } label: {
                Image(systemName: isZoomLocked ? "lock.fill" : "lock.open")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(isZoomLocked ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("canvas-zoom-lock")
            .accessibilityLabel(isZoomLocked ? "ズームロック解除" : "ズームロック")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color(.separator), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
    }

    // MARK: - ページナビゲーション(右上フローティング)

    /// 「前へ」「ページ番号」「次へ」を表示する。先頭/末尾では矢印を Disabled にする。
    private var pageIndicator: some View {
        HStack(spacing: 4) {
            Button {
                scrollToPage = max(0, currentPageIndex - 1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 28, height: 28)
            }
            .disabled(currentPageIndex <= 0)
            .buttonStyle(.plain)
            .foregroundStyle(currentPageIndex <= 0 ? .tertiary : .primary)
            .accessibilityIdentifier("canvas-prev-page")

            Text("\(currentPageIndex + 1) / \(note.resolvedPageCount)")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(.primary)
                .frame(minWidth: 44)

            Button {
                scrollToPage = min(note.resolvedPageCount - 1, currentPageIndex + 1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 28, height: 28)
            }
            .disabled(currentPageIndex >= note.resolvedPageCount - 1)
            .buttonStyle(.plain)
            .foregroundStyle(currentPageIndex >= note.resolvedPageCount - 1 ? .tertiary : .primary)
            .accessibilityIdentifier("canvas-next-page")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.thinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color(.separator), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
    }

    // MARK: - ページ削除ボタン(右下フローティング)

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

    // MARK: - ページマネージャー(並び替え・複製・削除)

    /// ページ編集プラン(並び替え/複製/削除)に従って、手書きストローク・オブジェクト・ページ数を
    /// まとめて再配置する。オブジェクトの移動/削除/複製・描画・ページ数を1つの Undo グループにまとめる。
    private func applyPagePlan(_ plan: PagePlan) {
        guard note.canvasNoteType == .paged, plan.oldCount == note.resolvedPageCount else { return }
        let twoPage = note.isTwoPageLayout
        let horizontal = note.isHorizontalScroll
        let oldLayout = PagedLayoutCalculator(pageCount: plan.oldCount, isTwoPageLayout: twoPage, isHorizontalScroll: horizontal)
        let newLayout = PagedLayoutCalculator(pageCount: plan.newCount, isTwoPageLayout: twoPage, isHorizontalScroll: horizontal)
        let manager = undoBridge.activeUndoManager

        // --- オブジェクト: 中心が属するページごとに 複製→移動/削除 を適用 ---
        for object in Array(objects) where !object.isDeleted {
            let center = CGPoint(x: object.contentFrame.midX, y: object.contentFrame.midY)
            guard let page = PagePlanner.pageIndex(of: center, layout: oldLayout) else { continue }
            // 複製元ページなら、先に複製(元の移動前フレームを基準にコピーを作る)
            if page == plan.duplicatedSource,
               let dt = plan.duplicateTranslation(oldLayout: oldLayout, newLayout: newLayout) {
                duplicateObject(object, offset: dt, manager: manager)
            }
            if let t = plan.translation(forOldPage: page, oldLayout: oldLayout, newLayout: newLayout) {
                if t.dx != 0 || t.dy != 0 {
                    let previous = object.contentFrame
                    object.contentFrame = previous.offsetBy(dx: t.dx, dy: t.dy)
                    object.updatedAt = .now
                    if let uuid = object.id {
                        CanvasObjectUndo.registerFrameChange(
                            objectUUID: uuid, previousFrame: previous,
                            in: manager, context: context, bridge: undoBridge
                        )
                    }
                }
            } else {
                // 削除されるページ上のオブジェクト
                if let snapshot = CanvasObjectSnapshot(object: object) {
                    CanvasObjectUndo.registerDelete(
                        snapshot: snapshot, in: manager, context: context, bridge: undoBridge
                    )
                }
                context.delete(object)
            }
        }

        // --- 手書き: ストロークをページごとに 複製→移動/削除 して drawing を作り直す ---
        let drawingBefore = drawing
        var newStrokes: [PKStroke] = []
        for stroke in drawing.strokes {
            let bounds = stroke.renderBounds
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            guard let page = PagePlanner.pageIndex(of: center, layout: oldLayout) else {
                newStrokes.append(stroke)  // 用紙外(通常は無い)はそのまま残す
                continue
            }
            if page == plan.duplicatedSource,
               let dt = plan.duplicateTranslation(oldLayout: oldLayout, newLayout: newLayout) {
                newStrokes.append(translated(stroke, by: dt))
            }
            if let t = plan.translation(forOldPage: page, oldLayout: oldLayout, newLayout: newLayout) {
                newStrokes.append((t.dx == 0 && t.dy == 0) ? stroke : translated(stroke, by: t))
            }
            // translation が nil = 削除ページ → drop
        }
        let drawingAfter = PKDrawing(strokes: newStrokes)

        CanvasObjectUndo.registerPageStructureChange(
            noteID: note.objectID,
            drawingToRestore: drawingBefore, pageCountToRestore: Int16(plan.oldCount),
            drawingToReapply: drawingAfter, pageCountToReapply: Int16(plan.newCount),
            in: manager, context: context, bridge: undoBridge
        )

        // しおり・目次のページ index も同じ写像で追従させる(Undo は積まない簡易対応)
        remapNavigation(plan)

        drawing = drawingAfter
        note.pageCount = Int16(plan.newCount)
        note.updatedAt = .now
        persist()
    }

    /// ページ並び替え/複製/削除に合わせて、しおり・目次のページ index を張り替える。
    private func remapNavigation(_ plan: PagePlan) {
        // しおり(集合)
        var newBookmarks = Set<Int>()
        let oldBookmarks = note.bookmarkedPageSet
        for page in oldBookmarks {
            guard page >= 0, page < plan.oldToNew.count, let mapped = plan.oldToNew[page] else { continue }
            newBookmarks.insert(mapped)
        }
        if let src = plan.duplicatedSource, let dst = plan.duplicatedNewIndex, oldBookmarks.contains(src) {
            newBookmarks.insert(dst)  // 複製元がしおり付きなら複製先も付ける
        }
        if newBookmarks != oldBookmarks { note.bookmarkedPageSet = newBookmarks }

        // 目次(エンティティ)
        let outlines = (note.outlines as? Set<NoteOutline>) ?? []
        var duplicates: [(title: String?, page: Int)] = []
        for outline in outlines {
            let old = Int(outline.pageIndex)
            if let src = plan.duplicatedSource, let dst = plan.duplicatedNewIndex, old == src {
                duplicates.append((outline.title, dst))
            }
            guard old >= 0, old < plan.oldToNew.count else { continue }
            if let mapped = plan.oldToNew[old] {
                if Int16(mapped) != outline.pageIndex { outline.pageIndex = Int16(mapped) }
            } else {
                context.delete(outline)  // 削除ページの目次も消す
            }
        }
        for dup in duplicates {
            let outline = NoteOutline(context: context)
            outline.id = UUID()
            outline.title = dup.title
            outline.pageIndex = Int16(dup.page)
            outline.createdAt = .now
            outline.note = note
        }
    }

    /// ストロークを平行移動した複製(mask も引き継ぐ)
    private func translated(_ s: PKStroke, by v: CGVector) -> PKStroke {
        PKStroke(
            ink: s.ink, path: s.path,
            transform: s.transform.concatenating(CGAffineTransform(translationX: v.dx, y: v.dy)),
            mask: s.mask
        )
    }

    /// オブジェクトを平行移動した位置へ複製し、追加を Undo に登録する。
    private func duplicateObject(_ src: CanvasObject, offset: CGVector, manager: UndoManager?) {
        let copy = CanvasObject(context: context)
        copy.id = UUID()
        copy.kind = src.kind
        copy.text = src.text
        copy.fontSize = src.fontSize
        copy.payload = src.payload
        copy.linkedNoteUUID = src.linkedNoteUUID
        copy.isLocked = src.isLocked
        copy.isUserLocked = src.isUserLocked
        // parentGroupID は複製しない(コピー同士が元グループと混ざるのを避け、非グループで複製する)
        copy.zOrder = src.zOrder
        copy.contentFrame = src.contentFrame.offsetBy(dx: offset.dx, dy: offset.dy)
        copy.createdAt = .now
        copy.updatedAt = .now
        copy.note = note
        // 保存前後で objectID が変わるとレイヤーのビューが作り直されるため先に確定させる
        try? context.obtainPermanentIDs(for: [copy])
        if let uuid = copy.id {
            CanvasObjectUndo.registerInsert(
                objectUUID: uuid, in: manager, context: context, bridge: undoBridge
            )
        }
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

    // MARK: - 表の編集(セルテキスト / 列幅・行高)

    /// セルテキスト変更の保存(payload 変更・Undo あり)。
    private func handleObjectTableChanged(_ id: NSManagedObjectID, payload: TablePayload) {
        withObject(id) { object in
            let previous = object.payload
            object.tablePayload = payload
            if previous != object.payload, let uuid = object.id {
                CanvasObjectUndo.registerPayloadChange(
                    objectUUID: uuid, previousPayload: previous,
                    in: undoBridge.activeUndoManager,
                    context: context, bridge: undoBridge
                )
            }
        }
    }

    /// 列幅/行高ドラッグ確定: 新フレーム + 新 payload を 1つの Undo グループとして保存。
    private func handleObjectTableResized(_ id: NSManagedObjectID, frame: CGRect, payload: TablePayload) {
        withObject(id) { object in
            let previousFrame = object.contentFrame
            let previousPayload = object.payload
            object.contentFrame = frame
            object.tablePayload = payload
            guard let uuid = object.id else { return }
            let manager = undoBridge.activeUndoManager
            // フレームと payload を同一 Undo グループにまとめる。
            manager?.beginUndoGrouping()
            if previousFrame != frame {
                CanvasObjectUndo.registerFrameChange(
                    objectUUID: uuid, previousFrame: previousFrame,
                    in: manager, context: context, bridge: undoBridge
                )
            }
            if previousPayload != object.payload {
                CanvasObjectUndo.registerPayloadChange(
                    objectUUID: uuid, previousPayload: previousPayload,
                    in: manager, context: context, bridge: undoBridge
                )
            }
            manager?.endUndoGrouping()
        }
    }

    // MARK: - 図形の編集(線色 / 塗り / 太さ)

    /// 図形のダブルタップ → 編集ポップオーバーを開く(開いた時点の payload を控える)。
    private func requestShapeEdit(_ id: NSManagedObjectID) {
        guard let object = (try? context.existingObject(with: id)) as? CanvasObject,
              object.objectKind == .shape else { return }
        editingShape = EditingShape(id: id, previousPayload: object.payload)
    }

    /// ポップオーバー操作中のリアルタイム反映(Undo は積まず、閉じるときにまとめて積む)。
    private func updateShapePayload(_ id: NSManagedObjectID, _ payload: ShapePayload) {
        withObject(id) { $0.shapePayload = payload }
    }

    /// ポップオーバーを閉じたとき、開いた時点からの変化を 1つの Undo として登録する。
    private func commitShapeEdit(_ editing: EditingShape) {
        guard let object = (try? context.existingObject(with: editing.id)) as? CanvasObject,
              object.payload != editing.previousPayload, let uuid = object.id else { return }
        CanvasObjectUndo.registerPayloadChange(
            objectUUID: uuid, previousPayload: editing.previousPayload,
            in: undoBridge.activeUndoManager,
            context: context, bridge: undoBridge
        )
        persist()
    }

    // MARK: - 投げ縄でのインクとオブジェクトの連動

    /// 投げ縄で移動したインク領域に中心があるオブジェクトを、同じ差分だけ平行移動する。
    /// ロック(PDF背景など)は対象外。Undo はインク移動と同一グループにまとまる。
    private func moveObjectsWithLasso(in region: CGRect, by delta: CGVector) {
        for object in objects where !object.isDeleted && !object.isMovementLocked
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

    /// オブジェクトのユーザーロックをトグルする(即時保存して南京錠表示に反映)
    private func toggleUserLock(objectID: NSManagedObjectID) {
        guard let object = (try? context.existingObject(with: objectID)) as? CanvasObject else { return }
        onActivate()
        object.isUserLocked.toggle()
        object.updatedAt = .now
        persist()
    }

    /// 選択中の複数オブジェクトへ共通の parentGroupID を付与してグループ化する(Undo なし・即時保存)
    private func groupObjects(_ ids: [NSManagedObjectID]) {
        guard ids.count >= 2 else { return }
        onActivate()
        let groupID = UUID()
        for id in ids {
            guard let object = (try? context.existingObject(with: id)) as? CanvasObject else { continue }
            object.parentGroupID = groupID
            object.updatedAt = .now
        }
        persist()
    }

    /// 選択中の2オブジェクトをコネクタ線で接続する(接続元/先の UUID を保存・Undo あり)。
    /// 端点の移動・リサイズには描画時に都度追従する。端点が消えると自動的に描かれなくなる。
    private func connectObjects(_ ids: [NSManagedObjectID]) {
        guard ids.count == 2 else { return }
        onActivate()
        guard let a = (try? context.existingObject(with: ids[0])) as? CanvasObject,
              let b = (try? context.existingObject(with: ids[1])) as? CanvasObject,
              a.objectKind != .connector, b.objectKind != .connector,
              let aUUID = a.id?.uuidString, let bUUID = b.id?.uuidString else { return }
        let object = CanvasObject(context: context)
        object.id = UUID()
        object.createdAt = .now
        object.updatedAt = .now
        object.note = note
        object.zOrder = (objects.last?.zOrder ?? 0) + 1
        object.kind = CanvasObjectKind.connector.rawValue
        object.connectorPayload = ConnectorPayload(sourceID: aUUID, targetID: bUUID, hasArrow: true)
        object.contentFrame = a.contentFrame.union(b.contentFrame)  // 参考値(実表示は端点から都度算出)
        try? context.obtainPermanentIDs(for: [object])
        persist()
        if let uuid = object.id {
            CanvasObjectUndo.registerInsert(
                objectUUID: uuid, in: undoBridge.activeUndoManager,
                context: context, bridge: undoBridge
            )
        }
    }

    /// グループを解除する(渡された全 ID の parentGroupID を消す)
    private func ungroupObjects(_ ids: [NSManagedObjectID]) {
        onActivate()
        for id in ids {
            guard let object = (try? context.existingObject(with: id)) as? CanvasObject else { continue }
            object.parentGroupID = nil
            object.updatedAt = .now
        }
        persist()
    }

    /// 投げ縄で削除したインク領域に中心があるオブジェクトも削除する(ロックは対象外)。
    private func deleteObjectsWithLasso(in region: CGRect) {
        for object in objects where !object.isDeleted && !object.isMovementLocked
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

    /// 無限キャンバスの原点リベースで座標系全体が平行移動したとき、全オブジェクトの座標にも
    /// 同じ量を反映する。内部座標系の実装詳細でありユーザー操作ではないため、Undo 登録はしない
    /// (見た目は一切動かないので Undo 対象にする必要がない。自動保存デバウンスに任せる)。
    private func rebaseCanvas(by delta: CGVector) {
        for object in objects where !object.isDeleted {
            object.contentFrame = object.contentFrame.offsetBy(dx: delta.dx, dy: delta.dy)
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

    /// テキスト/Todo の配置ツールで、タップ位置にオブジェクトを作成して配置モードを解除する。
    /// タップ配置(テキスト/Todo): オブジェクトを同期生成し、生成した表示ビューを作るための
    /// item を返す。呼び出し側(タップハンドラ)がタッチ文脈内で placeAndFocus し編集を開始する。
    private func placeObjectItem(_ tool: CanvasTool, at point: CGPoint) -> CanvasObjectItem {
        let request: ObjectInsertion
        switch tool {
        case .todo: request = .todo
        case .shape: request = .shape(toolState.pendingShapeType ?? .rectangle)
        case .table:
            let size = toolState.pendingTableSize ?? TableGridSize(rows: 3, cols: 3)
            request = .table(rows: size.rows, cols: size.cols)
        default: request = .text
        }
        // 配置モードを解除して投げ縄(選択モード)へ戻す。
        toolState.tool = .lasso
        toolState.pendingShapeType = nil
        toolState.pendingTableSize = nil
        let object = insert(request, viewSize: .zero, at: point)
        // このパスでは placeAndFocus が同期的に選択・編集開始するので、render 経由の
        // autoFocus は不要(二重フォーカスを避けるためクリアする)。
        autoFocusObjectID = nil
        return CanvasObjectItem(
            id: object.objectID,
            kind: object.objectKind,
            frame: object.contentFrame,
            text: object.text ?? "",
            fontSize: object.fontSize > 0 ? object.fontSize : 24,
            image: nil,
            isLocked: object.isLocked,
            isUserLocked: object.isUserLocked,
            parentGroupID: object.parentGroupID,
            linkTitle: "",
            todoItems: object.objectKind == .todo ? object.todoItems : [],
            shapePayload: object.objectKind == .shape ? object.shapePayload : nil,
            tablePayload: object.objectKind == .table ? object.tablePayload : nil
        )
    }

    @discardableResult
    private func insert(_ request: ObjectInsertion, viewSize: CGSize, at point: CGPoint? = nil) -> CanvasObject {
        let center = point ?? insertionCenter(viewSize: viewSize)
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
        case .shape(let type):
            object.kind = CanvasObjectKind.shape.rawValue
            // デフォルト: 黒線 / 透明塗り / 太さ 2.0、150×150pt をタップ位置中心に配置。
            object.shapePayload = ShapePayload(
                shapeType: type, strokeColor: "#000000FF", fillColor: "#00000000", lineWidth: 2.0
            )
            object.contentFrame = CGRect(x: center.x - 75, y: center.y - 75, width: 150, height: 150)
        case .table(let rows, let cols):
            object.kind = CanvasObjectKind.table.rawValue
            // 列幅 100 / 行高 40 の空の表。タップ位置を中心に配置。
            let table = TablePayload.make(rows: rows, cols: cols)
            object.tablePayload = table
            let size = table.totalSize
            object.contentFrame = CGRect(
                x: center.x - size.width / 2, y: center.y - size.height / 2,
                width: size.width, height: size.height
            )
        case .stickyNote(let color):
            object.kind = CanvasObjectKind.stickyNote.rawValue
            object.text = ""
            object.fontSize = 20
            object.stickyNotePayload = StickyNotePayload(color: color)
            // 正方形に近い付箋(180×180)をタップ/ビューポート中心に配置。
            object.contentFrame = CGRect(x: center.x - 90, y: center.y - 90, width: 180, height: 180)
        }

        // 保存前後で objectID が変わるとレイヤーのビューが作り直されるため先に確定させる
        try? context.obtainPermanentIDs(for: [object])
        // 配置直後はオブジェクトを選択状態にし、そのまま移動・編集できるようにする。
        // 選択は autoFocus(layer.focus)が行い、その通知で選択モードへ切り替わる。
        autoFocusObjectID = object.objectID
        persist()
        if let uuid = object.id {
            CanvasObjectUndo.registerInsert(
                objectUUID: uuid,
                in: undoBridge.activeUndoManager,
                context: context, bridge: undoBridge
            )
        }
        return object
    }

    /// 現在のビューポート中央(コンテンツ空間)。未スクロールなら形式ごとの初期位置
    private func insertionCenter(viewSize: CGSize) -> CGPoint {
        if let viewport = session.viewports[note.objectID], viewport.zoomScale > 0 {
            return CGPoint(
                x: (viewport.contentOffset.x + viewSize.width / 2) / viewport.zoomScale,
                y: (viewport.contentOffset.y + viewSize.height / 2) / viewport.zoomScale
            )
        }
        // ビューポート未取得時のフォールバック: 通常ノートは第1ページの中央、
        // 無限キャンバスはキャンバス中央(50,000pt)。
        if note.canvasNoteType == .paged {
            let layout = PagedLayoutCalculator(
                pageCount: note.resolvedPageCount,
                isTwoPageLayout: note.isTwoPageLayout,
                isHorizontalScroll: note.isHorizontalScroll
            )
            let firstPage = layout.pageRect(0)
            return CGPoint(x: firstPage.midX, y: firstPage.midY)
        }
        let half = DynamicCanvasBounds.initialWorldSize / 2
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
            // 1) オブジェクト → 2) 前面インク(ペン・マーカーとも drawing に含まれる)の順で重ねる
            for object in objects where !object.isDeleted {
                object.drawInThumbnail(pageColor: pageColor)
            }
            // キャンバスと同様、ダークモードでのインク色自動反転を避けて描き出す
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                drawing.image(from: target, scale: scale).draw(in: target)
            }
        }
        return image.jpegData(compressionQuality: 0.7)
    }
}
