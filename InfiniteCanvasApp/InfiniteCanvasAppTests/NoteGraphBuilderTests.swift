import Testing
import CoreData
@testable import InfiniteCanvasApp

// MARK: - グラフビュー用データ抽出

@Suite("ノートグラフ構築")
struct NoteGraphBuilderTests {

    private func makeContext() -> NSManagedObjectContext {
        PersistenceController(inMemory: true).container.viewContext
    }

    /// note にリンクカード(kind == noteLink)を1枚追加して target を指す
    @discardableResult
    private func addLink(from source: NoteFile, to target: NoteFile,
                         in context: NSManagedObjectContext) -> CanvasObject {
        let object = CanvasObject(context: context)
        object.id = UUID()
        object.kind = CanvasObjectKind.noteLink.rawValue
        object.linkedNoteUUID = target.id?.uuidString
        object.note = source
        object.createdAt = .now
        object.updatedAt = .now
        return object
    }

    private func allLinkObjects(in context: NSManagedObjectContext) -> [CanvasObject] {
        let request = CanvasObject.fetchRequest()
        request.predicate = NSPredicate(format: "kind == %@", CanvasObjectKind.noteLink.rawValue)
        return (try? context.fetch(request)) ?? []
    }

    @Test("ノートがノード、ノートリンクがエッジになる")
    func nodesAndEdges() {
        let context = makeContext()
        let a = LibraryService.createNote(titled: "A", folder: nil, in: context)
        let b = LibraryService.createNote(titled: "B", folder: nil, in: context)
        addLink(from: a, to: b, in: context)

        let graph = NoteGraphBuilder.build(
            notes: [a, b], linkObjects: allLinkObjects(in: context), hideIsolated: false
        )
        #expect(graph.nodes.count == 2)
        #expect(graph.links.count == 1)
        let link = try! #require(graph.links.first)
        #expect(link.source == a.id?.uuidString)
        #expect(link.target == b.id?.uuidString)
        // 次数はリンクの両端で1ずつ
        #expect(graph.nodes.allSatisfy { $0.degree == 1 })
    }

    @Test("ゴミ箱のノートと、そこへ向かうリンクは除外される")
    func excludesTrashed() {
        let context = makeContext()
        let a = LibraryService.createNote(titled: "A", folder: nil, in: context)
        let b = LibraryService.createNote(titled: "B", folder: nil, in: context)
        addLink(from: a, to: b, in: context)
        b.isTrashed = true   // リンク先をゴミ箱へ

        let graph = NoteGraphBuilder.build(
            notes: [a], linkObjects: allLinkObjects(in: context), hideIsolated: false
        )
        #expect(graph.nodes.map(\.id) == [a.id?.uuidString])
        #expect(graph.links.isEmpty)   // ダングリングリンクは張らない
    }

    @Test("同一ペアへの複数リンクは1本にまとめる")
    func deduplicatesParallelLinks() {
        let context = makeContext()
        let a = LibraryService.createNote(titled: "A", folder: nil, in: context)
        let b = LibraryService.createNote(titled: "B", folder: nil, in: context)
        addLink(from: a, to: b, in: context)
        addLink(from: a, to: b, in: context)   // 2枚目のカード(同じ相手)

        let graph = NoteGraphBuilder.build(
            notes: [a, b], linkObjects: allLinkObjects(in: context), hideIsolated: false
        )
        #expect(graph.links.count == 1)
    }

    @Test("自己リンクは無視する")
    func ignoresSelfLink() {
        let context = makeContext()
        let a = LibraryService.createNote(titled: "A", folder: nil, in: context)
        addLink(from: a, to: a, in: context)

        let graph = NoteGraphBuilder.build(
            notes: [a], linkObjects: allLinkObjects(in: context), hideIsolated: false
        )
        #expect(graph.links.isEmpty)
        #expect(graph.nodes.first?.degree == 0)
    }

    @Test("hideIsolated で孤立ノードを除外できる")
    func hidesIsolatedNodes() {
        let context = makeContext()
        let a = LibraryService.createNote(titled: "A", folder: nil, in: context)
        let b = LibraryService.createNote(titled: "B", folder: nil, in: context)
        let lonely = LibraryService.createNote(titled: "C", folder: nil, in: context)
        addLink(from: a, to: b, in: context)

        let all = NoteGraphBuilder.build(
            notes: [a, b, lonely], linkObjects: allLinkObjects(in: context), hideIsolated: false
        )
        #expect(all.nodes.count == 3)

        let connected = NoteGraphBuilder.build(
            notes: [a, b, lonely], linkObjects: allLinkObjects(in: context), hideIsolated: true
        )
        #expect(connected.nodes.count == 2)
        #expect(!connected.nodes.contains { $0.title == "C" })
    }

    @Test("出力は d3 が読める JSON 文字列にシリアライズされる")
    func serializesToJSON() throws {
        let context = makeContext()
        let a = LibraryService.createNote(titled: "A", folder: nil, in: context)
        let b = LibraryService.createNote(titled: "B", folder: nil, in: context)
        addLink(from: a, to: b, in: context)

        let graph = NoteGraphBuilder.build(
            notes: [a, b], linkObjects: allLinkObjects(in: context), hideIsolated: false
        )
        let json = NoteGraphBuilder.jsonString(graph)
        let decoded = try JSONDecoder().decode(
            NoteGraphBuilder.GraphData.self, from: Data(json.utf8)
        )
        #expect(decoded.nodes.count == 2)
        #expect(decoded.links.count == 1)
    }
}
