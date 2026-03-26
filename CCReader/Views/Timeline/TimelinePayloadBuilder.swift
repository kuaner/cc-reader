import Foundation

/// Builds JS payload dictionaries from timeline messages.
/// Keep pure rendering data mapping out of `TimelineHostView.Coordinator`.
struct TimelinePayloadBuilder {
    let snapshot: TimelineRenderSnapshot
    let labels: TimelineWebLabels

    func messagePayload(for message: TimelineMessageDisplayData) -> [String: Any] {
        let presentation = TimelineMessagePresentationResolver.resolve(
            for: message,
            snapshot: snapshot,
            labels: labels
        )
        var payload: [String: Any] = [
            "uuid": message.uuid,
            "domId": message.timelineDOMId,
            "isUser": message.type == .user,
            "isSummary": presentation.isSummary,
            "timeLabel": Self.messageTimeFormatter.string(from: message.timestamp),
            "content": message.content ?? "",
            "thinking": message.thinking ?? "",
            "thinkingTitle": presentation.thinkingTitle ?? labels.thinking,
            "modelTitle": presentation.modelTitle ?? "",
            "assistantLabel": presentation.assistantLabel,
            "contextLabel": presentation.contextLabel,
            "legendLabel": presentation.legendLabel,
            "bubbleKind": presentation.bubbleKind.rawValue,
            "specialTag": presentation.specialTag ?? "",
            "summaryLabel": labels.summaryLabel,
            "legendUser": labels.legendUser,
            "legendAssistant": labels.legendAssistant,
            "legendSummary": labels.legendSummary,
            "rawData": message.rawJsonString,
            "rawDataLabel": labels.rawData,
            "metaTags": presentation.metaTags,
            "renderMode": presentation.renderMode.rawValue
        ]

        if !message.toolUses.isEmpty {
            payload["tools"] = message.toolUses.map { tool in
                let toolPresentation = TimelineToolPresentationResolver.resolve(
                    tool: tool,
                    messageId: message.uuid,
                    snapshot: snapshot
                )
                return [
                    "title": toolPresentation.title,
                    "body": toolPresentation.body ?? "",
                    "renderStyle": toolPresentation.renderStyle.rawValue
                ]
            }
        } else {
            payload["tools"] = []
        }

        return payload
    }

    private static let messageTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()
}
