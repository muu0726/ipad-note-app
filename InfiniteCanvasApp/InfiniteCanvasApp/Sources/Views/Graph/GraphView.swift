import SwiftUI
import CoreData

/// 全ノートの「ノートリンク」関係を力学ネットワークで可視化する画面(Obsidian 風グラフビュー)。
/// ノードをタップすると該当ノートをタブで開く。上部で検索と孤立ノートの表示切替ができる。
struct GraphView: View {
    @EnvironmentObject private var session: OpenNotesSession
    @Environment(\.managedObjectContext) private var context

    // Core Data を監視してグラフを自動更新する
    @FetchRequest(
        entity: NoteFile.entity(),
        sortDescriptors: [NSSortDescriptor(keyPath: \NoteFile.updatedAt, ascending: false)],
        predicate: NSPredicate(format: "isTrashed == NO")
    ) private var notes: FetchedResults<NoteFile>

    @FetchRequest(
        entity: CanvasObject.entity(),
        sortDescriptors: [],
        predicate: NSPredicate(format: "kind == %@", CanvasObjectKind.noteLink.rawValue)
    ) private var linkObjects: FetchedResults<CanvasObject>

    @State private var search = ""
    @State private var hideIsolated = false

    private var graph: NoteGraphBuilder.GraphData {
        NoteGraphBuilder.build(
            notes: Array(notes),
            linkObjects: Array(linkObjects),
            hideIsolated: hideIsolated
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            GraphWebView(
                json: NoteGraphBuilder.jsonString(graph),
                search: search,
                onOpenNote: openNote
            )
            .background(Color(.systemGroupedBackground))
            .accessibilityIdentifier("graph-webview")
        }
        .navigationTitle("グラフビュー")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - 上部コントロール

    private var controls: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("ノートを検索", text: $search)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("graph-search")
                if !search.isEmpty {
                    Button {
                        search = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color(.secondarySystemBackground), in: Capsule())
            .frame(maxWidth: 320)

            Toggle(isOn: $hideIsolated) {
                Label("孤立を隠す", systemImage: "circle.dashed")
            }
            .toggleStyle(.button)
            .accessibilityIdentifier("graph-hide-isolated")

            Spacer()

            Text("\(graph.nodes.count) ノート ・ \(graph.links.count) リンク")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("graph-counts")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - ノードタップ → ノートを開く

    private func openNote(_ id: UUID) {
        let request = NoteFile.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        guard let note = (try? context.fetch(request))?.first,
              !note.isTrashed, !note.isDeleted else { return }
        session.open(note)
    }
}
