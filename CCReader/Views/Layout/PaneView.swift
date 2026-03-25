import SwiftUI
import SwiftData

struct PaneView: View {
    let pane: Pane
    @Binding var selectedSession: Session?
    @EnvironmentObject var layoutManager: LayoutManager
    @Query(sort: \Session.updatedAt, order: .reverse) private var sessions: [Session]

    private var session: Session? {
        guard let sessionId = pane.sessionId else { return nil }
        return sessions.first { $0.sessionId == sessionId }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            PaneHeaderView(pane: pane, sessions: sessions)

            // Main content
            if let session = session {
                SessionMessagesView(session: session, visibleMessageCount: .constant(0))
            } else {
                EmptyPaneView(pane: pane, sessions: sessions)
            }
        }
        .background(layoutManager.focusedPaneId == pane.id ? Color.accentColor.opacity(0.05) : Color.clear)
        .onTapGesture {
            layoutManager.focusedPaneId = pane.id
            if let session = session {
                selectedSession = session
            }
        }
        .dropDestination(for: String.self) { sessionIds, _ in
            if let sessionId = sessionIds.first {
                layoutManager.assignSession(sessionId, to: pane.id)
                return true
            }
            return false
        }
    }
}

// MARK: - Pane Header

struct PaneHeaderView: View {
    let pane: Pane
    let sessions: [Session]
    @EnvironmentObject var layoutManager: LayoutManager

    private var currentSession: Session? {
        guard let sessionId = pane.sessionId else { return nil }
        return sessions.first { $0.sessionId == sessionId }
    }

    var body: some View {
        HStack(spacing: 8) {
            // Session title
            HStack(spacing: 4) {
                if let session = currentSession {
                    if session.needsAttention {
                        Image(systemName: "bell.fill")
                            .foregroundStyle(.orange)
                            .font(.caption2)
                    }
                    Text(session.displayTitle)
                        .lineLimit(1)
                } else {
                    Text(String(localized: "layout.noSessionSelected"))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)

            Spacer()

            // Split menu
            Menu {
                Button(String(localized: "layout.split.horizontal")) {
                    layoutManager.splitPane(pane.id, direction: .horizontal)
                }
                .disabled(!layoutManager.canSplit())

                Button(String(localized: "layout.split.vertical")) {
                    layoutManager.splitPane(pane.id, direction: .vertical)
                }
                .disabled(!layoutManager.canSplit())

                Divider()

                Button(String(localized: "layout.pane.close"), role: .destructive) {
                    layoutManager.closePane(pane.id)
                }
                .disabled(layoutManager.allPanes().count <= 1)
            } label: {
                Image(systemName: "rectangle.split.3x1")
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

// MARK: - Empty Pane

struct EmptyPaneView: View {
    let pane: Pane
    let sessions: [Session]
    @EnvironmentObject var layoutManager: LayoutManager

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "plus.rectangle.on.rectangle")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)

            Text(String(localized: "content.selectSession"))
                .font(.headline)
                .foregroundStyle(.secondary)

            Text(String(localized: "layout.emptyHint"))
                .font(.caption)
                .foregroundStyle(.tertiary)

            // Recent sessions for quick assignment.
            if !sessions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(localized: "layout.recentSessions"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)

                    ForEach(sessions.prefix(5)) { session in
                        Button {
                            layoutManager.assignSession(session.sessionId, to: pane.id)
                        } label: {
                            HStack(spacing: 6) {
                                if session.needsAttention {
                                    Image(systemName: "bell.fill")
                                        .foregroundStyle(.orange)
                                        .font(.caption2)
                                }
                                Text(session.displayTitle)
                                    .lineLimit(1)

                                if session.unacknowledgedCount > 0 {
                                    Text("\(session.unacknowledgedCount)")
                                        .font(.caption2)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(.orange.opacity(0.2))
                                        .clipShape(Capsule())
                                }
                            }
                            .font(.caption)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
                .background(.quaternary.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
