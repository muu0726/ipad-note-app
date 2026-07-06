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
        // 各ページのY座標範囲へロック配置されている
        for (index, object) in objects.enumerated() {
            #expect(abs(object.contentFrame.minY - PageMetrics.pageRect(index).minY) < 0.5)
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
