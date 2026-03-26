import Foundation

/// Builds JS payload dictionaries from timeline messages.
/// Keep pure rendering data mapping out of `TimelineHostView.Coordinator`.
struct TimelinePayloadBuilder {
    let snapshot: TimelineRenderSnapshot
    let labels: TimelineWebLabels

    func messagePayload(for message: TimelineMessageDisplayData) -> [String: Any] {
        var payload: [String: Any] = [
            "uuid": message.uuid,
            "domId": message.timelineDOMId,
            "isUser": message.type == .user,
            "isSummary": isSummaryMessage(message),
            "timeLabel": Self.messageTimeFormatter.string(from: message.timestamp),
            "content": message.content ?? "",
            "thinking": message.thinking ?? "",
            "thinkingTitle": thinkingTitle(for: message) ?? labels.thinking,
            "modelTitle": modelTitle(message.model) ?? "",
            "assistantLabel": labels.assistant,
            "contextLabel": labels.context,
            "summaryLabel": labels.summaryLabel,
            "legendUser": labels.legendUser,
            "legendAssistant": labels.legendAssistant,
            "legendSummary": labels.legendSummary,
            "rawData": message.rawJsonString,
            "rawDataLabel": labels.rawData
        ]

        if !message.toolUses.isEmpty {
            payload["tools"] = message.toolUses.map { tool in
                [
                    "title": toolTitle(tool),
                    "body": toolBody(tool: tool, messageId: message.uuid) ?? ""
                ]
            }
        } else {
            payload["tools"] = []
        }

        return payload
    }

    private func isSummaryMessage(_ message: TimelineMessageDisplayData) -> Bool {
        message.type == .user && (message.content?.contains("This session is being continued") == true)
    }

    private func modelTitle(_ model: String?) -> String? {
        guard let model, !model.isEmpty else { return nil }
        if model.contains("opus") { return "Opus" }
        if model.contains("sonnet") { return "Sonnet" }
        if model.contains("haiku") { return "Haiku" }
        return model
    }

    private func thinkingTitle(for message: TimelineMessageDisplayData) -> String? {
        guard message.thinking?.isEmpty == false else { return nil }
        let duration: Int
        if let previous = snapshot.prevTimestampMap[message.uuid] {
            duration = max(1, Int(message.timestamp.timeIntervalSince(previous)))
        } else {
            duration = 1
        }
        return String(format: L("timeline.thinking.seconds"), duration)
    }

    private func toolTitle(_ tool: ToolUseInfo) -> String {
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

    private func toolBody(tool: ToolUseInfo, messageId: String) -> String? {
        if tool.name == "Edit",
           let patch = snapshot.rowPatchesMap[messageId]?[tool.id],
           !patch.isEmpty {
            let header = tool.filePath ?? toolTitle(tool)
            return ([header] + patch.flatMap(\.lines)).joined(separator: "\n")
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

    private static let messageTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()
}
