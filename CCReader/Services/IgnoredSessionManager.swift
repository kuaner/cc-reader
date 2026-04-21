import Foundation

/// Tracks deleted sessions so they are not re-imported from transcript files.
class IgnoredSessionManager {
    static let shared = IgnoredSessionManager()

    private static let key = "ignored.session.ids"

    private init() {}

    /// Set of ignored session IDs.
    var ignoredSessionIds: Set<String> {
        get {
            let array = UserDefaults.standard.stringArray(forKey: Self.key) ?? []
            return Set(array)
        }
        set {
            UserDefaults.standard.set(Array(newValue), forKey: Self.key)
        }
    }

    /// Add a session to the ignore list.
    func ignore(sessionId: String) {
        var ids = ignoredSessionIds
        ids.insert(sessionId)
        ignoredSessionIds = ids
    }

    /// Check whether a session is ignored.
    func isIgnored(sessionId: String) -> Bool {
        ignoredSessionIds.contains(sessionId)
    }

    /// Remove a session from the ignore list.
    func unignore(sessionId: String) {
        var ids = ignoredSessionIds
        ids.remove(sessionId)
        ignoredSessionIds = ids
    }

    /// Clear the entire ignore list.
    func clearAll() {
        ignoredSessionIds = []
    }
}
