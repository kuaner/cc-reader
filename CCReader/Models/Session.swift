import Foundation
import SwiftData

@Model
class Session {
    @Attribute(.unique) var sessionId: String  // UUID
    var project: Project?
    @Relationship(deleteRule: .cascade, inverse: \Message.session)
    var messages: [Message] = []
    var slug: String?                          // "streamed-skipping-tarjan"
    var isSlugManual: Bool = false             // Do not overwrite a manually assigned slug.
    var additionalSessionIds: [String] = []   // Merged sessionIds from plan/subagent runs.
    var cwd: String
    var gitBranch: String?
    var startedAt: Date
    var updatedAt: Date
    var isCompacted: Bool = false              // Indicates whether compaction was detected.
    var lastUserMessageAt: Date?               // Timestamp of the most recent user message.
    var cachedTurnCount: Int = 0               // Cached number of user turns.
    var cachedTitle: String?                   // Cached session title.
    var needsAttention: Bool = false           // Whether unread assistant replies exist.
    var cachedUnacknowledgedCount: Int = 0     // Cached count of unacknowledged assistant messages.

    init(sessionId: String, cwd: String, gitBranch: String? = nil, slug: String? = nil, startedAt: Date = Date(), updatedAt: Date = Date()) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.gitBranch = gitBranch
        self.slug = slug
        self.startedAt = startedAt
        self.updatedAt = updatedAt
    }

    var jsonlFileURL: URL? {
        guard let projectPath = project?.path else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let filePath = "\(home)/.claude/projects/\(projectPath)/\(sessionId).jsonl"
        return URL(fileURLWithPath: filePath)
    }

    // MARK: - Computed Properties for UI

    private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M/d HH:mm"
        return f
    }()

    /// Title shown in the UI.
    var displayTitle: String {
        if let slug = slug {
            return slug.split(separator: "-")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
        if let cachedTitle = cachedTitle {
            return cachedTitle
        }
        return Self.shortDateFormatter.string(from: startedAt)
    }

    /// Number of unacknowledged assistant messages.
    var unacknowledgedCount: Int {
        cachedUnacknowledgedCount
    }
}
