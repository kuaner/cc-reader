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

    // --- Metadata decoded from JSONL entries ---
    /// User-set session title (from custom-title entries). Takes priority over slug/AI title.
    public var customTitle: String?
    /// AI-generated session title (from ai-title entries). Only used when no custom title.
    public var aiGeneratedTitle: String?
    /// Last user prompt for resume display (from last-prompt entries).
    public var lastPrompt: String?
    /// Session tag (from tag entries). Last-wins.
    public var sessionTag: String?
    /// Agent custom name (from agent-name entries).
    public var agentName: String?
    /// Agent color (from agent-color entries).
    public var agentColor: String?
    /// Agent definition used (from agent-setting entries).
    public var agentSetting: String?
    /// Session mode: coordinator or normal (from mode entries).
    public var sessionMode: String?
    /// Linked PR info (from pr-link entries).
    public var prNumber: Int?
    public var prUrl: String?
    public var prRepository: String?
    /// Conversation summary text (from summary entries, for compacted sessions).
    public var sessionSummary: String?
    /// Rolling task summary (from task-summary entries). Last-wins.
    public var taskSummary: String?

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
    /// Priority: custom title (user-set) > slug > cached title (first user message) > AI title > date.
    public var displayTitle: String {
        if let customTitle = customTitle, !customTitle.isEmpty {
            return customTitle
        }
        if let slug = slug {
            return slug.split(separator: "-")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
        if let cachedTitle = cachedTitle {
            return cachedTitle
        }
        if let aiTitle = aiGeneratedTitle, !aiTitle.isEmpty {
            return aiTitle
        }
        return Self.shortDateFormatter.string(from: startedAt)
    }

    /// Number of unacknowledged assistant messages.
    public var unacknowledgedCount: Int {
        cachedUnacknowledgedCount
    }
}
