import Testing
import CoreData
@testable import InfiniteCanvasApp

// MARK: - アプリ内スプリットビュー(セッション管理)

@Suite("スプリットビュー セッション")
struct SplitViewSessionTests {

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

    @Test("右側で開くと分割が有効になり、現在ノートが左・対象が右になる")
    func openRightStartsSplit() {
        let context = makeContext()
        let session = OpenNotesSession()
        let a = makeNote("A", in: context)
        let b = makeNote("B", in: context)
        session.open(a)          // A を全画面
        session.openRight(b)     // B を右に

        #expect(session.isSplitActive)
        #expect(session.leftNoteID == a.objectID)
        #expect(session.rightNoteID == b.objectID)
        #expect(session.activeSide == .right)
        #expect(session.selectedNote == b)
        #expect(session.openNotes.contains(b))
    }

    @Test("開いているノートが無い/同一ノートでは分割せず通常オープンにフォールバック")
    func openRightFallbacks() {
        let context = makeContext()
        let a = makeNote("A", in: context)

        let s1 = OpenNotesSession()
        s1.openRight(a)          // まだ何も開いていない
        #expect(!s1.isSplitActive)
        #expect(s1.selectedNote == a)

        let s2 = OpenNotesSession()
        s2.open(a)
        s2.openRight(a)          // 選択中と同一
        #expect(!s2.isSplitActive)
    }

    @Test("分割解除で指定ノートの全画面に戻る")
    func closeSplitKeepsNote() {
        let context = makeContext()
        let session = OpenNotesSession()
        let a = makeNote("A", in: context)
        let b = makeNote("B", in: context)
        session.open(a)
        session.openRight(b)

        session.closeSplit(keeping: a)
        #expect(!session.isSplitActive)
        #expect(session.leftNoteID == nil)
        #expect(session.rightNoteID == nil)
        #expect(session.selectedNote == a)
    }

    @Test("分割解除の既定はアクティブ側のノートを残す")
    func closeSplitKeepsActiveSide() {
        let context = makeContext()
        let session = OpenNotesSession()
        let a = makeNote("A", in: context)
        let b = makeNote("B", in: context)
        session.open(a)
        session.openRight(b)     // activeSide = .right (=B)

        session.closeSplit()
        #expect(!session.isSplitActive)
        #expect(session.selectedNote == b)
    }

    @Test("分割中に片側を閉じると、もう片方の全画面へ畳む")
    func closingOneSideCollapses() {
        let context = makeContext()
        let session = OpenNotesSession()
        let a = makeNote("A", in: context)
        let b = makeNote("B", in: context)
        session.open(a)
        session.openRight(b)

        session.close(b)         // 右側(B)を閉じる
        #expect(!session.isSplitActive)
        #expect(session.selectedNote == a)
        #expect(!session.openNotes.contains(b))
    }

    @Test("アクティブ側の切替で選択ノートも切り替わる")
    func activateSideSwitchesSelection() {
        let context = makeContext()
        let session = OpenNotesSession()
        let a = makeNote("A", in: context)
        let b = makeNote("B", in: context)
        session.open(a)
        session.openRight(b)     // active=right(B)

        session.activateSide(.left)
        #expect(session.activeSide == .left)
        #expect(session.selectedNote == a)
    }

    @Test("分割中に open するとアクティブ側のノートが差し替わる")
    func openReplacesActiveSide() {
        let context = makeContext()
        let session = OpenNotesSession()
        let a = makeNote("A", in: context)
        let b = makeNote("B", in: context)
        let c = makeNote("C", in: context)
        session.open(a)
        session.openRight(b)     // active=right
        session.activateSide(.left)  // active=left
        session.open(c)          // 左側へ C

        #expect(session.isSplitActive)
        #expect(session.leftNoteID == c.objectID)
        #expect(session.rightNoteID == b.objectID)
    }

    @Test("分割側がゴミ箱行きになったら分割を畳んで生存側を残す")
    func trashedSplitSideCollapses() {
        let context = makeContext()
        let session = OpenNotesSession()
        let a = makeNote("A", in: context)
        let b = makeNote("B", in: context)
        session.open(a)
        session.openRight(b)

        b.isTrashed = true
        session.closeTrashedNotes()
        #expect(!session.isSplitActive)
        #expect(session.selectedNote == a)
        #expect(!session.openNotes.contains { $0.isTrashed })
    }
}
