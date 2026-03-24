import SwiftUI

enum MessageRowAction {
    case rewindHere(String)
    case delete(Message)
    case editSummary(Message)
}

struct MessageRow: View, Equatable {
    let message: Message
    var previousUserTimestamp: Date? = nil
    var structuredPatches: [String: [StructuredPatchHunk]] = [:]
    var onAction: ((MessageRowAction) -> Void)? = nil

    private var isSummaryMessage: Bool {
        message.type == .user &&
        (message.content?.contains("This session is being continued") == true)
    }

    static func == (lhs: MessageRow, rhs: MessageRow) -> Bool {
        lhs.message.uuid == rhs.message.uuid &&
        lhs.previousUserTimestamp == rhs.previousUserTimestamp &&
        lhs.structuredPatches == rhs.structuredPatches
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if message.type == .user {
                Spacer(minLength: 60)
                userBubble
            } else {
                assistantBubble
                Spacer(minLength: 60)
            }
        }
    }

    // 共通のcontextMenu
    @ViewBuilder
    private var messageContextMenu: some View {
        Button {
            onAction?(.delete(message))
        } label: {
            Label(String(localized: "timeline.messageContext.delete"), systemImage: "trash")
        }

        Divider()

        Button {
            onAction?(.rewindHere(message.uuid))
        } label: {
            Label(String(localized: "timeline.messageContext.rewind"), systemImage: "arrow.counterclockwise")
        }
    }

    // MARK: - User Bubble (右側)

    @ViewBuilder
    private var userBubble: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if isSummaryMessage {
                summaryBubble
            } else if let content = message.content, !content.isEmpty {
                Text(verbatim: content)
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
                Text(String(localized: "timeline.summary.label"))
                    .fontWeight(.semibold)
                Spacer()
                Button {
                    onAction?(.editSummary(message))
                } label: {
                    Image(systemName: "pencil.circle")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .help(String(localized: "timeline.summary.edit"))
            }
            .foregroundStyle(.orange)

            if let content = message.content {
                Text(verbatim: content)
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
            if let thinking = message.thinking, !thinking.isEmpty {
                ThinkingBubble(thinking: thinking, duration: calculatedThinkingDuration)
            }

            if !message.toolUses.isEmpty {
                ToolUsesView(toolUses: message.toolUses, structuredPatchMap: structuredPatches)
            }

            if let content = message.content, !content.isEmpty {
                let displayModel = message.model.map(modelDisplayName)
                ResponseBubble(content: content, modelDisplayName: displayModel, timestamp: message.timestamp, contextMenu: messageContextMenu)
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

// MARK: - Thinking Bubble（折り畳み対応で巨大テキストのレンダリングコスト排除）

struct ThinkingBubble: View {
    let thinking: String
    let duration: Int
    @State private var isExpanded = false

    private var isLong: Bool { thinking.count > 500 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Text(String(localized: "timeline.thinking.label"))
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.orange)
                    Text(String(format: String(localized: "timeline.thinking.seconds"), duration))
                        .font(.caption2)
                        .foregroundStyle(.orange.opacity(0.7))
                    if isLong {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.orange.opacity(0.5))
                    }
                }
            }
            .buttonStyle(.plain)

            Text(verbatim: thinking)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(isExpanded ? nil : 6)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

// MARK: - Response Bubble（大量テキスト対応）

struct ResponseBubble<MenuContent: View>: View {
    let content: String
    let modelDisplayName: String?
    let timestamp: Date
    let contextMenu: MenuContent

    private static var collapseThreshold: Int { 800 }
    @State private var isExpanded = false

    private var isLong: Bool { content.count > Self.collapseThreshold }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(String(localized: "timeline.claude.label"))
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.purple)
                if let modelDisplayName {
                    Text(verbatim: modelDisplayName)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Text(verbatim: content)
                .font(.body)
                .textSelection(.enabled)
                .lineLimit(isExpanded || !isLong ? nil : 20)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.purple.opacity(0.1))
                .clipShape(ChatBubble(isUser: false))
                .contextMenu { contextMenu }

            HStack {
                if isLong {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
                    } label: {
                        Text(isExpanded
                             ? String(localized: "common.collapse")
                             : String(localized: "common.expand"))
                            .font(.caption)
                            .foregroundStyle(.purple)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Text(timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Tool Uses View (コンテキスト表示)

struct ToolUsesView: View {
    let toolUses: [ToolUseInfo]
    var structuredPatchMap: [String: [StructuredPatchHunk]] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "timeline.context.label"))
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.cyan)

            FlowLayout(spacing: 6) {
                ForEach(toolUses) { toolUse in
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

    private var hasEditPatch: Bool {
        toolUse.name == "Edit" && structuredPatch != nil
    }

    private var hasLongSummary: Bool {
        guard let s = toolUse.inputSummary else { return false }
        return s.count > 40 || s.contains("\n")
    }

    private var canExpand: Bool {
        hasEditPatch || hasLongSummary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
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

            if isExpanded {
                if hasEditPatch, let patch = structuredPatch {
                    StructuredPatchDiffView(
                        filePath: toolUse.filePath ?? "",
                        patch: patch
                    )
                } else if let summary = toolUse.inputSummary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(12)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(backgroundColor.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
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
        case "Agent", "Task": return "person.2.wave.2"
        case "TodoWrite": return "checklist"
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
        if let summary = toolUse.inputSummary {
            let first = summary.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .newlines).first ?? summary
            let label = String(first.prefix(40))
            return toolUse.name + ": " + label + (first.count > 40 ? "…" : "")
        }
        return toolUse.name
    }

    private var backgroundColor: Color {
        switch toolUse.name {
        case "Read": return .blue.opacity(0.15)
        case "Edit": return .orange.opacity(0.15)
        case "Write": return .green.opacity(0.15)
        case "Bash": return .purple.opacity(0.15)
        case "Agent", "Task": return .indigo.opacity(0.15)
        default: return .gray.opacity(0.15)
        }
    }

    private var foregroundColor: Color {
        switch toolUse.name {
        case "Read": return .blue
        case "Edit": return .orange
        case "Write": return .green
        case "Bash": return .purple
        case "Agent", "Task": return .indigo
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
                Text(String(format: String(localized: "timeline.update.file"), fileName))
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

    @State private var cachedLines: [DiffLine] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(cachedLines.indices, id: \.self) { i in
                let line = cachedLines[i]
                HStack(spacing: 0) {
                    Text(line.lineNumber)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, alignment: .trailing)
                    Text(" \(line.mark) ")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(line.color)
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
        .onAppear { buildDiffLines() }
    }

    private func buildDiffLines() {
        guard cachedLines.isEmpty else { return }
        var result: [DiffLine] = []
        var oldLine = hunk.oldStart
        var newLine = hunk.newStart
        result.reserveCapacity(hunk.lines.count)

        for line in hunk.lines {
            guard !line.isEmpty else { continue }
            let prefix = line.first!
            let content = String(line.dropFirst())

            switch prefix {
            case " ":
                result.append(DiffLine(lineNumber: "\(newLine)", mark: " ", content: content, type: .context))
                oldLine += 1; newLine += 1
            case "-":
                result.append(DiffLine(lineNumber: "\(oldLine)", mark: "-", content: content, type: .removed))
                oldLine += 1
            case "+":
                result.append(DiffLine(lineNumber: "\(newLine)", mark: "+", content: content, type: .added))
                newLine += 1
            default:
                result.append(DiffLine(lineNumber: "\(newLine)", mark: " ", content: line, type: .context))
                oldLine += 1; newLine += 1
            }
        }
        cachedLines = result
    }
}

// シンプルなFlowLayout
struct FlowLayout: Layout {
    struct CacheData {
        var width: CGFloat?
        var result: (size: CGSize, positions: [CGPoint]) = (.zero, [])
    }

    var spacing: CGFloat = 8

    func makeCache(subviews: Subviews) -> CacheData {
        CacheData()
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout CacheData) -> CGSize {
        let width = proposal.width
        if cache.width != width {
            cache.width = width
            cache.result = arrange(proposal: proposal, subviews: subviews)
        }
        return cache.result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout CacheData) {
        let width = proposal.width
        if cache.width != width {
            cache.width = width
            cache.result = arrange(proposal: proposal, subviews: subviews)
        }
        for (index, position) in cache.result.positions.enumerated() {
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
            Text(String(localized: "timeline.toolResult.label"))
                    .font(.caption2)
                    .fontWeight(.medium)
                if result.is_error == true {
                    Text(String(localized: "timeline.error.label"))
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
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "timeline.claude.label"))
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.purple)

                TimelineView(.periodic(from: .now, by: 0.4)) { context in
                    let ticks = Int(context.date.timeIntervalSinceReferenceDate / 0.4)
                    let dotCount = (ticks % 3) + 1
                    HStack(spacing: 0) {
                        Text(String(localized: "timeline.thinking.label"))
                        Text(String(repeating: ".", count: dotCount))
                            .frame(width: 24, alignment: .leading)
                    }
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .background(.purple.opacity(0.1))
                    .clipShape(ChatBubble(isUser: false))
                }
            }
            Spacer(minLength: 60)
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
                {"type": "thinking", "thinking": "Reviewing requirements and preparing implementation."},
                {"type": "text", "text": "Reviewed the specification and started implementation."}
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
