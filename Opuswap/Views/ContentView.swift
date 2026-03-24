import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var coordinator: AppCoordinator

    @State private var selectedProject: Project?
    @State private var selectedSession: Session?
    @State private var currentVisibleMessageCount = 0

    init(modelContext: ModelContext) {
        _coordinator = StateObject(wrappedValue: AppCoordinator(modelContext: modelContext))
    }

    var body: some View {
        NavigationSplitView {
            ProjectListView(selectedProject: $selectedProject, selectedSession: $selectedSession)
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 360)
        } detail: {
            if let session = selectedSession {
                SessionMessagesView(session: session, visibleMessageCount: $currentVisibleMessageCount)
                    .id(session.sessionId)
                    .navigationSubtitle(subtitleText)
                    .toolbar {
                        ToolbarItem(placement: .automatic) {
                            Button {
                                Task {
                                    await coordinator.syncSession(session)
                                }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .help(String(localized: "content.refresh.help"))
                            .disabled(coordinator.isSyncing)
                        }
                    }
            } else {
                ContentUnavailableView(String(localized: "content.selectSession"), systemImage: "message")
            }
        }
        .onChange(of: selectedSession) { _, newSession in
            currentVisibleMessageCount = 0
            if let session = newSession {
                Task(priority: .utility) {
                    await coordinator.syncSession(session)
                }
            }
        }
        .navigationTitle("Opuswap")
        .overlay {
            SyncOverlayView(coordinator: coordinator)
        }
        .task {
            await coordinator.start()
        }
        .onDisappear {
            coordinator.stop()
        }
    }

    private var subtitleText: String {
        let count = currentVisibleMessageCount
        if count == 0 { return "" }
        return String(format: String(localized: "status.messageCount"), count)
    }
}

private struct SyncOverlayView: View {
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        if coordinator.isSyncing && !coordinator.syncProgress.isEmpty {
            VStack(spacing: 12) {
                ProgressView()
                Text(coordinator.syncProgress)
                    .font(.headline)
                Text(String(localized: "content.initialSyncing"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

#Preview {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: Project.self, Session.self, Message.self, configurations: config)
    return ContentView(modelContext: container.mainContext)
        .modelContainer(container)
}
