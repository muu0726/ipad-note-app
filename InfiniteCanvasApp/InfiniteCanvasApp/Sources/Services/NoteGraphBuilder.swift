import CoreData

/// ノート同士の「ノートリンク」関係を d3.js 用のグラフ構造に変換するヘルパー。
/// - ノード = ゴミ箱以外の全ノート(id / タイトル / 次数)
/// - エッジ = ノート内のノートリンクオブジェクト(kind == "noteLink")が指すリンク元→リンク先
enum NoteGraphBuilder {

    struct GraphData: Codable {
        struct Node: Codable {
            let id: String       // NoteFile.id の UUID 文字列
            let title: String
            let degree: Int      // 接続本数(半径・レイアウトに使用)
        }
        struct Link: Codable {
            let source: String
            let target: String
        }
        var nodes: [Node]
        var links: [Link]
    }

    /// フェッチ済みの配列からグラフを構築する(@FetchRequest から渡してリアクティブに使う)。
    /// - Parameters:
    ///   - notes: ゴミ箱以外の全ノート
    ///   - linkObjects: kind == "noteLink" の全 CanvasObject
    ///   - hideIsolated: true なら接続の無い(孤立)ノードを除外する
    static func build(notes: [NoteFile],
                      linkObjects: [CanvasObject],
                      hideIsolated: Bool) -> GraphData {
        // 有効なノート(id を持ち、ゴミ箱外)のみを対象に id→タイトルの引き当て表を作る
        var titleByID: [UUID: String] = [:]
        for note in notes where !note.isTrashed && !note.isDeleted {
            if let id = note.id { titleByID[id] = note.displayTitle }
        }

        var degree: [UUID: Int] = [:]
        var seenPairs = Set<String>()   // 同一ペアの重複リンクは1本にまとめる
        var links: [GraphData.Link] = []

        for object in linkObjects {
            // リンク元ノートが有効であること
            guard let source = object.note, !source.isTrashed, !source.isDeleted,
                  let sourceID = source.id, titleByID[sourceID] != nil else { continue }
            // リンク先が存在し有効で、自己リンクでないこと
            guard let uuidString = object.linkedNoteUUID,
                  let targetID = UUID(uuidString: uuidString),
                  titleByID[targetID] != nil, targetID != sourceID else { continue }

            let key = sourceID.uuidString + "->" + targetID.uuidString
            guard !seenPairs.contains(key) else { continue }
            seenPairs.insert(key)

            links.append(GraphData.Link(source: sourceID.uuidString, target: targetID.uuidString))
            degree[sourceID, default: 0] += 1
            degree[targetID, default: 0] += 1
        }

        var nodes = titleByID.map { id, title in
            GraphData.Node(id: id.uuidString, title: title, degree: degree[id] ?? 0)
        }
        if hideIsolated {
            nodes = nodes.filter { $0.degree > 0 }
        }
        // 表示の安定のためタイトル順に整列
        nodes.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

        return GraphData(nodes: nodes, links: links)
    }

    /// Core Data から直接フェッチして構築する(監視が不要な単発利用向け)。
    static func build(in context: NSManagedObjectContext, hideIsolated: Bool = false) -> GraphData {
        let noteRequest = NoteFile.fetchRequest()
        noteRequest.predicate = NSPredicate(format: "isTrashed == NO")
        let notes = (try? context.fetch(noteRequest)) ?? []

        let linkRequest = CanvasObject.fetchRequest()
        linkRequest.predicate = NSPredicate(format: "kind == %@", CanvasObjectKind.noteLink.rawValue)
        let linkObjects = (try? context.fetch(linkRequest)) ?? []

        return build(notes: notes, linkObjects: linkObjects, hideIsolated: hideIsolated)
    }

    /// d3.js に流し込む JSON 文字列にシリアライズする({ "nodes": [...], "links": [...] })。
    static func jsonString(_ data: GraphData) -> String {
        guard let encoded = try? JSONEncoder().encode(data),
              let string = String(data: encoded, encoding: .utf8) else {
            return #"{"nodes":[],"links":[]}"#
        }
        return string
    }
}
