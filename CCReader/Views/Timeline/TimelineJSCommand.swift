import Foundation

enum TimelineJSCommand {
    case replaceMessagesFromPayload(json: String)
    case appendMessagesFromPayload(json: String)
    case replaceTimelineFromPayloads(json: String)
    case prependOlderFromPayloads(json: String)
    case setWaitingIndicator(htmlOrEmpty: String)
    case setLoadOlderBar(htmlOrEmpty: String)

    func script(escapingWith escapeForJS: (String) -> String) -> String {
        switch self {
        case .replaceMessagesFromPayload(let json):
            let escaped = escapeForJS(json)
            return """
            if (window.ccreader && typeof window.ccreader.replaceMessagesFromPayload === 'function') {
                window.ccreader.replaceMessagesFromPayload(JSON.parse('\(escaped)'));
            }
            """
        case .appendMessagesFromPayload(let json):
            let escaped = escapeForJS(json)
            return """
            if (window.ccreader && typeof window.ccreader.appendMessagesFromPayload === 'function') {
                window.ccreader.appendMessagesFromPayload(JSON.parse('\(escaped)'));
            }
            """
        case .replaceTimelineFromPayloads(let json):
            let escaped = escapeForJS(json)
            return """
            if (window.ccreader && typeof window.ccreader.replaceTimelineFromPayloads === 'function') {
                window.ccreader.replaceTimelineFromPayloads(JSON.parse('\(escaped)'));
            }
            """
        case .prependOlderFromPayloads(let json):
            let escaped = escapeForJS(json)
            return """
            if (window.ccreader && typeof window.ccreader.prependOlderFromPayloads === 'function') {
                window.ccreader.prependOlderFromPayloads(JSON.parse('\(escaped)'));
            }
            """
        case .setWaitingIndicator(let htmlOrEmpty):
            let escaped = escapeForJS(htmlOrEmpty)
            return """
            if (window.ccreader && typeof window.ccreader.setWaitingIndicator === 'function') {
                window.ccreader.setWaitingIndicator('\(escaped)');
            }
            """
        case .setLoadOlderBar(let htmlOrEmpty):
            let escaped = escapeForJS(htmlOrEmpty)
            return """
            if (window.ccreader && typeof window.ccreader.setLoadOlderBar === 'function') {
                window.ccreader.setLoadOlderBar('\(escaped)');
            }
            """
        }
    }
}
