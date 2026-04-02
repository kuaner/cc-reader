import SwiftUI
import SwiftData

struct PaneView: View {
    let pane: Pane
    @Binding var selectedSession: Session?
    @EnvironmentObject var layoutManager: LayoutManager
    @Query(sort: \Session.updatedAt, order: .reverse) private var sessions: [Session]
    @State private var showContextPanel = true

    private var session: Session? {
        guard let sessionId = pane.sessionId else { return nil }
        return sessions.first { $0.sessionId == sessionId }
    }

    var body: some View {
        if let session = session {
            VStack(spacing: 0) {
                PaneHeaderView(pane: pane, session: session, showContextPanel: $showContextPanel)
                SessionMessagesView(session: session, visibleMessageCount: .constant(0), showContextPanel: $showContextPanel)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .onTapGesture {
                layoutManager.focusedPaneId = pane.id
                selectedSession = session
            }
        } else {
            EmptyPaneView(pane: pane)
        }
    }
}

// MARK: - Pane Header

struct PaneHeaderView: View {
    let pane: Pane
    let session: Session?
    @Binding var showContextPanel: Bool
    @EnvironmentObject var layoutManager: LayoutManager
    @EnvironmentObject var coordinator: AppCoordinator

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                if let session = session {
                    if session.needsAttention {
                        Image(systemName: "bell.fill")
                            .foregroundStyle(.orange)
                            .font(.caption2)
                    }
                    Text(session.displayTitle)
                        .lineLimit(1)
                } else {
                    Text(L("layout.noSessionSelected"))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)

            Spacer()

            // Per-session action buttons
            if let session = session {
                // Open CWD
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: session.cwd))
                } label: {
                    Image(systemName: "folder")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help(session.cwd)

                // Resume (copy command)
                if !session.sessionId.hasPrefix("agent-") {
                    PaneResumeButton(sessionId: session.sessionId)
                }

                // Refresh
                Button {
                    Task { await coordinator.syncSession(session) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .disabled(coordinator.isSyncing)
                .help(L("content.refresh.help"))
            }

            // Context panel toggle
            Button {
                withAnimation { showContextPanel.toggle() }
            } label: {
                Image(systemName: showContextPanel ? "sidebar.right" : "sidebar.left")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .help(L("timeline.context.help"))

            // Switch session
            Button {
                layoutManager.focusedPaneId = pane.id
                layoutManager.requestSwitchSession()
            } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .help(L("picker.switch.help"))

            // Split / close menu
            Menu {
                Button(L("layout.split.horizontal")) {
                    layoutManager.focusedPaneId = pane.id
                    layoutManager.requestSplitFocused(direction: .horizontal)
                }
                .disabled(!layoutManager.canSplit())

                Button(L("layout.split.vertical")) {
                    layoutManager.focusedPaneId = pane.id
                    layoutManager.requestSplitFocused(direction: .vertical)
                }
                .disabled(!layoutManager.canSplit())

                Divider()

                Button(L("layout.pane.close"), role: .destructive) {
                    layoutManager.closePane(pane.id)
                }
            } label: {
                Image(systemName: "rectangle.split.3x1")
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
        .animation(.easeInOut(duration: 0.12), value: layoutManager.focusedPaneId == pane.id)
    }
}

// MARK: - Pane Resume Button

private struct PaneResumeButton: View {
    let sessionId: String
    @State private var copied = false

    var body: some View {
        Button {
            let command = "claude --resume \(sessionId)"
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.caption)
        }
        .buttonStyle(.plain)
        .help(copied ? L("session.resume.copied") : L("session.resume.help"))
    }
}

// MARK: - Empty Pane

struct EmptyPaneView: View {
    let pane: Pane
    @EnvironmentObject var layoutManager: LayoutManager

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "plus.rectangle.on.rectangle")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)

            Text(L("content.selectSession"))
                .font(.headline)
                .foregroundStyle(.secondary)

            Text(L("layout.emptyHint"))
                .font(.caption)
                .foregroundStyle(.tertiary)

            Button {
                layoutManager.focusedPaneId = pane.id
                layoutManager.requestSwitchSession()
            } label: {
                Label(L("content.selectSession"), systemImage: "list.bullet")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
