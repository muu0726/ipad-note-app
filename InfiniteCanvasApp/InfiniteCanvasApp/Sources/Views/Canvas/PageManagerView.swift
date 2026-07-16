import SwiftUI
import PencilKit
import UniformTypeIdentifiers

/// 通常ノート(paged)の全ページをサムネイル格子で一覧し、並び替え・複製・削除を行うシート。
/// 実際のデータ変更(座標再割り当て・Undo)は呼び出し側(NoteCanvasView.applyPagePlan)が担う。
struct PageManagerView: View {
    @ObservedObject var note: NoteFile
    /// 現在の手書き描画(操作後に読み直せるようクロージャで受け取る)
    let drawing: () -> PKDrawing
    /// 現在のオブジェクト(main コンテキストのマネージドオブジェクト)
    let objects: () -> [CanvasObject]
    let onReorder: (Int, Int) -> Void
    let onDuplicate: (Int) -> Void
    let onDelete: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var thumbnails: [Int: UIImage] = [:]
    @State private var dragging: Int?

    private var pageCount: Int { note.resolvedPageCount }
    private var layout: PagedLayoutCalculator {
        PagedLayoutCalculator(pageCount: pageCount, isTwoPageLayout: note.isTwoPageLayout, isHorizontalScroll: true)
    }

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 24)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 24) {
                    ForEach(0..<pageCount, id: \.self) { index in
                        pageCell(index)
                    }
                }
                .padding(24)
            }
            .navigationTitle("ページ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }
                        .accessibilityIdentifier("page-manager-done")
                }
            }
        }
        .task { await regenerate() }
        .onChange(of: pageCount) { _, _ in Task { await regenerate() } }
    }

    // MARK: - セル

    private func pageCell(_ index: Int) -> some View {
        VStack(spacing: 8) {
            thumbnailImage(index)
                .frame(maxWidth: .infinity)
                .aspectRatio(PageMetrics.width / PageMetrics.height, contentMode: .fit)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(.separator), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
            Text("\(index + 1)")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("page-cell-\(index)")
        .contextMenu { cellMenu(index) }
        .onDrag {
            dragging = index
            return NSItemProvider(object: String(index) as NSString)
        }
        .onDrop(of: [UTType.plainText], isTargeted: nil) { _ in
            defer { dragging = nil }
            guard let from = dragging, from != index else { return false }
            perform { onReorder(from, index) }
            return true
        }
    }

    @ViewBuilder
    private func thumbnailImage(_ index: Int) -> some View {
        if let image = thumbnails[index] {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            ProgressView()
        }
    }

    @ViewBuilder
    private func cellMenu(_ index: Int) -> some View {
        Button {
            perform { onDuplicate(index) }
        } label: { Label("複製", systemImage: "plus.square.on.square") }
        .accessibilityIdentifier("page-duplicate-\(index)")

        if index > 0 {
            Button {
                perform { onReorder(index, index - 1) }
            } label: { Label("左へ移動", systemImage: "arrow.left") }
            .accessibilityIdentifier("page-move-left-\(index)")
        }
        if index < pageCount - 1 {
            Button {
                perform { onReorder(index, index + 1) }
            } label: { Label("右へ移動", systemImage: "arrow.right") }
            .accessibilityIdentifier("page-move-right-\(index)")
        }
        if pageCount > 1 {
            Button(role: .destructive) {
                perform { onDelete(index) }
            } label: { Label("このページを削除", systemImage: "trash") }
            .accessibilityIdentifier("page-delete-\(index)")
        }
    }

    // MARK: - 操作 + サムネイル再生成

    /// 変更操作を実行し、変更後のデータでサムネイルを作り直す。
    private func perform(_ action: () -> Void) {
        action()
        Task { await regenerate() }
    }

    /// 全ページのサムネイルを生成する(Core Data 参照のためメインアクター上で逐次実行)。
    @MainActor
    private func regenerate() async {
        let currentDrawing = drawing()
        let currentObjects = objects()
        let color = note.canvasPageColor
        let lay = layout
        let count = pageCount
        var result: [Int: UIImage] = [:]
        for i in 0..<count {
            result[i] = PageThumbnailRenderer.render(
                pageRect: lay.pageRect(i),
                drawing: currentDrawing,
                objects: currentObjects,
                pageColor: color
            )
            thumbnails = result   // 生成でき次第そのページを表示
            await Task.yield()
        }
        thumbnails = result
    }
}
