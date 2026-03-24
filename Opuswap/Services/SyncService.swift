import Foundation
import SwiftData

@MainActor
class SyncService: ObservableObject {
    private let parser = JSONLParser()
    private let modelContext: ModelContext
    private static let sharedEncoder = JSONEncoder()

    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncedFile: URL?
    @Published private(set) var syncedMessageCount = 0
    @Published private(set) var syncProgress: String = ""

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // 初回起動時: 新規ファイルのみスキャン
    func fullSync() async {
        isSyncing = true
        syncProgress = "ファイルを検索中..."

        let files = FileWatcherService.existingJSONLFiles()
        // 新規ファイルのみフィルタ
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
            syncProgress = "同期中 \(index + 1)/\(newFiles.count)"

            // バックグラウンドでパース
            let rawMessages = await parseFileInBackground(file)

            // メインスレッドでDB保存
            await processMessages(rawMessages, from: file)

            // UIの応答性を保つため少し待機
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

    // ファイル変更時: 差分のみ追加
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
                // フルシンク後にオフセットを記録
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

        // プロジェクトを取得または作成
        let projectPath = fileURL.deletingLastPathComponent().lastPathComponent
        let project = getOrCreateProject(path: projectPath)

        // セッションを取得または作成
        guard let sessionId = JSONLParser.sessionId(from: fileURL) else { return }
        let session = getOrCreateSession(sessionId: sessionId, in: project, from: rawMessages.first)

        // 既存のUUIDを一括取得（N+1クエリ回避）
        let existingUuids = Set(session.messages.map { $0.uuid })

        // メッセージを追加（バッチ処理）
        for raw in rawMessages {
            // 重複チェック（メモリ上で実行）
            if existingUuids.contains(raw.uuid) { continue }
            addMessageWithoutCheck(raw: raw, to: session)
        }

        // セッションの時間をメッセージのtimestampから設定
        if let firstTimestamp = rawMessages.first.flatMap({ parseTimestamp($0.timestamp) }) {
            // startedAtが未設定か、より古いtimestampがあれば更新
            if session.startedAt > firstTimestamp {
                session.startedAt = firstTimestamp
            }
        }
        if let lastTimestamp = rawMessages.last.flatMap({ parseTimestamp($0.timestamp) }) {
            // 最新のtimestampでupdatedAtを更新
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
        // まずsessionIdで検索（既存の動作）
        let predicate = #Predicate<Session> { $0.sessionId == sessionId }
        let descriptor = FetchDescriptor<Session>(predicate: predicate)

        if let existing = try? modelContext.fetch(descriptor).first {
            // 手動設定されていない場合のみslugを更新
            if let slug = firstMessage?.slug, existing.slug == nil, !existing.isSlugManual {
                existing.slug = slug
            }
            // キャッシュが未設定なら再計算（マイグレーション対応）
            if existing.cachedTurnCount == 0 && !existing.messages.isEmpty {
                rebuildSessionCache(existing)
            }
            return existing
        }

        // sessionIdで見つからない場合、同じslugを持つセッションを検索（マージ）
        if let slug = firstMessage?.slug, !slug.isEmpty {
            let projectPath = project.path
            let slugPredicate = #Predicate<Session> { $0.slug == slug && $0.project?.path == projectPath }
            let slugDescriptor = FetchDescriptor<Session>(predicate: slugPredicate)

            if let existingBySlug = try? modelContext.fetch(slugDescriptor).first {
                // 同じslugのセッションが見つかった → マージ
                // additionalSessionIdsに追加（重複回避）
                if !existingBySlug.additionalSessionIds.contains(sessionId) {
                    existingBySlug.additionalSessionIds.append(sessionId)
                }
                return existingBySlug
            }
        }

        // 新規セッション作成
        let cwd = firstMessage?.cwd ?? ""
        let gitBranch = firstMessage?.gitBranch
        let slug = firstMessage?.slug

        // メッセージのtimestampを使用
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

    /// 重複チェックなしでメッセージを追加（バッチ処理用）
    private func addMessageWithoutCheck(raw: RawMessageData, to session: Session) {
        let timestamp = parseTimestamp(raw.timestamp) ?? Date()
        let rawJson: Data
        if let original = raw.originalLineData {
            rawJson = original
        } else if let encoded = try? Self.sharedEncoder.encode(raw) {
            rawJson = encoded
        } else {
            return
        }

        let messageType: MessageType = raw.type == "user" ? .user : .assistant
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

        // セッションのキャッシュを更新（rawから直接取得してJSONの再デコードを回避）
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

    /// 既存セッションのキャッシュを再計算（マイグレーション用）
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
