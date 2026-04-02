import SwiftUI
import SwiftData
import AppKit

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
                selectedProject: .constant(nil),
                selectedSession: $selectedSession
            )
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            LayoutView(selectedSession: $selectedSession)
        }
        .onChange(of: selectedSession) { _, newSession in
            guard let session = newSession else { return }
            if let pane = layoutManager.allPanes().first(where: { $0.sessionId == session.sessionId }) {
                layoutManager.focusedPaneId = pane.id
            } else {
                let targetPaneId = layoutManager.focusedPaneId
                    ?? layoutManager.allPanes().first?.id
                if let paneId = targetPaneId {
                    layoutManager.focusedPaneId = paneId
                    layoutManager.assignSession(session.sessionId, to: paneId)
                }
            }
        }
        .environmentObject(layoutManager)
        .environmentObject(coordinator)
        .background(WindowConfigurator(layoutManager: layoutManager))
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button {
                    layoutManager.requestSwitchSession()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11))
                        Text(L("picker.switch.help"))
                            .font(.system(size: 12))
                    }
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 200)
                }
                .buttonStyle(.plain)
            }
        }
        .onChange(of: selectedSession) { _, newSession in
            if let session = newSession {
                Task(priority: .utility) {
                    await coordinator.syncSession(session)
                }
            }
        }
        .navigationTitle(windowTitle)
        .onReceive(NotificationCenter.default.publisher(for: .navigateToSession)) { notification in
            guard layoutManager.window?.isKeyWindow == true else { return }
            guard let targetSessionId = notification.object as? String else { return }
            let descriptor = FetchDescriptor<Session>(predicate: #Predicate { $0.sessionId == targetSessionId })
            guard let session = try? modelContext.fetch(descriptor).first else { return }

            if let pane = layoutManager.findPane(for: targetSessionId) {
                layoutManager.focusedPaneId = pane.id
            } else {
                let targetPaneId = layoutManager.focusedPaneId
                    ?? layoutManager.allPanes().first?.id
                if let paneId = targetPaneId {
                    layoutManager.focusedPaneId = paneId
                    layoutManager.assignSession(targetSessionId, to: paneId)
                }
            }
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
        .overlay {
            SyncOverlayView(coordinator: coordinator)
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
            withAnimation {
                columnVisibility = visible ? .doubleColumn : .detailOnly
            }
        }
        .onChange(of: columnVisibility) { _, visibility in
            layoutManager.sidebarVisible = (visibility != .detailOnly)
        }
    }

    private var windowTitle: String {
        guard let focusedId = layoutManager.focusedPaneId,
              let pane = layoutManager.allPanes().first(where: { $0.id == focusedId }),
              let sessionId = pane.sessionId,
              let session = sessions.first(where: { $0.sessionId == sessionId }) else {
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

// MARK: - Sync Overlay

private struct SyncOverlayView: View {
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        if coordinator.isSyncing && !coordinator.syncProgress.isEmpty {
            VStack(spacing: 12) {
                ProgressView()
                Text(coordinator.syncProgress)
                    .font(.headline)
                Text(L("content.initialSyncing"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

#Preview {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: Project.self, Session.self, Message.self, configurations: config)
    return ContentView(modelContainer: container)
        .modelContainer(container)
}
