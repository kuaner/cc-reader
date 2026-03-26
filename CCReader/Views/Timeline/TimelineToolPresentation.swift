import Foundation

enum TimelineToolRenderStyle: String {
    case markdown
    case code
}

struct TimelineToolPresentation {
    let title: String
    let body: String?
    let renderStyle: TimelineToolRenderStyle
}

enum TimelineToolPresentationResolver {
    private static let agentToolNames: Set<String> = ["Agent", "Task", "Subagent"]

    static func resolve(
        tool: ToolUseInfo,
        messageId: String,
        snapshot: TimelineRenderSnapshot
    ) -> TimelineToolPresentation {
        let title = makeTitle(tool)
        let body = makeBody(tool: tool, messageId: messageId, snapshot: snapshot, title: title)
        let renderStyle: TimelineToolRenderStyle = agentToolNames.contains(tool.name) ? .markdown : .code
        return TimelineToolPresentation(title: title, body: body, renderStyle: renderStyle)
    }

    private static func makeTitle(_ tool: ToolUseInfo) -> String {
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

    private static func makeBody(
        tool: ToolUseInfo,
        messageId: String,
        snapshot: TimelineRenderSnapshot,
        title: String
    ) -> String? {
        if tool.name == "Edit",
           let patch = snapshot.rowPatchesMap[messageId]?[tool.id],
           !patch.isEmpty {
            let header = tool.filePath ?? title
            return ([header] + patch.flatMap(\.lines)).joined(separator: "\n")
        }

        if agentToolNames.contains(tool.name),
           let prompt = tool.prompt,
           !prompt.isEmpty {
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
}
