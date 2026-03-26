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
        private static let renderBatchSize = 200
        private static let followBottomThreshold: CGFloat = 96

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
            let hasOlder = renderedMessageRange.lowerBound > 0
            let waiting = snapshot.visibleMessages.last?.type == .user
            let renderer = TimelineHTMLRenderer(prevTimestampMap: snapshot.prevTimestampMap, rowPatchesMap: snapshot.rowPatchesMap)
            let messageHTML = messages.map { renderer.renderMessage($0, labels: labels) }.joined(separator: "\n")
            let loadOlderHTML = hasOlder ? "<div id=\"load-older-bar\" class=\"topbar\"><a class=\"pill\" onclick=\"window.webkit.messageHandlers.ccreader.postMessage({action:'loadOlder'})\">\(escapeHTML(labels.loadOlder))</a></div>" : ""
            let waitingHTML = waiting ? "<div id=\"waiting-indicator\" class=\"row assistant\"><div class=\"stack\"><div class=\"bubble assistant\">\(escapeHTML(labels.waiting))</div></div></div>" : ""

            // Track initial state
            renderedMessageUUIDs = messages.map(\.uuid)
            renderedMessageSet = Set(renderedMessageUUIDs)
            renderedFingerprints = Dictionary(uniqueKeysWithValues: messages.map { ($0.uuid, $0.rawFingerprint) })
            hasWaitingIndicator = waiting
            hasOlderIndicator = hasOlder

            let document = makeShellHTML(
                messageHTML: messageHTML,
                loadOlderHTML: loadOlderHTML,
                waitingHTML: waitingHTML,
                labels: labels
            )

            shellState = .loading
            webView.loadHTMLString(document, baseURL: nil)
        }

        // MARK: - Incremental update (no page reload!)

        private func incrementalUpdate() {
            guard let webView else { return }
            let labels = TimelineWebLabels.localized()
            let windowMessages = currentRenderedMessages()
            let renderer = TimelineHTMLRenderer(prevTimestampMap: snapshot.prevTimestampMap, rowPatchesMap: snapshot.rowPatchesMap)

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

            var js = ""

            // Handle updated messages (replace in-place).
            for msg in updatedMessages {
                let html = renderer.renderMessage(msg, labels: labels)
                let escaped = escapeForJS(html)
                let domId = escapeForJS(TimelineHTMLRenderer.messageDOMId(for: msg.uuid))
                js += """
                (function() {
                    var existing = document.getElementById('\(domId)');
                    if (existing) {
                        var temp = document.createElement('div');
                        temp.innerHTML = '\(escaped)';
                        var newNode = temp.firstElementChild;
                        if (newNode) {
                            existing.replaceWith(newNode);
                            renderMarkdownIn(newNode);
                            highlightCodeBlocksIn(newNode);
                            enhanceCodeBlocks(newNode);
                            enhanceMessageCopyButtons(newNode);
                        }
                    }
                })();
                """
                renderedFingerprints[msg.uuid] = msg.rawFingerprint
            }

            // Handle new messages (append to timeline).
            if !newMessages.isEmpty {
                let html = newMessages.map { renderer.renderMessage($0, labels: labels) }.joined(separator: "\n")
                let escaped = escapeForJS(html)

                js += """
                (function() {
                    var timeline = document.querySelector('.timeline');
                    var waiting = document.getElementById('waiting-indicator');
                    var wasAtBottom = isNearBottom();
                    var temp = document.createElement('div');
                    temp.innerHTML = '\(escaped)';
                    var inserted = [];
                    while (temp.firstElementChild) {
                        var node = temp.firstElementChild;
                        if (waiting) {
                            timeline.insertBefore(node, waiting);
                        } else {
                            timeline.appendChild(node);
                        }
                        inserted.push(node);
                    }
                    for (var i = 0; i < inserted.length; i++) {
                        renderMarkdownIn(inserted[i]);
                        highlightCodeBlocksIn(inserted[i]);
                        enhanceCodeBlocks(inserted[i]);
                        enhanceMessageCopyButtons(inserted[i]);
                    }
                    if (wasAtBottom) {
                        window.scrollTo(0, document.body.scrollHeight);
                    }
                })();
                """

                for msg in newMessages {
                    renderedMessageUUIDs.append(msg.uuid)
                    renderedMessageSet.insert(msg.uuid)
                    renderedFingerprints[msg.uuid] = msg.rawFingerprint
                }
            }

            // Handle waiting indicator changes.
            if waitingChanged {
                if shouldShowWaiting {
                    let waitHTML = escapeForJS("<div id=\"waiting-indicator\" class=\"row assistant\"><div class=\"stack\"><div class=\"bubble assistant\">\(escapeHTML(labels.waiting))</div></div></div>")
                    js += """
                    (function() {
                        if (!document.getElementById('waiting-indicator')) {
                            var timeline = document.querySelector('.timeline');
                            var temp = document.createElement('div');
                            temp.innerHTML = '\(waitHTML)';
                            timeline.appendChild(temp.firstElementChild);
                            if (isNearBottom()) { window.scrollTo(0, document.body.scrollHeight); }
                        }
                    })();
                    """
                } else {
                    js += """
                    (function() {
                        var w = document.getElementById('waiting-indicator');
                        if (w) { w.remove(); }
                    })();
                    """
                }
                hasWaitingIndicator = shouldShowWaiting
            }

            // Handle "load older" indicator changes.
            if olderChanged {
                if shouldShowOlder && !hasOlderIndicator {
                    let olderHTML = escapeForJS("<div id=\"load-older-bar\" class=\"topbar\"><a class=\"pill\" onclick=\"window.webkit.messageHandlers.ccreader.postMessage({action:'loadOlder'})\">\(escapeHTML(labels.loadOlder))</a></div>")
                    js += """
                    (function() {
                        var timeline = document.querySelector('.timeline');
                        var temp = document.createElement('div');
                        temp.innerHTML = '\(olderHTML)';
                        timeline.insertBefore(temp.firstElementChild, timeline.firstChild);
                    })();
                    """
                } else if !shouldShowOlder && hasOlderIndicator {
                    js += """
                    (function() {
                        var bar = document.getElementById('load-older-bar');
                        if (bar) { bar.remove(); }
                    })();
                    """
                }
                hasOlderIndicator = shouldShowOlder
            }

            if !js.isEmpty {
                webView.evaluateJavaScript(js) { _, error in
                    if let error { print("[TimelineHostView] JS error: \(error)") }
                }
            }
        }

        // MARK: - Session switch without full web reload

        /// Replace the `.timeline` DOM in-place when the shell has already been loaded.
        /// This avoids a visible blank caused by reloading the whole WKWebView.
        private func replaceTimelineForSession() {
            guard let webView else { return }

            let labels = TimelineWebLabels.localized()
            let messages = currentRenderedMessages()
            let hasOlder = renderedMessageRange.lowerBound > 0
            let waiting = snapshot.visibleMessages.last?.type == .user

            let renderer = TimelineHTMLRenderer(prevTimestampMap: snapshot.prevTimestampMap, rowPatchesMap: snapshot.rowPatchesMap)
            let messageHTML = messages.map { renderer.renderMessage($0, labels: labels) }.joined(separator: "\n")
            let loadOlderHTML = hasOlder ? "<div id=\"load-older-bar\" class=\"topbar\"><a class=\"pill\" onclick=\"window.webkit.messageHandlers.ccreader.postMessage({action:'loadOlder'})\">\(escapeHTML(labels.loadOlder))</a></div>" : ""
            let waitingHTML = waiting ? "<div id=\"waiting-indicator\" class=\"row assistant\"><div class=\"stack\"><div class=\"bubble assistant\">\(escapeHTML(labels.waiting))</div></div></div>" : ""
            let allHTML = loadOlderHTML + messageHTML + waitingHTML
            let escaped = escapeForJS(allHTML)

            // Track new DOM state to keep incremental updates consistent.
            renderedMessageUUIDs = messages.map(\.uuid)
            renderedMessageSet = Set(renderedMessageUUIDs)
            renderedFingerprints = Dictionary(uniqueKeysWithValues: messages.map { ($0.uuid, $0.rawFingerprint) })
            hasWaitingIndicator = waiting
            hasOlderIndicator = hasOlder
            isFollowingBottom = true

            let js = """
            (function() {
                if (window.ccreader && typeof window.ccreader.replaceTimeline === 'function') {
                    window.ccreader.replaceTimeline('\(escaped)');
                }
            })();
            """

            webView.evaluateJavaScript(js) { _, error in
                if let error { print("[TimelineHostView] replaceTimelineForSession JS error: \(error)") }
            }
        }

        // MARK: - Load older (prepend with scroll preservation)

        private func loadOlderMessages() {
            guard renderedMessageRange.lowerBound > 0, let webView else { return }
            let labels = TimelineWebLabels.localized()
            let renderer = TimelineHTMLRenderer(prevTimestampMap: snapshot.prevTimestampMap, rowPatchesMap: snapshot.rowPatchesMap)

            let oldLower = renderedMessageRange.lowerBound
            let newLower = max(0, oldLower - Self.renderBatchSize)
            renderedMessageRange = newLower..<renderedMessageRange.upperBound

            let totalMessages = snapshot.visibleMessages
            let olderMessages = Array(totalMessages[newLower..<oldLower])
            guard !olderMessages.isEmpty else { return }

            let html = olderMessages.map { renderer.renderMessage($0, labels: labels) }.joined(separator: "\n")
            let escaped = escapeForJS(html)

            let shouldRemoveOlderBar = newLower == 0

            // Prepend and restore scroll position.
            var js = """
            (function() {
                var timeline = document.querySelector('.timeline');
                var scrollHeightBefore = document.documentElement.scrollHeight;
                var scrollYBefore = window.scrollY;

                var temp = document.createElement('div');
                temp.innerHTML = '\(escaped)';
                var frag = document.createDocumentFragment();
                var inserted = [];
                while (temp.firstElementChild) {
                    var node = temp.firstElementChild;
                    inserted.push(node);
                    frag.appendChild(node);
                }

                var olderBar = document.getElementById('load-older-bar');
                if (olderBar) {
                    olderBar.after(frag);
                } else {
                    timeline.insertBefore(frag, timeline.firstChild);
                }

                // Only enhance newly inserted nodes to keep loadOlder cheap and consistent.
                for (var i = 0; i < inserted.length; i++) {
                    renderMarkdownIn(inserted[i]);
                    highlightCodeBlocksIn(inserted[i]);
                    enhanceCodeBlocks(inserted[i]);
                    enhanceMessageCopyButtons(inserted[i]);
                }

                var scrollHeightAfter = document.documentElement.scrollHeight;
                window.scrollTo(0, scrollYBefore + (scrollHeightAfter - scrollHeightBefore));
            """

            if shouldRemoveOlderBar {
                js += """

                var bar = document.getElementById('load-older-bar');
                if (bar) { bar.remove(); }
                """
                hasOlderIndicator = false
            }

            js += "\n})();"

            isFollowingBottom = false

            let olderUUIDs = olderMessages.map(\.uuid)
            renderedMessageUUIDs = olderUUIDs + renderedMessageUUIDs
            renderedMessageSet.formUnion(olderUUIDs)
            for msg in olderMessages {
                renderedFingerprints[msg.uuid] = msg.rawFingerprint
            }

            previousVisibleMessageCount = snapshot.visibleMessages.count

            webView.evaluateJavaScript(js) { _, error in
                if let error { print("[TimelineHostView] prepend JS error: \(error)") }
            }
        }

        // MARK: - Navigation delegate

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard shellState == .loading else { return }
            shellState = .loaded
            // Process any data that accumulated while the page was loading.
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
            // Keep the already-loaded shell when possible to avoid a visible blank.
            // Only force a full reload when the page isn't ready yet.
            shellState = (shellState == .loaded) ? .loaded : .notLoaded
            isFollowingBottom = true
            renderedMessageUUIDs = []
            renderedMessageSet = []
            renderedFingerprints = [:]
            hasWaitingIndicator = false
            hasOlderIndicator = false
        }

        private func updateRenderedRangeIfNeeded() {
            let totalCount = snapshot.visibleMessages.count
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
            let total = snapshot.visibleMessages
            let lowerBound = min(max(renderedMessageRange.lowerBound, 0), total.count)
            let upperBound = min(max(renderedMessageRange.upperBound, lowerBound), total.count)
            return Array(total[lowerBound..<upperBound])
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
            loadOlder: "Load older messages",
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
