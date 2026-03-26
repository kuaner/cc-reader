import AppKit
import Foundation
import SwiftUI
import WebKit

struct TimelineHostView: NSViewRepresentable, Equatable {
    let sessionId: String
    let snapshot: TimelineRenderSnapshot

    static func == (lhs: TimelineHostView, rhs: TimelineHostView) -> Bool {
        lhs.sessionId == rhs.sessionId &&
        lhs.snapshot.generation == rhs.snapshot.generation
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "ccreader")
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        context.coordinator.attach(to: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.apply(sessionId: sessionId, snapshot: snapshot)
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "ccreader")
        nsView.navigationDelegate = nil
    }

    // MARK: - Coordinator (incremental DOM)

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        /// Max logical messages in the WK slice: initially the **last N** of the session; each “load older” prepends up to **N** older rows.
        /// (Scroll distance to the top bar is unrelated — that bar appears when there are older rows not yet in the window.)
        private static let renderBatchSize = TimelineRenderTuning.renderBatchSize
        private static let followBottomThreshold = TimelineRenderTuning.followBottomThreshold
        private static let progressiveReplaceThreshold = TimelineRenderTuning.progressiveReplaceThreshold
        private static let progressiveInitialLatestCount = TimelineRenderTuning.progressiveInitialLatestCount
        private static let progressivePrependChunkSize = TimelineRenderTuning.progressivePrependChunkSize

        private weak var webView: WKWebView?
        private var currentSessionId = ""
        private var snapshot = TimelineRenderSnapshot()

        // Incremental state — tracks exactly what the DOM contains.
        private enum ShellState { case notLoaded, loading, loaded }
        private var shellState: ShellState = .notLoaded
        private var renderedMessageUUIDs: [String] = []       // Ordered list of UUIDs in DOM
        private var renderedMessageSet: Set<String> = []       // Fast lookup
        private var renderedFingerprints: [String: Int] = [:]  // UUID → rawFingerprint for change detection
        private var hasWaitingIndicator = false
        private var hasOlderIndicator = false

        // Window range
        private var renderedMessageRange: Range<Int> = 0..<0
        private var previousVisibleMessageCount = 0

        // Scroll state — reported by JavaScript
        private var isFollowingBottom = true

        /// True after a suffix-only snapshot (`tailStartIndex > 0`); next full snapshot must replace DOM, not incremental-append.
        private var hadTailOnlySnapshot = false

        func attach(to webView: WKWebView) {
            self.webView = webView
        }

        // MARK: - WKScriptMessageHandler

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            let action = body["action"] as? String ?? ""

            switch action {
            case "scrollState":
                isFollowingBottom = (body["following"] as? Bool) ?? true
            case "loadOlder":
                loadOlderMessages()
            default:
                break
            }
        }

        // MARK: - Main entry point

        func apply(sessionId: String, snapshot: TimelineRenderSnapshot) {
            let sessionChanged = currentSessionId != sessionId
            // New SessionMessagesView starts with an empty bootstrap snapshot.
            // If we switch DOM immediately, timeline flashes blank until query data arrives.
            if sessionChanged && isBootstrapSnapshot(snapshot) {
                return
            }
            if sessionChanged {
                resetState(for: sessionId)
            }

            self.snapshot = snapshot
            updateRenderedRangeIfNeeded()

            switch shellState {
            case .notLoaded:
                loadShellAndRenderInitial()
            case .loading:
                // Page still loading; snapshot is stored — didFinish will
                // call incrementalUpdate() to pick up accumulated changes.
                break
            case .loaded:
                if sessionChanged {
                    replaceTimelineForSession()
                    hadTailOnlySnapshot = snapshot.tailStartIndex > 0
                } else if hadTailOnlySnapshot, snapshot.tailStartIndex == 0 {
                    hadTailOnlySnapshot = false
                    replaceTimelineForSession()
                } else {
                    incrementalUpdate()
                }
            }
        }

        // MARK: - Shell loading (one-time per session)

        private func loadShellAndRenderInitial() {
            guard let webView else { return }

            let messages = currentRenderedMessages()
            let labels = TimelineWebLabels.localized()

            // Track initial state (DOM filled in `didFinish` via payload → JS, same path as session replace).
            renderedMessageUUIDs = messages.map(\.uuid)
            renderedMessageSet = Set(renderedMessageUUIDs)
            renderedFingerprints = Dictionary(uniqueKeysWithValues: messages.map { ($0.uuid, $0.rawFingerprint) })
            hasWaitingIndicator = snapshot.visibleMessages.last?.type == .user
            hasOlderIndicator = renderedMessageRange.lowerBound > 0

            let document = makeShellHTML(
                messageHTML: "",
                loadOlderHTML: "",
                waitingHTML: "",
                labels: labels
            )

            shellState = .loading
            webView.loadHTMLString(document, baseURL: nil)
        }

        // MARK: - Incremental update (no page reload!)

        private func incrementalUpdate() {
            let labels = TimelineWebLabels.localized()
            let payloadBuilder = TimelinePayloadBuilder(snapshot: snapshot, labels: labels)
            let windowMessages = currentRenderedMessages()

            // 1. Find new messages to append at the bottom.
            var newMessages: [TimelineMessageDisplayData] = []
            for msg in windowMessages {
                if !renderedMessageSet.contains(msg.uuid) {
                    newMessages.append(msg)
                }
            }

            // 2. Find messages whose content changed (e.g. streaming updates).
            var updatedMessages: [TimelineMessageDisplayData] = []
            for msg in windowMessages {
                if let oldFP = renderedFingerprints[msg.uuid], oldFP != msg.rawFingerprint {
                    updatedMessages.append(msg)
                }
            }

            // 3. Update waiting indicator.
            let shouldShowWaiting = snapshot.visibleMessages.last?.type == .user
            let waitingChanged = shouldShowWaiting != hasWaitingIndicator

            // 4. Update "load older" indicator.
            let shouldShowOlder = renderedMessageRange.lowerBound > 0
            let olderChanged = shouldShowOlder != hasOlderIndicator

            // No changes — skip.
            if newMessages.isEmpty && updatedMessages.isEmpty && !waitingChanged && !olderChanged {
                return
            }

            var commands: [TimelineJSCommand] = []

            // Handle updated messages (replace in-place).
            var updatedPayloads: [[String: Any]] = []
            for msg in updatedMessages {
                updatedPayloads.append(payloadBuilder.messagePayload(for: msg))
                renderedFingerprints[msg.uuid] = msg.rawFingerprint
            }
            if !updatedPayloads.isEmpty, let payloadJSON = toJSONString(updatedPayloads) {
                commands.append(.replaceMessagesFromPayload(json: payloadJSON))
            }

            // Handle new messages (append to timeline).
            if !newMessages.isEmpty {
                let payloads = newMessages.map { payloadBuilder.messagePayload(for: $0) }
                if let payloadJSON = toJSONString(payloads) {
                    commands.append(.appendMessagesFromPayload(json: payloadJSON))
                }

                for msg in newMessages {
                    renderedMessageUUIDs.append(msg.uuid)
                    renderedMessageSet.insert(msg.uuid)
                    renderedFingerprints[msg.uuid] = msg.rawFingerprint
                }
            }

            // Handle waiting indicator changes.
            if waitingChanged {
                if shouldShowWaiting {
                    commands.append(.setWaitingIndicator(htmlOrEmpty: waitingIndicatorHTML(labels: labels)))
                } else {
                    commands.append(.setWaitingIndicator(htmlOrEmpty: ""))
                }
                hasWaitingIndicator = shouldShowWaiting
            }

            // Handle "load older" indicator changes.
            if olderChanged {
                if shouldShowOlder && !hasOlderIndicator {
                    commands.append(.setLoadOlderBar(htmlOrEmpty: loadOlderBarHTML(labels: labels)))
                } else if !shouldShowOlder && hasOlderIndicator {
                    commands.append(.setLoadOlderBar(htmlOrEmpty: ""))
                }
                hasOlderIndicator = shouldShowOlder
            }

            evaluate(commands: commands, errorPrefix: "[TimelineHostView] incremental JS error")
        }

        // MARK: - Session switch without full web reload

        /// Replace the `.timeline` DOM in-place when the shell has already been loaded.
        /// This avoids a visible blank caused by reloading the whole WKWebView.
        private func replaceTimelineForSession() {
            replaceTimelineContentViaPayloads(updatingCoordinatorState: true)
        }

        /// Renders the current window from `messagePayload` + chrome HTML in JS. Used on first shell load (`didFinish`) and session switch.
        private func replaceTimelineContentViaPayloads(updatingCoordinatorState: Bool) {
            let labels = TimelineWebLabels.localized()
            let payloadBuilder = TimelinePayloadBuilder(snapshot: snapshot, labels: labels)
            let messages = currentRenderedMessages()
            let hasOlder = renderedMessageRange.lowerBound > 0
            let waiting = snapshot.visibleMessages.last?.type == .user

            let loadOlderHTML = hasOlder ? loadOlderBarHTML(labels: labels) : ""
            let waitingHTML = waiting ? waitingIndicatorHTML(labels: labels) : ""

            let envelope: [String: Any] = [
                "messages": messages.map { payloadBuilder.messagePayload(for: $0) },
                "loadOlderBarHTML": loadOlderHTML,
                "waitingHTML": waitingHTML,
                "initialLatestCount": Self.progressiveInitialLatestCount,
                "prependChunkSize": Self.progressivePrependChunkSize
            ]
            guard let payloadJSON = toJSONString(envelope) else { return }

            if updatingCoordinatorState {
                renderedMessageUUIDs = messages.map(\.uuid)
                renderedMessageSet = Set(renderedMessageUUIDs)
                renderedFingerprints = Dictionary(uniqueKeysWithValues: messages.map { ($0.uuid, $0.rawFingerprint) })
                hasWaitingIndicator = waiting
                hasOlderIndicator = hasOlder
                isFollowingBottom = true
            }

            let replaceCommand: TimelineJSCommand = messages.count >= Self.progressiveReplaceThreshold
                ? .replaceTimelineFromPayloadsProgressive(json: payloadJSON)
                : .replaceTimelineFromPayloads(json: payloadJSON)
            evaluate(commands: [replaceCommand], errorPrefix: "[TimelineHostView] replaceTimelineFromPayloads JS error")
        }

        // MARK: - Load older (prepend with scroll preservation)

        private func loadOlderMessages() {
            guard renderedMessageRange.lowerBound > 0 else { return }
            let labels = TimelineWebLabels.localized()
            let payloadBuilder = TimelinePayloadBuilder(snapshot: snapshot, labels: labels)

            let oldLower = renderedMessageRange.lowerBound
            let newLower = max(0, oldLower - Self.renderBatchSize)
            renderedMessageRange = newLower..<renderedMessageRange.upperBound

            let totalMessages = snapshot.visibleMessages
            let olderMessages = Array(totalMessages[newLower..<oldLower])
            guard !olderMessages.isEmpty else { return }

            let shouldRemoveOlderBar = newLower == 0

            let envelope: [String: Any] = [
                "messages": olderMessages.map { payloadBuilder.messagePayload(for: $0) },
                "removeOlderBar": shouldRemoveOlderBar
            ]
            guard let payloadJSON = toJSONString(envelope) else { return }
            
            if shouldRemoveOlderBar {
                hasOlderIndicator = false
            }

            isFollowingBottom = false

            let olderUUIDs = olderMessages.map(\.uuid)
            renderedMessageUUIDs = olderUUIDs + renderedMessageUUIDs
            renderedMessageSet.formUnion(olderUUIDs)
            for msg in olderMessages {
                renderedFingerprints[msg.uuid] = msg.rawFingerprint
            }

            previousVisibleMessageCount = snapshot.visibleMessages.count

            evaluate(commands: [.prependOlderFromPayloads(json: payloadJSON)], errorPrefix: "[TimelineHostView] prepend JS error")
        }

        private func toJSONString(_ value: Any) -> String? {
            guard JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(withJSONObject: value, options: []),
                  let json = String(data: data, encoding: .utf8) else {
                return nil
            }
            return json
        }

        private func loadOlderBarHTML(labels: TimelineWebLabels) -> String {
            "<div id=\"load-older-bar\" class=\"topbar\"><a class=\"pill\" onclick=\"window.webkit.messageHandlers.ccreader.postMessage({action:'loadOlder'})\">\(escapeHTML(labels.loadOlder))</a></div>"
        }

        private func waitingIndicatorHTML(labels: TimelineWebLabels) -> String {
            "<div id=\"waiting-indicator\" class=\"row assistant\"><div class=\"stack\"><div class=\"bubble assistant\">\(escapeHTML(labels.waiting))</div></div></div>"
        }

        private func evaluate(commands: [TimelineJSCommand], errorPrefix: String) {
            guard !commands.isEmpty, let webView else { return }
            let commandScript = commands
                .map { $0.script(escapingWith: escapeForJS) }
                .joined(separator: "\n")
            let js = "(function(){\n\(commandScript)\n})();"
            webView.evaluateJavaScript(js) { _, error in
                if let error { print("\(errorPrefix): \(error)") }
            }
        }

        // MARK: - Navigation delegate

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard shellState == .loading else { return }
            shellState = .loaded
            // Shell HTML loads with an empty `.timeline`; fill it with the same payload path as session replace.
            replaceTimelineContentViaPayloads(updatingCoordinatorState: false)
            // Pick up any snapshot drift while the shell was loading.
            incrementalUpdate()
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            if ["http", "https"].contains(url.scheme?.lowercased()) {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.allow)
        }

        // MARK: - State management

        private func resetState(for sessionId: String) {
            currentSessionId = sessionId
            snapshot = TimelineRenderSnapshot()
            renderedMessageRange = 0..<0
            previousVisibleMessageCount = 0
            // Preserve current shell lifecycle state:
            // - loaded: keep incremental path (no blank reload)
            // - loading: keep waiting for current navigation `didFinish`
            // - notLoaded: still requires initial load
            //
            // Resetting `.loading` -> `.notLoaded` causes an extra empty-shell reload
            // during fast session switches, which can present as a visible blank.
            switch shellState {
            case .loaded, .loading:
                break
            case .notLoaded:
                shellState = .notLoaded
            }
            isFollowingBottom = true
            renderedMessageUUIDs = []
            renderedMessageSet = []
            renderedFingerprints = [:]
            hasWaitingIndicator = false
            hasOlderIndicator = false
            hadTailOnlySnapshot = false
        }

        private func updateRenderedRangeIfNeeded() {
            let totalCount = snapshot.effectiveVisibleCount
            guard totalCount > 0 else {
                renderedMessageRange = 0..<0
                previousVisibleMessageCount = 0
                return
            }

            if renderedMessageRange.isEmpty {
                let lowerBound = max(0, totalCount - Self.renderBatchSize)
                renderedMessageRange = lowerBound..<totalCount
                previousVisibleMessageCount = totalCount
                return
            }

            if totalCount > previousVisibleMessageCount,
               renderedMessageRange.upperBound == previousVisibleMessageCount {
                // New messages appended — expand window to include them.
                renderedMessageRange = renderedMessageRange.lowerBound..<totalCount
                previousVisibleMessageCount = totalCount
                return
            }

            if renderedMessageRange.upperBound <= totalCount,
               renderedMessageRange.lowerBound >= 0,
               renderedMessageRange.lowerBound < renderedMessageRange.upperBound {
                previousVisibleMessageCount = totalCount
                return
            }

            let lowerBound = max(0, totalCount - Self.renderBatchSize)
            renderedMessageRange = lowerBound..<totalCount
            previousVisibleMessageCount = totalCount
        }

        private func currentRenderedMessages() -> [TimelineMessageDisplayData] {
            let rows = snapshot.visibleMessages
            let totalCount = snapshot.effectiveVisibleCount
            guard totalCount > 0, !rows.isEmpty else { return [] }

            let gLow = min(max(renderedMessageRange.lowerBound, 0), totalCount)
            let gHigh = min(max(renderedMessageRange.upperBound, gLow), totalCount)

            if snapshot.tailStartIndex == 0 {
                let l = min(max(gLow, 0), rows.count)
                let u = min(max(gHigh, l), rows.count)
                return Array(rows[l..<u])
            }

            let tailStart = snapshot.tailStartIndex
            let overlapLow = max(gLow, tailStart)
            let overlapHigh = min(gHigh, totalCount)
            if overlapLow >= overlapHigh { return [] }

            let localLow = overlapLow - tailStart
            let localHigh = overlapHigh - tailStart
            let l = min(max(localLow, 0), rows.count)
            let u = min(max(localHigh, l), rows.count)
            return Array(rows[l..<u])
        }

        private func isBootstrapSnapshot(_ snapshot: TimelineRenderSnapshot) -> Bool {
            snapshot.generation == 0 &&
            snapshot.visibleMessages.isEmpty &&
            snapshot.prevTimestampMap.isEmpty
        }

        // MARK: - Shell HTML (loaded once per session)

        private func makeShellHTML(messageHTML: String, loadOlderHTML: String, waitingHTML: String, labels: TimelineWebLabels) -> String {
            let highlightStyles = HighlightThemeLoader.stylesheet
            let codeBlockStyles = WebRenderChrome.codeBlockStylesheet
            let messageActionStyles = WebRenderChrome.messageActionStylesheet
            let markedJS = MarkedJavaScriptLoader.script
            let highlightJS = HighlightJavaScriptLoader.script
            let codeBlockScript = WebRenderChrome.codeBlockEnhancementScript(copyLabel: labels.copy, copiedLabel: labels.copied)
            let messageCopyScript = WebRenderChrome.messageCopyEnhancementScript(copiedLabel: labels.copied)
            let shellCSS = WebRenderResourceLoader.text(named: "timeline-shell", extension: "css")
            let shellJS = WebRenderResourceLoader.text(named: "timeline-shell", extension: "js")
                .replacingOccurrences(of: "__FOLLOW_BOTTOM_THRESHOLD__", with: "\(Int(Self.followBottomThreshold))")

            return """
            <!DOCTYPE html>
            <html>
            <head>
              <meta charset="utf-8" />
              <meta name="viewport" content="width=device-width, initial-scale=1" />
              <style>
                \(shellCSS)
                \(codeBlockStyles)
                \(messageActionStyles)
                \(highlightStyles)
              </style>
            </head>
            <body>
              <div class="timeline">\(loadOlderHTML)\(messageHTML)\(waitingHTML)</div>
              <script>
                \(markedJS)
                \(highlightJS)
                \(codeBlockScript)
                \(messageCopyScript)

                \(shellJS)
              </script>
            </body>
            </html>
            """
        }

        private func escapeHTML(_ text: String) -> String {
            text
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "'", with: "&#39;")
        }

        private func escapeForJS(_ text: String) -> String {
            text
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "")
                // U+2028/U+2029 are valid JS line separators even inside strings and can break evaluateJavaScript.
                .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
                .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        }
    }
}

struct TimelineWebLabels {
    let summaryLabel: String
    let context: String
    let assistant: String
    let thinking: String
    let waiting: String
    let loadOlder: String
    let copy: String
    let rawData: String
    let copied: String
    let legendUser: String
    let legendAssistant: String
    let legendThinking: String
    let legendTool: String
    let legendSummary: String

    static func localized() -> TimelineWebLabels {
        TimelineWebLabels(
            summaryLabel: L("timeline.summary.label"),
            context: L("timeline.context.label"),
            assistant: L("timeline.claude.label"),
            thinking: L("timeline.thinking.label"),
            waiting: L("timeline.thinking.label") + "...",
            loadOlder: L("timeline.loadOlder"),
            copy: L("timeline.message.copy"),
            rawData: L("timeline.message.rawdata"),
            copied: L("timeline.message.copied"),
            legendUser: L("timeline.legend.user"),
            legendAssistant: L("timeline.legend.assistant"),
            legendThinking: L("timeline.legend.thinking"),
            legendTool: L("timeline.legend.tool"),
            legendSummary: L("timeline.legend.summary")
        )
    }
}
