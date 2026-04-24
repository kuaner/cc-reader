import SwiftUI
import SwiftData

/// Localized string helper that always looks up from the package bundle.
@usableFromInline
internal func L(_ key: String.LocalizationValue) -> String {
#if SWIFT_PACKAGE
    String(localized: key, bundle: .module)
#else
    String(localized: key, bundle: .main)
#endif
}

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
        let coordinator = AppCoordinator(modelContainer: modelContainer)
        return ContentView()
            .modelContainer(modelContainer)
            .environmentObject(coordinator)
    }

    /// Open CC Reader in a new macOS window.
    @MainActor
    public static func open(title: String = "CC Reader", width: CGFloat = 1200, height: CGFloat = 800) {
        // Reuse existing window if still around
        if let existing = _readerWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let hostingController = NSHostingController(rootView: makeView())
        let window = NSWindow(contentViewController: hostingController)
        window.title = title
        window.toolbarStyle = .unified
        window.setContentSize(NSSize(width: width, height: height))
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)

        _readerWindow = window
    }

    /// Retained window reference to prevent deallocation.
    @MainActor
    private static var _readerWindow: NSWindow?
}
