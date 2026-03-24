import SwiftUI
import SwiftData

struct SessionMessagesView: View {
    let session: Session
    @Binding var visibleMessageCount: Int
    @Environment(\.modelContext) private var modelContext

    @Query private var messages: [Message]

    // Rewind
    @State private var showRewindConfirm = false
    @State private var rewindTargetId: String? = nil

    // 単一メッセージ削除
    @State private var showDeleteConfirm = false
    @State private var deleteTargetMessage: Message? = nil
    @AppStorage("skipMessageDeleteConfirmation") private var skipDeleteConfirmation = false

    // 要約編集
    @State private var showSummaryEditor = false
    @State private var editingSummaryMessage: Message? = nil
    @State private var editedSummaryContent = ""

    // エラー表示
    @State private var errorMessage: String? = nil
    @State private var showError = false

    // ローディング状態
    @State private var isDeleting = false

    // 派生データ一括スナップショット
    @State private var timeline = TimelineSnapshot()

    // ContextPanel 用のキャッシュ
    @State private var ctxLatestThinking: String? = nil
    @State private var ctxReadFiles: [ContextItem] = []
    @State private var ctxEditedFiles: [ContextItem] = []
    @State private var ctxWrittenFiles: [ContextItem] = []

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
            TimelineListView(
                snapshotId: timeline.generation,
                visibleMessages: timeline.visibleMessages,
                prevTimestampMap: timeline.prevTimestampMap,
                rowPatchesMap: timeline.rowPatchesMap,
                isDeleting: isDeleting,
                onAction: handleRowAction
            )

            Divider()
            ContextPanel(
                latestThinking: ctxLatestThinking,
                readFiles: ctxReadFiles,
                editedFiles: ctxEditedFiles,
                writtenFiles: ctxWrittenFiles
            )
            .frame(width: 260)
        }
        .navigationTitle(sessionTitle)
        .confirmationDialog(String(localized: "timeline.rewind.confirmTitle"), isPresented: $showRewindConfirm, titleVisibility: .visible) {
            Button(String(localized: "timeline.rewind.execute"), role: .destructive) {
                performRewind()
            }
            Button(String(localized: "common.cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "timeline.rewind.confirmMessage"))
        }
        .sheet(isPresented: $showDeleteConfirm) {
            DeleteConfirmSheet(
                skipConfirmation: $skipDeleteConfirmation,
                onDelete: { performSingleDelete() },
                onCancel: { showDeleteConfirm = false }
            )
        }
        .sheet(isPresented: $showSummaryEditor) {
            SummaryEditorSheet(
                content: $editedSummaryContent,
                onSave: { saveSummaryEdit() },
                onCancel: { showSummaryEditor = false }
            )
        }
        .alert(String(localized: "common.error"), isPresented: $showError) {
            Button(String(localized: "common.ok")) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .onAppear {
            rebuildDerivedData()
        }
        .onChange(of: messages.count) { _, _ in
            rebuildDerivedData()
        }
    }

    // MARK: - Row Action Handler

    private func handleRowAction(_ action: MessageRowAction) {
        switch action {
        case .rewindHere(let uuid):
            rewindTargetId = uuid
            showRewindConfirm = true
        case .delete(let message):
            deleteTargetMessage = message
            if skipDeleteConfirmation {
                performSingleDelete()
            } else {
                showDeleteConfirm = true
            }
        case .editSummary(let message):
            editingSummaryMessage = message
            editedSummaryContent = message.content ?? ""
            showSummaryEditor = true
        }
    }

    // MARK: - Derived Data

    @State private var derivedDataGeneration = 0
    @State private var lastProcessedMessageCount = 0
    @State private var derivedToolUseMap: [String: ToolUseInfo] = [:]
    @State private var toolUseOwnerMap: [String: String] = [:]

    private func rebuildDerivedData() {
        derivedDataGeneration += 1
        let gen = derivedDataGeneration

        let visible = messages.filter { $0.rawJson.count > 50 }
        let visibleCount = visible.count

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
        immediateSnap.visibleMessages = visible
        immediateSnap.prevTimestampMap = tsMap
        immediateSnap.generation = gen
        timeline = immediateSnap
        visibleMessageCount = visibleCount

        // Phase 1: 差分だけ非同期デコード
        let needsFullRebuild = visibleCount < lastProcessedMessageCount
        let startIndex = needsFullRebuild ? 0 : lastProcessedMessageCount
        guard startIndex <= visibleCount else { return }
        let deltaMessages = Array(visible[startIndex..<visibleCount])

        if deltaMessages.isEmpty {
            publishContext(contextMap: timeline.derivedContextMap, latestThinking: ctxLatestThinking)
            return
        }

        var patchMap = needsFullRebuild ? [String: [StructuredPatchHunk]]() : timeline.derivedPatchMap
        var toolUseMap = needsFullRebuild ? [String: ToolUseInfo]() : derivedToolUseMap
        var ownerMap = needsFullRebuild ? [String: String]() : toolUseOwnerMap
        var contextMap = needsFullRebuild ? [String: ContextItem]() : timeline.derivedContextMap
        var latestThinking: String? = needsFullRebuild ? nil : ctxLatestThinking
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

            var snap = TimelineSnapshot()
            snap.generation = gen
            snap.visibleMessages = visible
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
        ctxLatestThinking = latestThinking
        ctxReadFiles = reads
        ctxEditedFiles = edits
        ctxWrittenFiles = writes
    }

    // MARK: - Actions

    private func performSingleDelete() {
        guard let message = deleteTargetMessage,
              let fileURL = session.jsonlFileURL else {
            errorMessage = String(localized: "error.sessionFile.notFound")
            showError = true
            return
        }

        Task {
            isDeleting = true
            defer { isDeleting = false }

            do {
                try await JSONLWriter.backup(url: fileURL)
                try await JSONLWriter.deleteMessages(uuids: [message.uuid], from: fileURL)

                modelContext.delete(message)
                try? modelContext.save()

                deleteTargetMessage = nil
            } catch {
                errorMessage = String(
                    format: String(localized: "error.delete.failed"),
                    error.localizedDescription
                )
                showError = true
            }
        }
    }

    private func performRewind() {
        guard let targetId = rewindTargetId,
              let fileURL = session.jsonlFileURL else {
            errorMessage = String(localized: "error.sessionFile.notFound")
            showError = true
            return
        }

        Task {
            isDeleting = true
            defer { isDeleting = false }

            do {
                try await JSONLWriter.backup(url: fileURL)
                try await JSONLWriter.deleteMessagesAfter(uuid: targetId, from: fileURL, inclusive: false)

                var foundTarget = false
                for message in messages {
                    if message.uuid == targetId {
                        foundTarget = true
                        continue
                    }
                    if foundTarget {
                        modelContext.delete(message)
                    }
                }
                try? modelContext.save()

                rewindTargetId = nil
            } catch {
                errorMessage = String(
                    format: String(localized: "error.rewind.failed"),
                    error.localizedDescription
                )
                showError = true
            }
        }
    }

    private func saveSummaryEdit() {
        guard let message = editingSummaryMessage,
              let fileURL = session.jsonlFileURL else {
            errorMessage = String(localized: "error.sessionFile.notFound")
            showError = true
            return
        }

        Task {
            do {
                try await JSONLWriter.backup(url: fileURL)
                try await JSONLWriter.updateMessageContent(uuid: message.uuid, newContent: editedSummaryContent, in: fileURL)
                showSummaryEditor = false
                editingSummaryMessage = nil
            } catch {
                errorMessage = String(
                    format: String(localized: "error.save.failed"),
                    error.localizedDescription
                )
                showError = true
            }
        }
    }

    private var sessionTitle: String {
        session.slug ?? String(session.sessionId.prefix(8))
    }
}

// MARK: - Timeline Snapshot

struct TimelineSnapshot {
    var generation = 0
    var visibleMessages: [Message] = []
    var prevTimestampMap: [String: Date] = [:]
    var derivedPatchMap: [String: [StructuredPatchHunk]] = [:]
    var derivedContextMap: [String: ContextItem] = [:]
    var hasSummaryThinking = false
    var rowPatchesMap: [String: [String: [StructuredPatchHunk]]] = [:]
}

// MARK: - Timeline List View (Equatable で親の無関係な @State 変更を遮断)

struct TimelineListView: View, Equatable {
    let snapshotId: Int
    let visibleMessages: [Message]
    let prevTimestampMap: [String: Date]
    let rowPatchesMap: [String: [String: [StructuredPatchHunk]]]
    let isDeleting: Bool
    let onAction: (MessageRowAction) -> Void

    static func == (lhs: TimelineListView, rhs: TimelineListView) -> Bool {
        lhs.snapshotId == rhs.snapshotId &&
        lhs.isDeleting == rhs.isDeleting
    }

    private var isWaitingForResponse: Bool {
        visibleMessages.last?.type == MessageType.user
    }

    var body: some View {
        if visibleMessages.isEmpty {
            Spacer()
            Text(String(localized: "timeline.noMessages"))
                .foregroundStyle(.secondary)
            Spacer()
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(visibleMessages) { message in
                            MessageRow(
                                message: message,
                                previousUserTimestamp: prevTimestampMap[message.uuid],
                                structuredPatches: rowPatchesMap[message.uuid] ?? [:],
                                onAction: onAction
                            )
                            .id(message.uuid)
                        }

                        if isWaitingForResponse {
                            WaitingForResponseBubble()
                                .id("waiting")
                        }
                    }
                    .padding()
                }
                .onAppear {
                    if let last = visibleMessages.last {
                        proxy.scrollTo(last.uuid, anchor: .bottom)
                    }
                }
                .onChange(of: visibleMessages.count) { oldCount, newCount in
                    guard newCount > oldCount, !isDeleting else { return }
                    if let last = visibleMessages.last {
                        withAnimation {
                            proxy.scrollTo(last.uuid, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Delete Confirm Sheet

struct DeleteConfirmSheet: View {
    @Binding var skipConfirmation: Bool
    let onDelete: () -> Void
    let onCancel: () -> Void

    @State private var dontAskAgain = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "trash")
                .font(.largeTitle)
                .foregroundStyle(.red)

            Text(String(localized: "timeline.deleteMessage.title"))
                .font(.headline)

            Text(String(localized: "timeline.deleteMessage.body"))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Toggle(String(localized: "common.dontAskAgain"), isOn: $dontAskAgain)
                .toggleStyle(.checkbox)

            HStack(spacing: 12) {
                Button(String(localized: "common.cancel")) {
                    onCancel()
                }
                .keyboardShortcut(.escape)

                Button(String(localized: "common.delete")) {
                    if dontAskAgain {
                        skipConfirmation = true
                    }
                    onDelete()
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
        .padding(24)
        .frame(width: 280)
    }
}

// MARK: - Summary Editor Sheet

struct SummaryEditorSheet: View {
    @Binding var content: String
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(String(localized: "timeline.summaryEditor.title"))
                    .font(.headline)
                Spacer()
                Button(String(localized: "common.cancel")) {
                    onCancel()
                }
                .keyboardShortcut(.escape)
                Button(String(localized: "common.save")) {
                    onSave()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
            }
            .padding()

            Divider()

            TextEditor(text: $content)
                .font(.system(.body, design: .monospaced))
                .padding()
        }
        .frame(minWidth: 600, minHeight: 400)
    }
}

// MARK: - Context Panel

struct ContextPanel: View {
    let latestThinking: String?
    let readFiles: [ContextItem]
    let editedFiles: [ContextItem]
    let writtenFiles: [ContextItem]

    @State private var selectedFileItem: ContextItem? = nil

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if let latest = latestThinking {
                    CurrentUnderstandingView(thinking: latest)
                }

                if !readFiles.isEmpty {
                    ContextSectionView(title: String(localized: "context.section.read"), icon: "doc.text", color: .blue, items: readFiles, onOpenFile: { selectedFileItem = $0 })
                }

                if !editedFiles.isEmpty {
                    ContextSectionView(title: String(localized: "context.section.edited"), icon: "pencil", color: .orange, items: editedFiles, onOpenFile: { selectedFileItem = $0 })
                }

                if !writtenFiles.isEmpty {
                    ContextSectionView(title: String(localized: "context.section.created"), icon: "doc.badge.plus", color: .green, items: writtenFiles, onOpenFile: { selectedFileItem = $0 })
                }

                if latestThinking == nil && readFiles.isEmpty && editedFiles.isEmpty && writtenFiles.isEmpty {
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

struct ContextItem: Identifiable, Hashable {
    let id: String
    let toolName: String
    let filePath: String?
    let command: String?
    let content: String
    let isError: Bool

    var displayTitle: String {
        if let path = filePath {
            return (path as NSString).lastPathComponent
        }
        if let cmd = command {
            return String(cmd.prefix(30))
        }
        return toolName
    }

    var color: Color {
        switch toolName {
        case "Read": return .blue
        case "Edit": return .orange
        case "Write": return .green
        case "Bash": return .purple
        default: return .gray
        }
    }

    var icon: String {
        switch toolName {
        case "Read": return "doc.text"
        case "Edit": return "pencil"
        case "Write": return "doc.badge.plus"
        case "Bash": return "terminal"
        default: return "wrench"
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

// MARK: - Markdown Render View (WKWebView, bundled JS)

import WebKit

struct MarkdownRenderView: NSViewRepresentable {
    let markdown: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.loadTemplate(into: webView, markdown: markdown)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.lastMarkdown != markdown else { return }
        context.coordinator.loadTemplate(into: webView, markdown: markdown)
    }

    class Coordinator {
        var lastMarkdown: String?
        private static var cachedMarkedJS: String?

        private var markedJS: String {
            if let cached = Self.cachedMarkedJS { return cached }
            if let url = Bundle.main.url(forResource: "marked.min", withExtension: "js"),
               let js = try? String(contentsOf: url, encoding: .utf8) {
                Self.cachedMarkedJS = js
                return js
            }
            return ""
        }

        func loadTemplate(into webView: WKWebView, markdown: String) {
            lastMarkdown = markdown
            let escaped = markdown
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "`", with: "\\`")
                .replacingOccurrences(of: "$", with: "\\$")
            let html = """
            <!DOCTYPE html>
            <html>
            <head>
            <meta charset="utf-8">
            <style>
              :root { color-scheme: light dark; }
              body {
                font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                font-size: 14px; line-height: 1.6;
                padding: 16px; margin: 0;
                color: var(--text); background: transparent;
              }
              @media (prefers-color-scheme: dark) {
                :root { --text: #e0e0e0; --code-bg: #1e1e1e; --border: #333; }
              }
              @media (prefers-color-scheme: light) {
                :root { --text: #1d1d1f; --code-bg: #f5f5f5; --border: #d1d1d6; }
              }
              h1 { font-size: 1.6em; border-bottom: 1px solid var(--border); padding-bottom: 4px; }
              h2 { font-size: 1.3em; border-bottom: 1px solid var(--border); padding-bottom: 4px; }
              h3 { font-size: 1.1em; }
              code {
                font-family: Menlo, monospace; font-size: 0.9em;
                background: var(--code-bg); padding: 2px 5px; border-radius: 4px;
              }
              pre { background: var(--code-bg); padding: 12px; border-radius: 8px; overflow-x: auto; }
              pre code { background: none; padding: 0; }
              blockquote {
                border-left: 3px solid var(--border);
                margin-left: 0; padding-left: 12px; color: #888;
              }
              table { border-collapse: collapse; width: 100%; }
              th, td { border: 1px solid var(--border); padding: 6px 12px; text-align: left; }
              img { max-width: 100%; }
              a { color: #007aff; }
            </style>
            </head>
            <body>
            <div id="content"></div>
            <script>\(markedJS)</script>
            <script>
              document.getElementById('content').innerHTML = marked.parse(`\(escaped)`);
            </script>
            </body>
            </html>
            """
            webView.loadHTMLString(html, baseURL: nil)
        }
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
