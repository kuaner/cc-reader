import Foundation
import SwiftData

@ModelActor
actor SyncService {
    private let parser = JSONLParser()
    private let transcriptParsers = SessionTranscriptParserRegistry.shared
    private var loggedFilteredEventTypes: Set<String> = []

    // On first launch, scan file paths and create lightweight session rows only.
    func initialSync() async {
        let files = FileWatcherService.existingJSONLFiles()
        for file in files {
            ensureSessionIndex(fileURL: file)
        }

        try? modelContext.save()
    }

    // On file changes, rebuild only the changed session index.
    func incrementalSync(fileURL: URL) {
        rebuildSessionIndex(fileURL: fileURL)
        try? modelContext.save()
    }

    func warmupSessionMetadata() async {
        let files = FileWatcherService.existingJSONLFiles()
            .sorted { lhs, rhs in
                (fileModifiedDate(lhs) ?? .distantPast) > (fileModifiedDate(rhs) ?? .distantPast)
            }
        var processed = 0

        for file in files {
            if Task.isCancelled { return }
            guard shouldWarmup(fileURL: file) else { continue }
            rebuildSessionIndex(fileURL: file)
            processed += 1

            if processed % 20 == 0 {
                try? modelContext.save()
                await Task.yield()
            }
        }

        try? modelContext.save()
    }

    // MARK: - Session Indexing

    private func ensureSessionIndex(fileURL: URL) {
        guard let transcriptParser = transcriptParsers.parser(for: fileURL) else { return }
        let source = transcriptParser.source.rawValue
        let metadata = transcriptParser.readMetadata(from: fileURL)
        let projectPath = projectPath(fileURL: fileURL, metadata: metadata)
        let project = getOrCreateProject(path: projectPath)

        guard let sessionId = transcriptParser.sessionId(from: fileURL) else { return }

        if let existing = findSession(sessionId: sessionId) {
            existing.source = existing.source ?? source
            existing.transcriptPath = existing.transcriptPath ?? fileURL.path
            return
        }

        let fileDate = fileModifiedDate(fileURL) ?? Date()
        let session = Session(
            sessionId: sessionId,
            cwd: metadata?.cwd ?? "",
            gitBranch: metadata?.gitBranch,
            startedAt: fileDate,
            updatedAt: fileDate,
            source: source,
            transcriptPath: fileURL.path
        )
        session.project = project
        project.sessions.append(session)
        modelContext.insert(session)
    }

    private func rebuildSessionIndex(fileURL: URL) {
        guard let transcriptParser = transcriptParsers.parser(for: fileURL) else { return }
        let rawMessages = (try? parser.parseFile(url: fileURL)) ?? []
        guard !rawMessages.isEmpty else { return }

        let source = transcriptParser.source.rawValue
        let metadata = transcriptParser.readMetadata(from: fileURL)
        let projectPath = projectPath(fileURL: fileURL, metadata: metadata)
        let project = getOrCreateProject(path: projectPath)

        guard let sessionId = transcriptParser.sessionId(from: fileURL) else { return }
        let firstTranscript = rawMessages.first(where: { $0.entryType?.isTranscriptMessage == true })
        let session = getOrCreateSession(
            sessionId: sessionId,
            in: project,
            from: firstTranscript,
            source: source,
            transcriptPath: fileURL.path
        )
        resetIndexedSessionState(session)
        session.source = source
        session.transcriptPath = fileURL.path

        var earliestTimestamp: Date?
        var latestTimestamp: Date?
        var firstUserContent: String?

        for raw in rawMessages {
            guard let entryType = raw.entryType else {
                logFilteredEventIfNeeded(raw)
                continue
            }

            if let ts = raw.timestamp.flatMap(parseTimestamp) {
                if earliestTimestamp == nil || ts < earliestTimestamp! {
                    earliestTimestamp = ts
                }
                if latestTimestamp == nil || ts > latestTimestamp! {
                    latestTimestamp = ts
                }
            }

            if entryType.isSessionMetadata {
                applyMetadataEntry(raw, entryType: entryType, to: session)
                continue
            }

            if entryType == .summary || entryType == .taskSummary {
                applySummaryEntry(raw, entryType: entryType, to: session)
                continue
            }

            if entryType == .lastPrompt {
                if let prompt = raw.lastPrompt, !prompt.isEmpty {
                    session.lastPrompt = prompt
                }
                continue
            }

            if entryType == .system, raw.subtype == "compact_boundary" {
                session.isCompacted = true
            }

            if entryType.isTranscriptMessage {
                updateSessionCaches(session, with: raw, firstUserContent: &firstUserContent)
            }
        }

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

    private func shouldWarmup(fileURL: URL) -> Bool {
        guard let sessionId = JSONLParser.sessionId(from: fileURL),
              let session = findSession(sessionId: sessionId) else {
            return true
        }

        return session.cwd.isEmpty
            || session.cachedTurnCount == 0
            || session.cachedTitle == nil && session.slug == nil
            || session.gitBranch == nil
            || session.transcriptPath == nil
    }

    private func resetIndexedSessionState(_ session: Session) {
        session.lastUserMessageAt = nil
        session.cachedTurnCount = 0
        session.cachedTitle = nil
        session.cachedUnacknowledgedCount = 0
        session.aiGeneratedTitle = nil
        session.lastPrompt = nil
        session.sessionTag = nil
        session.agentName = nil
        session.agentColor = nil
        session.agentSetting = nil
        session.sessionMode = nil
        session.prNumber = nil
        session.prUrl = nil
        session.prRepository = nil
        session.sessionSummary = nil
        session.taskSummary = nil
        session.isCompacted = false
    }

    private func updateSessionCaches(
        _ session: Session,
        with raw: RawMessageData,
        firstUserContent: inout String?
    ) {
        guard let messageType = resolveMessageType(from: raw) else {
            logFilteredEventIfNeeded(raw)
            return
        }

        let timestamp = raw.timestamp.flatMap(parseTimestamp) ?? Date()

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
                if firstUserContent == nil {
                    firstUserContent = content
                    session.cachedTitle = extractTitle(from: content)
                }
            }
        } else if messageType == .assistant,
                  let lastUserAt = session.lastUserMessageAt,
                  timestamp > lastUserAt {
            session.cachedUnacknowledgedCount += 1
        }
    }

    // MARK: - Database Operations

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

    private func getOrCreateSession(
        sessionId: String,
        in project: Project,
        from firstMessage: RawMessageData?,
        source: String,
        transcriptPath: String
    ) -> Session {
        if let existing = findSession(sessionId: sessionId) {
            existing.source = existing.source ?? source
            existing.transcriptPath = existing.transcriptPath ?? transcriptPath
            if let slug = firstMessage?.slug,
               existing.slug == nil,
               !existing.isSlugManual,
               !sessionId.hasPrefix("agent-"),
               source == "claude" {
                existing.slug = slug
            }
            return existing
        }

        if source == "claude",
           !sessionId.hasPrefix("agent-"),
           let slug = firstMessage?.slug,
           !slug.isEmpty {
            let projectPath = project.path
            let slugPredicate = #Predicate<Session> { $0.slug == slug && $0.project?.path == projectPath }
            let slugDescriptor = FetchDescriptor<Session>(predicate: slugPredicate)

            if let matches = try? modelContext.fetch(slugDescriptor),
               let existingBySlug = matches.first(where: { !$0.sessionId.hasPrefix("agent-") }) {
                if !existingBySlug.additionalSessionIds.contains(sessionId) {
                    existingBySlug.additionalSessionIds.append(sessionId)
                }
                return existingBySlug
            }
        }

        let cwd = firstMessage?.cwd ?? ""
        let gitBranch = firstMessage?.gitBranch
        let slug = firstMessage?.slug
        let messageTime = firstMessage.flatMap { $0.timestamp.flatMap(parseTimestamp) } ?? Date()

        let session = Session(
            sessionId: sessionId,
            cwd: cwd,
            gitBranch: gitBranch,
            slug: slug,
            startedAt: messageTime,
            updatedAt: messageTime,
            source: source,
            transcriptPath: transcriptPath
        )
        session.project = project
        project.sessions.append(session)
        modelContext.insert(session)
        return session
    }

    private func findSession(sessionId: String) -> Session? {
        let predicate = #Predicate<Session> { $0.sessionId == sessionId }
        let descriptor = FetchDescriptor<Session>(predicate: predicate)
        return try? modelContext.fetch(descriptor).first
    }

    private func resolveMessageType(from raw: RawMessageData) -> MessageType? {
        JSONLParser.resolveMessageType(from: raw)
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
            if let title = raw.aiTitle, !title.isEmpty, session.customTitle == nil {
                session.aiGeneratedTitle = title
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
            break
        default:
            break
        }
    }

    private func applySummaryEntry(_ raw: RawMessageData, entryType: JSONLEntryType, to session: Session) {
        if entryType == .summary, let summaryText = raw.summary, !summaryText.isEmpty {
            session.sessionSummary = summaryText
            session.isCompacted = true
        }
        if entryType == .taskSummary, let text = raw.summary, !text.isEmpty {
            session.taskSummary = text
        }
    }

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

    private func extractTitle(from content: String) -> String {
        let firstLine = content.components(separatedBy: .newlines).first ?? content
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        if trimmed.count > 40 {
            return String(trimmed.prefix(40)) + "..."
        }
        return trimmed.isEmpty ? "..." : trimmed
    }

    private func parseTimestamp(_ string: String) -> Date? {
        JSONLParser.parseTimestamp(string)
    }

    private func fileModifiedDate(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private func projectPath(fileURL: URL, metadata: SessionTranscriptMetadata?) -> String {
        if let cwd = metadata?.cwd, !cwd.isEmpty {
            return JSONLParser.projectPath(fromCwd: cwd)
        }
        return fileURL.deletingLastPathComponent().lastPathComponent
    }

}
