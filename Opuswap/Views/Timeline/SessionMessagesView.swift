import SwiftUI
import SwiftData

struct SessionMessagesView: View {
    let session: Session
    @Environment(\.modelContext) private var modelContext
    @State private var showContext = true

    // SQLiteがtimestampでソート → View側のO(n log n)ソート完全不要
    @Query private var messages: [Message]

    // Surgery Mode
    @State private var isSurgeryMode = false
    @State private var selectedMessageIds: Set<String> = []

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

    // 予計算済みデータ（メッセージ数変化時のみ更新）
    @State private var prevTimestampMap: [String: Date] = [:]
    @State private var lastProcessedMessageCount = 0
    @State private var derivedPatchMap: [String: [StructuredPatchHunk]] = [:]
    @State private var derivedToolUseMap: [String: ToolUseInfo] = [:]
    @State private var derivedContextMap: [String: ContextItem] = [:]
    @State private var derivedLatestThinking: String? = nil
    @State private var derivedHasSummaryThinking = false
    @State private var tokenCountByMessageId: [String: Int] = [:]
    @State private var cachedTotalTokens = 0
    @StateObject private var patchMapStore = PatchMapStore()

    // ContextPanel 用のキャッシュ（重複 @Query 排除）
    @State private var ctxLatestThinking: String? = nil
    @State private var ctxReadFiles: [ContextItem] = []
    @State private var ctxEditedFiles: [ContextItem] = []
    @State private var ctxWrittenFiles: [ContextItem] = []

    init(session: Session) {
        self.session = session
        let sid = session.sessionId
        _messages = Query(
            filter: #Predicate<Message> { $0.session?.sessionId == sid },
            sort: \Message.timestamp,
            order: .forward
        )
    }

    private var isWaitingForResponse: Bool {
        messages.last?.type == MessageType.user
    }

    private var selectedTokenCount: Int {
        guard isSurgeryMode else { return 0 }
        return selectedMessageIds.reduce(0) { partial, id in
            partial + (tokenCountByMessageId[id] ?? 0)
        }
    }

    private var totalTokenCount: Int {
        isSurgeryMode ? cachedTotalTokens : 0
    }

    var body: some View {
        HStack(spacing: 0) {
            // メインタイムライン
            VStack(spacing: 0) {
                if isSurgeryMode {
                    surgeryToolbar
                }

                if messages.isEmpty {
                    Spacer()
                    Text("メッセージなし")
                        .foregroundStyle(.secondary)
                    Spacer()
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 12) {
                                ForEach(messages) { message in
                                    MessageRow(
                                        message: message,
                                        previousUserTimestamp: prevTimestampMap[message.uuid],
                                        isInSurgeryMode: isSurgeryMode,
                                        isSelected: selectedMessageIds.contains(message.uuid),
                                        tokenCount: isSurgeryMode ? TokenEstimator.estimateTokens(for: message) : 0,
                                        onAction: handleRowAction
                                    )
                                    .id(message.uuid)
                                }

                                if isWaitingForResponse && !isSurgeryMode {
                                    WaitingForResponseBubble()
                                        .id("waiting")
                                }
                            }
                            .padding()
                        }
                        .environmentObject(patchMapStore)
                        .onChange(of: messages.count) { oldCount, newCount in
                            rebuildDerivedData()
                            guard newCount > oldCount, !isDeleting else { return }
                            if let last = messages.last {
                                withAnimation {
                                    proxy.scrollTo(last.uuid, anchor: .bottom)
                                }
                            }
                        }
                    }
                }
            }

            // コンテキストパネル（固定幅サイドバー、@Query 排除済み）
            if showContext && !isSurgeryMode {
                Divider()
                ContextPanel(
                    latestThinking: ctxLatestThinking,
                    readFiles: ctxReadFiles,
                    editedFiles: ctxEditedFiles,
                    writtenFiles: ctxWrittenFiles
                )
                .frame(width: 260)
            }
        }
        .navigationTitle(sessionTitle)
        .toolbar {
            // Surgery Modeトグル
            ToolbarItem(placement: .automatic) {
                Button {
                    withAnimation {
                        isSurgeryMode.toggle()
                        if !isSurgeryMode {
                            selectedMessageIds.removeAll()
                        }
                    }
                } label: {
                    Image(systemName: "scissors")
                        .symbolVariant(isSurgeryMode ? .fill : .none)
                        .foregroundStyle(isSurgeryMode ? .red : .primary)
                }
                .help("Surgery Mode")
            }

            ToolbarItem(placement: .automatic) {
                Button {
                    withAnimation { showContext.toggle() }
                } label: {
                    Image(systemName: showContext ? "sidebar.right" : "sidebar.right")
                        .symbolVariant(showContext ? .fill : .none)
                }
                .help("コンテキストを表示")
                .disabled(isSurgeryMode)
            }
        }
        // Rewind確認ダイアログ
        .confirmationDialog("巻き戻し確認", isPresented: $showRewindConfirm, titleVisibility: .visible) {
            Button("巻き戻す", role: .destructive) {
                performRewind()
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("このメッセージ以降を全て削除します。この操作は取り消せません。")
        }
        // 単一メッセージ削除確認
        .sheet(isPresented: $showDeleteConfirm) {
            DeleteConfirmSheet(
                skipConfirmation: $skipDeleteConfirmation,
                onDelete: { performSingleDelete() },
                onCancel: { showDeleteConfirm = false }
            )
        }
        // 要約編集シート
        .sheet(isPresented: $showSummaryEditor) {
            SummaryEditorSheet(
                content: $editedSummaryContent,
                onSave: { saveSummaryEdit() },
                onCancel: { showSummaryEditor = false }
            )
        }
        // エラーアラート
        .alert("エラー", isPresented: $showError) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
        .onAppear {
            rebuildDerivedData()
        }
    }

    // MARK: - Row Action Handler

    private func handleRowAction(_ action: MessageRowAction) {
        switch action {
        case .toggleSelection(let uuid):
            toggleSelection(uuid)
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

    /// Phase 1（同期・高速）: timestamp マップのみ構築。type / timestamp / uuid は SQLite 直接読み出しで JSON デコード不要。
    /// Phase 2（非同期・yield 付き）: 全メッセージのデコード + patchMap + context を段階的に構築。
    private func rebuildDerivedData() {
        derivedDataGeneration += 1
        let gen = derivedDataGeneration

        // --- Phase 1: 同期（デコード不要のプロパティのみ） ---
        var tsMap: [String: Date] = [:]
        var lastUserTime: Date? = nil
        for msg in messages {
            if msg.type == .assistant, let t = lastUserTime {
                tsMap[msg.uuid] = t
            }
            if msg.type == .user {
                lastUserTime = msg.timestamp
            }
        }
        prevTimestampMap = tsMap

        // --- Phase 2: 非同期（デコード + patchMap + context） ---
        let count = messages.count
        let needsFullRebuild = count < lastProcessedMessageCount
        let startIndex = needsFullRebuild ? 0 : lastProcessedMessageCount
        guard startIndex <= count else { return }
        let deltaMessages = Array(messages[startIndex..<count])

        var initialPatchMap = needsFullRebuild ? [:] : derivedPatchMap
        var initialToolUseMap = needsFullRebuild ? [:] : derivedToolUseMap
        var initialContextMap = needsFullRebuild ? [:] : derivedContextMap
        var initialLatestThinking = needsFullRebuild ? nil : derivedLatestThinking
        var initialHasSummaryThinking = needsFullRebuild ? false : derivedHasSummaryThinking
        var initialTokenMap = needsFullRebuild ? [:] : tokenCountByMessageId

        if deltaMessages.isEmpty {
            publishContext(
                patchMap: initialPatchMap,
                contextMap: initialContextMap,
                latestThinking: initialLatestThinking
            )
            return
        }

        Task { @MainActor in
            for (i, msg) in deltaMessages.enumerated() {
                guard gen == derivedDataGeneration else { return }
                msg.preload()
                initialTokenMap[msg.uuid] = TokenEstimator.estimateTokens(for: msg)

                if msg.type == .assistant {
                    for toolUse in msg.toolUses {
                        initialToolUseMap[toolUse.id] = toolUse
                        if let key = toolUse.filePath ?? toolUse.command {
                            if initialContextMap[key] == nil {
                                initialContextMap[key] = ContextItem(
                                    id: key, toolName: toolUse.name,
                                    filePath: toolUse.filePath, command: toolUse.command,
                                    content: "(実行中...)", isError: false
                                )
                            }
                        }
                    }
                    if !initialHasSummaryThinking, let t = msg.thinking, !t.isEmpty {
                        initialLatestThinking = t
                    }
                } else {
                    if let patches = msg.toolUseResultsWithPatch {
                        for (id, hunks) in patches { initialPatchMap[id] = hunks }
                    }
                    if let c = msg.content, c.contains("This session is being continued") {
                        initialLatestThinking = c
                        initialHasSummaryThinking = true
                    }
                    if let results = msg.toolResults {
                        for result in results {
                            guard let toolUseId = result.tool_use_id,
                                  let toolUse = initialToolUseMap[toolUseId] else { continue }
                            let content = result.content ?? ""
                            let key = toolUse.filePath ?? toolUse.command ?? toolUseId
                            initialContextMap[key] = ContextItem(
                                id: key, toolName: toolUse.name,
                                filePath: toolUse.filePath, command: toolUse.command,
                                content: content.isEmpty ? "(成功)" : content,
                                isError: result.is_error ?? false
                            )
                        }
                    }
                }
                if i.isMultiple(of: 40) { await Task.yield() }
            }

            guard gen == derivedDataGeneration else { return }
            lastProcessedMessageCount = count
            derivedPatchMap = initialPatchMap
            derivedToolUseMap = initialToolUseMap
            derivedContextMap = initialContextMap
            derivedLatestThinking = initialLatestThinking
            derivedHasSummaryThinking = initialHasSummaryThinking
            tokenCountByMessageId = initialTokenMap
            cachedTotalTokens = initialTokenMap.values.reduce(0, +)
            publishContext(
                patchMap: initialPatchMap,
                contextMap: initialContextMap,
                latestThinking: initialLatestThinking
            )
        }
    }

    private func publishContext(
        patchMap: [String: [StructuredPatchHunk]],
        contextMap: [String: ContextItem],
        latestThinking: String?
    ) {
        patchMapStore.map = patchMap
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

    // MARK: - Surgery Mode Toolbar

    private var surgeryToolbar: some View {
        HStack {
            // トークン使用状況
            VStack(alignment: .leading, spacing: 2) {
                Text("トークン使用量")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Text(TokenEstimator.formatTokens(totalTokenCount))
                        .fontWeight(.semibold)
                    Text("/ 200K")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            }

            Spacer()

            // 選択状況
            if !selectedMessageIds.isEmpty {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(selectedMessageIds.count)件選択中")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("-\(TokenEstimator.formatTokens(selectedTokenCount))")
                        .font(.callout)
                        .fontWeight(.semibold)
                        .foregroundStyle(.red)
                }
            }

            // 削除ボタン
            Button {
                performSurgeryDelete()
            } label: {
                Label("削除", systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(selectedMessageIds.isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Actions

    private func toggleSelection(_ uuid: String) {
        if selectedMessageIds.contains(uuid) {
            selectedMessageIds.remove(uuid)
        } else {
            selectedMessageIds.insert(uuid)
        }
    }

    private func performSurgeryDelete() {
        guard let fileURL = session.jsonlFileURL else {
            errorMessage = "セッションファイルが見つかりません"
            showError = true
            return
        }
        let deleteIds = Array(selectedMessageIds)
        Task {
            isDeleting = true
            defer { isDeleting = false }

            do {
                try await JSONLWriter.backup(url: fileURL)
                try await JSONLWriter.deleteMessages(uuids: deleteIds, from: fileURL)

                let messagesToDelete = session.messages.filter { selectedMessageIds.contains($0.uuid) }
                for message in messagesToDelete {
                    modelContext.delete(message)
                }
                try? modelContext.save()

                selectedMessageIds.removeAll()
                isSurgeryMode = false
            } catch {
                errorMessage = "削除に失敗しました: \(error.localizedDescription)"
                showError = true
            }
        }
    }

    private func performSingleDelete() {
        guard let message = deleteTargetMessage,
              let fileURL = session.jsonlFileURL else {
            errorMessage = "セッションファイルが見つかりません"
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
                errorMessage = "削除に失敗しました: \(error.localizedDescription)"
                showError = true
            }
        }
    }

    private func performRewind() {
        guard let targetId = rewindTargetId,
              let fileURL = session.jsonlFileURL else {
            errorMessage = "セッションファイルが見つかりません"
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
                errorMessage = "巻き戻しに失敗しました: \(error.localizedDescription)"
                showError = true
            }
        }
    }

    private func saveSummaryEdit() {
        guard let message = editingSummaryMessage,
              let fileURL = session.jsonlFileURL else {
            errorMessage = "セッションファイルが見つかりません"
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
                errorMessage = "保存に失敗しました: \(error.localizedDescription)"
                showError = true
            }
        }
    }

    private var sessionTitle: String {
        session.slug ?? String(session.sessionId.prefix(8))
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

            Text("メッセージを削除")
                .font(.headline)

            Text("このメッセージを削除します。")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Toggle("今後確認しない", isOn: $dontAskAgain)
                .toggleStyle(.checkbox)

            HStack(spacing: 12) {
                Button("キャンセル") {
                    onCancel()
                }
                .keyboardShortcut(.escape)

                Button("削除") {
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
            // ヘッダー
            HStack {
                Text("要約を編集")
                    .font(.headline)
                Spacer()
                Button("キャンセル") {
                    onCancel()
                }
                .keyboardShortcut(.escape)
                Button("保存") {
                    onSave()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
            }
            .padding()

            Divider()

            // エディタ
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
                    ContextSectionView(title: "読み込み済み", icon: "doc.text", color: .blue, items: readFiles, onOpenFile: { selectedFileItem = $0 })
                }

                if !editedFiles.isEmpty {
                    ContextSectionView(title: "編集済み", icon: "pencil", color: .orange, items: editedFiles, onOpenFile: { selectedFileItem = $0 })
                }

                if !writtenFiles.isEmpty {
                    ContextSectionView(title: "作成済み", icon: "doc.badge.plus", color: .green, items: writtenFiles, onOpenFile: { selectedFileItem = $0 })
                }

                if latestThinking == nil && readFiles.isEmpty && editedFiles.isEmpty && writtenFiles.isEmpty {
                    Text("コンテキストなし")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .background(.quaternary.opacity(0.5))
        .sheet(item: $selectedFileItem) { item in
            if let path = item.filePath {
                FileEditorSheet(filePath: path)
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
                        Text("Claudeの理解")
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
                .help("拡大表示")
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
                        Text("全文を表示…")
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

// Claudeの理解モーダル
struct UnderstandingModalView: View {
    let thinking: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // ヘッダー
            HStack {
                Image(systemName: "brain.head.profile")
                    .foregroundStyle(.orange)
                Text("Claudeの理解")
                    .font(.headline)
                Spacer()
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

            // 本文
            ScrollView {
                Text(thinking)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
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
                        Image(systemName: "pencil.and.outline")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("ファイルを編集")
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

// MARK: - File Editor Sheet

struct FileEditorSheet: View {
    let filePath: String
    @Environment(\.dismiss) private var dismiss
    @State private var content = ""
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var isSaving = false

    var body: some View {
        VStack(spacing: 0) {
            // ヘッダー
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

                Button("外部で開く") {
                    openInExternalEditor()
                }
                .help("デフォルトのエディタで開く")

                Button("キャンセル") {
                    dismiss()
                }
                .keyboardShortcut(.escape)

                Button("保存") {
                    saveFile()
                }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(isSaving)
            }
            .padding()

            Divider()

            // エディタ
            if isLoading {
                Spacer()
                ProgressView("読み込み中...")
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
            } else {
                TextEditor(text: $content)
                    .font(.system(.body, design: .monospaced))
                    .padding(8)
            }
        }
        .frame(minWidth: 700, minHeight: 500)
        .frame(maxWidth: 1000, maxHeight: 800)
        .task {
            await loadFile()
        }
    }

    private var fileName: String {
        (filePath as NSString).lastPathComponent
    }

    private func loadFile() async {
        isLoading = true
        defer { isLoading = false }

        let url = URL(fileURLWithPath: filePath)
        do {
            content = try String(contentsOf: url, encoding: .utf8)
        } catch {
            errorMessage = "ファイルを読み込めませんでした: \(error.localizedDescription)"
        }
    }

    private func saveFile() {
        isSaving = true
        defer { isSaving = false }

        let url = URL(fileURLWithPath: filePath)
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            dismiss()
        } catch {
            errorMessage = "保存に失敗しました: \(error.localizedDescription)"
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

    return SessionMessagesView(session: session)
        .modelContainer(container)
}
