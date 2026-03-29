import SwiftUI
import SwiftData

struct ProjectListView: View {
    @Query(sort: \Session.updatedAt, order: .reverse) private var sessions: [Session]
    @Binding var selectedProject: Project?
    @Binding var selectedSession: Session?

    var body: some View {
        List {
            ForEach(sessions) { session in
                SessionRow(
                    session: session,
                    isSelected: selectedSession?.sessionId == session.sessionId
                )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedSession = session
                    }
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.sidebar)
    }
}

// MARK: - Session Row

struct SessionRow: View {
    @Bindable var session: Session
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Title
            Text(sessionTitle)
                .font(.subheadline)
                .fontWeight(.medium)
                .lineLimit(2)
                .foregroundStyle(.primary)

            // Metadata
            HStack(spacing: 6) {
                // User turn count
                HStack(spacing: 3) {
                    Image(systemName: "message")
                        .font(.caption2)
                    Text("\(turnCount)")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)

                // Branch
                if let branch = session.gitBranch {
                    Text("•")
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

                if isSubagentSession {
                    Text("•")
                        .font(.caption2)
                        .foregroundStyle(.quaternary)
                    Text("sub")
                        .font(.caption2)
                        .fontWeight(.semibold)
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
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(
            isSelected
                ? AnyShapeStyle(Color.accentColor.opacity(0.18))
                : AnyShapeStyle(.quaternary.opacity(0.5))
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private static let sessionDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy/M/d HH:mm"
        return f
    }()

    private var formattedDate: String {
        Self.sessionDateFormatter.string(from: session.updatedAt)
    }

    // Cached user turn count.
    private var turnCount: Int {
        session.cachedTurnCount
    }

    private var isSubagentSession: Bool {
        session.sessionId.hasPrefix("agent-")
    }

    private var sessionTitle: String {
        if let slug = session.slug {
            return formatSlug(slug)
        }
        if let cachedTitle = session.cachedTitle {
            return cachedTitle
        }
        return session.displayTitle
    }

    private func formatSlug(_ slug: String) -> String {
        // reactive-prancing-bird -> Reactive Prancing Bird
        slug.split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

#Preview {
    ProjectListView(selectedProject: .constant(nil), selectedSession: .constant(nil))
        .modelContainer(for: [Project.self, Session.self, Message.self], inMemory: true)
}
