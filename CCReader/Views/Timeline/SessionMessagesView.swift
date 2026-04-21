import SwiftUI
import SwiftData

struct SessionMessagesView: View {
    let session: Session
    @Binding var visibleMessageCount: Int
    @Binding var showContextPanel: Bool

    // Snapshot of the timeline render state.
    @State private var timeline = TimelineRenderSnapshot()

    // Snapshot used by the context panel.
    @State private var contextPanel = ContextPanelSnapshot()
    @State private var messages: [Message] = []
    @State private var isLargeSessionMode = false
    @State private var hasMoreOlderMessages = false
    @State private var loadedMessageCount = Self.largeSessionInitialMessageCount
    @State private var timelineLoadGeneration = 0
    @State private var timelineLoader = SessionFileTimelineLoader()

    private static let largeSessionThresholdBytes = 5 * 1024 * 1024
    private static let largeSessionInitialMessageCount = 200
    private static let largeSessionPageSize = 200

    init(session: Session, visibleMessageCount: Binding<Int>, showContextPanel: Binding<Bool>) {
        self.session = session
        self._visibleMessageCount = visibleMessageCount
        self._showContextPanel = showContextPanel
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                if let summary = session.sessionSummary, !summary.isEmpty {
                    CompactedSessionBanner(summary: summary)
                }

                if isLargeSessionMode {
                    LargeSessionBanner(messageCount: messages.count)
                }

                TimelineHostView(
                    sessionId: session.sessionId,
                    snapshot: timeline,
                    onRequestOlderMessages: isLargeSessionMode ? loadOlderMessagesPage : nil
                )
                .equatable()
                .clipped()
                .transaction { $0.animation = nil }
            }

            if showContextPanel {
                Divider()
                ContextPanel(snapshot: contextPanel)
                    .frame(width: 260)
            }
        }
        .onAppear {
            reloadMessages(forceReload: true)
        }
        .onChange(of: session.sessionId) { _, _ in
            resetViewState()
            reloadMessages(forceReload: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .sessionDidSync)) { notification in
            guard notification.object as? String == session.sessionId else { return }
            reloadMessages()
        }
        .onChange(of: messageFingerprint) { _, _ in
            rebuildDerivedData()
        }
    }

    // MARK: - Derived Data

    @State private var derivedDataGeneration = 0
    @State private var lastFingerprint = MessageFingerprint(count: 0, hash: 0)
    @State private var lastVisibleMessageCount = 0
    @State private var derivedToolUseMap: [String: ToolUseInfo] = [:]
    @State private var toolUseOwnerMap: [String: String] = [:]
    @State private var shouldForceFullRebuild = false

    /// Lightweight fingerprint hash — count + XOR accumulator of raw JSON hashes.
    /// O(n) but only integer ops (no string allocation).
    private struct MessageFingerprint: Equatable {
        var count: Int
        var hash: Int
    }
    @State private var messageFingerprint = MessageFingerprint(count: 0, hash: 0)

    private func fingerprint(for messages: [Message]) -> MessageFingerprint {
        var accumulator = 0
        for msg in messages {
            accumulator ^= msg.rawJson.hashValue
        }
        return MessageFingerprint(count: messages.count, hash: accumulator)
    }

    private func resetViewState() {
        messages = []
        timeline = TimelineRenderSnapshot()
        contextPanel = ContextPanelSnapshot()
        visibleMessageCount = 0
        hasMoreOlderMessages = false
        loadedMessageCount = Self.largeSessionInitialMessageCount
        lastFingerprint = MessageFingerprint(count: 0, hash: 0)
        lastVisibleMessageCount = 0
        messageFingerprint = MessageFingerprint(count: 0, hash: 0)
        derivedToolUseMap = [:]
        toolUseOwnerMap = [:]
        shouldForceFullRebuild = false
        isLargeSessionMode = false
    }

    private func reloadMessages(forceReload: Bool = false) {
        let largeMode = shouldUseLargeSessionMode()
        timelineLoadGeneration += 1
        let generation = timelineLoadGeneration

        Task {
            let state = await timelineLoader.load(
                sessionId: session.sessionId,
                fileURL: session.jsonlFileURL,
                largeMode: largeMode,
                initialMessageCount: Self.largeSessionInitialMessageCount,
                forceReload: forceReload
            )

            guard generation == timelineLoadGeneration else { return }

            let mappedMessages = state.messages.map { $0.makeMessage() }
            messages = mappedMessages
            loadedMessageCount = mappedMessages.count
            hasMoreOlderMessages = state.hasMoreBefore
            messageFingerprint = fingerprint(for: mappedMessages)
            shouldForceFullRebuild = false
            isLargeSessionMode = largeMode
        }
    }

    private func loadOlderMessagesPage() {
        guard isLargeSessionMode else { return }
        guard hasMoreOlderMessages else { return }

        Task {
            let state = await timelineLoader.loadOlder(pageSize: Self.largeSessionPageSize)
            let mappedMessages = state.messages.map { $0.makeMessage() }
            messages = mappedMessages
            loadedMessageCount = mappedMessages.count
            hasMoreOlderMessages = state.hasMoreBefore
            messageFingerprint = fingerprint(for: mappedMessages)
            shouldForceFullRebuild = state.didPrepend
        }
    }

    private func shouldUseLargeSessionMode() -> Bool {
        guard let fileURL = session.jsonlFileURL else { return false }
        guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
              let fileSize = values.fileSize else {
            return false
        }
        return fileSize > Self.largeSessionThresholdBytes
    }

    private var hasMoreBeforeLoaded: Bool {
        isLargeSessionMode && hasMoreOlderMessages
    }

    private func buildPrevTimestampMap(
        visible: [Message],
        visibleCount: Int,
        needsFullRebuild: Bool,
        isPrependingHistory: Bool,
        prependedCount: Int,
        startIndex: Int
    ) -> [String: Date] {
        if needsFullRebuild || timeline.prevTimestampMap.isEmpty {
            return rebuildPrevTimestampMapFully(for: visible)
        }

        if isPrependingHistory {
            var tsMap = timeline.prevTimestampMap
            var lastUserTime: Date? = nil

            for msg in visible.prefix(prependedCount) {
                if msg.type == .assistant {
                    if let t = lastUserTime {
                        tsMap[msg.uuid] = t
                    } else {
                        tsMap.removeValue(forKey: msg.uuid)
                    }
                }
                if msg.type == .user {
                    lastUserTime = msg.timestamp
                }
            }

            if prependedCount < visibleCount {
                for msg in visible[prependedCount..<visibleCount] {
                    if msg.type == .assistant {
                        if let t = lastUserTime {
                            tsMap[msg.uuid] = t
                        } else {
                            tsMap.removeValue(forKey: msg.uuid)
                        }
                    }
                    if msg.type == .user {
                        break
                    }
                }
            }

            return tsMap
        }

        var tsMap = timeline.prevTimestampMap
        var lastUserTime = latestUserTimestamp(in: visible, upTo: startIndex)
        for msg in visible[startIndex..<visibleCount] {
            if msg.type == .assistant {
                if let t = lastUserTime {
                    tsMap[msg.uuid] = t
                } else {
                    tsMap.removeValue(forKey: msg.uuid)
                }
            }
            if msg.type == .user {
                lastUserTime = msg.timestamp
            }
        }
        return tsMap
    }

    private func rebuildPrevTimestampMapFully(for visible: [Message]) -> [String: Date] {
        var tsMap: [String: Date] = [:]
        tsMap.reserveCapacity(visible.count)
        var lastUserTime: Date? = nil
        for msg in visible {
            if msg.type == .assistant, let t = lastUserTime {
                tsMap[msg.uuid] = t
            }
            if msg.type == .user {
                lastUserTime = msg.timestamp
            }
        }
        return tsMap
    }

    private func latestUserTimestamp(in visible: [Message], upTo endIndex: Int) -> Date? {
        guard endIndex > 0 else { return nil }
        for msg in visible[..<endIndex].reversed() where msg.type == .user {
            return msg.timestamp
        }
        return nil
    }

    private func rebuildDerivedData() {
        // Early return: skip if message set is identical to last processed state.
        let fp = messageFingerprint
        if fp == lastFingerprint {
            return
        }
        let fpHash = fp.hash

        derivedDataGeneration += 1
        let gen = derivedDataGeneration

        Task { @MainActor in
            await Task.yield()
            guard gen == derivedDataGeneration else { return }

            // Filter and timestamp map — moved off synchronous path.
            let visible = messages.filter {
                if $0.type == .system {
                    return $0.subtype == "api_error" && $0.level == "error"
                }
                guard $0.type == .user || $0.type == .assistant else { return false }
                if $0.isMeta && !$0.isCompactSummary { return false }
                return true
            }
            let visibleCount = visible.count
            let prependedCount = max(0, visibleCount - lastVisibleMessageCount)
            let isPrependingHistory = shouldForceFullRebuild && lastVisibleMessageCount > 0 && prependedCount > 0
            let hasInPlaceVisibleMutation =
                !shouldForceFullRebuild &&
                visibleCount == lastVisibleMessageCount &&
                fp != lastFingerprint
            let needsFullRebuild = visibleCount < lastVisibleMessageCount || hasInPlaceVisibleMutation
            let startIndex = needsFullRebuild ? 0 : min(lastVisibleMessageCount, visibleCount)
            let tsMap = buildPrevTimestampMap(
                visible: visible,
                visibleCount: visibleCount,
                needsFullRebuild: needsFullRebuild,
                isPrependingHistory: isPrependingHistory,
                prependedCount: prependedCount,
                startIndex: startIndex
            )

            let firstPaintThreshold = TimelineRenderTuning.firstPaintThreshold
            let firstPaintTailSize = TimelineRenderTuning.firstPaintTailSize

            if visibleCount > firstPaintThreshold {
                visibleMessageCount = visibleCount

                let visibleRows = Array(visible)
                let shouldUseSuffixFirstPaint = timeline.generation == 0
                let firstPaintTailStart =
                    shouldUseSuffixFirstPaint
                    ? max(0, visibleCount - firstPaintTailSize) : 0
                let firstPaintRows =
                    firstPaintTailStart > 0
                    ? Array(visible[firstPaintTailStart..<visibleCount]) : visibleRows

                derivedDataGeneration += 1
                let genFinal = derivedDataGeneration

                await runPhase1Decode(
                    gen: genFinal,
                    fpHash: fpHash,
                    visible: visible,
                    visibleCount: visibleCount,
                    startIndex: startIndex,
                    prependedCount: prependedCount,
                    needsFullRebuild: needsFullRebuild,
                    isPrependingHistory: isPrependingHistory,
                    tsMap: tsMap,
                    visibleRows: visibleRows,
                    firstPaintRows: firstPaintRows,
                    firstPaintTailStart: firstPaintTailStart
                )
                return
            }

            guard startIndex <= visibleCount else { return }
            let deltaMessages: [Message] =
                isPrependingHistory ? Array(visible.prefix(prependedCount)) : Array(visible[startIndex..<visibleCount])

            if deltaMessages.isEmpty {
                let visibleRows = Array(visible)

                var immediateSnap = timeline
                immediateSnap.visibleMessages = visibleRows
                immediateSnap.hasMoreBeforeLoaded = hasMoreBeforeLoaded
                immediateSnap.prevTimestampMap = tsMap
                immediateSnap.tailStartIndex = 0
                immediateSnap.totalVisibleCount = 0
                immediateSnap.generation = gen
                timeline = immediateSnap
                visibleMessageCount = visibleCount
                lastFingerprint = MessageFingerprint(count: visibleCount, hash: fpHash)
                lastVisibleMessageCount = visibleCount
                shouldForceFullRebuild = false
                publishContextDeferred(contextMap: timeline.derivedContextMap, latestThinking: contextPanel.latestThinking)
                return
            }

            visibleMessageCount = visibleCount

            var patchMap = needsFullRebuild ? [String: [StructuredPatchHunk]]() : timeline.derivedPatchMap
            var toolUseMap = needsFullRebuild ? [String: ToolUseInfo]() : derivedToolUseMap
            var ownerMap = needsFullRebuild ? [String: String]() : toolUseOwnerMap
            var contextMap = needsFullRebuild ? [String: ContextItem]() : timeline.derivedContextMap
            var latestThinking: String? = needsFullRebuild ? nil : contextPanel.latestThinking
            var hasSummaryThinking = needsFullRebuild ? false : timeline.hasSummaryThinking
            var rowPatchesMap = needsFullRebuild ? [String: [String: [StructuredPatchHunk]]]() : timeline.rowPatchesMap

            derivedDataGeneration += 1
            let genRows = derivedDataGeneration

            var rowSnap = TimelineRenderSnapshot()
            rowSnap.generation = genRows
            rowSnap.visibleMessages = Array(visible)
            rowSnap.hasMoreBeforeLoaded = hasMoreBeforeLoaded
            rowSnap.prevTimestampMap = tsMap
            rowSnap.tailStartIndex = 0
            rowSnap.totalVisibleCount = 0
            rowSnap.derivedPatchMap = patchMap
            rowSnap.derivedContextMap = contextMap
            rowSnap.hasSummaryThinking = hasSummaryThinking
            rowSnap.rowPatchesMap = rowPatchesMap
            timeline = rowSnap
            visibleMessageCount = visibleCount

            await runPhase1DecodeLoop(
                gen: genRows,
                deltaMessages: deltaMessages,
                isPrependingHistory: isPrependingHistory,
                patchMap: &patchMap,
                toolUseMap: &toolUseMap,
                ownerMap: &ownerMap,
                contextMap: &contextMap,
                latestThinking: &latestThinking,
                hasSummaryThinking: &hasSummaryThinking,
                rowPatchesMap: &rowPatchesMap
            )

            guard genRows == derivedDataGeneration else { return }
            derivedDataGeneration += 1
            let genFinal = derivedDataGeneration

            lastFingerprint = MessageFingerprint(count: visibleCount, hash: fpHash)
            lastVisibleMessageCount = visibleCount
            derivedToolUseMap = toolUseMap
            toolUseOwnerMap = ownerMap
            shouldForceFullRebuild = false

            var snap = TimelineRenderSnapshot()
            snap.generation = genFinal
            snap.visibleMessages = Array(visible)
            snap.hasMoreBeforeLoaded = hasMoreBeforeLoaded
            snap.prevTimestampMap = tsMap
            snap.tailStartIndex = 0
            snap.totalVisibleCount = 0
            snap.derivedPatchMap = patchMap
            snap.derivedContextMap = contextMap
            snap.hasSummaryThinking = hasSummaryThinking
            snap.rowPatchesMap = rowPatchesMap
            timeline = snap
            visibleMessageCount = visibleCount
            publishContextDeferred(contextMap: contextMap, latestThinking: latestThinking)
        }
    }

    /// Phase 1 for large sessions: full `visibleRows` + patch decode + single timeline write.
    private func runPhase1Decode(
        gen: Int,
        fpHash: Int,
        visible: [Message],
        visibleCount: Int,
        startIndex: Int,
        prependedCount: Int,
        needsFullRebuild: Bool,
        isPrependingHistory: Bool,
        tsMap: [String: Date],
        visibleRows: [Message],
        firstPaintRows: [Message],
        firstPaintTailStart: Int
    ) async {
        guard startIndex <= visibleCount else { return }
        let deltaMessages: [Message] =
            isPrependingHistory ? Array(visible.prefix(prependedCount)) : Array(visible[startIndex..<visibleCount])

        if deltaMessages.isEmpty {
            var snap = TimelineRenderSnapshot()
            snap.generation = gen
            snap.visibleMessages = visibleRows
            snap.hasMoreBeforeLoaded = hasMoreBeforeLoaded
            snap.prevTimestampMap = tsMap
            snap.tailStartIndex = 0
            snap.totalVisibleCount = 0
            if needsFullRebuild {
                snap.derivedPatchMap = [:]
                snap.derivedContextMap = [:]
                snap.hasSummaryThinking = false
                snap.rowPatchesMap = [:]
            } else {
                snap.derivedPatchMap = timeline.derivedPatchMap
                snap.derivedContextMap = timeline.derivedContextMap
                snap.hasSummaryThinking = timeline.hasSummaryThinking
                snap.rowPatchesMap = timeline.rowPatchesMap
            }
            timeline = snap
            visibleMessageCount = visibleCount
            lastVisibleMessageCount = visibleCount
            shouldForceFullRebuild = false
            lastFingerprint = MessageFingerprint(count: visibleCount, hash: fpHash)
            publishContextDeferred(
                contextMap: snap.derivedContextMap,
                latestThinking: needsFullRebuild ? nil : contextPanel.latestThinking
            )
            return
        }

        var patchMap = needsFullRebuild ? [String: [StructuredPatchHunk]]() : timeline.derivedPatchMap
        var toolUseMap = needsFullRebuild ? [String: ToolUseInfo]() : derivedToolUseMap
        var ownerMap = needsFullRebuild ? [String: String]() : toolUseOwnerMap
        var contextMap = needsFullRebuild ? [String: ContextItem]() : timeline.derivedContextMap
        var latestThinking: String? = needsFullRebuild ? nil : contextPanel.latestThinking
        var hasSummaryThinking = needsFullRebuild ? false : timeline.hasSummaryThinking
        var rowPatchesMap = needsFullRebuild ? [String: [String: [StructuredPatchHunk]]]() : timeline.rowPatchesMap

        var rowSnap = TimelineRenderSnapshot()
        rowSnap.generation = gen
        rowSnap.visibleMessages = firstPaintRows
        rowSnap.hasMoreBeforeLoaded = hasMoreBeforeLoaded
        rowSnap.prevTimestampMap = tsMap
        rowSnap.tailStartIndex = firstPaintTailStart
        rowSnap.totalVisibleCount = firstPaintTailStart > 0 ? visibleCount : 0
        rowSnap.derivedPatchMap = patchMap
        rowSnap.derivedContextMap = contextMap
        rowSnap.hasSummaryThinking = hasSummaryThinking
        rowSnap.rowPatchesMap = rowPatchesMap
        timeline = rowSnap
        visibleMessageCount = visibleCount

        await runPhase1DecodeLoop(
            gen: gen,
            deltaMessages: deltaMessages,
            isPrependingHistory: isPrependingHistory,
            patchMap: &patchMap,
            toolUseMap: &toolUseMap,
            ownerMap: &ownerMap,
            contextMap: &contextMap,
            latestThinking: &latestThinking,
            hasSummaryThinking: &hasSummaryThinking,
            rowPatchesMap: &rowPatchesMap
        )

        guard gen == derivedDataGeneration else { return }
        lastFingerprint = MessageFingerprint(count: visibleCount, hash: fpHash)
        lastVisibleMessageCount = visibleCount
        derivedToolUseMap = toolUseMap
        toolUseOwnerMap = ownerMap
        shouldForceFullRebuild = false

        derivedDataGeneration += 1
        let genPatched = derivedDataGeneration

        var snap = TimelineRenderSnapshot()
        snap.generation = genPatched
        snap.visibleMessages = visibleRows
        snap.hasMoreBeforeLoaded = hasMoreBeforeLoaded
        snap.prevTimestampMap = tsMap
        snap.tailStartIndex = 0
        snap.totalVisibleCount = 0
        snap.derivedPatchMap = patchMap
        snap.derivedContextMap = contextMap
        snap.hasSummaryThinking = hasSummaryThinking
        snap.rowPatchesMap = rowPatchesMap
        timeline = snap
        visibleMessageCount = visibleCount
        publishContextDeferred(contextMap: contextMap, latestThinking: latestThinking)
    }

    private func runPhase1DecodeLoop(
        gen: Int,
        deltaMessages: [Message],
        isPrependingHistory: Bool,
        patchMap: inout [String: [StructuredPatchHunk]],
        toolUseMap: inout [String: ToolUseInfo],
        ownerMap: inout [String: String],
        contextMap: inout [String: ContextItem],
        latestThinking: inout String?,
        hasSummaryThinking: inout Bool,
        rowPatchesMap: inout [String: [String: [StructuredPatchHunk]]]
    ) async {
        for (i, msg) in deltaMessages.enumerated() {
            guard gen == derivedDataGeneration else { return }
            msg.preload()

            if msg.type == .assistant {
                let uses = msg.toolUses
                for toolUse in uses {
                    toolUseMap[toolUse.id] = toolUse
                    ownerMap[toolUse.id] = msg.uuid
                    if let key = toolUse.filePath ?? toolUse.command {
                        if contextMap[key] == nil {
                            contextMap[key] = ContextItem(
                                id: key, toolName: toolUse.name,
                                filePath: toolUse.filePath, command: toolUse.command,
                                content: L("timeline.tool.running"), isError: false
                            )
                        }
                    }
                }
                if !uses.isEmpty && !patchMap.isEmpty {
                    var rowMap: [String: [StructuredPatchHunk]] = [:]
                    for tu in uses {
                        if let p = patchMap[tu.id] { rowMap[tu.id] = p }
                    }
                    if !rowMap.isEmpty { rowPatchesMap[msg.uuid] = rowMap }
                }
                if !isPrependingHistory, !hasSummaryThinking, let t = msg.thinking, !t.isEmpty {
                    latestThinking = t
                }
            } else {
                if let patches = msg.toolUseResultsWithPatch {
                    for (id, hunks) in patches {
                        patchMap[id] = hunks
                        if let ownerUuid = ownerMap[id] {
                            var existing = rowPatchesMap[ownerUuid] ?? [:]
                            existing[id] = hunks
                            rowPatchesMap[ownerUuid] = existing
                        }
                    }
                }
                if !isPrependingHistory, let c = msg.content, c.contains("This session is being continued") {
                    latestThinking = c
                    hasSummaryThinking = true
                }
                if let results = msg.toolResults {
                    for result in results {
                        guard let toolUseId = result.tool_use_id,
                              let toolUse = toolUseMap[toolUseId] else { continue }
                        let content = result.content ?? ""
                        let key = toolUse.filePath ?? toolUse.command ?? toolUseId
                        if isPrependingHistory, contextMap[key] != nil {
                            continue
                        }
                        contextMap[key] = ContextItem(
                            id: key, toolName: toolUse.name,
                            filePath: toolUse.filePath, command: toolUse.command,
                            content: content.isEmpty ? L("timeline.tool.success") : content,
                            isError: result.is_error ?? false
                        )
                    }
                }
            }
            if i.isMultiple(of: 15) { await Task.yield() }
        }
    }

    private func publishContextDeferred(contextMap: [String: ContextItem], latestThinking: String?) {
        Task { @MainActor in
            await Task.yield()
            publishContext(contextMap: contextMap, latestThinking: latestThinking)
        }
    }

    private func publishContext(
        contextMap: [String: ContextItem],
        latestThinking: String?
    ) {
        let sorted = contextMap.values.sorted { ($0.filePath ?? "") < ($1.filePath ?? "") }
        var reads: [ContextItem] = []
        var edits: [ContextItem] = []
        var writes: [ContextItem] = []
        reads.reserveCapacity(sorted.count)
        edits.reserveCapacity(sorted.count)
        writes.reserveCapacity(sorted.count)
        for item in sorted {
            switch item.toolName {
            case "Read": reads.append(item)
            case "Edit": edits.append(item)
            case "Write": writes.append(item)
            default: break
            }
        }
        contextPanel = ContextPanelSnapshot(
            latestThinking: latestThinking,
            readFiles: reads,
            editedFiles: edits,
            writtenFiles: writes
        )
    }

    private var sessionTitle: String {
        session.displayTitle
    }
}

// MARK: - Compacted Session Banner

struct CompactedSessionBanner: View {
    let summary: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3))
    }
}

struct LargeSessionBanner: View {
    let messageCount: Int

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "speedometer")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Large session mode: loaded \(messageCount) recent messages first. Use Load older to fetch more on demand.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3))
    }
}

// MARK: - Context Panel

struct ContextPanel: View {
    let snapshot: ContextPanelSnapshot

    @State private var selectedFileItem: ContextItem? = nil

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if let latest = snapshot.latestThinking {
                    CurrentUnderstandingView(thinking: latest)
                }

                if !snapshot.readFiles.isEmpty {
                    ContextSectionView(title: L("context.section.read"), icon: "doc.text", color: .blue, items: snapshot.readFiles, onOpenFile: { selectedFileItem = $0 })
                }

                if !snapshot.editedFiles.isEmpty {
                    ContextSectionView(title: L("context.section.edited"), icon: "pencil", color: .orange, items: snapshot.editedFiles, onOpenFile: { selectedFileItem = $0 })
                }

                if !snapshot.writtenFiles.isEmpty {
                    ContextSectionView(title: L("context.section.created"), icon: "doc.badge.plus", color: .green, items: snapshot.writtenFiles, onOpenFile: { selectedFileItem = $0 })
                }

                if snapshot.latestThinking == nil && snapshot.readFiles.isEmpty && snapshot.editedFiles.isEmpty && snapshot.writtenFiles.isEmpty {
                    Text(L("context.empty"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .sheet(item: $selectedFileItem) { item in
            if let path = item.filePath {
                FilePreviewSheet(filePath: path)
            }
        }
    }
}

struct CurrentUnderstandingView: View {
    let thinking: String
    @State private var isExpanded = true
    @State private var showModal = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "brain.head.profile")
                            .foregroundStyle(.orange)
                        Text(L("context.understanding.title"))
                            .fontWeight(.semibold)
                        Spacer()
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .font(.subheadline)
                }
                .buttonStyle(.plain)

                Button {
                    showModal = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L("context.expand.help"))
            }

            if isExpanded {
                Text(thinking)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(15)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.orange.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                if thinking.count > 500 {
                    Button {
                        showModal = true
                    } label: {
                        Text(L("context.showFull"))
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .sheet(isPresented: $showModal) {
            UnderstandingModalView(thinking: thinking)
        }
    }
}

struct UnderstandingModalView: View {
    let thinking: String
    @Environment(\.dismiss) private var dismiss
    @State private var showRendered = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "brain.head.profile")
                    .foregroundStyle(.orange)
                Text(L("context.understanding.title"))
                    .font(.headline)
                Spacer()

                Picker("", selection: $showRendered) {
                    Text(L("file.preview.source")).tag(false)
                    Text(L("file.preview.rendered")).tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 160)

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape)
            }
            .padding()

            Divider()

            if showRendered {
                MarkdownRenderView(markdown: thinking)
            } else {
                ScrollView {
                    Text(verbatim: thinking)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }
        }
        .frame(minWidth: 500, minHeight: 400)
        .frame(maxWidth: 800, maxHeight: 600)
    }
}

struct ContextSectionView: View {
    let title: String
    let icon: String
    let color: Color
    let items: [ContextItem]
    var onOpenFile: ((ContextItem) -> Void)? = nil

    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .foregroundStyle(color)
                    Text(title)
                        .fontWeight(.semibold)
                    Text("\(items.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .font(.subheadline)
            }
            .buttonStyle(.plain)

            if isExpanded {
                ForEach(items) { item in
                    ContextItemView(item: item, onOpenFile: { onOpenFile?(item) })
                }
            }
        }
    }
}

struct ContextItemView: View {
    let item: ContextItem
    var onOpenFile: (() -> Void)? = nil
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: item.icon)
                            .font(.caption)
                            .foregroundStyle(item.color)
                        Text(item.displayTitle)
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer()
                    }
                }
                .buttonStyle(.plain)

                if item.filePath != nil {
                    Button {
                        onOpenFile?()
                    } label: {
                        Image(systemName: "eye")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(L("file.preview.help"))
                }
            }

            if isExpanded {
                Text(item.content)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(item.isError ? .red : .secondary)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(item.color.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(8)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - File Preview Sheet

struct FilePreviewSheet: View {
    let filePath: String
    @Environment(\.dismiss) private var dismiss
    @State private var content = ""
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showRendered = false
    @State private var image: NSImage?

    private var fileName: String {
        (filePath as NSString).lastPathComponent
    }

    private var isMarkdown: Bool {
        let ext = (filePath as NSString).pathExtension.lowercased()
        return ext == "md" || ext == "markdown"
    }

    private var isImageFile: Bool {
        let ext = (filePath as NSString).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "heic", "heif"].contains(ext)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(fileName)
                        .font(.headline)
                    Text(filePath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()

                if isMarkdown && !content.isEmpty {
                    Picker("", selection: $showRendered) {
                        Text(L("file.preview.source")).tag(false)
                        Text(L("file.preview.rendered")).tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                }

                Button(L("file.open.external")) {
                    openInExternalEditor()
                }
                .help(L("file.open.defaultEditor.help"))

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape)
            }
            .padding()

            Divider()

            if isLoading {
                Spacer()
                ProgressView(L("common.loading"))
                Spacer()
            } else if let error = errorMessage {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.orange)
                    Text(error)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else if let loadedImage = image {
                GeometryReader { _ in
                    ZStack {
                        Color.clear
                        Image(nsImage: loadedImage)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .padding()
                    }
                }
            } else if showRendered && isMarkdown {
                MarkdownRenderView(markdown: content)
            } else {
                ScrollView {
                    Text(verbatim: content)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }
        }
        .frame(minWidth: 700, minHeight: 500)
        .frame(maxWidth: 1000, maxHeight: 800)
        .task {
            await loadFile()
        }
    }

    private func loadFile() async {
        isLoading = true
        errorMessage = nil
        content = ""
        image = nil
        defer { isLoading = false }

        let url = URL(fileURLWithPath: filePath)
        do {
            if isImageFile {
                if let nsImage = NSImage(contentsOf: url) {
                    image = nsImage
                } else {
                    errorMessage = L("error.file.notSupported")
                }
                return
            }
            content = try String(contentsOf: url, encoding: .utf8)
            if isMarkdown { showRendered = true }
        } catch {
            errorMessage = String(
                format: L("error.file.read.failed"),
                error.localizedDescription
            )
        }
    }

    private func openInExternalEditor() {
        let url = URL(fileURLWithPath: filePath)
        NSWorkspace.shared.open(url)
    }
}

private struct SessionFileTimelineState: Sendable {
    let messages: [TimelineFileMessage]
    let hasMoreBefore: Bool
    let didPrepend: Bool
}

private actor SessionFileTimelineLoader {
    private var parser = JSONLParser()
    private var currentSessionId: String?
    private var currentFileURL: URL?
    private var currentLargeMode = false
    private var oldestLoadedOffset: UInt64 = 0
    private var newestLoadedOffset: UInt64 = 0
    private var currentMessages: [TimelineFileMessage] = []

    func load(
        sessionId: String,
        fileURL: URL?,
        largeMode: Bool,
        initialMessageCount: Int,
        forceReload: Bool
    ) -> SessionFileTimelineState {
        guard let fileURL else {
            reset()
            return SessionFileTimelineState(messages: [], hasMoreBefore: false, didPrepend: false)
        }

        if forceReload
            || currentSessionId != sessionId
            || currentFileURL != fileURL
            || currentLargeMode != largeMode
            || currentMessages.isEmpty {
            currentSessionId = sessionId
            currentFileURL = fileURL
            currentLargeMode = largeMode
            return reloadInitial(fileURL: fileURL, largeMode: largeMode, initialMessageCount: initialMessageCount)
        }

        if !largeMode {
            return reloadInitial(fileURL: fileURL, largeMode: false, initialMessageCount: initialMessageCount)
        }

        let fileSize = fileSize(of: fileURL)
        if fileSize < newestLoadedOffset {
            return reloadInitial(fileURL: fileURL, largeMode: true, initialMessageCount: initialMessageCount)
        }

        let appendResult = (try? parser.parseTimelineMessages(url: fileURL, afterOffset: newestLoadedOffset))
            ?? ([], fileSize)
        newestLoadedOffset = appendResult.1

        if !appendResult.0.isEmpty {
            mergeAppended(appendResult.0)
        }

        return SessionFileTimelineState(
            messages: currentMessages,
            hasMoreBefore: oldestLoadedOffset > 0,
            didPrepend: false
        )
    }

    func loadOlder(pageSize: Int) -> SessionFileTimelineState {
        guard currentLargeMode, let fileURL = currentFileURL, oldestLoadedOffset > 0 else {
            return SessionFileTimelineState(
                messages: currentMessages,
                hasMoreBefore: oldestLoadedOffset > 0,
                didPrepend: false
            )
        }

        let page = (try? parser.parseTimelinePage(
            url: fileURL,
            beforeOffset: oldestLoadedOffset,
            limit: pageSize
        )) ?? TimelineFilePage(messages: [], startOffset: oldestLoadedOffset, endOffset: oldestLoadedOffset, hasMoreBefore: false)

        oldestLoadedOffset = page.startOffset
        prependOlder(page.messages)

        return SessionFileTimelineState(
            messages: currentMessages,
            hasMoreBefore: page.hasMoreBefore,
            didPrepend: !page.messages.isEmpty
        )
    }

    private func reloadInitial(
        fileURL: URL,
        largeMode: Bool,
        initialMessageCount: Int
    ) -> SessionFileTimelineState {
        if largeMode {
            let page = (try? parser.parseTimelinePage(url: fileURL, limit: initialMessageCount))
                ?? TimelineFilePage(messages: [], startOffset: 0, endOffset: fileSize(of: fileURL), hasMoreBefore: false)
            currentMessages = page.messages
            oldestLoadedOffset = page.startOffset
            newestLoadedOffset = page.endOffset
            return SessionFileTimelineState(
                messages: currentMessages,
                hasMoreBefore: page.hasMoreBefore,
                didPrepend: false
            )
        }

        let messages = (try? parser.parseTimelineMessages(url: fileURL)) ?? []
        currentMessages = messages
        oldestLoadedOffset = 0
        newestLoadedOffset = fileSize(of: fileURL)
        return SessionFileTimelineState(
            messages: currentMessages,
            hasMoreBefore: false,
            didPrepend: false
        )
    }

    private func mergeAppended(_ newMessages: [TimelineFileMessage]) {
        var byId: [String: TimelineFileMessage] = [:]
        byId.reserveCapacity(currentMessages.count + newMessages.count)
        for message in currentMessages {
            byId[message.uuid] = message
        }
        for message in newMessages {
            byId[message.uuid] = message
        }
        currentMessages = Array(byId.values).sorted(by: messageSort)
    }

    private func prependOlder(_ olderMessages: [TimelineFileMessage]) {
        guard !olderMessages.isEmpty else { return }
        let existingIds = Set(currentMessages.map(\.uuid))
        let uniqueOlder = olderMessages.filter { !existingIds.contains($0.uuid) }
        guard !uniqueOlder.isEmpty else { return }
        currentMessages = (uniqueOlder + currentMessages).sorted(by: messageSort)
    }

    private func reset() {
        currentSessionId = nil
        currentFileURL = nil
        currentLargeMode = false
        oldestLoadedOffset = 0
        newestLoadedOffset = 0
        currentMessages = []
    }

    private func fileSize(of url: URL) -> UInt64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
    }

    private func messageSort(_ lhs: TimelineFileMessage, _ rhs: TimelineFileMessage) -> Bool {
        if lhs.timestamp == rhs.timestamp {
            return lhs.uuid < rhs.uuid
        }
        return lhs.timestamp < rhs.timestamp
    }
}
