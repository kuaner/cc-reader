import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var coordinator: AppCoordinator
    @StateObject private var layoutManager = LayoutManager()

    @State private var selectedProject: Project?
    @State private var selectedSession: Session?
    @State private var showTerminal = true

    init(modelContext: ModelContext) {
        _coordinator = StateObject(wrappedValue: AppCoordinator(modelContext: modelContext))
    }

    var body: some View {
        HSplitView {
            // 左側: 会話ビュー
            NavigationSplitView {
                ProjectListView(selectedProject: $selectedProject, selectedSession: $selectedSession)
                    .environmentObject(layoutManager)
                    .frame(minWidth: 200)
            } detail: {
                if let session = selectedSession {
                    SessionMessagesView(session: session)
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
                // セッション切り替え時に差分同期
                if let session = newSession {
                    Task {
                        await coordinator.syncSession(session)
                    }
                }
            }
            .frame(minWidth: 500)

            // 右側: ターミナル
            if showTerminal, let pane = layoutManager.allPanes().first {
                TerminalContainerView(
                    paneId: pane.id,
                    cwd: FileManager.default.homeDirectoryForCurrentUser.path
                )
                .id(pane.id)  // paneIdが変わらない限り再生成しない
                .frame(minWidth: 400)
            }
        }
        .navigationTitle("Opuswap")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    withAnimation { showTerminal.toggle() }
                } label: {
                    Image(systemName: "terminal")
                        .symbolVariant(showTerminal ? .fill : .none)
                }
                .help("内蔵ターミナル表示")
            }
            ToolbarItem(placement: .primaryAction) {
                externalTerminalMenu
            }
            ToolbarItem(placement: .primaryAction) {
                statusIndicator
            }
        }
        .overlay {
            if coordinator.isSyncing && !coordinator.syncProgress.isEmpty {
                syncOverlay
            }
        }
        .task {
            await coordinator.start()
        }
        .onDisappear {
            coordinator.stop()
        }
    }

    @ViewBuilder
    private var externalTerminalMenu: some View {
        let terminals = ExternalTerminalLauncher.availableTerminals()
        Menu {
            ForEach(terminals) { terminal in
                Button {
                    openExternalTerminal(terminal)
                } label: {
                    Label(terminal.rawValue, systemImage: terminal.icon)
                }
            }
        } label: {
            Image(systemName: "arrow.up.forward.app")
        }
        .menuIndicator(.hidden)
        .help("外部ターミナルで開く")
    }

    private func openExternalTerminal(_ app: TerminalApp) {
        // 選択中のプロジェクトのディレクトリ、なければホーム
        let directory = selectedProject?.path
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        ExternalTerminalLauncher.open(app, at: directory)
    }

    @ViewBuilder
    private var statusIndicator: some View {
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

    @ViewBuilder
    private var syncOverlay: some View {
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

#Preview {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: Project.self, Session.self, Message.self, configurations: config)
    return ContentView(modelContext: container.mainContext)
        .modelContainer(container)
}
