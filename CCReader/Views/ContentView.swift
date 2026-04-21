import AppKit
import SwiftData
import SwiftUI

public struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var coordinator: AppCoordinator
    @StateObject private var layoutManager = LayoutManager()

    @State private var selectedSession: Session?
    @State private var columnVisibility: NavigationSplitViewVisibility = .doubleColumn
    @SceneStorage("windowLayoutJSON") private var layoutData: String?
    @Query(sort: \Session.updatedAt, order: .reverse) private var sessions: [Session]

    public init(modelContainer: ModelContainer) {
        _coordinator = StateObject(wrappedValue: AppCoordinator(modelContainer: modelContainer))
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ProjectListView(
                selectedSession: $selectedSession
            )
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            LayoutView(selectedSession: $selectedSession)
        }
        .onChange(of: selectedSession) { _, newSession in
            guard let session = newSession else { return }
            layoutManager.focusOrAssignSession(session.sessionId)
        }
        .environmentObject(layoutManager)
        .environmentObject(coordinator)
        .background(WindowConfigurator(layoutManager: layoutManager))
        .toolbar(removing: .sidebarToggle)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Spacer()
                Button {
                    layoutManager.requestSwitchSession()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                        Text(L("picker.switch.help"))
                    }
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: 220)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .help(L("picker.switch.help"))
            }
        }
        .navigationTitle(windowTitle)
        .onReceive(NotificationCenter.default.publisher(for: .navigateToSession)) { notification in
            guard layoutManager.window?.isKeyWindow == true else { return }
            guard let targetSessionId = notification.object as? String else { return }
            guard let session = sessions.first(where: { $0.sessionId == targetSessionId }) else {
                return
            }

            layoutManager.focusOrAssignSession(targetSessionId)
            selectedSession = session
        }
        .sheet(item: $layoutManager.pendingPickerAction) { _ in
            SessionPickerView(
                onSelect: { session in
                    layoutManager.handlePickerSelection(sessionId: session.sessionId)
                    selectedSession = session
                },
                onCancel: {
                    layoutManager.cancelPicker()
                }
            )
            .environmentObject(layoutManager)
        }
        .task {
            if let layoutData {
                layoutManager.restoreLayout(from: layoutData)
            } else {
                layoutManager.migrateFromUserDefaults()
            }
            if layoutManager.focusedPaneId == nil {
                layoutManager.focusedPaneId = layoutManager.allPanes().first?.id
            }
            await coordinator.start()
        }
        .onDisappear {
            layoutManager.unregisterWindow()
            coordinator.stop()
        }
        .onChange(of: layoutManager.layout) { _, _ in
            layoutData = layoutManager.encodeLayout()
        }
        .onChange(of: layoutManager.sidebarVisible) { _, visible in
            let target = visible ? NavigationSplitViewVisibility.doubleColumn : .detailOnly
            guard columnVisibility != target else { return }
            withAnimation {
                columnVisibility = target
            }
        }
        .onChange(of: columnVisibility) { _, visibility in
            let visible = visibility != .detailOnly
            guard layoutManager.sidebarVisible != visible else { return }
            layoutManager.sidebarVisible = visible
        }
    }

    private var windowTitle: String {
        guard let focusedId = layoutManager.focusedPaneId,
            let pane = layoutManager.allPanes().first(where: { $0.id == focusedId }),
            let sessionId = pane.sessionId,
            let session = sessions.first(where: { $0.sessionId == sessionId })
        else {
            return "CC Reader"
        }
        return session.displayTitle
    }
}

// MARK: - Window Configurator (native tab support)

private struct WindowConfigurator: NSViewRepresentable {
    let layoutManager: LayoutManager

    func makeNSView(context: Context) -> WindowConfigView {
        let view = WindowConfigView()
        view.layoutManager = layoutManager
        return view
    }

    func updateNSView(_ nsView: WindowConfigView, context: Context) {}
}

class WindowConfigView: NSView {
    weak var layoutManager: LayoutManager?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let previousWindow = layoutManager?.window,
            previousWindow !== window
        {
            layoutManager?.unregisterWindow()
        }
        guard let window else {
            layoutManager?.unregisterWindow()
            return
        }
        window.tabbingIdentifier = "cc-reader.main"
        window.tabbingMode = .preferred
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        layoutManager?.registerWindow(window)
    }
}

#Preview {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(
        for: Project.self, Session.self, Message.self, configurations: config)
    return ContentView(modelContainer: container)
        .modelContainer(container)
}
