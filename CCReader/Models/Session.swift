import Foundation
import SwiftData

@Model
public class Session {
    @Attribute(.unique) public var sessionId: String
    public var project: Project?
    @Relationship(deleteRule: .cascade, inverse: \Message.session)
    public var messages: [Message] = []
    public var slug: String?
    public var isSlugManual: Bool = false
    public var additionalSessionIds: [String] = []
    public var cwd: String
    public var gitBranch: String?
    public var startedAt: Date
    public var updatedAt: Date
    public var isCompacted: Bool = false
    public var lastUserMessageAt: Date?
    public var cachedTurnCount: Int = 0
    public var cachedTitle: String?
    public var needsAttention: Bool = false
    public var cachedUnacknowledgedCount: Int = 0

    public init(sessionId: String, cwd: String, gitBranch: String? = nil, slug: String? = nil, startedAt: Date = Date(), updatedAt: Date = Date()) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.gitBranch = gitBranch
        self.slug = slug
        self.startedAt = startedAt
        self.updatedAt = updatedAt
    }

    public var jsonlFileURL: URL? {
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
    public var displayTitle: String {
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
    public var unacknowledgedCount: Int {
        cachedUnacknowledgedCount
    }
}
