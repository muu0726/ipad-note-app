import Testing
import CoreData
import PencilKit
import CoreTransferable
import UIKit
@testable import InfiniteCanvasApp

// MARK: - 投げ縄とオブジェクトの連動

@Suite("投げ縄のインク差分検知")
struct LassoObjectSyncTests {

    /// 指定領域あたりに小さなストロークを作る
    private func stroke(at origin: CGPoint) -> PKStroke {
        let points = (0...10).map { i -> PKStrokePoint in
            PKStrokePoint(
                location: CGPoint(x: origin.x + CGFloat(i) * 4, y: origin.y),
                timeOffset: TimeInterval(i) * 0.01,
                size: CGSize(width: 3, height: 3), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2
            )
        }
        return PKStroke(ink: PKInk(.pen, color: .black),
                        path: PKStrokePath(controlPoints: points, creationDate: Date()))
    }

    /// stroke を平行移動した複製
    private func moved(_ s: PKStroke, by delta: CGVector) -> PKStroke {
        PKStroke(ink: s.ink, path: s.path,
                 transform: CGAffineTransform(translationX: delta.dx, y: delta.dy))
    }

    @Test("ストロークの平行移動を移動として検知する")
    func detectsMove() {
        let a = stroke(at: CGPoint(x: 100, y: 100))
        let b = stroke(at: CGPoint(x: 400, y: 400))  // 動かさない
        let before = PKDrawing(strokes: [a, b])
        let after = PKDrawing(strokes: [moved(a, by: CGVector(dx: 120, dy: 60)), b])

        guard case .moved(let region, let delta) = LassoObjectSync.detect(from: before, to: after) else {
            Issue.record("移動として検知されなかった")
            return
        }
        #expect(abs(delta.dx - 120) < 3 && abs(delta.dy - 60) < 3)
        #expect(region.midX > 90 && region.midX < 160)  // 動かした a の元領域
    }

    @Test("ストロークの削除を削除として検知する")
    func detectsDelete() {
        let a = stroke(at: CGPoint(x: 100, y: 100))
        let b = stroke(at: CGPoint(x: 400, y: 400))
        let before = PKDrawing(strokes: [a, b])
        let after = PKDrawing(strokes: [b])  // a を消す

        guard case .deleted(let region) = LassoObjectSync.detect(from: before, to: after) else {
            Issue.record("削除として検知されなかった")
            return
        }
        #expect(region.midX > 90 && region.midX < 160)
    }

    @Test("ストローク追加(通常描画)は移動・削除と誤検知しない")
    func ignoresPlainAdd() {
        let a = stroke(at: CGPoint(x: 100, y: 100))
        let before = PKDrawing(strokes: [a])
        let after = PKDrawing(strokes: [a, stroke(at: CGPoint(x: 500, y: 500))])
        #expect(LassoObjectSync.detect(from: before, to: after) == nil)
    }

    @Test("同一外接矩形のストロークが複数あっても片方の削除を検知する(回帰防止)")
    func detectsDeleteAmongDuplicateBounds() {
        // renderBounds が完全に一致する2本のストローク(例: ×印の対角線2本を想定)を用意し、
        // 片方だけ削除する。Set の contains 判定(修正前)だと、もう1本が同キーで
        // 生き残っているため削除自体を見逃してしまっていた。
        let a1 = stroke(at: CGPoint(x: 100, y: 100))
        let a2 = stroke(at: CGPoint(x: 100, y: 100))  // a1 と同じ renderBounds
        let b = stroke(at: CGPoint(x: 400, y: 400))
        let before = PKDrawing(strokes: [a1, a2, b])
        let after = PKDrawing(strokes: [a2, b])  // a1 のみ削除、a2(同じ外接矩形)は残す

        guard case .deleted(let region) = LassoObjectSync.detect(from: before, to: after) else {
            Issue.record("同一外接矩形のストロークが残っているために削除が検知されなかった")
            return
        }
        #expect(region.midX > 90 && region.midX < 160)
    }
}

// MARK: - PDF 背景インポート

@Suite("PDF背景インポート")
struct PDFImportTests {

    /// テスト用に pages ページの PDF データを生成する
    private func makePDF(pages: Int) -> Data {
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)  // US Letter
        return UIGraphicsPDFRenderer(bounds: bounds).pdfData { ctx in
            for i in 0..<pages {
                ctx.beginPage()
                ("Page \(i + 1)" as NSString).draw(
                    at: CGPoint(x: 50, y: 50),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 40)]
                )
            }
        }
    }

    @Test("PDFの全ページが背景ロック画像として通常ノートへ展開される")
    func pdfExpandsToLockedPagedNote() throws {
        let context = PersistenceController(inMemory: true).container.viewContext
        let note = try #require(
            LibraryService.createPagedNoteFromPDF(data: makePDF(pages: 3), titled: "資料", folder: nil, in: context)
        )
        #expect(note.canvasNoteType == .paged)
        #expect(note.pageCount == 3)

        let objects = ((note.objects as? Set<CanvasObject>) ?? []).sorted { $0.zOrder < $1.zOrder }
        #expect(objects.count == 3)
        for object in objects {
            #expect(object.objectKind == .image)   // 背景は画像オブジェクト
            #expect(object.isLocked)               // 移動・削除不可
            #expect(object.payload != nil)         // レンダリング画像を保持
        }
        // 各ページの矩形へロック配置されている。
        // 通常ノートは横スクロール固定(NoteCanvasView.swift の isHorizontalScroll 強制)なので、
        // 表示時のページ配置は PagedLayoutCalculator(isHorizontalScroll: true) の横並び矩形になる
        // (PageMetrics.pageRect は縦一列の別レイアウト用で、この検証には使えない)。
        let layout = PagedLayoutCalculator(pageCount: 3, isTwoPageLayout: false, isHorizontalScroll: true)
        for (index, object) in objects.enumerated() {
            let expected = layout.pageRect(index)
            #expect(abs(object.contentFrame.minX - expected.minX) < 0.5)
            #expect(abs(object.contentFrame.minY - expected.minY) < 0.5)
            #expect(object.contentFrame.width == PageMetrics.width)
        }
    }

    @Test("ページの無い/壊れたデータでは nil を返す")
    func invalidPDFReturnsNil() {
        let context = PersistenceController(inMemory: true).container.viewContext
        #expect(LibraryService.createPagedNoteFromPDF(data: Data([0, 1, 2]), titled: "", folder: nil, in: context) == nil)
    }
}

// MARK: - PenToolState

@Suite("ペンツール状態")
struct PenToolStateTests {

    @Test("太さはツールごとの可動域にクランプされる")
    func widthClamping() {
        let state = PenToolState()
        state.tool = .pen
        state.currentWidth = 100
        #expect(state.currentWidth == 20)  // ペンの上限
        state.currentWidth = 0
        #expect(state.currentWidth == 0.5)  // ペンの下限
    }

    @Test("太さはツールごとに独立して記憶される")
    func widthPerTool() {
        let state = PenToolState()
        state.tool = .pen
        state.currentWidth = 5
        state.tool = .eraser
        state.currentWidth = 40
        state.tool = .pen
        #expect(state.currentWidth == 5)
        state.tool = .eraser
        #expect(state.currentWidth == 40)
    }

    @Test("消しゴムは部分消去(ストローク全体が消える vector ではない)")
    func eraserIsBitmap() {
        let state = PenToolState()
        state.tool = .eraser
        let eraser = state.pkTool as? PKEraserTool
        #expect(eraser != nil)
        // 幅指定付き .bitmap は内部的に .fixedWidthBitmap になることがあるため、
        // 「vector(全体消去)でない」ことを検証する
        #expect(eraser?.eraserType != .vector)
    }

    @Test("投げ縄ツールは PKLassoTool を返す")
    func lassoTool() {
        let state = PenToolState()
        state.tool = .lasso
        #expect(state.pkTool is PKLassoTool)
    }

    @Test("色はペンとマーカーで独立、消しゴム・投げ縄では変更不可")
    func colorPerTool() {
        let state = PenToolState()
        state.tool = .pen
        state.setColor(.systemRed)
        state.tool = .marker
        state.setColor(.systemBlue)
        #expect(state.penColor == .systemRed)
        #expect(state.markerColor == .systemBlue)

        state.tool = .lasso
        state.setColor(.systemGreen)
        #expect(state.penColor == .systemRed)  // 変わらない
    }
}

// MARK: - 用紙色

@Suite("用紙色")
struct CanvasPageColorTests {

    @Test("白紙は黒コンテンツ、黒紙は白コンテンツ")
    func contentColorInversion() {
        #expect(CanvasPageColor.white.contentUIColor == .black)
        #expect(CanvasPageColor.black.contentUIColor == .white)
    }

    @Test("rawValue から復元できる(Core Data 保存値との互換)")
    func rawValueRoundTrip() {
        for color in CanvasPageColor.allCases {
            #expect(CanvasPageColor(rawValue: color.rawValue) == color)
        }
    }
}

// MARK: - ドラッグ&ドロップ移動

@Suite("ドラッグ&ドロップ移動")
struct LibraryDragDropTests {

    private func makeContext() -> NSManagedObjectContext {
        PersistenceController(inMemory: true).container.viewContext
    }

    @Test("ドラッグ&ドロップの転送経路(NSItemProvider)で往復できる")
    func transferRoundTripThroughItemProvider() async throws {
        let context = makeContext()
        let note = LibraryService.createNote(titled: "N", folder: nil, in: context)
        let transfer = LibraryItemTransfer(item: .note(note))

        // 実際のドラッグ&ドロップと同じ NSItemProvider 経由でエンコード→デコード
        let provider = NSItemProvider()
        provider.register(transfer)
        let loaded: LibraryItemTransfer? = try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadTransferable(type: LibraryItemTransfer.self) { result in
                continuation.resume(with: result.map { $0 })
            }
        }
        #expect(loaded?.uri == transfer.uri)
        #expect(loaded?.kind == transfer.kind)
    }

    @Test("ノートをフォルダへドロップすると移動する")
    func dropNoteIntoFolder() throws {
        let context = makeContext()
        let folder = LibraryService.createFolder(named: "F", parent: nil, in: context)
        let note = LibraryService.createNote(titled: "N", folder: nil, in: context)

        let transfer = LibraryItemTransfer(item: .note(note))
        let moved = handleLibraryDrop([transfer], into: folder, context: context)
        #expect(moved)
        #expect(note.folder == folder)
    }

    @Test("「すべてのノート」へのドロップでルートへ戻る")
    func dropToRoot() throws {
        let context = makeContext()
        let folder = LibraryService.createFolder(named: "F", parent: nil, in: context)
        let note = LibraryService.createNote(titled: "N", folder: folder, in: context)

        let moved = handleLibraryDrop([LibraryItemTransfer(item: .note(note))], into: nil, context: context)
        #expect(moved)
        #expect(note.folder == nil)
    }

    @Test("フォルダを自分の子孫へドロップしても移動しない(循環参照防止)")
    func dropFolderIntoDescendantIsRejected() throws {
        let context = makeContext()
        let parent = LibraryService.createFolder(named: "親", parent: nil, in: context)
        let child = LibraryService.createFolder(named: "子", parent: parent, in: context)

        let moved = handleLibraryDrop([LibraryItemTransfer(item: .folder(parent))], into: child, context: context)
        #expect(!moved)
        #expect(parent.parent == nil)

        // 自分自身へのドロップも同様
        let ontoSelf = handleLibraryDrop([LibraryItemTransfer(item: .folder(parent))], into: parent, context: context)
        #expect(!ontoSelf)
    }

    @Test("同じ場所へのドロップは何もしない")
    func dropToSamePlaceIsNoop() throws {
        let context = makeContext()
        let folder = LibraryService.createFolder(named: "F", parent: nil, in: context)
        let note = LibraryService.createNote(titled: "N", folder: folder, in: context)

        let moved = handleLibraryDrop([LibraryItemTransfer(item: .note(note))], into: folder, context: context)
        #expect(!moved)
        #expect(note.folder == folder)
    }

    @Test("フォルダを別フォルダへドロップすると子フォルダになる")
    func dropFolderIntoFolder() throws {
        let context = makeContext()
        let a = LibraryService.createFolder(named: "A", parent: nil, in: context)
        let b = LibraryService.createFolder(named: "B", parent: nil, in: context)

        let moved = handleLibraryDrop([LibraryItemTransfer(item: .folder(b))], into: a, context: context)
        #expect(moved)
        #expect(b.parent == a)
    }
}

// MARK: - タブセッション

@Suite("タブセッション")
struct OpenNotesSessionTests {

    private func makeContext() -> NSManagedObjectContext {
        PersistenceController(inMemory: true).container.viewContext
    }

    private func makeNote(_ title: String, in context: NSManagedObjectContext) -> NoteFile {
        let note = NoteFile(context: context)
        note.id = UUID()
        note.title = title
        note.createdAt = .now
        note.updatedAt = .now
        return note
    }

    @Test("同じノートを二度開いても重複タブは作られない")
    func noDuplicateTabs() {
        let context = makeContext()
        let session = OpenNotesSession()
        let note = makeNote("A", in: context)
        session.open(note)
        session.open(note)
        #expect(session.openNotes.count == 1)
        #expect(session.selectedNote == note)
        #expect(session.isCanvasVisible)
    }

    @Test("選択中タブを閉じると右隣(なければ末尾)が選択される")
    func closeSelectsNeighbor() {
        let context = makeContext()
        let session = OpenNotesSession()
        let a = makeNote("A", in: context)
        let b = makeNote("B", in: context)
        let c = makeNote("C", in: context)
        session.open(a)
        session.open(b)
        session.open(c)

        session.selectedNote = b
        session.close(b)
        #expect(session.selectedNote == c)  // 右隣

        session.close(c)
        #expect(session.selectedNote == a)  // 末尾
    }

    @Test("最後のタブを閉じるとキャンバスが非表示になる")
    func closingLastTabHidesCanvas() {
        let context = makeContext()
        let session = OpenNotesSession()
        let note = makeNote("A", in: context)
        session.open(note)
        session.close(note)
        #expect(session.openNotes.isEmpty)
        #expect(!session.isCanvasVisible)
    }

    @Test("ゴミ箱行きのノートのタブは closeTrashedNotes で閉じる")
    func trashedTabsAreClosed() {
        let context = makeContext()
        let session = OpenNotesSession()
        let a = makeNote("A", in: context)
        let b = makeNote("B", in: context)
        session.open(a)
        session.open(b)
        a.isTrashed = true
        session.closeTrashedNotes()
        #expect(session.openNotes == [b])
    }

    @Test("親フォルダがゴミ箱行きのノートのタブも closeTrashedNotes で閉じる")
    func trashedNotesInTrashedFolderAreClosed() {
        let context = makeContext()
        let session = OpenNotesSession()
        let folder = Folder(context: context)
        folder.id = UUID()
        folder.name = "Folder"
        folder.isTrashed = true

        let noteInFolder = makeNote("InFolder", in: context)
        noteInFolder.folder = folder

        let safeNote = makeNote("Safe", in: context)
        session.open(noteInFolder)
        session.open(safeNote)

        session.closeTrashedNotes()
        #expect(session.openNotes == [safeNote])
    }

    @Test("ビューポート(スクロール位置・ズーム)が UserDefaults 経由で復元される")
    func viewportRoundTrip() throws {
        let controller = PersistenceController(inMemory: true)
        let context = controller.container.viewContext
        let note = makeNote("VP", in: context)
        try context.save()  // permanent objectID を確定

        // 保存側: ビューポートを更新して即時フラッシュ
        let saver = OpenNotesSession()
        saver.restore(in: context)
        saver.updateViewport(
            CanvasViewport(contentOffset: CGPoint(x: 123, y: 456), zoomScale: 2.5),
            for: note.objectID
        )
        saver.flushViewports()

        // 復元側(新規プロセス相当)
        let restored = OpenNotesSession()
        restored.restore(in: context)
        let got = restored.viewports[note.objectID]
        #expect(got?.contentOffset.x == 123)
        #expect(got?.contentOffset.y == 456)
        #expect(got?.zoomScale == 2.5)
    }

    @Test("永続化された URI からタブと選択状態を復元できる")
    func restoreFromDefaults() throws {
        let controller = PersistenceController(inMemory: true)
        let context = controller.container.viewContext
        let a = makeNote("A", in: context)
        let b = makeNote("B", in: context)
        try context.save()  // permanent objectID を確定させる

        // 保存側セッション: 2枚開いて A を選択
        let saver = OpenNotesSession()
        saver.restore(in: context)  // isRestored を立てて永続化を有効にする
        saver.open(b)
        saver.open(a)

        // 復元側セッション(新規プロセス相当)
        let restored = OpenNotesSession()
        restored.restore(in: context)
        #expect(restored.openNotes == [b, a])
        #expect(restored.selectedNote == a)
        #expect(restored.isCanvasVisible)
    }
}

// MARK: - ページ並び替え・複製・削除の座標再割り当て

@Suite("ページ編集プラン")
struct PagePlanTests {
    /// 通常ノートの標準(横スクロール・1ページ)。ページピッチ = 幅800 + gap20 = 820(X方向)
    private func layout(_ count: Int) -> PagedLayoutCalculator {
        PagedLayoutCalculator(pageCount: count, isTwoPageLayout: false, isHorizontalScroll: true)
    }

    @Test("並び替え: 先頭を末尾へ移すと写像が回転する")
    func reorderMapping() {
        let plan = PagePlan.reorder(count: 3, from: 0, to: 2)
        // 0→2, 1→0, 2→1
        #expect(plan.oldToNew == [2, 0, 1])
        #expect(plan.newCount == 3)
    }

    @Test("並び替え: 隣接ページの内容がページピッチぶん平行移動する")
    func reorderTranslation() {
        let plan = PagePlan.reorder(count: 2, from: 0, to: 1)  // ページ0と1を入れ替え
        let old = layout(2), new = layout(2)
        let t0 = plan.translation(forOldPage: 0, oldLayout: old, newLayout: new)
        let t1 = plan.translation(forOldPage: 1, oldLayout: old, newLayout: new)
        // ピッチ = 800 + 20 = 820。0は右へ+820、1は左へ-820。
        #expect(t0 == CGVector(dx: 820, dy: 0))
        #expect(t1 == CGVector(dx: -820, dy: 0))
    }

    @Test("削除: 対象ページは破棄、後続は1つ前へ詰める")
    func deleteMapping() {
        let plan = PagePlan.delete(count: 3, at: 1)
        #expect(plan.oldToNew == [0, nil, 1])   // 1は破棄、2は1へ
        #expect(plan.newCount == 2)
        let old = layout(3), new = layout(2)
        #expect(plan.translation(forOldPage: 1, oldLayout: old, newLayout: new) == nil)  // 破棄
        // 旧ページ2(x=1640)は新ページ1(x=820)へ → -820
        #expect(plan.translation(forOldPage: 2, oldLayout: old, newLayout: new) == CGVector(dx: -820, dy: 0))
    }

    @Test("複製: 後続を後ろへずらし、複製先の平行移動を出す")
    func duplicateMapping() {
        let plan = PagePlan.duplicate(count: 2, at: 0)   // ページ0を複製し index1へ挿入
        #expect(plan.oldToNew == [0, 2])                 // 旧1は新2へ
        #expect(plan.newCount == 3)
        #expect(plan.duplicatedSource == 0)
        #expect(plan.duplicatedNewIndex == 1)
        let old = layout(2), new = layout(3)
        // 複製元ページ0(x=0)の内容を複製先ページ1(x=820)へ → +820
        #expect(plan.duplicateTranslation(oldLayout: old, newLayout: new) == CGVector(dx: 820, dy: 0))
        // 旧1(x=820)は新2(x=1640)へ → +820
        #expect(plan.translation(forOldPage: 1, oldLayout: old, newLayout: new) == CGVector(dx: 820, dy: 0))
        // 旧0はそのまま(x=0→x=0)
        #expect(plan.translation(forOldPage: 0, oldLayout: old, newLayout: new) == CGVector(dx: 0, dy: 0))
    }

    @Test("点が属するページを判定する")
    func pageIndexOfPoint() {
        let l = layout(3)
        // ページ0: x[0,800], ページ1: x[820,1620], ページ2: x[1640,2440]、いずれも y[0,1130]
        #expect(PagePlanner.pageIndex(of: CGPoint(x: 400, y: 500), layout: l) == 0)
        #expect(PagePlanner.pageIndex(of: CGPoint(x: 1000, y: 500), layout: l) == 1)
        #expect(PagePlanner.pageIndex(of: CGPoint(x: 2000, y: 500), layout: l) == 2)
        // ページ間のグレー余白(x=810)はどのページにも属さない
        #expect(PagePlanner.pageIndex(of: CGPoint(x: 810, y: 500), layout: l) == nil)
    }

    @Test("ビューポート中心から現在ページを判定する")
    func currentPageFromViewport() {
        let l = layout(3)   // page midX: 400, 1230, 2050
        // 先頭表示(offset 0, 幅800, 等倍)→ 中心 x=400 → ページ0
        #expect(PagePlanner.currentPage(contentOffsetX: 0, viewWidth: 800, zoomScale: 1, layout: l) == 0)
        // ページ1を中央に(中心 x=1230 になる offset=830)→ ページ1
        #expect(PagePlanner.currentPage(contentOffsetX: 830, viewWidth: 800, zoomScale: 1, layout: l) == 1)
        // ページ2付近
        #expect(PagePlanner.currentPage(contentOffsetX: 1650, viewWidth: 800, zoomScale: 1, layout: l) == 2)
    }

    @Test("ページ表示のスクロール offset(収まるなら中央寄せ・超えるなら左マージン)")
    func scrollOffsetForPage() {
        let l = layout(3)
        // 用紙幅(800)< 画面幅(1200) → 中央寄せ: minX*zoom - (viewWidth - pageWidth)/2
        // page1 minX=820, zoom=1 → 820 - (1200-800)/2 = 820 - 200 = 620
        #expect(PagePlanner.scrollOffsetX(toPage: 1, zoomScale: 1, layout: l, margin: 24, viewWidth: 1200) == 620)
        // ズーム2倍で用紙幅(1600)> 画面幅(1200) → 左マージンスナップ: 820*2 - 24 = 1616
        #expect(PagePlanner.scrollOffsetX(toPage: 1, zoomScale: 2, layout: l, margin: 24, viewWidth: 1200) == 1616)
        // 境界: 用紙幅 == 画面幅(800)は「収まる」扱い(中央寄せ・余白0) → 820
        #expect(PagePlanner.scrollOffsetX(toPage: 1, zoomScale: 1, layout: l, margin: 24, viewWidth: 800) == 820)
    }
}

// MARK: - ページサムネイル生成(ページ範囲の切り出し)

@Suite("ページサムネイル生成")
struct PageThumbnailRendererTests {
    /// 指定範囲を横切る太い黒ストローク
    private func stroke(from: CGPoint, to: CGPoint) -> PKStroke {
        let n = 12
        let points = (0...n).map { i -> PKStrokePoint in
            let t = CGFloat(i) / CGFloat(n)
            return PKStrokePoint(
                location: CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t),
                timeOffset: TimeInterval(i) * 0.01,
                size: CGSize(width: 12, height: 12), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2
            )
        }
        return PKStroke(ink: PKInk(.pen, color: .black),
                        path: PKStrokePath(controlPoints: points, creationDate: Date()))
    }

    /// 画像の内側に「白背景でない(=描画された)」暗いピクセルが存在するか。
    /// 端1pxのスケーリング縁アーティファクトを避けるため外周は走査しない。
    private func hasInk(_ image: UIImage) -> Bool {
        guard let cg = image.cgImage else { return false }
        let w = cg.width, h = cg.height
        var pixels = [UInt8](repeating: 255, count: w * h * 4)  // 白で初期化(透明→黒化を防ぐ)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let margin = 2
        var darkCount = 0
        for y in margin..<(h - margin) {
            for x in margin..<(w - margin) {
                let i = (y * w + x) * 4
                if Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2]) < 300 { darkCount += 1 }
            }
        }
        return darkCount > 30   // ノイズ数点では反応しない
    }

    @Test("ページ範囲内のストロークはサムネイルに写り、範囲外は写らない")
    func cropsToPageRect() {
        let layout = PagedLayoutCalculator(pageCount: 2, isTwoPageLayout: false, isHorizontalScroll: true)
        // ページ0(x[0,800]) の内側に黒線を引く
        let drawing = PKDrawing(strokes: [stroke(from: CGPoint(x: 100, y: 200), to: CGPoint(x: 700, y: 900))])

        let page0 = PageThumbnailRenderer.render(
            pageRect: layout.pageRect(0), drawing: drawing, objects: [], pageColor: .white
        )
        let page1 = PageThumbnailRenderer.render(
            pageRect: layout.pageRect(1), drawing: drawing, objects: [], pageColor: .white
        )
        #expect(hasInk(page0))    // ページ0にはインクが写る
        #expect(!hasInk(page1))   // ページ1(x[820,1620])には写らない
    }
}
