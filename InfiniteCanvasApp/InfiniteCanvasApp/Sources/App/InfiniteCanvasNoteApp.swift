import SwiftUI
import CoreData

@main
struct InfiniteCanvasNoteApp: App {
    private let persistence = PersistenceController.shared
    @StateObject private var session = OpenNotesSession()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(\.managedObjectContext, persistence.container.viewContext)
                .environmentObject(session)
        }
    }
}
