import SwiftUI
import CoreData

/// サイドバーで選択できる対象
enum SidebarSelection: Hashable {
    case allNotes
    case trash
    case folder(Folder)
}

struct RootView: View {
    @EnvironmentObject private var session: OpenNotesSession
    @StateObject private var actions = LibraryActionCoordinator()
    @State private var selection: SidebarSelection? = .allNotes

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection, actions: actions)
        } detail: {
            detailContent
        }
        .libraryActionDialogs(actions)
    }

    @ViewBuilder
    private var detailContent: some View {
        if session.isCanvasVisible, session.selectedNote != nil {
            CanvasTabsView()
        } else {
            switch selection {
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
