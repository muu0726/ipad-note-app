import SwiftUI
import CoreData
import Combine

// MARK: - スナップ(吸着)

struct SnapGuide: Identifiable {
    enum Axis { case horizontal, vertical }
    let id = UUID()
    let axis: Axis
    /// コンテンツ座標での位置(vertical なら x、horizontal なら y)
    let position: CGFloat
}

/// 移動中の矩形を他オブジェクトの端・中心、およびグリッドへ吸着させる(要件④)
enum SnapEngine {
    static func snap(
        _ rect: CGRect,
        targets: [CGRect],
        gridSpacing: CGFloat?,
        tolerance: CGFloat
    ) -> (rect: CGRect, guides: [SnapGuide]) {
        var bestDX: CGFloat?
        var guideX: CGFloat?
        var bestDY: CGFloat?
        var guideY: CGFloat?

        let rectXs = [rect.minX, rect.midX, rect.maxX]
        let rectYs = [rect.minY, rect.midY, rect.maxY]

        for target in targets {
            for tx in [target.minX, target.midX, target.maxX] {
                for rx in rectXs {
                    let delta = tx - rx
                    if abs(delta) <= tolerance, abs(delta) < abs(bestDX ?? .greatestFiniteMagnitude) {
                        bestDX = delta
                        guideX = tx
                    }
                }
            }
            for ty in [target.minY, target.midY, target.maxY] {
                for ry in rectYs {
                    let delta = ty - ry
                    if abs(delta) <= tolerance, abs(delta) < abs(bestDY ?? .greatestFiniteMagnitude) {
                        bestDY = delta
                        guideY = ty
                    }
                }
            }
        }

        // グリッド吸着(方眼・ドット背景時のみ。左上角をグリッド交点へ)
        if let spacing = gridSpacing {
            let gx = (rect.minX / spacing).rounded() * spacing
            let dx = gx - rect.minX
            if abs(dx) <= tolerance, abs(dx) < abs(bestDX ?? .greatestFiniteMagnitude) {
                bestDX = dx
                guideX = gx
            }
            let gy = (rect.minY / spacing).rounded() * spacing
            let dy = gy - rect.minY
            if abs(dy) <= tolerance, abs(dy) < abs(bestDY ?? .greatestFiniteMagnitude) {
                bestDY = dy
                guideY = gy
            }
        }

        var result = rect
        var guides: [SnapGuide] = []
        if let dx = bestDX {
            result.origin.x += dx
            if let gx = guideX { guides.append(SnapGuide(axis: .vertical, position: gx)) }
        }
        if let dy = bestDY {
            result.origin.y += dy
            if let gy = guideY { guides.append(SnapGuide(axis: .horizontal, position: gy)) }
        }
        return (result, guides)
    }
}

// MARK: - オブジェクトレイヤー

/// キャンバスのオブジェクト(テキスト / 画像 / PDF)を描画・操作するレイヤー。
/// PKCanvasView の下に置かれ、手書きストロークは常にオブジェクトの上に見える(単一レイヤー要件)。
/// 選択モード(toolState.tool == .selector)のときだけヒットテストが有効になる。
struct CanvasObjectsOverlay: View {
    @ObservedObject var note: NoteFile
    @ObservedObject var viewportState: CanvasViewportState
    @Binding var selectedObjectID: NSManagedObjectID?
    @Binding var editingObjectID: NSManagedObjectID?
    let isSelectMode: Bool
    let gridSnapEnabled: Bool
    /// (移動前フレーム, 移動量) — ストローク追従に使う
    let onMoveCommitted: (CGRect, CGPoint) -> Void

    @Environment(\.managedObjectContext) private var context
    @FetchRequest private var objects: FetchedResults<CanvasObject>
    @State private var guides: [SnapGuide] = []
    @State private var panStartOffset: CGPoint?

    init(
        note: NoteFile,
        viewportState: CanvasViewportState,
        selectedObjectID: Binding<NSManagedObjectID?>,
        editingObjectID: Binding<NSManagedObjectID?>,
        isSelectMode: Bool,
        gridSnapEnabled: Bool,
        onMoveCommitted: @escaping (CGRect, CGPoint) -> Void
    ) {
        _note = ObservedObject(wrappedValue: note)
        _viewportState = ObservedObject(wrappedValue: viewportState)
        _selectedObjectID = selectedObjectID
        _editingObjectID = editingObjectID
        self.isSelectMode = isSelectMode
        self.gridSnapEnabled = gridSnapEnabled
        self.onMoveCommitted = onMoveCommitted
        _objects = FetchRequest(
            sortDescriptors: [NSSortDescriptor(key: "sortOrder", ascending: true)],
            predicate: NSPredicate(format: "note == %@", note),
            animation: .default)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // 空白部分: タップで選択解除、ドラッグでスクロール(選択モード中の代替スクロール)
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedObjectID = nil
                    editingObjectID = nil
                }
                .gesture(panGesture)

            ForEach(objects) { object in
                CanvasObjectItemView(
                    object: object,
                    viewportState: viewportState,
                    isSelected: selectedObjectID == object.objectID,
                    isEditing: editingObjectID == object.objectID,
                    isSelectMode: isSelectMode,
                    snapTargets: snapTargets(excluding: object),
                    gridSpacing: gridSnapEnabled ? 40 : nil,
                    onSelect: {
                        selectedObjectID = object.objectID
                        if editingObjectID != object.objectID { editingObjectID = nil }
                    },
                    onBeginEditing: { editingObjectID = object.objectID },
                    onGuidesChanged: { guides = $0 },
                    onMoveCommitted: onMoveCommitted,
                    onDelete: { delete(object) }
                )
            }

            guideLines
        }
        .allowsHitTesting(isSelectMode)
    }

    // MARK: - 空白ドラッグでのスクロール

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if panStartOffset == nil { panStartOffset = viewportState.offset }
                if let start = panStartOffset {
                    viewportState.externalOffsetRequest = CGPoint(
                        x: start.x - value.translation.width,
                        y: start.y - value.translation.height)
                }
            }
            .onEnded { _ in panStartOffset = nil }
    }

    // MARK: - スナップガイド線

    private var guideLines: some View {
        ZStack {
            ForEach(guides) { guide in
                Path { path in
                    switch guide.axis {
                    case .vertical:
                        let x = guide.position * viewportState.zoom - viewportState.offset.x
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: viewportState.viewSize.height))
                    case .horizontal:
                        let y = guide.position * viewportState.zoom - viewportState.offset.y
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: viewportState.viewSize.width, y: y))
                    }
                }
                .stroke(Color.yellow, lineWidth: 1.5)
            }
        }
        .allowsHitTesting(false)
    }

    private func snapTargets(excluding object: CanvasObject) -> [CGRect] {
        objects.filter { $0 != object }.map(\.frame)
    }

    private func delete(_ object: CanvasObject) {
        if selectedObjectID == object.objectID { selectedObjectID = nil }
        if editingObjectID == object.objectID { editingObjectID = nil }
        context.delete(object)
        try? context.save()
    }
}

// MARK: - 個々のオブジェクト

private struct CanvasObjectItemView: View {
    @ObservedObject var object: CanvasObject
    @ObservedObject var viewportState: CanvasViewportState
    let isSelected: Bool
    let isEditing: Bool
    let isSelectMode: Bool
    let snapTargets: [CGRect]
    let gridSpacing: CGFloat?
    let onSelect: () -> Void
    let onBeginEditing: () -> Void
    let onGuidesChanged: ([SnapGuide]) -> Void
    let onMoveCommitted: (CGRect, CGPoint) -> Void
    let onDelete: () -> Void

    @Environment(\.managedObjectContext) private var context
    /// ドラッグ / リサイズ中の一時フレーム(コンテンツ座標)
    @State private var dragRect: CGRect?
    @State private var gestureStartFrame: CGRect?

    private enum Corner { case topLeading, topTrailing, bottomLeading, bottomTrailing }

    private var contentRect: CGRect { dragRect ?? object.frame }
    private var screenRect: CGRect { viewportState.screenRect(fromContent: contentRect) }
    private var showsChrome: Bool { isSelected && isSelectMode }

    var body: some View {
        objectContent
            .frame(width: max(screenRect.width, 4), height: max(screenRect.height, 4))
            .overlay {
                if showsChrome {
                    RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(Color.accentColor, lineWidth: 1.5)
                }
            }
            .overlay(alignment: .topLeading) { resizeHandle(.topLeading) }
            .overlay(alignment: .topTrailing) { resizeHandle(.topTrailing) }
            .overlay(alignment: .bottomLeading) { resizeHandle(.bottomLeading) }
            .overlay(alignment: .bottomTrailing) { resizeHandle(.bottomTrailing) }
            .overlay(alignment: .topTrailing) { deleteButton }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                onSelect()
                if object.objectType == .text || object.objectType == .pdf {
                    onBeginEditing()
                }
            }
            .onTapGesture { onSelect() }
            .gesture(moveGesture, including: isEditing ? .subviews : .all)
            .position(x: screenRect.midX, y: screenRect.midY)
    }

    @ViewBuilder
    private var objectContent: some View {
        switch object.objectType {
        case .text:
            TextObjectContent(object: object, isEditing: isEditing, zoom: viewportState.zoom)
        case .image:
            ImageObjectContent(object: object)
        case .pdf:
            PDFObjectContent(data: object.content, isInteractive: isEditing)
        case nil:
            Rectangle().fill(Color(.secondarySystemBackground))
        }
    }

    // MARK: - 移動(スナップ付き)

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                guard isSelectMode else { return }
                if gestureStartFrame == nil {
                    gestureStartFrame = object.frame
                    onSelect()
                }
                guard let start = gestureStartFrame else { return }
                let proposed = start.offsetBy(
                    dx: value.translation.width / viewportState.zoom,
                    dy: value.translation.height / viewportState.zoom)
                let result = SnapEngine.snap(
                    proposed,
                    targets: snapTargets,
                    gridSpacing: gridSpacing,
                    tolerance: 8 / viewportState.zoom)
                dragRect = result.rect
                onGuidesChanged(result.guides)
            }
            .onEnded { _ in
                defer {
                    dragRect = nil
                    gestureStartFrame = nil
                    onGuidesChanged([])
                }
                guard let old = gestureStartFrame, let final = dragRect else { return }
                object.frame = final
                object.updatedAt = .now
                try? context.save()
                // 旧フレーム内のストロークを追従移動させる(単一レイヤー要件)
                onMoveCommitted(old, CGPoint(x: final.minX - old.minX, y: final.minY - old.minY))
            }
    }

    // MARK: - リサイズハンドル(四隅)

    @ViewBuilder
    private func resizeHandle(_ corner: Corner) -> some View {
        if showsChrome && !isEditing {
            let isLeading = (corner == .topLeading || corner == .bottomLeading)
            let isTop = (corner == .topLeading || corner == .topTrailing)
            Circle()
                .fill(Color(.systemBackground))
                .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 1.5))
                .frame(width: 14, height: 14)
                .offset(x: isLeading ? -7 : 7, y: isTop ? -7 : 7)
                .gesture(resizeGesture(corner))
        }
    }

    private func resizeGesture(_ corner: Corner) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if gestureStartFrame == nil { gestureStartFrame = object.frame }
                guard let start = gestureStartFrame else { return }
                let dx = value.translation.width / viewportState.zoom
                let dy = value.translation.height / viewportState.zoom
                let minSize: CGFloat = 40
                var rect = start
                switch corner {
                case .topLeading:
                    rect.origin.x = min(start.minX + dx, start.maxX - minSize)
                    rect.origin.y = min(start.minY + dy, start.maxY - minSize)
                    rect.size.width = start.maxX - rect.origin.x
                    rect.size.height = start.maxY - rect.origin.y
                case .topTrailing:
                    rect.origin.y = min(start.minY + dy, start.maxY - minSize)
                    rect.size.width = max(start.width + dx, minSize)
                    rect.size.height = start.maxY - rect.origin.y
                case .bottomLeading:
                    rect.origin.x = min(start.minX + dx, start.maxX - minSize)
                    rect.size.width = start.maxX - rect.origin.x
                    rect.size.height = max(start.height + dy, minSize)
                case .bottomTrailing:
                    rect.size.width = max(start.width + dx, minSize)
                    rect.size.height = max(start.height + dy, minSize)
                }
                dragRect = rect
            }
            .onEnded { _ in
                defer {
                    dragRect = nil
                    gestureStartFrame = nil
                }
                guard let final = dragRect else { return }
                object.frame = final
                object.updatedAt = .now
                try? context.save()
            }
    }

    // MARK: - 削除ボタン

    @ViewBuilder
    private var deleteButton: some View {
        if showsChrome && !isEditing {
            Button(action: onDelete) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .red)
                    .background(Circle().fill(.white))
            }
            .offset(x: 20, y: -20)
        }
    }
}
