import Foundation
import SwiftData

@MainActor
class SyncService: ObservableObject {
    private let parser = JSONLParser()
    private let modelContext: ModelContext
    private static let sharedEncoder = JSONEncoder()
    private var loggedFilteredEventTypes: Set<String> = []

    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncedFile: URL?
    @Published private(set) var syncedMessageCount = 0
    @Published private(set) var syncProgress: String = ""

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // On first launch, scan only files that are not already imported.
    func fullSync() async {
        isSyncing = true
        syncProgress = String(localized: "sync.searchingFiles")

        let files = FileWatcherService.existingJSONLFiles()
        // Keep only files that do not already have a matching session.
        var newFiles: [URL] = []
        newFiles.reserveCapacity(files.count)
        for file in files {
            guard let sessionId = JSONLParser.sessionId(from: file) else { continue }
            if !(await sessionExists(sessionId: sessionId)) {
                newFiles.append(file)
            }
        }

        print("Full sync: \(files.count) files, \(newFiles.count) new")

        for (index, file) in newFiles.enumerated() {
            syncProgress = String(
                format: String(localized: "sync.progress.indexed"),
                index + 1,
                newFiles.count
            )

            // Parse in the background.
            let rawMessages = await parseFileInBackground(file)

            // Persist on the main actor.
            await processMessages(rawMessages, from: file)

            // Yield briefly to keep the UI responsive.
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }

        try? modelContext.save()
        syncProgress = ""
        isSyncing = false
        print("Full sync completed: \(syncedMessageCount) messages")
    }

    private func sessionExists(sessionId: String) async -> Bool {
        let predicate = #Predicate<Session> { $0.sessionId == sessionId }
        var descriptor = FetchDescriptor<Session>(predicate: predicate)
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor).isEmpty == false) ?? false
    }

    // On file changes, import only newly appended data.
    func incrementalSync(fileURL: URL) async {
        let rawMessages = await parseNewLinesInBackground(fileURL)
        await processMessages(rawMessages, from: fileURL)
        try? modelContext.save()
    }

    // MARK: - Background Parsing

    private func parseFileInBackground(_ fileURL: URL) async -> [RawMessageData] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [parser] in
                let messages = (try? parser.parseFile(url: fileURL)) ?? []
                // Record the file size after a full sync completes.
                if let fileSize = try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? UInt64 {
                    DispatchQueue.main.async {
                        parser.setOffset(fileSize, for: fileURL)
                    }
                }
                continuation.resume(returning: messages)
            }
        }
    }

    private func parseNewLinesInBackground(_ fileURL: URL) async -> [RawMessageData] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [parser] in
                let messages = (try? parser.parseNewLines(url: fileURL)) ?? []
                continuation.resume(returning: messages)
            }
        }
    }

    // MARK: - Database Operations

    private func processMessages(_ rawMessages: [RawMessageData], from fileURL: URL) async {
        guard !rawMessages.isEmpty else { return }

        // Fetch or create the project.
        let projectPath = fileURL.deletingLastPathComponent().lastPathComponent
        let project = getOrCreateProject(path: projectPath)

        // Fetch or create the session.
        guard let sessionId = JSONLParser.sessionId(from: fileURL) else { return }
        let session = getOrCreateSession(sessionId: sessionId, in: project, from: rawMessages.first)

        // Collect existing UUIDs once to avoid N+1 fetches.
        let existingUuids = Set(session.messages.map { $0.uuid })

        // Add new messages in a batch.
        for raw in rawMessages {
            // Check duplicates in memory.
            if existingUuids.contains(raw.uuid) { continue }
            addMessageWithoutCheck(raw: raw, to: session)
        }

        // Refresh session timestamps from message timestamps.
        if let firstTimestamp = rawMessages.first.flatMap({ parseTimestamp($0.timestamp) }) {
            // Keep the earliest known start time.
            if session.startedAt > firstTimestamp {
                session.startedAt = firstTimestamp
            }
        }
        if let lastTimestamp = rawMessages.last.flatMap({ parseTimestamp($0.timestamp) }) {
            // Keep the latest update time.
            if session.updatedAt < lastTimestamp {
                session.updatedAt = lastTimestamp
            }
            if project.updatedAt < lastTimestamp {
                project.updatedAt = lastTimestamp
            }
        }

        lastSyncedFile = fileURL
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
        if let slug = firstMessage?.slug, !slug.isEmpty {
            let projectPath = project.path
            let slugPredicate = #Predicate<Session> { $0.slug == slug && $0.project?.path == projectPath }
            let slugDescriptor = FetchDescriptor<Session>(predicate: slugPredicate)

            if let existingBySlug = try? modelContext.fetch(slugDescriptor).first {
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
        let messageTime = firstMessage.flatMap { parseTimestamp($0.timestamp) } ?? Date()

        let session = Session(sessionId: sessionId, cwd: cwd, gitBranch: gitBranch, slug: slug, startedAt: messageTime, updatedAt: messageTime)
        session.project = project
        project.sessions.append(session)
        modelContext.insert(session)
        return session
    }

    private func addMessage(raw: RawMessageData, to session: Session) {
        let uuid = raw.uuid
        let predicate = #Predicate<Message> { $0.uuid == uuid }
        let descriptor = FetchDescriptor<Message>(predicate: predicate)

        if (try? modelContext.fetch(descriptor).first) != nil {
            return
        }

        addMessageWithoutCheck(raw: raw, to: session)
    }

    /// Add a message without a separate duplicate lookup.
    private func addMessageWithoutCheck(raw: RawMessageData, to session: Session) {
        // Claude Code JSONL mixes in non-conversation events such as progress updates.
        // Saving them as assistant messages creates blank timeline rows, so only
        // user / assistant messages, or equivalents inferred from message.role, are imported.
        guard let messageType = resolveMessageType(from: raw) else {
            logFilteredEventIfNeeded(raw)
            return
        }

        let timestamp = parseTimestamp(raw.timestamp) ?? Date()
        let rawJson: Data
        if let original = raw.originalLineData {
            rawJson = original
        } else if let encoded = try? Self.sharedEncoder.encode(raw) {
            rawJson = encoded
        } else {
            return
        }

        let message = Message(
            uuid: raw.uuid,
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
        } else if let lastUserAt = session.lastUserMessageAt, timestamp > lastUserAt {
            session.cachedUnacknowledgedCount += 1
        }
    }

    private func resolveMessageType(from raw: RawMessageData) -> MessageType? {
        switch raw.type.lowercased() {
        case "user":
            return .user
        case "assistant":
            return .assistant
        default:
            break
        }

        guard let role = raw.message?.role.lowercased() else { return nil }
        switch role {
        case "user":
            return .user
        case "assistant":
            return .assistant
        default:
            return nil
        }
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
        print("[cc-reader][SyncService] Filtered non-conversation event type=\(eventType), role=\(role), uuid=\(raw.uuid)")
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
