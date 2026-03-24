import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var coordinator: AppCoordinator

    @State private var selectedProject: Project?
    @State private var selectedSession: Session?

    init(modelContext: ModelContext) {
        _coordinator = StateObject(wrappedValue: AppCoordinator(modelContext: modelContext))
    }

    var body: some View {
        NavigationSplitView {
            ProjectListView(selectedProject: $selectedProject, selectedSession: $selectedSession)
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 360)
        } detail: {
            if let session = selectedSession {
                SessionMessagesView(session: session)
                    .id(session.sessionId)
                    .toolbar {
                        ToolbarItem(placement: .automatic) {
                            Button {
                                Task {
                                    await coordinator.syncSession(session)
                                }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .help("メッセージを更新")
                            .disabled(coordinator.isSyncing)
                        }
                    }
            } else {
                ContentUnavailableView("セッションを選択", systemImage: "message")
            }
        }
        .onChange(of: selectedSession) { _, newSession in
            if let session = newSession {
                Task(priority: .utility) {
                    await coordinator.syncSession(session)
                }
            }
        }
        .navigationTitle("Opuswap")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                SyncStatusView(coordinator: coordinator)
            }
        }
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
}

private struct SyncStatusView: View {
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        HStack(spacing: 8) {
            if coordinator.isSyncing {
                ProgressView()
                    .scaleEffect(0.7)
                Text("同期中")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("\(coordinator.messageCount) msgs")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
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
                Text("初回同期中...")
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
