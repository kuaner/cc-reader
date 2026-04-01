import SwiftUI
import SwiftData

struct SessionMessagesView: View {
    let session: Session
    @Binding var visibleMessageCount: Int

    @Query private var messages: [Message]

    // Toggle the context panel on and off.
    @State private var showContextPanel = true

    // Snapshot of the timeline render state.
    @State private var timeline = TimelineRenderSnapshot()

    // Snapshot used by the context panel.
    @State private var contextPanel = ContextPanelSnapshot()

    init(session: Session, visibleMessageCount: Binding<Int>) {
        self.session = session
        self._visibleMessageCount = visibleMessageCount
        let sid = session.sessionId
        _messages = Query(
            filter: #Predicate<Message> { $0.session?.sessionId == sid },
            sort: \Message.timestamp,
            order: .forward
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                // Session summary banner for compacted sessions
                if let summary = session.sessionSummary, !summary.isEmpty {
                    CompactedSessionBanner(summary: summary)
                }

                TimelineHostView(
                    sessionId: session.sessionId,
                    snapshot: timeline
                )
                .equatable()
            }

            if showContextPanel {
                Divider()
            }
            ContextPanel(snapshot: contextPanel)
            .frame(width: showContextPanel ? 260 : 0)
            .opacity(showContextPanel ? 1 : 0)
            .clipped()
            .allowsHitTesting(showContextPanel)
        }
        .navigationTitle(sessionTitle)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    showContextPanel.toggle()
                } label: {
                    Image(systemName: showContextPanel ? "sidebar.right" : "sidebar.left")
                }
                .help(L("timeline.context.help"))
            }
        }
        .onAppear {
            rebuildDerivedData()
        }
        .onChange(of: messages.count) { _, _ in
            rebuildDerivedData()
        }
        .onChange(of: messageFingerprints) { _, _ in
            rebuildDerivedData()
        }
    }

    // MARK: - Derived Data

    @State private var derivedDataGeneration = 0
    @State private var lastProcessedMessageCount = 0
    @State private var derivedToolUseMap: [String: ToolUseInfo] = [:]
    @State private var toolUseOwnerMap: [String: String] = [:]
    @State private var displayDataCache: [String: TimelineMessageDisplayData] = [:]

    private var messageFingerprints: [String] {
        messages.map { "\($0.uuid):\($0.rawJson.hashValue)" }
    }

    private func cachedDisplayData(for message: Message, cache: inout [String: TimelineMessageDisplayData]) -> TimelineMessageDisplayData {
        if let cached = cache[message.uuid], cached.rawFingerprint == message.rawJson.hashValue {
            return cached
        }

        message.preload()
        let displayData = TimelineMessageDisplayData(message: message)
        cache[message.uuid] = displayData
        return displayData
    }

    private func rebuildDerivedData() {
        derivedDataGeneration += 1
        let gen = derivedDataGeneration

        // Only show user and assistant messages in the timeline.
        // System and attachment messages are persisted but not rendered in the main timeline.
        let visible = messages.filter { $0.type == .user || $0.type == .assistant }
        let visibleCount = visible.count
        let needsFullRebuild = visibleCount < lastProcessedMessageCount
        let startIndex = needsFullRebuild ? 0 : lastProcessedMessageCount

        let visibleIds = Set(visible.map(\.uuid))
        var updatedDisplayCache = displayDataCache.filter { visibleIds.contains($0.key) }

        var tsMap: [String: Date] = [:]
        tsMap.reserveCapacity(visibleCount)
        var lastUserTime: Date? = nil
        for msg in visible {
            if msg.type == .assistant, let t = lastUserTime {
                tsMap[msg.uuid] = t
            }
            if msg.type == .user {
                lastUserTime = msg.timestamp
            }
        }

        /// More messages than this → async path (decode tail, then head, then Phase1).
        let firstPaintThreshold = TimelineRenderTuning.firstPaintThreshold
        /// In the async path, indices `[visibleCount - tailSize ..< visibleCount)` are built first (newest segment).
        let firstPaintTailSize = TimelineRenderTuning.firstPaintTailSize
        /// Yield during row building so WKNavigationDelegate `didFinish` can run before long JSON decodes block the main thread.
        let yieldEveryRowsDuringDecode = TimelineRenderTuning.yieldEveryRowsDuringDecode

        /// Build one row using the same cache rules as the legacy full loop.
        func appendRow(at index: Int, into rows: inout [TimelineMessageDisplayData]) {
            let message = visible[index]
            if !needsFullRebuild,
               index < startIndex,
               let cached = updatedDisplayCache[message.uuid],
               cached.rawFingerprint == message.rawJson.hashValue {
                rows.append(cached)
                return
            }
            rows.append(cachedDisplayData(for: message, cache: &updatedDisplayCache))
        }

        if visibleCount > firstPaintThreshold {
            let tailStart = max(0, visibleCount - firstPaintTailSize)
            visibleMessageCount = visibleCount

            Task { @MainActor in
                await Task.yield()
                guard gen == derivedDataGeneration else { return }

                var tailRows: [TimelineMessageDisplayData] = []
                tailRows.reserveCapacity(visibleCount - tailStart)
                for index in tailStart..<visibleCount {
                    appendRow(at: index, into: &tailRows)
                    let n = index - tailStart + 1
                    if n % yieldEveryRowsDuringDecode == 0, index < visibleCount - 1 {
                        await Task.yield()
                    }
                }

                var headRows: [TimelineMessageDisplayData] = []
                headRows.reserveCapacity(tailStart)
                for index in 0..<tailStart {
                    appendRow(at: index, into: &headRows)
                    if (index + 1) % yieldEveryRowsDuringDecode == 0, index < tailStart - 1 {
                        await Task.yield()
                    }
                }
                let visibleRows = headRows + tailRows
                displayDataCache = updatedDisplayCache

                derivedDataGeneration += 1
                let genFinal = derivedDataGeneration

                await runPhase1Decode(
                    gen: genFinal,
                    visible: visible,
                    visibleCount: visibleCount,
                    startIndex: startIndex,
                    needsFullRebuild: needsFullRebuild,
                    tsMap: tsMap,
                    visibleRows: visibleRows,
                    updatedDisplayCache: &updatedDisplayCache
                )
            }
            return
        }

        guard startIndex <= visibleCount else { return }
        let deltaMessages = Array(visible[startIndex..<visibleCount])

        if deltaMessages.isEmpty {
            var visibleRows: [TimelineMessageDisplayData] = []
            visibleRows.reserveCapacity(visibleCount)
            for index in 0..<visibleCount {
                appendRow(at: index, into: &visibleRows)
            }
            displayDataCache = updatedDisplayCache

            var immediateSnap = timeline
            immediateSnap.visibleMessages = visibleRows
            immediateSnap.prevTimestampMap = tsMap
            immediateSnap.tailStartIndex = 0
            immediateSnap.totalVisibleCount = 0
            immediateSnap.generation = gen
            timeline = immediateSnap
            visibleMessageCount = visibleCount
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

        Task { @MainActor in
            await Task.yield()
            guard gen == derivedDataGeneration else { return }

            var visibleRows: [TimelineMessageDisplayData] = []
            visibleRows.reserveCapacity(visibleCount)
            for index in 0..<visibleCount {
                appendRow(at: index, into: &visibleRows)
                if (index + 1) % yieldEveryRowsDuringDecode == 0, index < visibleCount - 1 {
                    await Task.yield()
                }
            }
            displayDataCache = updatedDisplayCache

            derivedDataGeneration += 1
            let genRows = derivedDataGeneration

            var rowSnap = TimelineRenderSnapshot()
            rowSnap.generation = genRows
            rowSnap.visibleMessages = visibleRows
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

            lastProcessedMessageCount = visibleCount
            derivedToolUseMap = toolUseMap
            toolUseOwnerMap = ownerMap
            displayDataCache = updatedDisplayCache

            var snap = TimelineRenderSnapshot()
            snap.generation = genFinal
            snap.visibleMessages = visibleRows
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
        visible: [Message],
        visibleCount: Int,
        startIndex: Int,
        needsFullRebuild: Bool,
        tsMap: [String: Date],
        visibleRows: [TimelineMessageDisplayData],
        updatedDisplayCache: inout [String: TimelineMessageDisplayData]
    ) async {
        guard startIndex <= visibleCount else { return }
        let deltaMessages = Array(visible[startIndex..<visibleCount])

        if deltaMessages.isEmpty {
            var snap = TimelineRenderSnapshot()
            snap.generation = gen
            snap.visibleMessages = visibleRows
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
            lastProcessedMessageCount = visibleCount
            displayDataCache = updatedDisplayCache
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
        rowSnap.visibleMessages = visibleRows
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
            gen: gen,
            deltaMessages: deltaMessages,
            patchMap: &patchMap,
            toolUseMap: &toolUseMap,
            ownerMap: &ownerMap,
            contextMap: &contextMap,
            latestThinking: &latestThinking,
            hasSummaryThinking: &hasSummaryThinking,
            rowPatchesMap: &rowPatchesMap
        )

        guard gen == derivedDataGeneration else { return }
        lastProcessedMessageCount = visibleCount
        derivedToolUseMap = toolUseMap
        toolUseOwnerMap = ownerMap
        displayDataCache = updatedDisplayCache

        derivedDataGeneration += 1
        let genPatched = derivedDataGeneration

        var snap = TimelineRenderSnapshot()
        snap.generation = genPatched
        snap.visibleMessages = visibleRows
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
                if !hasSummaryThinking, let t = msg.thinking, !t.isEmpty {
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
                if let c = msg.content, c.contains("This session is being continued") {
                    latestThinking = c
                    hasSummaryThinking = true
                }
                if let results = msg.toolResults {
                    for result in results {
                        guard let toolUseId = result.tool_use_id,
                              let toolUse = toolUseMap[toolUseId] else { continue }
                        let content = result.content ?? ""
                        let key = toolUse.filePath ?? toolUse.command ?? toolUseId
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
        .background(.quaternary.opacity(0.5))
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
                    .clipShape(RoundedRectangle(cornerRadius: 8))

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
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(8)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
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

#Preview {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: Project.self, Session.self, Message.self, configurations: config)

    let session = Session(sessionId: "test-session", cwd: "/test", slug: "test-slug")
    container.mainContext.insert(session)

    return SessionMessagesView(session: session, visibleMessageCount: .constant(0))
        .modelContainer(container)
}
