import SwiftUI
import SwiftData

struct SessionMessagesView: View {
    let session: Session
    @Environment(\.modelContext) private var modelContext
    @State private var showContext = true

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
    @State private var isLoading = true
    @State private var isDeleting = false  // 削除中はスクロールしない

    // ソート済みメッセージをキャッシュ
    private var messagesWithContext: [(message: Message, prevUserTime: Date?)] {
        let sorted = session.messages.sorted { $0.timestamp < $1.timestamp }
        var result: [(Message, Date?)] = []
        var lastUserTime: Date? = nil

        for msg in sorted {
            if msg.type == .assistant {
                result.append((msg, lastUserTime))
            } else {
                result.append((msg, nil))
                lastUserTime = msg.timestamp
            }
        }
        return result
    }

    // structuredPatchマップ: tool_use_idをキーに[StructuredPatchHunk]を保持
    private var structuredPatchMap: [String: [StructuredPatchHunk]] {
        var map: [String: [StructuredPatchHunk]] = [:]
        for msg in session.messages where msg.type == .user {
            if let results = msg.toolUseResultsWithPatch {
                for (toolUseId, patches) in results {
                    map[toolUseId] = patches
                }
            }
        }
        return map
    }

    private var isWaitingForResponse: Bool {
        guard let last = session.messages.max(by: { $0.timestamp < $1.timestamp }) else { return false }
        return last.type == .user
    }

    // Surgery Mode: 選択したメッセージの合計トークン数（Surgery Mode時のみ計算）
    private var selectedTokenCount: Int {
        guard isSurgeryMode else { return 0 }
        return session.messages
            .filter { selectedMessageIds.contains($0.uuid) }
            .map { TokenEstimator.estimateTokens(for: $0) }
            .reduce(0, +)
    }

    // 全メッセージの合計トークン数（Surgery Mode時のみ計算）
    private var totalTokenCount: Int {
        guard isSurgeryMode else { return 0 }
        return TokenEstimator.totalTokens(for: Array(session.messages))
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                // Surgery Mode ツールバー
                if isSurgeryMode {
                    surgeryToolbar
                }

                // ローディング中
                if isLoading {
                    Spacer()
                    ProgressView("読み込み中...")
                        .progressViewStyle(.circular)
                    Spacer()
                } else {
                    // メインタイムライン
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 12) {
                                ForEach(messagesWithContext, id: \.message.uuid) { item in
                                    MessageRow(
                                        message: item.message,
                                        previousUserTimestamp: item.prevUserTime,
                                        structuredPatchMap: structuredPatchMap,
                                        isInSurgeryMode: isSurgeryMode,
                                        isSelected: selectedMessageIds.contains(item.message.uuid),
                                        tokenCount: isSurgeryMode ? TokenEstimator.estimateTokens(for: item.message) : 0,
                                        onToggleSelection: {
                                            toggleSelection(item.message.uuid)
                                        },
                                        onRewindHere: {
                                            rewindTargetId = item.message.uuid
                                            showRewindConfirm = true
                                        },
                                        onDelete: {
                                            deleteTargetMessage = item.message
                                            if skipDeleteConfirmation {
                                                performSingleDelete()
                                            } else {
                                                showDeleteConfirm = true
                                            }
                                        },
                                        onEditSummary: {
                                            editingSummaryMessage = item.message
                                            editedSummaryContent = item.message.content ?? ""
                                            showSummaryEditor = true
                                        }
                                    )
                                    .id(item.message.uuid)
                                }

                                // 最新がuserメッセージなら、Claudeが考え中
                                if isWaitingForResponse && !isSurgeryMode {
                                    WaitingForResponseBubble()
                                        .id("waiting")
                                }
                            }
                            .padding()
                        }
                        .onChange(of: session.messages.count) { oldCount, newCount in
                            // 削除時（カウント減少時）はスクロールしない
                            guard newCount > oldCount, !isDeleting else { return }
                            if let lastItem = messagesWithContext.last {
                                withAnimation {
                                    proxy.scrollTo(lastItem.message.uuid, anchor: .bottom)
                                }
                            }
                        }
                    }
                }
            }
            .frame(minWidth: 400)

            // コンテキストパネル
            if showContext && !isSurgeryMode {
                ContextPanel(sessionId: session.sessionId)
                    .frame(minWidth: 250, maxWidth: 300)
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
            loadSession()
        }
        .onChange(of: session.sessionId) { _, _ in
            loadSession()
        }
    }

    private func loadSession() {
        isLoading = true
        // 少し遅延してUIを更新（メインスレッドをブロックしない）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            isLoading = false
        }
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

        isDeleting = true
        defer { isDeleting = false }

        do {
            try JSONLWriter.backup(url: fileURL)
            try JSONLWriter.deleteMessages(uuids: Array(selectedMessageIds), from: fileURL)

            // SwiftDataからも削除
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

    private func performSingleDelete() {
        guard let message = deleteTargetMessage,
              let fileURL = session.jsonlFileURL else {
            errorMessage = "セッションファイルが見つかりません"
            showError = true
            return
        }

        isDeleting = true
        defer { isDeleting = false }

        do {
            try JSONLWriter.backup(url: fileURL)
            try JSONLWriter.deleteMessages(uuids: [message.uuid], from: fileURL)

            // SwiftDataからも削除
            modelContext.delete(message)
            try? modelContext.save()

            deleteTargetMessage = nil
        } catch {
            errorMessage = "削除に失敗しました: \(error.localizedDescription)"
            showError = true
        }
    }

    private func performRewind() {
        guard let targetId = rewindTargetId,
              let fileURL = session.jsonlFileURL else {
            errorMessage = "セッションファイルが見つかりません"
            showError = true
            return
        }

        isDeleting = true
        defer { isDeleting = false }

        do {
            try JSONLWriter.backup(url: fileURL)
            try JSONLWriter.deleteMessagesAfter(uuid: targetId, from: fileURL, inclusive: false)

            // SwiftDataからも削除（targetId以降のメッセージ）
            let sortedMessages = session.messages.sorted { $0.timestamp < $1.timestamp }
            var foundTarget = false
            for message in sortedMessages {
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

    private func saveSummaryEdit() {
        guard let message = editingSummaryMessage,
              let fileURL = session.jsonlFileURL else {
            errorMessage = "セッションファイルが見つかりません"
            showError = true
            return
        }

        do {
            try JSONLWriter.backup(url: fileURL)
            try JSONLWriter.updateMessageContent(uuid: message.uuid, newContent: editedSummaryContent, in: fileURL)
            showSummaryEditor = false
            editingSummaryMessage = nil
        } catch {
            errorMessage = "保存に失敗しました: \(error.localizedDescription)"
            showError = true
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
    let sessionId: String

    @Query private var messages: [Message]

    init(sessionId: String) {
        self.sessionId = sessionId
        let id = sessionId
        _messages = Query(filter: #Predicate<Message> { message in
            message.session?.sessionId == id
        })
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                // 現在のClaude理解（最新の思考）
                if let latest = latestThinking {
                    CurrentUnderstandingView(thinking: latest)
                }

                // 読み込んだファイル
                if !readFiles.isEmpty {
                    ContextSectionView(title: "読み込み済み", icon: "doc.text", color: .blue, items: readFiles)
                }

                // 編集したファイル
                if !editedFiles.isEmpty {
                    ContextSectionView(title: "編集済み", icon: "pencil", color: .orange, items: editedFiles)
                }

                // 作成したファイル
                if !writtenFiles.isEmpty {
                    ContextSectionView(title: "作成済み", icon: "doc.badge.plus", color: .green, items: writtenFiles)
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
    }

    // compaction後のサマリー（Claudeの吟味された理解）
    private var latestThinking: String? {
        // "This session is being continued" で始まるメッセージを探す
        let summaries = messages
            .filter { $0.type == .user }
            .sorted { $0.timestamp > $1.timestamp }
            .compactMap { $0.content }
            .filter { $0.contains("This session is being continued") }

        // 最新のサマリーを返す
        if let latest = summaries.first {
            return latest
        }

        // サマリーがなければ最新のthinkingを返す
        return messages
            .filter { $0.type == .assistant }
            .sorted { $0.timestamp > $1.timestamp }
            .compactMap { $0.thinking }
            .first
    }

    // ファイル別に重複排除（最新の内容を保持）
    private var contextMap: [String: ContextItem] {
        var map: [String: ContextItem] = [:]
        var toolUseMap: [String: ToolUseInfo] = [:]

        // tool_useを収集（これだけで表示できるようにする）
        for msg in messages where msg.type == .assistant {
            for toolUse in msg.toolUses {
                toolUseMap[toolUse.id] = toolUse

                // tool_useだけでも表示（後でtool_resultで上書きされる）
                if let key = toolUse.filePath ?? toolUse.command {
                    if map[key] == nil {
                        map[key] = ContextItem(
                            id: key,
                            toolName: toolUse.name,
                            filePath: toolUse.filePath,
                            command: toolUse.command,
                            content: "(実行中...)",
                            isError: false
                        )
                    }
                }
            }
        }

        // tool_resultとマッチング（後から来たもので上書き = 最新）
        for msg in messages where msg.type == .user {
            guard let results = msg.toolResults else { continue }
            for result in results {
                guard let toolUseId = result.tool_use_id,
                      let toolUse = toolUseMap[toolUseId] else { continue }

                let content = result.content ?? ""
                let key = toolUse.filePath ?? toolUse.command ?? toolUseId
                map[key] = ContextItem(
                    id: key,
                    toolName: toolUse.name,
                    filePath: toolUse.filePath,
                    command: toolUse.command,
                    content: content.isEmpty ? "(成功)" : content,
                    isError: result.is_error ?? false
                )
            }
        }

        return map
    }

    private var readFiles: [ContextItem] {
        contextMap.values.filter { $0.toolName == "Read" }.sorted { ($0.filePath ?? "") < ($1.filePath ?? "") }
    }

    private var editedFiles: [ContextItem] {
        contextMap.values.filter { $0.toolName == "Edit" }.sorted { ($0.filePath ?? "") < ($1.filePath ?? "") }
    }

    private var writtenFiles: [ContextItem] {
        contextMap.values.filter { $0.toolName == "Write" }.sorted { ($0.filePath ?? "") < ($1.filePath ?? "") }
    }
}

// Claudeの理解（蓄積された思考）
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
                ScrollView {
                    Text(thinking)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 300)
                .padding(10)
                .background(.orange.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
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

// セクションビュー
struct ContextSectionView: View {
    let title: String
    let icon: String
    let color: Color
    let items: [ContextItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                Text(title)
                    .fontWeight(.semibold)
                Text("\(items.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)

            ForEach(items) { item in
                ContextItemView(item: item)
            }
        }
    }
}

// コンテキストアイテム
struct ContextItem: Identifiable {
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
    @State private var isExpanded = false
    @State private var showEditor = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // ヘッダー（クリックで展開）
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

                // ファイルを開くボタン
                if item.filePath != nil {
                    Button {
                        showEditor = true
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

            // 内容（展開時）
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
        .sheet(isPresented: $showEditor) {
            if let path = item.filePath {
                FileEditorSheet(filePath: path)
            }
        }
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
