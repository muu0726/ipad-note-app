import Testing
import Foundation
@testable import InfiniteCanvasApp

// MARK: - 表 payload

@Suite("TablePayload")
struct TablePayloadTests {

    @Test("make は指定サイズの空の表を作る(列幅100 / 行高40)")
    func makeBuildsEmptyTable() {
        let t = TablePayload.make(rows: 3, cols: 4)
        #expect(t.rowCount == 3)
        #expect(t.columnCount == 4)
        #expect(t.columnWidths == [100, 100, 100, 100])
        #expect(t.rowHeights == [40, 40, 40])
        #expect(t.cells.isEmpty)
        #expect(t.totalSize == CGSize(width: 400, height: 120))
    }

    @Test("JSON で往復できる(セルテキスト・可変列幅つき)")
    func roundTrips() throws {
        var t = TablePayload.make(rows: 2, cols: 2)
        t.columnWidths = [120, 80]
        t.rowHeights = [50, 30]
        t.cells = [TableCell(row: 0, col: 1, text: "A"), TableCell(row: 1, col: 0, text: "B")]
        let data = try JSONEncoder().encode(t)
        let decoded = try JSONDecoder().decode(TablePayload.self, from: data)
        #expect(decoded == t)
        #expect(decoded.totalSize == CGSize(width: 200, height: 80))
    }

    @Test("text(row:col:) は該当セル/未設定セルを正しく返す")
    func textLookup() {
        var t = TablePayload.make(rows: 2, cols: 2)
        t.cells = [TableCell(row: 1, col: 1, text: "X")]
        #expect(t.text(row: 1, col: 1) == "X")
        #expect(t.text(row: 0, col: 0) == "")
    }
}
