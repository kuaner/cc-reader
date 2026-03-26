import Foundation

enum TimelineBubbleKind: String {
    case assistantDefault = "assistant_default"
    case agentDispatch = "agent_dispatch"
}

enum TimelineRenderMode: String {
    case `default` = "default"
    case toolOnly = "tool_only"
}

struct TimelineMessagePresentation {
    let bubbleKind: TimelineBubbleKind
    let isSummary: Bool
    let modelTitle: String?
    let thinkingTitle: String?
    let assistantLabel: String
    let contextLabel: String
    let legendLabel: String
    let specialTag: String?
    let renderMode: TimelineRenderMode
    let metaTags: [String]
}

/// Centralized, case-by-case presentation rules for timeline assistant messages.
/// Add new rules here instead of mixing conditional UI logic into payload building.
enum TimelineMessagePresentationResolver {
    typealias RuleMatcher = (TimelineMessageDisplayData) -> Bool
    typealias RuleFactory = (TimelineMessageDisplayData, TimelineRenderSnapshot, TimelineWebLabels) -> TimelineMessagePresentation

    struct Rule {
        let id: String
        let matches: RuleMatcher
        let make: RuleFactory
    }

    private static let agentToolNames: Set<String> = ["Agent", "Task", "Subagent"]

    static var rules: [Rule] = [
        Rule(
            id: "agent_dispatch",
            matches: { message in
                message.type == .assistant &&
                message.toolUses.contains(where: { agentToolNames.contains($0.name) })
            },
            make: { message, snapshot, labels in
                TimelineMessagePresentation(
                    bubbleKind: .agentDispatch,
                    isSummary: isSummaryMessage(message),
                    modelTitle: modelTitle(message.model),
                    thinkingTitle: thinkingTitle(for: message, snapshot: snapshot),
                    assistantLabel: labels.assistant,
                    contextLabel: labels.context,
                    legendLabel: "Agent Dispatch",
                    specialTag: nil,
                    renderMode: renderMode(for: message),
                    metaTags: buildMetaTags(for: message)
                )
            }
        )
    ]

    static func resolve(
        for message: TimelineMessageDisplayData,
        snapshot: TimelineRenderSnapshot,
        labels: TimelineWebLabels
    ) -> TimelineMessagePresentation {
        for rule in rules where rule.matches(message) {
            return rule.make(message, snapshot, labels)
        }
        return TimelineMessagePresentation(
            bubbleKind: .assistantDefault,
            isSummary: isSummaryMessage(message),
            modelTitle: modelTitle(message.model),
            thinkingTitle: thinkingTitle(for: message, snapshot: snapshot),
            assistantLabel: labels.assistant,
            contextLabel: labels.context,
            legendLabel: message.type == .user ? labels.legendUser : labels.legendAssistant,
            specialTag: nil,
            renderMode: renderMode(for: message),
            metaTags: buildMetaTags(for: message)
        )
    }

    private static func renderMode(for message: TimelineMessageDisplayData) -> TimelineRenderMode {
        let hasTool = !message.toolUses.isEmpty
        let hasThinking = (message.thinking?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        let hasContent = (message.content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        if message.type == .assistant, hasTool, !hasThinking, !hasContent {
            return .toolOnly
        }
        return .default
    }

    private static func buildMetaTags(for message: TimelineMessageDisplayData) -> [String] {
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

    private static func isSummaryMessage(_ message: TimelineMessageDisplayData) -> Bool {
        message.type == .user && (message.content?.contains("This session is being continued") == true)
    }

    private static func modelTitle(_ model: String?) -> String? {
        guard let model, !model.isEmpty else { return nil }
        if model.contains("opus") { return "Opus" }
        if model.contains("sonnet") { return "Sonnet" }
        if model.contains("haiku") { return "Haiku" }
        return model
    }

    private static func thinkingTitle(
        for message: TimelineMessageDisplayData,
        snapshot: TimelineRenderSnapshot
    ) -> String? {
        guard message.thinking?.isEmpty == false else { return nil }
        let duration: Int
        if let previous = snapshot.prevTimestampMap[message.uuid] {
            duration = max(1, Int(message.timestamp.timeIntervalSince(previous)))
        } else {
            duration = 1
        }
        return String(format: L("timeline.thinking.seconds"), duration)
    }
}
