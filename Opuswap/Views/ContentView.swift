import SwiftUI
import SwiftData
import AppKit

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
                            SessionCwdButton(cwd: session.cwd)
                        }
                        ToolbarItem(placement: .automatic) {
                            SessionResumeButton(sessionId: session.sessionId)
                        }
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

// MARK: - Session Cwd Button

private struct SessionCwdButton: View {
    let cwd: String

    private var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let shortened = cwd.hasPrefix(home)
            ? "~" + cwd.dropFirst(home.count)
            : cwd
        return shortened
    }

    var body: some View {
        Button {
            NSWorkspace.shared.open(URL(fileURLWithPath: cwd))
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "folder")
                Text(displayPath)
                    .font(.caption)
                    .lineLimit(1)
            }
        }
        .help(cwd)
    }
}

// MARK: - Session Resume Button

private struct SessionResumeButton: View {
    let sessionId: String
    @State private var copied = false

    var body: some View {
        Button {
            let command = "claude --resume \(sessionId)"
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                copied = false
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                Text("Resume")
                    .font(.caption)
            }
        }
        .help(copied
              ? String(localized: "session.resume.copied")
              : String(localized: "session.resume.help"))
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
