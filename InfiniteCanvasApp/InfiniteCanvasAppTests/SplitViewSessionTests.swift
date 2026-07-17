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

    @Test("右へ移したノートだけが右の所属になり、残りは左のまま(タブを複製しない)")
    func openRightAssignsOnlyMovedNoteToRight() {
        let context = makeContext()
        let session = OpenNotesSession()
        let a = makeNote("A", in: context)
        let b = makeNote("B", in: context)
        let c = makeNote("C", in: context)
        session.open(a)
        session.open(b)
        session.open(c)          // タブ A/B/C、全画面 C
        session.openRight(a)     // A を右へ

        #expect(session.notes(on: .right).map(\.objectID) == [a.objectID])
        #expect(session.notes(on: .left).map(\.objectID) == [b.objectID, c.objectID])
        // 複製されない: A は左には出ない
        #expect(!session.notes(on: .left).contains(a))
    }

    @Test("分割中、既存の左タブをライブラリ経由で開いても左に留まる(右へ吸い寄せない)")
    func reopeningExistingTabKeepsItsSide() {
        let context = makeContext()
        let session = OpenNotesSession()
        let a = makeNote("A", in: context)
        let b = makeNote("B", in: context)
        session.open(a)
        session.openRight(b)     // left=[A], right=[B], active=right

        // 「すべてのノート」から左タブ A を開く操作(= session.open)
        session.open(a)
        #expect(session.isSplitActive)
        #expect(session.activeSide == .left)                 // A のいる左がアクティブに
        #expect(session.notes(on: .left).contains(a))        // A は左のまま
        #expect(!session.notes(on: .right).contains(a))      // 右へ移動していない
        #expect(session.leftNoteID == a.objectID)
        #expect(session.rightNoteID == b.objectID)           // 右はそのまま
    }

    @Test("分割中に左タブを繰り返しライブラリ経由で開いても右へ集まらない")
    func repeatedLibraryOpensDoNotGatherRight() {
        let context = makeContext()
        let session = OpenNotesSession()
        let a = makeNote("A", in: context)
        let b = makeNote("B", in: context)
        let c = makeNote("C", in: context)
        session.open(a)
        session.open(b)          // タブ A/B
        session.openRight(c)     // left=[A,B], right=[C], active=right

        // すべてのノートから A→B→A… と何度も開く
        session.open(a)
        session.open(b)
        session.open(a)

        #expect(session.notes(on: .left).map(\.objectID) == [a.objectID, b.objectID])
        #expect(session.notes(on: .right).map(\.objectID) == [c.objectID])
    }

    @Test("分割中に新規ノートをライブラリ経由で開くとアクティブ側へ載る")
    func openingNewNoteInSplitGoesToActiveSide() {
        let context = makeContext()
        let session = OpenNotesSession()
        let a = makeNote("A", in: context)
        let b = makeNote("B", in: context)
        let d = makeNote("D", in: context)  // まだ開いていない新規
        session.open(a)
        session.openRight(b)     // active=right

        session.open(d)          // 新規タブ
        #expect(session.notes(on: .right).map(\.objectID) == [b.objectID, d.objectID])
        #expect(session.notes(on: .left).map(\.objectID) == [a.objectID])
        #expect(session.selectedNote == d)
    }

    @Test("分割中に表示中タブを閉じると同じ側の別タブへ切替(側にタブが残る限り分割維持)")
    func closingShownTabSwitchesWithinSide() {
        let context = makeContext()
        let session = OpenNotesSession()
        let a = makeNote("A", in: context)
        let b = makeNote("B", in: context)
        let c = makeNote("C", in: context)
        session.open(a)
        session.open(b)          // 左に A,B
        session.openRight(c)     // right=[C], active=right, 表示 C
        session.activateSide(.left)  // 左をアクティブ、表示 B(leftNoteID=B)

        session.close(b)         // 左の表示中タブ B を閉じる
        #expect(session.isSplitActive)                       // まだ左に A が残るので分割維持
        #expect(session.notes(on: .left).map(\.objectID) == [a.objectID])
        #expect(session.leftNoteID == a.objectID)
        #expect(session.selectedNote == a)
    }

    @Test("分割中に片側の最後のタブを閉じると分割解除して他方を残す")
    func closingLastTabOnSideCollapses() {
        let context = makeContext()
        let session = OpenNotesSession()
        let a = makeNote("A", in: context)
        let b = makeNote("B", in: context)
        session.open(a)
        session.openRight(b)     // left=[A], right=[B]

        session.close(a)         // 左の唯一のタブを閉じる
        #expect(!session.isSplitActive)
        #expect(session.selectedNote == b)
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
