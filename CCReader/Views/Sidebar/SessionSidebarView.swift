import SwiftUI
import SwiftData

enum SessionSourceFilter: String, CaseIterable, Identifiable {
    case claude
    case codex

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }

    func contains(_ session: Session) -> Bool {
        switch self {
        case .claude:
            return session.source != "codex"
        case .codex:
            return session.source == "codex"
        }
    }

    static func filter(for session: Session?) -> SessionSourceFilter {
        session?.source == "codex" ? .codex : .claude
    }
}

struct SessionSourceScopeBar: View {
    @Environment(\.colorScheme) private var colorScheme

    @Binding var selection: SessionSourceFilter
    let sessions: [Session]

    private func count(for filter: SessionSourceFilter) -> Int {
        sessions.lazy.filter(filter.contains).count
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(SessionSourceFilter.allCases) { filter in
                let isSelected = selection == filter
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        selection = filter
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(filter.title)
                            .font(.caption)
                            .fontWeight(isSelected ? .semibold : .medium)
                        Text("\(count(for: filter))")
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(isSelected ? Color.sessionSourceScopeSelectedCount(for: colorScheme) : Color.secondary.opacity(0.78))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                .foregroundStyle(isSelected ? Color.sessionSourceScopeSelectedText(for: colorScheme) : Color.secondary.opacity(0.9))
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.sessionSourceScopeSelection(for: colorScheme))
                            .overlay {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .stroke(Color.sessionSourceScopeSelectionStroke(for: colorScheme), lineWidth: 0.7)
                            }
                            .shadow(color: .black.opacity(colorScheme == .dark ? 0.22 : 0.08), radius: 2, y: 1)
                    }
                }
            }
        }
        .padding(3)
        .background(Color.sessionSourceScopeBackground(for: colorScheme))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.sessionSourceScopeBorder(for: colorScheme), lineWidth: 0.7)
        }
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

struct SessionSidebarView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Query(sort: \Session.updatedAt, order: .reverse) private var sessions: [Session]
    @Binding var selectedSession: Session?

    @State private var selectedSessionId: String?
    @State private var sourceFilter: SessionSourceFilter = .claude

    private var filteredSessions: [Session] {
        sessions.filter(sourceFilter.contains)
    }

    var body: some View {
        VStack(spacing: 0) {
            SessionSourceScopeBar(selection: $sourceFilter, sessions: sessions)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            List {
                ForEach(filteredSessions) { session in
                    SessionRow(session: session, isSelected: selectedSessionId == session.sessionId)
                        .listRowSeparator(.hidden)
                        .listRowBackground(
                            selectedSessionId == session.sessionId
                                ? RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.sessionLedgerSidebarSelection(for: colorScheme))
                                    .padding(.horizontal, 4)
                                : nil
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedSessionId = session.sessionId
                        }
                }
            }
            .listStyle(.sidebar)
        }
        .onChange(of: selectedSessionId) { _, newValue in
            selectedSession = sessions.first { $0.sessionId == newValue }
        }
        .onChange(of: selectedSession?.sessionId) { _, newValue in
            sourceFilter = SessionSourceFilter.filter(for: selectedSession)
            if selectedSessionId != newValue {
                selectedSessionId = newValue
            }
        }
    }
}

// MARK: - Session Row

struct SessionRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var session: Session
    var isSelected: Bool = false

    private var selectedForeground: Color {
        colorScheme == .dark ? .white : .primary
    }

    private var selectedSecondaryForeground: Color {
        colorScheme == .dark ? Color.white.opacity(0.7) : Color.secondary.opacity(0.7)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Title — uses session.displayTitle which has the full priority chain.
            Text(session.displayTitle)
                .font(.subheadline)
                .fontWeight(.medium)
                .lineLimit(2)
                .foregroundStyle(isSelected ? selectedForeground : .primary)
                .help(taskSummaryTooltip)

            // Metadata badges
            HStack(spacing: 6) {
                // Turn count
                HStack(spacing: 3) {
                    Image(systemName: "message")
                        .font(.caption2)
                    Text("\(turnCount)")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)

                // Branch
                if let branch = session.gitBranch {
                    Text("·")
                        .foregroundStyle(.quaternary)
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.caption2)
                        Text(branch)
                            .font(.caption2)
                            .lineLimit(1)
                    }
                    .foregroundStyle(.secondary)
                }

                // Tag badge
                if let tag = session.sessionTag {
                    Text("·")
                        .foregroundStyle(.quaternary)
                    Text(tag)
                        .font(.caption2)
                        .fontWeight(.medium)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .foregroundStyle(.green)
                        .background(.green.opacity(0.15))
                        .clipShape(Capsule())
                }

                // PR link badge
                if session.prNumber != nil {
                    Text("·")
                        .foregroundStyle(.quaternary)
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.up.forward")
                            .font(.caption2)
                        Text("PR")
                            .font(.caption2)
                            .fontWeight(.semibold)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .foregroundStyle(Color.sessionLedgerBadgeRust)
                    .background(Color.sessionLedgerBadgeRust.opacity(0.15))
                    .clipShape(Capsule())
                }

                // Coordinator mode badge
                if session.sessionMode == "coordinator" {
                    Text("·")
                        .foregroundStyle(.quaternary)
                    HStack(spacing: 3) {
                        Image(systemName: "person.2")
                            .font(.caption2)
                        Text("coordinator")
                            .font(.caption2)
                            .fontWeight(.semibold)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .foregroundStyle(.orange)
                    .background(.orange.opacity(0.15))
                    .clipShape(Capsule())
                }

                // Compacted indicator
                if session.isCompacted {
                    Text("·")
                        .foregroundStyle(.quaternary)
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.caption2)
                        Text("compacted")
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }

                if isSubagentSession {
                    Text("·")
                        .foregroundStyle(.quaternary)
                    HStack(spacing: 3) {
                        Image(systemName: session.agentName != nil ? "person.fill" : "person")
                            .font(.caption2)
                        Text(agentLabel)
                            .font(.caption2)
                            .fontWeight(.semibold)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .foregroundStyle(Color.sessionLedgerBadgeAmber)
                    .background(Color.sessionLedgerBadgeAmber.opacity(0.18))
                    .clipShape(Capsule())
                }

                Spacer()

                // Last message timestamp
                Text(formattedDate)
                    .font(.caption2)
                    .foregroundStyle(isSelected ? selectedSecondaryForeground : Color.secondary.opacity(0.5))
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.10))
                .frame(height: 0.5)
                .padding(.horizontal, 4)
        }
    }

    private static let sessionDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy/M/d HH:mm"
        return f
    }()

    private var formattedDate: String {
        Self.sessionDateFormatter.string(from: session.updatedAt)
    }

    private var turnCount: Int {
        session.cachedTurnCount
    }

    private var isSubagentSession: Bool {
        session.sessionId.hasPrefix("agent-")
    }

    /// Label for agent sessions: prefers agentName, falls back to "sub".
    private var agentLabel: String {
        session.agentName ?? "sub"
    }

    /// Tooltip showing the rolling task summary when available.
    private var taskSummaryTooltip: String {
        session.taskSummary.map { "Task: " + $0 } ?? ""
    }
}

// MARK: - Session Ledger chrome (warm palette aligned with timeline web UI)

extension Color {
    /// Sidebar / picker row selection — umber tint, not system accent blue.
    static func sessionLedgerSidebarSelection(for colorScheme: ColorScheme) -> Color {
        switch colorScheme {
        case .dark:
            return Color(red: 0.42, green: 0.30, blue: 0.22).opacity(0.62)
        case .light:
            return Color(red: 0.82, green: 0.72, blue: 0.58).opacity(0.45)
        @unknown default:
            return Color(red: 0.42, green: 0.30, blue: 0.22).opacity(0.62)
        }
    }

    /// PR / link badges — warm rust (replaces indigo).
    static var sessionLedgerBadgeRust: Color {
        Color(red: 0.72, green: 0.42, blue: 0.28)
    }

    /// Subagent / secondary warm badges — amber (replaces system accent).
    static var sessionLedgerBadgeAmber: Color {
        Color(red: 0.78, green: 0.52, blue: 0.18)
    }

    static func sessionSourceScopeBackground(for colorScheme: ColorScheme) -> Color {
        switch colorScheme {
        case .dark:
            return Color(red: 0.18, green: 0.16, blue: 0.14).opacity(0.62)
        case .light:
            return Color(red: 0.91, green: 0.86, blue: 0.78).opacity(0.58)
        @unknown default:
            return Color(red: 0.18, green: 0.16, blue: 0.14).opacity(0.62)
        }
    }

    static func sessionSourceScopeSelection(for colorScheme: ColorScheme) -> Color {
        switch colorScheme {
        case .dark:
            return Color(red: 0.49, green: 0.35, blue: 0.25).opacity(0.92)
        case .light:
            return Color(red: 0.64, green: 0.46, blue: 0.31).opacity(0.86)
        @unknown default:
            return Color(red: 0.49, green: 0.35, blue: 0.25).opacity(0.92)
        }
    }

    static func sessionSourceScopeSelectionStroke(for colorScheme: ColorScheme) -> Color {
        switch colorScheme {
        case .dark:
            return Color(red: 0.88, green: 0.68, blue: 0.44).opacity(0.32)
        case .light:
            return Color(red: 0.43, green: 0.29, blue: 0.19).opacity(0.24)
        @unknown default:
            return Color(red: 0.88, green: 0.68, blue: 0.44).opacity(0.32)
        }
    }

    static func sessionSourceScopeBorder(for colorScheme: ColorScheme) -> Color {
        switch colorScheme {
        case .dark:
            return Color.white.opacity(0.07)
        case .light:
            return Color.black.opacity(0.08)
        @unknown default:
            return Color.white.opacity(0.07)
        }
    }

    /// Selected filter title — white in dark mode, dark warm tone in light mode for contrast.
    static func sessionSourceScopeSelectedText(for colorScheme: ColorScheme) -> Color {
        switch colorScheme {
        case .dark:
            return .white
        case .light:
            return Color(red: 0.22, green: 0.14, blue: 0.08)
        @unknown default:
            return .white
        }
    }

    /// Selected filter count badge — muted white in dark mode, muted dark in light mode.
    static func sessionSourceScopeSelectedCount(for colorScheme: ColorScheme) -> Color {
        switch colorScheme {
        case .dark:
            return Color.white.opacity(0.76)
        case .light:
            return Color(red: 0.22, green: 0.14, blue: 0.08).opacity(0.72)
        @unknown default:
            return Color.white.opacity(0.76)
        }
    }
}

#Preview {
    SessionSidebarView(selectedSession: .constant(nil))
        .modelContainer(for: [Project.self, Session.self, Message.self], inMemory: true)
}
