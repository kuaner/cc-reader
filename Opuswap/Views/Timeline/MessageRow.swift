import SwiftUI

struct MessageRow: View {
    let message: Message
    var previousUserTimestamp: Date? = nil

    // structuredPatchマップ: tool_use_idをキーに[StructuredPatchHunk]を保持
    var structuredPatchMap: [String: [StructuredPatchHunk]] = [:]

    // Surgery Mode
    var isInSurgeryMode: Bool = false
    var isSelected: Bool = false
    var tokenCount: Int = 0
    var onToggleSelection: (() -> Void)? = nil

    // Rewind
    var onRewindHere: (() -> Void)? = nil

    // 削除
    var onDelete: (() -> Void)? = nil

    // 要約編集
    var onEditSummary: (() -> Void)? = nil

    // 要約メッセージかどうか
    private var isSummaryMessage: Bool {
        message.type == .user &&
        (message.content?.contains("This session is being continued") == true)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Surgery Mode時のチェックボックス
            if isInSurgeryMode {
                VStack {
                    Button {
                        onToggleSelection?()
                    } label: {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isSelected ? .red : .secondary)
                            .font(.title2)
                    }
                    .buttonStyle(.plain)

                    Text(TokenEstimator.formatTokens(tokenCount))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(width: 50)
            }

            // メッセージコンテンツ
            if message.type == .user {
                Spacer(minLength: isInSurgeryMode ? 20 : 60)
                userBubble
            } else {
                assistantBubble
                Spacer(minLength: isInSurgeryMode ? 20 : 60)
            }
        }
        .opacity(isSelected ? 0.5 : 1.0)
    }

    // 共通のcontextMenu
    @ViewBuilder
    private var messageContextMenu: some View {
        Button {
            onDelete?()
        } label: {
            Label("このメッセージを削除", systemImage: "trash")
        }

        Divider()

        Button {
            onRewindHere?()
        } label: {
            Label("ここまで巻き戻す", systemImage: "arrow.counterclockwise")
        }
    }

    // MARK: - User Bubble (右側)

    @ViewBuilder
    private var userBubble: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if isSummaryMessage {
                // 要約メッセージの特別表示
                summaryBubble
            } else if let content = message.content, !content.isEmpty {
                Text(content)
                    .font(.body)
                    .textSelection(.enabled)
                    .padding(12)
                    .background(.blue)
                    .foregroundStyle(.white)
                    .clipShape(ChatBubble(isUser: true))
                    .contextMenu { messageContextMenu }
            }

            Text(message.timestamp, style: .time)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Summary Bubble (要約メッセージ)

    @ViewBuilder
    private var summaryBubble: some View {
        VStack(alignment: .trailing, spacing: 8) {
            HStack {
                Image(systemName: "doc.text.magnifyingglass")
                Text("セッション要約")
                    .fontWeight(.semibold)
                Spacer()
                if !isInSurgeryMode {
                    Button {
                        onEditSummary?()
                    } label: {
                        Image(systemName: "pencil.circle")
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                    .help("要約を編集")
                }
            }
            .foregroundStyle(.orange)

            if let content = message.content {
                Text(content)
                    .font(.callout)
                    .textSelection(.enabled)
                    .lineLimit(10)
            }
        }
        .padding(12)
        .frame(maxWidth: 500, alignment: .leading)
        .background(.orange.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(.orange.opacity(0.3), lineWidth: 1)
        )
        .contextMenu { messageContextMenu }
    }

    // MARK: - Assistant Bubble (左側)

    @ViewBuilder
    private var assistantBubble: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Thinking（常に展開）
            if let thinking = message.thinking, !thinking.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Thinking")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.orange)

                    Text(thinking)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                    // 思考時間（前のuserメッセージからの経過時間）
                    Text("\(calculatedThinkingDuration)秒")
                        .font(.caption2)
                        .foregroundStyle(.orange.opacity(0.7))
                }
            }

            // ツール使用（コンテキスト）
            if !message.toolUses.isEmpty {
                ToolUsesView(toolUses: message.toolUses, structuredPatchMap: structuredPatchMap)
            }

            // Response
            if let content = message.content, !content.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Claude")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.purple)
                        if let model = message.model {
                            Text(modelDisplayName(model))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Text(content)
                        .font(.body)
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.purple.opacity(0.1))
                        .clipShape(ChatBubble(isUser: false))
                        .contextMenu { messageContextMenu }

                    // 回答時刻を右下に
                    HStack {
                        Spacer()
                        Text(message.timestamp, style: .time)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    // 思考時間（前のuserメッセージからの経過時間）
    private var calculatedThinkingDuration: Int {
        guard let prevTime = previousUserTimestamp else {
            // フォールバック: 文字数ベースで概算
            let thinkingCount = message.thinking?.count ?? 0
            return max(1, thinkingCount / 50)
        }
        let duration = message.timestamp.timeIntervalSince(prevTime)
        return max(1, Int(duration))
    }

    private func modelDisplayName(_ model: String) -> String {
        if model.contains("opus") { return "Opus" }
        if model.contains("sonnet") { return "Sonnet" }
        if model.contains("haiku") { return "Haiku" }
        return model
    }
}

// MARK: - Tool Uses View (コンテキスト表示)

struct ToolUsesView: View {
    let toolUses: [ToolUseInfo]
    var structuredPatchMap: [String: [StructuredPatchHunk]] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Context")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.cyan)

            FlowLayout(spacing: 6) {
                ForEach(toolUses.indices, id: \.self) { index in
                    let toolUse = toolUses[index]
                    ToolUseTag(
                        toolUse: toolUse,
                        structuredPatch: structuredPatchMap[toolUse.id]
                    )
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.cyan.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct ToolUseTag: View {
    let toolUse: ToolUseInfo
    var structuredPatch: [StructuredPatchHunk]? = nil
    @State private var isExpanded = false

    // 展開可能かどうか: structuredPatchがある場合のみ
    private var canExpand: Bool {
        toolUse.name == "Edit" && structuredPatch != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // タグ部分
            Button {
                if canExpand {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: iconName)
                        .font(.caption2)
                    Text(displayText)
                        .font(.caption2)
                        .lineLimit(1)
                    if canExpand {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(backgroundColor)
                .foregroundStyle(foregroundColor)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            // Edit差分表示（structuredPatchがある場合のみ）
            if isExpanded, let patch = structuredPatch {
                StructuredPatchDiffView(
                    filePath: toolUse.filePath ?? "",
                    patch: patch
                )
            }
        }
    }

    private var iconName: String {
        switch toolUse.name {
        case "Read": return "doc.text"
        case "Edit": return "pencil"
        case "Write": return "doc.badge.plus"
        case "Bash": return "terminal"
        case "Glob": return "folder.badge.gearshape"
        case "Grep": return "magnifyingglass"
        default: return "wrench"
        }
    }

    private var displayText: String {
        if let path = toolUse.filePath {
            return (path as NSString).lastPathComponent
        }
        if let cmd = toolUse.command {
            let trimmed = cmd.trimmingCharacters(in: .whitespaces)
            return String(trimmed.prefix(20)) + (trimmed.count > 20 ? "..." : "")
        }
        return toolUse.name
    }

    private var backgroundColor: Color {
        switch toolUse.name {
        case "Read": return .blue.opacity(0.15)
        case "Edit": return .orange.opacity(0.15)
        case "Write": return .green.opacity(0.15)
        case "Bash": return .purple.opacity(0.15)
        default: return .gray.opacity(0.15)
        }
    }

    private var foregroundColor: Color {
        switch toolUse.name {
        case "Read": return .blue
        case "Edit": return .orange
        case "Write": return .green
        case "Bash": return .purple
        default: return .secondary
        }
    }
}

struct DiffLine {
    let lineNumber: String
    let mark: String
    let content: String
    let type: DiffType

    enum DiffType {
        case context, removed, added
    }

    var color: Color {
        switch type {
        case .context: return .primary
        case .removed: return .red
        case .added: return .green
        }
    }

    var backgroundColor: Color {
        switch type {
        case .context: return .clear
        case .removed: return .red.opacity(0.15)
        case .added: return .green.opacity(0.15)
        }
    }
}

// MARK: - StructuredPatch差分表示（正確な行番号）

struct StructuredPatchDiffView: View {
    let filePath: String
    let patch: [StructuredPatchHunk]

    private var fileName: String {
        (filePath as NSString).lastPathComponent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // ヘッダー
            HStack {
                Image(systemName: "pencil")
                    .font(.caption)
                Text("Update(\(fileName))")
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .foregroundStyle(.orange)

            Text(filePath)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            // Hunks
            VStack(alignment: .leading, spacing: 8) {
                ForEach(patch.indices, id: \.self) { i in
                    HunkView(hunk: patch[i])
                }
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct HunkView: View {
    let hunk: StructuredPatchHunk

    // 行番号とマーク、内容を計算
    private var diffLines: [DiffLine] {
        var result: [DiffLine] = []
        var oldLine = hunk.oldStart
        var newLine = hunk.newStart

        for line in hunk.lines {
            guard !line.isEmpty else { continue }
            let prefix = String(line.prefix(1))
            let content = String(line.dropFirst())

            switch prefix {
            case " ":
                // コンテキスト行: 両方の行番号が進む（new側の行番号を表示）
                result.append(DiffLine(lineNumber: "\(newLine)", mark: " ", content: content, type: .context))
                oldLine += 1
                newLine += 1
            case "-":
                // 削除行: old行番号
                result.append(DiffLine(lineNumber: "\(oldLine)", mark: "-", content: content, type: .removed))
                oldLine += 1
            case "+":
                // 追加行: new行番号
                result.append(DiffLine(lineNumber: "\(newLine)", mark: "+", content: content, type: .added))
                newLine += 1
            default:
                // その他の場合はコンテキストとして扱う
                result.append(DiffLine(lineNumber: "\(newLine)", mark: " ", content: line, type: .context))
                oldLine += 1
                newLine += 1
            }
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(diffLines.indices, id: \.self) { i in
                let line = diffLines[i]
                HStack(spacing: 0) {
                    // 行番号
                    Text(line.lineNumber)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, alignment: .trailing)
                    // マーク
                    Text(" \(line.mark) ")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(line.color)
                    // 内容
                    Text(line.content)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(line.color.opacity(0.9))
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 1)
                .padding(.trailing, 4)
                .background(line.backgroundColor)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

// シンプルなFlowLayout
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > maxWidth && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            positions.append(CGPoint(x: currentX, y: currentY))
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }

        return (CGSize(width: maxWidth, height: currentY + lineHeight), positions)
    }
}

// MARK: - Tool Result Bubble

struct ToolResultBubble: View {
    let result: ToolResultData

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            HStack(spacing: 4) {
                Text("Tool Result")
                    .font(.caption2)
                    .fontWeight(.medium)
                if result.is_error == true {
                    Text("ERROR")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.red)
                        .clipShape(Capsule())
                }
            }
            .foregroundStyle(result.is_error == true ? .red : .green)

            if let content = result.content, !content.isEmpty {
                Text(content)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(5)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: 300, alignment: .leading)
                    .background(result.is_error == true ? .red.opacity(0.1) : .green.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

// MARK: - Waiting For Response (userメッセージ後の待機表示)

struct WaitingForResponseBubble: View {
    @State private var dotCount = 0
    private let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Claude")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.purple)

                HStack(spacing: 0) {
                    Text("Thinking")
                    Text(String(repeating: ".", count: dotCount + 1))
                        .frame(width: 24, alignment: .leading)
                }
                .font(.body)
                .foregroundStyle(.secondary)
                .padding(12)
                .background(.purple.opacity(0.1))
                .clipShape(ChatBubble(isUser: false))
            }
            Spacer(minLength: 60)
        }
        .onReceive(timer) { _ in
            dotCount = (dotCount + 1) % 3
        }
    }
}

// MARK: - Chat Bubble Shape

struct ChatBubble: Shape {
    let isUser: Bool

    func path(in rect: CGRect) -> Path {
        let radius: CGFloat = 12
        var path = Path()

        if isUser {
            // 右下に尻尾
            path.addRoundedRect(in: CGRect(x: 0, y: 0, width: rect.width - 6, height: rect.height), cornerSize: CGSize(width: radius, height: radius))
            path.move(to: CGPoint(x: rect.width - 6, y: rect.height - 16))
            path.addLine(to: CGPoint(x: rect.width, y: rect.height - 8))
            path.addLine(to: CGPoint(x: rect.width - 6, y: rect.height - 4))
        } else {
            // 左下に尻尾
            path.addRoundedRect(in: CGRect(x: 6, y: 0, width: rect.width - 6, height: rect.height), cornerSize: CGSize(width: radius, height: radius))
            path.move(to: CGPoint(x: 6, y: rect.height - 16))
            path.addLine(to: CGPoint(x: 0, y: rect.height - 8))
            path.addLine(to: CGPoint(x: 6, y: rect.height - 4))
        }

        return path
    }
}

#Preview {
    let rawJson = """
    {
        "type": "assistant",
        "uuid": "test-uuid",
        "sessionId": "test-session",
        "timestamp": "2026-01-15T10:00:00.000Z",
        "message": {
            "role": "assistant",
            "content": [
                {"type": "thinking", "thinking": "ユーザーはOpuswapの実装を求めています。設計書を確認して進めます。"},
                {"type": "text", "text": "設計書を確認しました。実装を開始します。"}
            ],
            "model": "claude-sonnet-4-5-20250929"
        }
    }
    """.data(using: .utf8)!

    let message = Message(uuid: "test", type: .assistant, timestamp: Date(), rawJson: rawJson)

    return ScrollView {
        VStack(spacing: 12) {
            MessageRow(message: message)
        }
        .padding()
    }
    .frame(width: 500, height: 400)
}
