import SwiftUI
import SwiftData

@main
struct CCReaderApp: App {
    let container: ModelContainer

    init() {
        do {
            let schema = Schema([
                Project.self,
                Session.self,
                Message.self
            ])
            let modelConfiguration = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: false
            )
            container = try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not initialize ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(modelContainer: container)
                .modelContainer(container)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1200, height: 800)
    }
}
