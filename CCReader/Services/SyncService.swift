import Foundation
import SwiftData

@ModelActor
actor SyncService {
    private let parser = JSONLParser()
    private static let sharedEncoder = JSONEncoder()
    private var loggedFilteredEventTypes: Set<String> = []
    private var syncedMessageCount = 0

    /// Callbacks for UI state updates (invoked on MainActor by the caller).
    private var onSyncStateChanged: (@MainActor @Sendable (Bool, String) -> Void)?

    func setStateCallback(_ callback: @escaping @MainActor @Sendable (Bool, String) -> Void) {
        self.onSyncStateChanged = callback
    }

    private func updateUI(syncing: Bool, progress: String) async {
        if let callback = onSyncStateChanged {
            await callback(syncing, progress)
        }
    }

    // On first launch, scan only files that are not already imported.
    func fullSync() async {
        await updateUI(syncing: true, progress: L("sync.searchingFiles"))

        // Enumerate files off the main thread (already off main — we're an actor).
        let files = FileWatcherService.existingJSONLFiles()

        // Pre-fetch all known sessionIds in one query to avoid N sequential fetches.
        let existingIds: Set<String>
        do {
            let descriptor = FetchDescriptor<Session>()
            let sessions = try modelContext.fetch(descriptor)
            existingIds = Set(sessions.map(\.sessionId))
        } catch {
            existingIds = []
        }

        // Filter new files in memory.
        var newFiles: [URL] = []
        newFiles.reserveCapacity(files.count)
        for file in files {
            guard let sessionId = JSONLParser.sessionId(from: file) else { continue }
            if !existingIds.contains(sessionId) {
                newFiles.append(file)
            }
        }

        print("Full sync: \(files.count) files, \(newFiles.count) new")

        for (index, file) in newFiles.enumerated() {
            let progress = String(
                format: L("sync.progress.indexed"),
                index + 1,
                newFiles.count
            )
            await updateUI(syncing: true, progress: progress)

            // Parse the file (we're already off main thread).
            let rawMessages = (try? parser.parseFile(url: file)) ?? []

            // Record the byte offset for future incremental parses.
            if let fileSize = try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? UInt64 {
                parser.setOffset(fileSize, for: file)
            }

            // Persist using the actor's own ModelContext.
            processMessages(rawMessages, from: file)
        }

        try? modelContext.save()
        await updateUI(syncing: false, progress: "")
        print("Full sync completed: \(syncedMessageCount) messages")
    }

    // On file changes, import only newly appended data.
    func incrementalSync(fileURL: URL) {
        let rawMessages = (try? parser.parseNewLines(url: fileURL)) ?? []
        processMessages(rawMessages, from: fileURL)
        try? modelContext.save()
    }

    // MARK: - Database Operations

    private func processMessages(_ rawMessages: [RawMessageData], from fileURL: URL) {
        guard !rawMessages.isEmpty else { return }

        // Fetch or create the project.
        let projectPath = fileURL.deletingLastPathComponent().lastPathComponent
        let project = getOrCreateProject(path: projectPath)

        // Fetch or create the session.
        guard let sessionId = JSONLParser.sessionId(from: fileURL) else { return }
        // For session resolution, use the first transcript message (not metadata).
        let firstTranscript = rawMessages.first(where: { $0.entryType?.isTranscriptMessage == true })
        let session = getOrCreateSession(sessionId: sessionId, in: project, from: firstTranscript)

        // Collect existing messages once to avoid N+1 fetches.
        var existingByUuid: [String: Message] = [:]
        existingByUuid.reserveCapacity(session.messages.count)
        for message in session.messages {
            existingByUuid[message.uuid] = message
        }

        var earliestTimestamp: Date?
        var latestTimestamp: Date?

        // Route each entry by its type — aligned with official Entry union dispatch.
        for raw in rawMessages {
            guard let entryType = raw.entryType else {
                // Unknown entry type — log and skip.
                logFilteredEventIfNeeded(raw)
                continue
            }

            // Track timestamps from all entries for session freshness.
            if let ts = raw.timestamp.flatMap({ parseTimestamp($0) }) {
                if earliestTimestamp == nil || ts < earliestTimestamp! {
                    earliestTimestamp = ts
                }
                if latestTimestamp == nil || ts > latestTimestamp! {
                    latestTimestamp = ts
                }
            }

            // Route: session metadata → update session directly, no Message row.
            if entryType.isSessionMetadata {
                applyMetadataEntry(raw, entryType: entryType, to: session)
                continue
            }

            // Route: summary entries → store on session for context collapse display.
            if entryType == .summary || entryType == .taskSummary {
                applySummaryEntry(raw, entryType: entryType, to: session)
                continue
            }

            // Route: last-prompt → update session's last prompt display.
            if entryType == .lastPrompt {
                if let prompt = raw.lastPrompt, !prompt.isEmpty {
                    session.lastPrompt = prompt
                }
                continue
            }

            // Route: compact_boundary → mark session as compacted.
            if entryType == .system, raw.subtype == "compact_boundary" {
                session.isCompacted = true
            }

            // Route: transcript messages (user/assistant/system/attachment) → Message rows.
            if entryType.isTranscriptMessage {
                guard let uuid = raw.uuid, !uuid.isEmpty else { continue }

                if let existing = existingByUuid[uuid] {
                    updateMessageIfNeeded(existing, from: raw)
                    continue
                }
                addMessageWithoutCheck(raw: raw, to: session)
                continue
            }

            // All other entry types (file-history-snapshot, attribution-snapshot,
            // content-replacement, context-collapse, speculation-accept, queue-operation)
            // are internal/technical — skip silently.
        }

        // Refresh session timestamps.
        if let earliest = earliestTimestamp, session.startedAt > earliest {
            session.startedAt = earliest
        }
        if let latest = latestTimestamp {
            if session.updatedAt < latest {
                session.updatedAt = latest
            }
            if project.updatedAt < latest {
                project.updatedAt = latest
            }
        }
    }

    private func getOrCreateProject(path: String) -> Project {
        let predicate = #Predicate<Project> { $0.path == path }
        let descriptor = FetchDescriptor<Project>(predicate: predicate)

        if let existing = try? modelContext.fetch(descriptor).first {
            return existing
        }

        let displayName = JSONLParser.displayName(from: path)
        let project = Project(path: path, displayName: displayName)
        modelContext.insert(project)
        return project
    }

    private func getOrCreateSession(sessionId: String, in project: Project, from firstMessage: RawMessageData?) -> Session {
        // First try a direct lookup by sessionId.
        let predicate = #Predicate<Session> { $0.sessionId == sessionId }
        let descriptor = FetchDescriptor<Session>(predicate: predicate)

        if let existing = try? modelContext.fetch(descriptor).first {
            // Only update the slug when it was not manually assigned.
            if let slug = firstMessage?.slug, existing.slug == nil, !existing.isSlugManual {
                existing.slug = slug
            }
            // Rebuild caches when migrating older rows that do not have them yet.
            if existing.cachedTurnCount == 0 && !existing.messages.isEmpty {
                rebuildSessionCache(existing)
            }
            return existing
        }

        // If sessionId misses, try to merge by slug within the same project.
        // Subagent files (agent-*.jsonl) always stay separate; slug merge only targets
        // non-agent sessions so agent transcripts are not folded into the main thread.
        if !sessionId.hasPrefix("agent-"), let slug = firstMessage?.slug, !slug.isEmpty {
            let projectPath = project.path
            let slugPredicate = #Predicate<Session> { $0.slug == slug && $0.project?.path == projectPath }
            let slugDescriptor = FetchDescriptor<Session>(predicate: slugPredicate)

            if let matches = try? modelContext.fetch(slugDescriptor),
               let existingBySlug = matches.first(where: { !$0.sessionId.hasPrefix("agent-") }) {
                // Merge sessions that share the same slug.
                // Track secondary IDs without duplicating them.
                if !existingBySlug.additionalSessionIds.contains(sessionId) {
                    existingBySlug.additionalSessionIds.append(sessionId)
                }
                return existingBySlug
            }
        }

        // Create a brand-new session.
        let cwd = firstMessage?.cwd ?? ""
        let gitBranch = firstMessage?.gitBranch
        let slug = firstMessage?.slug

        // Seed timestamps from the first message when possible.
        let messageTime = firstMessage.flatMap { $0.timestamp.flatMap(parseTimestamp) } ?? Date()

        let session = Session(sessionId: sessionId, cwd: cwd, gitBranch: gitBranch, slug: slug, startedAt: messageTime, updatedAt: messageTime)
        session.project = project
        project.sessions.append(session)
        modelContext.insert(session)
        return session
    }

    private func addMessage(raw: RawMessageData, to session: Session) {
        guard let uuid = raw.uuid else { return }
        let predicate = #Predicate<Message> { $0.uuid == uuid }
        let descriptor = FetchDescriptor<Message>(predicate: predicate)

        if (try? modelContext.fetch(descriptor).first) != nil {
            return
        }

        addMessageWithoutCheck(raw: raw, to: session)
    }

    /// Add a transcript message without a separate duplicate lookup.
    /// Only called after entry type routing confirms this is a transcript message.
    private func addMessageWithoutCheck(raw: RawMessageData, to session: Session) {
        guard let messageType = resolveMessageType(from: raw) else {
            logFilteredEventIfNeeded(raw)
            return
        }
        guard let uuid = raw.uuid, !uuid.isEmpty else { return }

        let timestamp = raw.timestamp.flatMap { parseTimestamp($0) } ?? Date()
        let rawJson: Data
        if let original = raw.originalLineData {
            rawJson = original
        } else if let encoded = try? Self.sharedEncoder.encode(raw) {
            rawJson = encoded
        } else {
            return
        }

        let message = Message(
            uuid: uuid,
            type: messageType,
            timestamp: timestamp,
            rawJson: rawJson,
            parentUuid: raw.parentUuid
        )
        message.session = session
        session.messages.append(message)
        modelContext.insert(message)

        syncedMessageCount += 1

        // Refresh session caches directly from the raw payload to avoid re-decoding JSON.
        if messageType == .user {
            let contentText: String? = {
                if let str = raw.message?.contentString, !str.isEmpty { return str }
                return raw.message?.content?
                    .filter { $0.type == "text" }
                    .compactMap { $0.text }
                    .joined(separator: "\n")
            }()
            if let content = contentText, !content.isEmpty {
                session.cachedTurnCount += 1
                session.lastUserMessageAt = timestamp
                session.cachedUnacknowledgedCount = 0
                if session.cachedTitle == nil {
                    session.cachedTitle = extractTitle(from: content)
                }
            }
        } else if messageType == .assistant, let lastUserAt = session.lastUserMessageAt, timestamp > lastUserAt {
            session.cachedUnacknowledgedCount += 1
        }
    }

    /// Update an existing message row when a newer line reuses the same UUID.
    /// This is common for streaming assistant output/tool status updates.
    private func updateMessageIfNeeded(_ message: Message, from raw: RawMessageData) {
        guard let messageType = resolveMessageType(from: raw) else { return }

        let timestamp = raw.timestamp.flatMap { parseTimestamp($0) } ?? message.timestamp
        let rawJson: Data
        if let original = raw.originalLineData {
            rawJson = original
        } else if let encoded = try? Self.sharedEncoder.encode(raw) {
            rawJson = encoded
        } else {
            return
        }

        var changed = false
        if message.type != messageType {
            message.type = messageType
            changed = true
        }
        if message.timestamp != timestamp {
            message.timestamp = timestamp
            changed = true
        }
        if message.parentUuid != raw.parentUuid {
            message.parentUuid = raw.parentUuid
            changed = true
        }
        if message.rawJson != rawJson {
            message.rawJson = rawJson
            changed = true
        }

        if changed {
            message.invalidateCache()
        }
    }

    /// Resolve MessageType from the top-level `type` field only.
    /// Aligned with official `isTranscriptMessage()` — no fallback to message.role.
    private func resolveMessageType(from raw: RawMessageData) -> MessageType? {
        switch raw.type.lowercased() {
        case "user":
            return .user
        case "assistant":
            return .assistant
        case "system":
            return .system
        case "attachment":
            return .attachment
        default:
            return nil
        }
    }

    /// Apply a session-scoped metadata entry to the Session model.
    /// Aligned with official loadTranscriptFile metadata dispatch (sessionStorage.ts:3585-3698).
    private func applyMetadataEntry(_ raw: RawMessageData, entryType: JSONLEntryType, to session: Session) {
        switch entryType {
        case .customTitle:
            if let title = raw.customTitle, !title.isEmpty {
                session.customTitle = title
            }
        case .aiTitle:
            if let title = raw.aiTitle, !title.isEmpty {
                // AI titles only set when no user-set title exists.
                if session.customTitle == nil {
                    session.aiGeneratedTitle = title
                }
            }
        case .tag:
            if let tag = raw.tag, !tag.isEmpty {
                session.sessionTag = tag
            }
        case .agentName:
            if let name = raw.agentName, !name.isEmpty {
                session.agentName = name
            }
        case .agentColor:
            if let color = raw.agentColor, !color.isEmpty {
                session.agentColor = color
            }
        case .agentSetting:
            if let setting = raw.agentSetting, !setting.isEmpty {
                session.agentSetting = setting
            }
        case .prLink:
            session.prNumber = raw.prNumber
            if let url = raw.prUrl, !url.isEmpty {
                session.prUrl = url
            }
            if let repo = raw.prRepository, !repo.isEmpty {
                session.prRepository = repo
            }
        case .mode:
            if let mode = raw.mode, !mode.isEmpty {
                session.sessionMode = mode
            }
        case .worktreeState:
            // worktree-session state is available as raw JSON if needed.
            // Currently we only need to know that a worktree session exists.
            break
        default:
            break
        }
    }

    /// Apply a summary entry to the Session model.
    /// Summary entries carry conversation summaries for compacted sessions.
    private func applySummaryEntry(_ raw: RawMessageData, entryType: JSONLEntryType, to session: Session) {
        if entryType == .summary, let summaryText = raw.summary, !summaryText.isEmpty {
            session.sessionSummary = summaryText
            session.isCompacted = true
        }
        // task-summary entries are rolling status updates; they don't replace the canonical summary.
        // They could be shown as a status indicator in the UI in the future.
    }

    /// Log filtered non-conversation events only when debugging is enabled.
    /// Enable with:
    /// - defaults write com.your.bundle.id debug.logFilteredSessionEvents -bool true
    /// - environment variable CCREADER_DEBUG_FILTERED_EVENTS=1
    private func logFilteredEventIfNeeded(_ raw: RawMessageData) {
        guard isFilteredEventLoggingEnabled else { return }
        let eventType = raw.type.lowercased()
        guard !loggedFilteredEventTypes.contains(eventType) else { return }
        loggedFilteredEventTypes.insert(eventType)

        let role = raw.message?.role ?? "nil"
        print("[cc-reader][SyncService] Filtered non-conversation event type=\(eventType), role=\(role), uuid=\(raw.uuid ?? "nil")")
    }

    private var isFilteredEventLoggingEnabled: Bool {
        if ProcessInfo.processInfo.environment["CCREADER_DEBUG_FILTERED_EVENTS"] == "1" {
            return true
        }
        return UserDefaults.standard.bool(forKey: "debug.logFilteredSessionEvents")
    }

    /// Rebuild cached session metadata for migrated or older rows.
    private func rebuildSessionCache(_ session: Session) {
        var turnCount = 0
        var firstUserContent: String?
        var lastUserMessageAt: Date?
        var assistantAfterLastUser = 0

        for message in session.messages where message.type == .user {
            if let content = message.content, !content.isEmpty {
                turnCount += 1
                lastUserMessageAt = message.timestamp
                if firstUserContent == nil {
                    firstUserContent = content
                }
            }
        }

        session.cachedTurnCount = turnCount
        session.lastUserMessageAt = lastUserMessageAt
        if let lastUserMessageAt {
            assistantAfterLastUser = session.messages.filter {
                $0.type == .assistant && $0.timestamp > lastUserMessageAt
            }.count
        }
        session.cachedUnacknowledgedCount = assistantAfterLastUser
        if let content = firstUserContent {
            session.cachedTitle = extractTitle(from: content)
        }
    }

    private func extractTitle(from content: String) -> String {
        let firstLine = content.components(separatedBy: .newlines).first ?? content
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        if trimmed.count > 40 {
            return String(trimmed.prefix(40)) + "..."
        }
        return trimmed.isEmpty ? "..." : trimmed
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private func parseTimestamp(_ string: String) -> Date? {
        Self.timestampFormatter.date(from: string)
    }
}
