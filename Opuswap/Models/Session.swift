import Foundation
import SwiftData

@Model
class Session {
    @Attribute(.unique) var sessionId: String  // UUID
    var project: Project?
    @Relationship(deleteRule: .cascade, inverse: \Message.session)
    var messages: [Message] = []
    var slug: String?                          // "streamed-skipping-tarjan"
    var isSlugManual: Bool = false             // 手動設定されたslugは上書きしない
    var additionalSessionIds: [String] = []   // マージされた他のsessionId（plan/subagent用）
    var cwd: String
    var gitBranch: String?
    var startedAt: Date
    var updatedAt: Date
    var isCompacted: Bool = false              // compact検出フラグ
    var lastUserMessageAt: Date?               // ユーザーが最後にメッセージを送った時刻
    var cachedTurnCount: Int = 0               // ユーザーの指示回数（キャッシュ）
    var cachedTitle: String?                   // セッションタイトル（キャッシュ）
    var needsAttention: Bool = false           // 未読の回答あり

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

    /// 表示用タイトル
    var displayTitle: String {
        if let slug = slug {
            return slug.split(separator: "-")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
        if let cachedTitle = cachedTitle {
            return cachedTitle
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d HH:mm"
        return formatter.string(from: startedAt)
    }

    /// 未確認メッセージ数
    var unacknowledgedCount: Int {
        guard let lastUserAt = lastUserMessageAt else { return 0 }
        return messages.filter { $0.type == .assistant && $0.timestamp > lastUserAt }.count
    }
}
