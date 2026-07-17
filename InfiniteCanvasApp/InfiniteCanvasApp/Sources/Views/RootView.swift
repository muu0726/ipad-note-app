import SwiftUI
import CoreData

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
            // グラフビューを選んだらキャンバスを畳んでグラフを前面に出す
            if newValue == .graph { session.showLibrary() }
        }
        // ノートを開いたらサイドバーを畳み、ライブラリ/グラフへ戻したら再表示する
        .onChange(of: session.isCanvasVisible) { _, visible in
            withAnimation(.easeInOut(duration: 0.2)) {
                columnVisibility = sidebarVisibility(forCanvas: visible)
            }
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
