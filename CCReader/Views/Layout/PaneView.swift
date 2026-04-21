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
    
    private var isFocused: Bool {
        layoutManager.focusedPaneId == pane.id
    }

    var body: some View {
        HStack(spacing: 6) {
            Group {
                HStack(spacing: 4) {
                    if let session = session {
                        if session.needsAttention {
                            Image(systemName: "bell.fill")
                                .foregroundStyle(.orange)
                                .font(.caption2)
                        }
                        Text(session.displayTitle)
                            .lineLimit(1)
                            .foregroundStyle(isFocused ? Color.primary : Color.secondary)
                    } else {
                        Text(L("layout.noSessionSelected"))
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background {
                    Capsule(style: .continuous)
                        .fill(
                            isFocused
                                ? Color.primary.opacity(0.12)
                                : Color.primary.opacity(0.06)
                        )
                }
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(
                            isFocused
                                ? Color.primary.opacity(0.22)
                                : Color(nsColor: .separatorColor).opacity(0.65),
                            lineWidth: 1
                        )
                }
            }

            Spacer()

            // Per-session action buttons
            if let session = session {
                SessionSourceBadge(session: session)

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
                    PaneResumeButton(session: session)
                }

                // Refresh
                Button {
                    Task { await coordinator.syncSession(session) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help(L("content.refresh.help"))
            }

            // Context panel toggle
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showContextPanel.toggle() }
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
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .animation(.easeInOut(duration: 0.12), value: layoutManager.focusedPaneId == pane.id)
    }
}

// MARK: - Pane Resume Button

private struct SessionSourceBadge: View {
    let session: Session

    private var sourceTitle: String {
        session.source == "codex" ? "Codex" : "Claude"
    }

    private var sourceIcon: String {
        session.source == "codex" ? "terminal" : "sparkles"
    }

    private var sourceColor: Color {
        session.source == "codex" ? .cyan : .orange
    }

    var body: some View {
        Label(sourceTitle, systemImage: sourceIcon)
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundStyle(sourceColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(sourceColor.opacity(0.12))
            .clipShape(Capsule(style: .continuous))
            .help(sourceTitle)
    }
}

private struct PaneResumeButton: View {
    let session: Session
    @State private var copied = false

    private var command: String {
        if session.source == "codex" {
            return "codex resume \(session.sessionId)"
        }
        return "claude --resume \(session.sessionId)"
    }

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.caption)
        }
        .buttonStyle(.plain)
        .help(copied ? "\(L("session.resume.copied")): \(command)" : L("session.resume.help"))
    }
}

// MARK: - Empty Pane

struct EmptyPaneView: View {
    let pane: Pane
    @EnvironmentObject var layoutManager: LayoutManager

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "plus.rectangle.on.rectangle")
                .font(.system(size: 56))
                .foregroundStyle(.tertiary)

            Text(L("content.selectSession"))
                .font(.title2)
                .foregroundStyle(.secondary)

            Text(L("layout.emptyHint"))
                .font(.subheadline)
                .foregroundStyle(.tertiary)

            Button {
                layoutManager.focusedPaneId = pane.id
                layoutManager.requestSwitchSession()
            } label: {
                Label(L("content.selectSession"), systemImage: "list.bullet")
                    .font(.body)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
