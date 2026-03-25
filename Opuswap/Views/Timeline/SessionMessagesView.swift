import SwiftUI
import SwiftData

struct SessionMessagesView: View {
    let session: Session
    @Binding var visibleMessageCount: Int

    @Query private var messages: [Message]

    // ContextPanel 表示切替
    @State private var showContextPanel = true

    // 派生データ一括スナップショット
    @State private var timeline = TimelineRenderSnapshot()

    // ContextPanel 用のキャッシュ
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
            TimelineHostView(
                sessionId: session.sessionId,
                snapshot: timeline
            )
            .equatable()

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
                .help(String(localized: "timeline.context.help"))
            }
        }
        .onAppear {
            rebuildDerivedData()
        }
        .onChange(of: messages.count) { _, _ in
            rebuildDerivedData()
        }
    }

    // MARK: - Derived Data

    @State private var derivedDataGeneration = 0
    @State private var lastProcessedMessageCount = 0
    @State private var derivedToolUseMap: [String: ToolUseInfo] = [:]
    @State private var toolUseOwnerMap: [String: String] = [:]
    @State private var displayDataCache: [String: TimelineMessageDisplayData] = [:]

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

        let visible = messages.filter { $0.rawJson.count > 50 }
        let visibleCount = visible.count
        let needsFullRebuild = visibleCount < lastProcessedMessageCount
        let startIndex = needsFullRebuild ? 0 : lastProcessedMessageCount

        let visibleIds = Set(visible.map(\.uuid))
        var updatedDisplayCache = displayDataCache.filter { visibleIds.contains($0.key) }
        var visibleRows: [TimelineMessageDisplayData] = []
        visibleRows.reserveCapacity(visibleCount)

        for (index, message) in visible.enumerated() {
            if !needsFullRebuild,
               index < startIndex,
               let cached = updatedDisplayCache[message.uuid],
               cached.rawFingerprint == message.rawJson.hashValue {
                visibleRows.append(cached)
                continue
            }

            visibleRows.append(cachedDisplayData(for: message, cache: &updatedDisplayCache))
        }
        displayDataCache = updatedDisplayCache

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

        // Phase 0: UI を即座に更新（デコード不要のデータだけ）
        var immediateSnap = timeline
        immediateSnap.visibleMessages = visibleRows
        immediateSnap.prevTimestampMap = tsMap
        immediateSnap.generation = gen
        timeline = immediateSnap
        visibleMessageCount = visibleCount

        // Phase 1: 差分だけ非同期デコード
        guard startIndex <= visibleCount else { return }
        let deltaMessages = Array(visible[startIndex..<visibleCount])

        if deltaMessages.isEmpty {
            publishContext(contextMap: timeline.derivedContextMap, latestThinking: contextPanel.latestThinking)
            return
        }

        var patchMap = needsFullRebuild ? [String: [StructuredPatchHunk]]() : timeline.derivedPatchMap
        var toolUseMap = needsFullRebuild ? [String: ToolUseInfo]() : derivedToolUseMap
        var ownerMap = needsFullRebuild ? [String: String]() : toolUseOwnerMap
        var contextMap = needsFullRebuild ? [String: ContextItem]() : timeline.derivedContextMap
        var latestThinking: String? = needsFullRebuild ? nil : contextPanel.latestThinking
        var hasSummaryThinking = needsFullRebuild ? false : timeline.hasSummaryThinking
        var rowPatchesMap = needsFullRebuild ? [String: [String: [StructuredPatchHunk]]]() : timeline.rowPatchesMap

        Task { @MainActor in
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
                                    content: String(localized: "timeline.tool.running"), isError: false
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
                                content: content.isEmpty ? String(localized: "timeline.tool.success") : content,
                                isError: result.is_error ?? false
                            )
                        }
                    }
                }
                if i.isMultiple(of: 15) { await Task.yield() }
            }

            guard gen == derivedDataGeneration else { return }
            lastProcessedMessageCount = visibleCount
            derivedToolUseMap = toolUseMap
            toolUseOwnerMap = ownerMap
            displayDataCache = updatedDisplayCache

            var snap = TimelineRenderSnapshot()
            snap.generation = gen
            snap.visibleMessages = visibleRows
            snap.prevTimestampMap = tsMap
            snap.derivedPatchMap = patchMap
            snap.derivedContextMap = contextMap
            snap.hasSummaryThinking = hasSummaryThinking
            snap.rowPatchesMap = rowPatchesMap
            timeline = snap
            visibleMessageCount = visibleCount
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
        session.slug ?? String(session.sessionId.prefix(8))
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
                    ContextSectionView(title: String(localized: "context.section.read"), icon: "doc.text", color: .blue, items: snapshot.readFiles, onOpenFile: { selectedFileItem = $0 })
                }

                if !snapshot.editedFiles.isEmpty {
                    ContextSectionView(title: String(localized: "context.section.edited"), icon: "pencil", color: .orange, items: snapshot.editedFiles, onOpenFile: { selectedFileItem = $0 })
                }

                if !snapshot.writtenFiles.isEmpty {
                    ContextSectionView(title: String(localized: "context.section.created"), icon: "doc.badge.plus", color: .green, items: snapshot.writtenFiles, onOpenFile: { selectedFileItem = $0 })
                }

                if snapshot.latestThinking == nil && snapshot.readFiles.isEmpty && snapshot.editedFiles.isEmpty && snapshot.writtenFiles.isEmpty {
                    Text(String(localized: "context.empty"))
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
                        Text(String(localized: "context.understanding.title"))
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
                .help(String(localized: "context.expand.help"))
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
                        Text(String(localized: "context.showFull"))
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
                Text(String(localized: "context.understanding.title"))
                    .font(.headline)
                Spacer()

                Picker("", selection: $showRendered) {
                    Text(String(localized: "file.preview.source")).tag(false)
                    Text(String(localized: "file.preview.rendered")).tag(true)
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
                    .help(String(localized: "file.preview.help"))
                }

                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
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

    private var fileName: String {
        (filePath as NSString).lastPathComponent
    }

    private var isMarkdown: Bool {
        let ext = (filePath as NSString).pathExtension.lowercased()
        return ext == "md" || ext == "markdown"
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
                        Text(String(localized: "file.preview.source")).tag(false)
                        Text(String(localized: "file.preview.rendered")).tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                }

                Button(String(localized: "file.open.external")) {
                    openInExternalEditor()
                }
                .help(String(localized: "file.open.defaultEditor.help"))

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
                ProgressView(String(localized: "common.loading"))
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
        defer { isLoading = false }

        let url = URL(fileURLWithPath: filePath)
        do {
            content = try String(contentsOf: url, encoding: .utf8)
            if isMarkdown { showRendered = true }
        } catch {
            errorMessage = String(
                format: String(localized: "error.file.read.failed"),
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
