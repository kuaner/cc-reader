import Foundation

/// 削除済みセッションを管理（.claudeから再同期されないようにする）
class IgnoredSessionManager {
    static let shared = IgnoredSessionManager()

    private static let key = "ignored.session.ids"

    private init() {}

    /// 無視するセッションIDのセット
    var ignoredSessionIds: Set<String> {
        get {
            let array = UserDefaults.standard.stringArray(forKey: Self.key) ?? []
            return Set(array)
        }
        set {
            UserDefaults.standard.set(Array(newValue), forKey: Self.key)
        }
    }

    /// セッションを無視リストに追加
    func ignore(sessionId: String) {
        var ids = ignoredSessionIds
        ids.insert(sessionId)
        ignoredSessionIds = ids
    }

    /// セッションが無視されているか
    func isIgnored(sessionId: String) -> Bool {
        ignoredSessionIds.contains(sessionId)
    }

    /// 無視リストから削除（復活させる場合）
    func unignore(sessionId: String) {
        var ids = ignoredSessionIds
        ids.remove(sessionId)
        ignoredSessionIds = ids
    }

    /// 全てクリア
    func clearAll() {
        ignoredSessionIds = []
    }
}
