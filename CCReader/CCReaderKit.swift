import SwiftUI
import SwiftData

/// Public entry point for embedding CC Reader in another application.
///
/// Usage:
/// ```swift
/// import CCReaderKit
///
/// // Option 1: Open CC Reader in a new window.
/// CCReaderKit.open()
///
/// // Option 2: Embed CC Reader as a SwiftUI View.
/// struct MyApp: App {
///     var body: some Scene {
///         WindowGroup {
///             CCReaderKit.makeView()
///         }
///     }
/// }
/// ```
public enum CCReaderKit {

    /// Shared SwiftData ModelContainer for CC Reader.
    public static let modelContainer: ModelContainer = {
        do {
            let schema = Schema([
                Project.self,
                Session.self,
                Message.self,
            ])
            let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("CCReaderKit: Could not initialize ModelContainer: \(error)")
        }
    }()

    /// Create a standalone `ContentView` ready for embedding.
    @MainActor
    public static func makeView() -> some View {
        ContentView(modelContainer: modelContainer)
            .modelContainer(modelContainer)
    }

    /// Open CC Reader in a new macOS window.
    @MainActor
    public static func open(title: String = "CC Reader", width: CGFloat = 1200, height: CGFloat = 800) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.center()
        window.contentView = NSHostingView(rootView: makeView())
        window.makeKeyAndOrderFront(nil)

        // Prevent the window from being deallocated by retaining it.
        _retainedWindows.append(window)
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { notification in
            _retainedWindows.removeAll { $0 === notification.object as? NSWindow }
        }
    }

    /// Retained windows to prevent deallocation.
    @MainActor
    private static var _retainedWindows: [NSWindow] = []
}
