import Foundation

/// Dedicated renderer for timeline message HTML.
/// Keep this logic isolated to make DOM output deterministic and testable.
struct TimelineHTMLRenderer {
    let prevTimestampMap: [String: Date]
    let rowPatchesMap: [String: [String: [StructuredPatchHunk]]]

    func renderMessage(_ message: TimelineMessageDisplayData, labels: TimelineWebLabels) -> String {
        if message.type == .user {
            return renderUserMessage(message, labels: labels)
        }
        return renderAssistantMessage(message, labels: labels)
    }

    static func messageDOMId(for messageId: String) -> String {
        "msg-\(messageId)"
    }

    private func renderUserMessage(_ message: TimelineMessageDisplayData, labels: TimelineWebLabels) -> String {
        let domId = Self.escapeHTML(Self.messageDOMId(for: message.uuid))
        let copyButton = messageRawDataButtonHTML(for: message, labels: labels)
        let time = Self.escapeHTML(Self.timeFormatter.string(from: message.timestamp))

        let bubble: String
        if isSummaryMessage(message) {
            let tag = "<span class=\"type-tag summary-tag\">\(Self.escapeHTML(labels.legendSummary))</span>"
            let footer = "<div class=\"bubble-footer\"><span>\(time)</span>\(tag)<span class=\"spacer\"></span>\(copyButton)</div>"
            bubble = "<div class=\"bubble summary\"><div class=\"summary-title\">\(Self.escapeHTML(labels.summaryLabel))</div>\(messageBodyHTML(message.content ?? ""))\(footer)</div>"
        } else {
            let tag = "<span class=\"type-tag user-tag\">\(Self.escapeHTML(labels.legendUser))</span>"
            let footer = "<div class=\"bubble-footer\"><span>\(time)</span>\(tag)<span class=\"spacer\"></span>\(copyButton)</div>"
            bubble = "<div class=\"bubble user\">\(messageBodyHTML(message.content ?? ""))\(footer)</div>"
        }

        return "<div class=\"row user\" id=\"\(domId)\"><div class=\"stack\">\(bubble)</div></div>"
    }

    private func renderAssistantMessage(_ message: TimelineMessageDisplayData, labels: TimelineWebLabels) -> String {
        var sections: [String] = []
        let domId = Self.escapeHTML(Self.messageDOMId(for: message.uuid))

        let headerTitle = Self.escapeHTML(labels.assistant)
        let model = modelTitle(message.model).map { "<span class=\"pill\">\(Self.escapeHTML($0))</span>" } ?? ""
        sections.append("<div class=\"assistant-header\"><span class=\"assistant-title\">\(headerTitle)</span>\(model)</div>")

        if let thinking = message.thinking, !thinking.isEmpty {
            let title = Self.escapeHTML(thinkingTitle(for: message) ?? labels.thinking)
            sections.append("<div class=\"card-section thinking\"><div class=\"section-title\">\(title)</div>\(messageBodyHTML(thinking))</div>")
        }

        if !message.toolUses.isEmpty {
            sections.append(renderToolUses(message, labels: labels))
        }

        if let content = message.content, !content.isEmpty {
            sections.append("<div class=\"card-section\">\(messageBodyHTML(content))</div>")
        }

        let copyButton = messageRawDataButtonHTML(for: message, labels: labels)
        let time = Self.escapeHTML(Self.timeFormatter.string(from: message.timestamp))
        let tag = "<span class=\"type-tag assistant-tag\">\(Self.escapeHTML(labels.legendAssistant))</span>"
        sections.append("<div class=\"bubble-footer\"><span>\(time)</span>\(tag)<span class=\"spacer\"></span>\(copyButton)</div>")

        return "<div class=\"row assistant\" id=\"\(domId)\"><div class=\"stack\"><div class=\"bubble assistant-card\">\(sections.joined())</div></div></div>"
    }

    private func renderToolUses(_ message: TimelineMessageDisplayData, labels: TimelineWebLabels) -> String {
        let body = message.toolUses.map { tool in
            let title = Self.escapeHTML(toolTitle(tool))
            let content = toolBody(tool: tool, messageId: message.uuid).map {
                "<pre class=\"plain-pre\">\(Self.escapeHTML($0))</pre>"
            } ?? ""
            return "<div><div class=\"section-title\">\(title)</div>\(content)</div>"
        }.joined()

        return "<div class=\"card-section tool\"><div class=\"section-title\">\(Self.escapeHTML(labels.context))</div>\(body)</div>"
    }

    private func toolBody(tool: ToolUseInfo, messageId: String) -> String? {
        if tool.name == "Edit",
           let patch = rowPatchesMap[messageId]?[tool.id],
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
        if let previous = prevTimestampMap[message.uuid] {
            duration = max(1, Int(message.timestamp.timeIntervalSince(previous)))
        } else {
            duration = 1
        }
        return String(format: L("timeline.thinking.seconds"), duration)
    }

    private func isSummaryMessage(_ message: TimelineMessageDisplayData) -> Bool {
        message.type == .user && (message.content?.contains("This session is being continued") == true)
    }

    private func messageBodyHTML(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        let fallback = Self.escapeHTML(text).replacingOccurrences(of: "\n", with: "<br>")
        let encoded = encodeBase64(text)
        return "<div class=\"markdown\" data-markdown-base64=\"\(encoded)\"><div class=\"plain-text\">\(fallback)</div></div>"
    }

    private func messageRawDataButtonHTML(for message: TimelineMessageDisplayData, labels: TimelineWebLabels) -> String {
        let dump = message.rawJsonString
        guard !dump.isEmpty else { return "" }

        let encoded = encodeBase64(dump)
        let rawLabel = Self.escapeHTML(labels.rawData)
        return "<button type=\"button\" class=\"message-copy-button\" data-message-copy-base64=\"\(encoded)\" data-copy-label=\"\(rawLabel)\">\(rawLabel)</button>"
    }

    private func encodeBase64(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
    }

    private static func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()
}

