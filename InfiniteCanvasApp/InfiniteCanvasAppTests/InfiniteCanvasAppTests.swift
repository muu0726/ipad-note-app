import Testing
import CoreData
import PencilKit
@testable import InfiniteCanvasApp

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
