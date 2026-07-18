import SwiftUI
import CoreData
import UniformTypeIdentifiers

/// サイドバーで選択できる対象
enum SidebarSelection: Hashable {
    case allNotes
    case graph
    case trash
    case folder(Folder)
}

struct RootView: View {
    @EnvironmentObject private var session: OpenNotesSession
    @Environment(\.managedObjectContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var actions = LibraryActionCoordinator()
    @State private var selection: SidebarSelection? = .allNotes
    /// サイドバーの表示状態。ノート編集中は畳んでキャンバスへ幅を明け渡す
    /// (横向きレギュラー幅では既定でサイドバーが常時出てキャンバス左側・分割の左ペインを覆い、
    ///  ディテール幅が狭まってツールバー右側が見切れる問題を避ける)。
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selection: $selection, actions: actions)
        } detail: {
            detailContent
        }
        .libraryActionDialogs(actions)
        .onAppear {
            // 前回開いていたタブ・選択中ノートを復元(初回のみ有効)
            session.restore(in: context)
            columnVisibility = sidebarVisibility(forCanvas: session.isCanvasVisible)
        }
        .onChange(of: scenePhase) { _, phase in
            // バックグラウンド移行・終了直前に、保留中のスクロール位置を確定保存
            if phase != .active { session.flushViewports() }
        }
        .onChange(of: selection) { _, newValue in
            // サイドバーで対象(すべてのノート/グラフ/ゴミ箱/フォルダ)を選んだら、
            // 確実にキャンバスを畳んで選択したライブラリ画面へ遷移する。
            if newValue != nil { session.showLibrary() }
        }
        // ノートを開いたらサイドバーを畳み、ライブラリ/グラフへ戻したら再表示する
        .onChange(of: session.isCanvasVisible) { _, visible in
            withAnimation(.easeInOut(duration: 0.2)) {
                columnVisibility = sidebarVisibility(forCanvas: visible)
            }
        }
        // PDF 直接インポート: 選んだ PDF を全ページ背景の通常ノートとして作成し、即開く
        .fileImporter(
            isPresented: $actions.isPDFPickerPresented,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: false
        ) { result in
            importPDF(from: result)
        }
    }

    /// PDF ピッカーの結果を安全に読み込み、通常ノートを作成して開く。
    private func importPDF(from result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        let title = url.deletingPathExtension().lastPathComponent
        if let note = LibraryService.createPagedNoteFromPDF(
            data: data, titled: title, folder: actions.pdfImportParentFolder, in: context
        ) {
            session.open(note)
        }
    }

    /// キャンバス表示中はサイドバーを畳み(`.detailOnly`)、それ以外は既定(`.automatic`)。
    private func sidebarVisibility(forCanvas canvasVisible: Bool) -> NavigationSplitViewVisibility {
        canvasVisible ? .detailOnly : .automatic
    }

    @ViewBuilder
    private var detailContent: some View {
        if session.isCanvasVisible, session.selectedNote != nil {
            CanvasTabsView()
        } else {
            switch selection {
            case .graph:
                GraphView()
            case .trash:
                TrashView()
            case .folder(let folder):
                LibraryGridView(folder: folder, actions: actions) { opened in
                    selection = .folder(opened)
                }
            default:
                LibraryGridView(folder: nil, actions: actions) { opened in
                    selection = .folder(opened)
                }
            }
        }
    }
}

#Preview {
    RootView()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
        .environmentObject(OpenNotesSession())
}
