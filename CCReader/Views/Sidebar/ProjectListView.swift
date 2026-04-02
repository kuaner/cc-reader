import SwiftUI
import SwiftData

struct ProjectListView: View {
    @Query(sort: \Session.updatedAt, order: .reverse) private var sessions: [Session]
    @Binding var selectedSession: Session?

    @State private var selectedSessionId: String?

    var body: some View {
        List {
            ForEach(sessions) { session in
                SessionRow(session: session, isSelected: selectedSessionId == session.sessionId)
                    .listRowSeparator(.hidden)
                    .listRowBackground(
                        selectedSessionId == session.sessionId
                            ? RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color(nsColor: .selectedContentBackgroundColor).opacity(0.5))
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
        .safeAreaInset(edge: .top) { Color.clear.frame(height: 8) }
        .onChange(of: selectedSessionId) { _, newValue in
            selectedSession = sessions.first { $0.sessionId == newValue }
        }
        .onChange(of: selectedSession?.sessionId) { _, newValue in
            if selectedSessionId != newValue {
                selectedSessionId = newValue
            }
        }
    }
}

// MARK: - Session Row

struct SessionRow: View {
    @Bindable var session: Session
    var isSelected: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Title — uses session.displayTitle which has the full priority chain.
            Text(session.displayTitle)
                .font(.subheadline)
                .fontWeight(.medium)
                .lineLimit(2)
                .foregroundStyle(isSelected ? .white : .primary)
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
                    .foregroundStyle(.indigo)
                    .background(.indigo.opacity(0.15))
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
                    .foregroundStyle(Color.accentColor)
                    .background(Color.accentColor.opacity(0.2))
                    .clipShape(Capsule())
                }

                Spacer()

                // Last message timestamp
                Text(formattedDate)
                    .font(.caption2)
                    .foregroundStyle(isSelected ? Color.white.opacity(0.7) : Color.secondary.opacity(0.5))
            }
        }
        .padding(.vertical, 2)
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


#Preview {
    ProjectListView(selectedSession: .constant(nil))
        .modelContainer(for: [Project.self, Session.self, Message.self], inMemory: true)
}
