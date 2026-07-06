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

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection, actions: actions)
        } detail: {
            detailContent
        }
        .libraryActionDialogs(actions)
        .onAppear {
            // 前回開いていたタブ・選択中ノートを復元(初回のみ有効)
            session.restore(in: context)
        }
        .onChange(of: scenePhase) { _, phase in
            // バックグラウンド移行・終了直前に、保留中のスクロール位置を確定保存
            if phase != .active { session.flushViewports() }
        }
        .onChange(of: selection) { _, newValue in
            // グラフビューを選んだらキャンバスを畳んでグラフを前面に出す
            if newValue == .graph { session.showLibrary() }
        }
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
