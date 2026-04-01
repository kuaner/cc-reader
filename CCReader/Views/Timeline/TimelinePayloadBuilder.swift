import Foundation

/// Builds JS payload dictionaries directly from Message.
/// This is the single translation layer: Message → JS payload for timeline-shell.js.
struct TimelinePayloadBuilder {
    let prevTimestampMap: [String: Date]
    let rowPatchesMap: [String: [String: [StructuredPatchHunk]]]
    let labels: TimelineWebLabels

    init(snapshot: TimelineRenderSnapshot, labels: TimelineWebLabels) {
        self.prevTimestampMap = snapshot.prevTimestampMap
        self.rowPatchesMap = snapshot.rowPatchesMap
        self.labels = labels
    }

    // MARK: - Message → JS payload

    func messagePayload(for message: Message) -> [String: Any] {
        message.preload()

        let isUser = message.type == .user
        let content = message.content ?? ""
        let thinking = message.thinking ?? ""
        let model = message.model
        let toolUses = message.toolUses
        let rawJsonString = String(data: message.rawJson, encoding: .utf8) ?? ""

        let bubbleKind = Self.resolveBubbleKind(toolUses: toolUses)
        let renderMode = Self.resolveRenderMode(message: message, toolUses: toolUses)
        let isSummary = isUser && content.contains("This session is being continued")

        let toolPayloads = toolUses.map { tool in
            [
                "title": Self.toolTitle(tool: tool),
                "body": Self.toolBody(tool: tool, messageId: message.uuid, rowPatchesMap: rowPatchesMap) ?? "",
                "renderStyle": Self.agentToolNames.contains(tool.name) ? "markdown" : "code"
            ]
        }

        let payload: [String: Any] = [
            "uuid": message.uuid,
            "domId": "msg-\(message.uuid)",
            "isUser": isUser,
            "isSummary": isSummary,
            "timeLabel": Self.messageTimeFormatter.string(from: message.timestamp),
            "content": content,
            "thinking": thinking,
            "thinkingTitle": thinking.isEmpty ? "" : thinkingTitle(for: message, prevTimestampMap: prevTimestampMap),
            "modelTitle": model.map { Self.shortModelTitle($0) } ?? "",
            "assistantLabel": labels.assistant,
            "contextLabel": labels.context,
            "legendLabel": isUser ? labels.legendUser : labels.legendAssistant,
            "bubbleKind": bubbleKind,
            "specialTag": "",
            "summaryLabel": labels.summaryLabel,
            "legendUser": labels.legendUser,
            "legendAssistant": labels.legendAssistant,
            "legendSummary": labels.legendSummary,
            "rawData": rawJsonString,
            "rawDataLabel": labels.rawData,
            "metaTags": Self.buildMetaTags(message: message),
            "renderMode": renderMode,
            "resultImages": message.toolResultImages.map {
                ["mediaType": $0.mediaType, "base64": $0.base64]
            },
            "tools": toolPayloads
        ]

        return payload
    }

    // MARK: - Bubble / Render resolution

    private static func resolveBubbleKind(toolUses: [ToolUseInfo]) -> String {
        let hasAgentTool = toolUses.contains { agentToolNames.contains($0.name) }
        return hasAgentTool ? "agent_dispatch" : "assistant_default"
    }

    private static func resolveRenderMode(message: Message, toolUses: [ToolUseInfo]) -> String {
        let hasTool = !toolUses.isEmpty
        let hasThinking = !(message.thinking ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasContent = !(message.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if message.type == .assistant, hasTool, !hasThinking, !hasContent {
            return "tool_only"
        }
        return "default"
    }

    private static let agentToolNames: Set<String> = ["Agent", "Task", "Subagent"]

    // MARK: - Thinking title

    private func thinkingTitle(for message: Message, prevTimestampMap: [String: Date]) -> String {
        let template = labels.thinking
        guard !(message.thinking ?? "").isEmpty else { return template }
        let duration: Int
        if let previous = prevTimestampMap[message.uuid] {
            duration = max(1, Int(message.timestamp.timeIntervalSince(previous)))
        } else {
            duration = 1
        }
        return String(format: template, duration)
    }

    // MARK: - Meta tags

    private static func buildMetaTags(message: Message) -> [String] {
        var tags: [String] = []
        var seen = Set<String>()

        func append(_ value: String?) {
            guard let value else { return }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let normalized = trimmed.lowercased()
            guard seen.insert(normalized).inserted else { return }
            tags.append(trimmed)
        }

        append(message.entryType)
        append(message.role)
        for type in message.blockTypes {
            append(type)
        }
        return tags
    }

    // MARK: - Tool title / body

    private static func toolTitle(tool: ToolUseInfo) -> String {
        if agentToolNames.contains(tool.name) {
            return "\(tool.name) Prompt"
        }
        if tool.name == "Bash", let summary = tool.inputSummary, !summary.isEmpty {
            return "Bash: " + String(summary.prefix(40))
        }
        if let path = tool.filePath, !path.isEmpty {
            return (path as NSString).lastPathComponent
        }
        if let command = tool.command, !command.isEmpty {
            let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
            let prefix = String(trimmed.prefix(20))
            return trimmed.count > 20 ? prefix + "..." : prefix
        }
        if let summary = tool.inputSummary, !summary.isEmpty {
            return tool.name + ": " + String(summary.prefix(32))
        }
        return tool.name
    }

    private static func toolBody(tool: ToolUseInfo, messageId: String, rowPatchesMap: [String: [String: [StructuredPatchHunk]]]) -> String? {
        // Edit tool: show structured diff
        if tool.name == "Edit",
           let patch = rowPatchesMap[messageId]?[tool.id],
           !patch.isEmpty {
            let header = tool.filePath ?? toolTitle(tool: tool)
            return ([header] + patch.flatMap(\.lines)).joined(separator: "\n")
        }

        // Agent tools: show prompt
        if agentToolNames.contains(tool.name),
           let prompt = tool.prompt, !prompt.isEmpty {
            return prompt
        }

        if let command = tool.command, !command.isEmpty { return command }
        if let oldString = tool.oldString, let newString = tool.newString {
            return "<<<\n\(oldString)\n===\n\(newString)\n>>>"
        }
        if let oldString = tool.oldString, !oldString.isEmpty { return oldString }
        if let newString = tool.newString, !newString.isEmpty { return newString }
        if let summary = tool.inputSummary, !summary.isEmpty { return summary }
        if let path = tool.filePath, !path.isEmpty { return path }
        if let raw = tool.rawInput, !raw.isEmpty { return raw }
        return nil
    }

    // MARK: - Model title

    private static func shortModelTitle(_ model: String) -> String {
        if model.contains("opus") { return "Opus" }
        if model.contains("sonnet") { return "Sonnet" }
        if model.contains("haiku") { return "Haiku" }
        return model
    }

    // MARK: - Formatter

    private static let messageTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()
}
