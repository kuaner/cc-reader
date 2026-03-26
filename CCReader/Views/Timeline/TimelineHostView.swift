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
                incrementalUpdate()
            }
        }

        // MARK: - Shell loading (one-time per session)

        private func loadShellAndRenderInitial() {
            guard let webView else { return }

            let messages = currentRenderedMessages()
            let labels = TimelineWebLabels.localized()
            let hasOlder = renderedMessageRange.lowerBound > 0
            let waiting = snapshot.visibleMessages.last?.type == .user

            let messageHTML = messages.map { renderMessage($0, labels: labels) }.joined(separator: "\n")
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
                let html = renderMessage(msg, labels: labels)
                let escaped = escapeForJS(html)
                let domId = escapeForJS(messageDOMId(for: msg.uuid))
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
                let html = newMessages.map { renderMessage($0, labels: labels) }.joined(separator: "\n")
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

        // MARK: - Load older (prepend with scroll preservation)

        private func loadOlderMessages() {
            guard renderedMessageRange.lowerBound > 0, let webView else { return }
            let labels = TimelineWebLabels.localized()

            let oldLower = renderedMessageRange.lowerBound
            let newLower = max(0, oldLower - Self.renderBatchSize)
            renderedMessageRange = newLower..<renderedMessageRange.upperBound

            let totalMessages = snapshot.visibleMessages
            let olderMessages = Array(totalMessages[newLower..<oldLower])
            guard !olderMessages.isEmpty else { return }

            let html = olderMessages.map { renderMessage($0, labels: labels) }.joined(separator: "\n")
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
            shellState = .notLoaded
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
                /* INLINE_LEGACY_CSS
                :root {
                  color-scheme: light dark;
                  --text: #1d1d1f;
                  --muted: rgba(60,60,67,0.68);
                  --border: rgba(60,60,67,0.20);
                  --surface-user: #1f8fff;
                  --surface-user-text: #ffffff;
                  --surface-assistant: rgba(151,71,255,0.12);
                  --surface-thinking: rgba(255,149,0,0.10);
                  --surface-tool: rgba(20,184,166,0.08);
                  --surface-summary: rgba(255,149,0,0.14);
                  --button: rgba(60,60,67,0.08);
                  --code-bg: rgba(60,60,67,0.08);
                  --code-block-border: rgba(60,60,67,0.16);
                  --code-header-bg: rgba(60,60,67,0.05);
                  --code-header-border: rgba(60,60,67,0.12);
                  --code-button-bg: rgba(60,60,67,0.08);
                  --code-button-border: rgba(60,60,67,0.14);
                  --message-button-bg: rgba(60,60,67,0.08);
                  --message-button-border: rgba(60,60,67,0.14);
                  --max-width: clamp(560px, 72vw, 980px);
                }
                @media (prefers-color-scheme: dark) {
                  :root {
                    --text: #f5f5f7;
                    --muted: rgba(235,235,245,0.60);
                    --border: rgba(255,255,255,0.12);
                    --surface-assistant: rgba(151,71,255,0.16);
                    --surface-thinking: rgba(255,149,0,0.12);
                    --surface-tool: rgba(45,212,191,0.10);
                    --surface-summary: rgba(255,149,0,0.16);
                    --button: rgba(255,255,255,0.08);
                    --code-bg: rgba(255,255,255,0.08);
                    --code-block-border: rgba(255,255,255,0.14);
                    --code-header-bg: rgba(255,255,255,0.05);
                    --code-header-border: rgba(255,255,255,0.10);
                    --code-button-bg: rgba(255,255,255,0.06);
                    --code-button-border: rgba(255,255,255,0.14);
                    --message-button-bg: rgba(255,255,255,0.06);
                    --message-button-border: rgba(255,255,255,0.14);
                  }
                }
                * { box-sizing: border-box; }
                html, body { margin: 0; padding: 0; background: transparent; color: var(--text); overflow-x: hidden; }
                body {
                  font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
                  font-size: 14px;
                  line-height: 1.55;
                  padding: 14px 12px 20px;
                }
                .timeline { display: flex; flex-direction: column; gap: 14px; }
                .topbar { display: flex; justify-content: center; }
                .row { display: flex; width: 100%; }
                .row.user { justify-content: flex-end; }
                .row.assistant { justify-content: flex-start; }
                .stack { display: flex; flex-direction: column; gap: 8px; width: min(100%, var(--max-width)); max-width: 100%; }
                .bubble { border-radius: 14px; padding: 10px 12px; overflow-wrap: anywhere; word-break: break-word; position: relative; }
                .bubble.user {
                  background: var(--surface-user);
                  color: var(--surface-user-text);
                  --code-block-border: rgba(255,255,255,0.22);
                  --code-header-bg: rgba(255,255,255,0.10);
                  --code-header-border: rgba(255,255,255,0.18);
                  --code-button-bg: rgba(255,255,255,0.10);
                  --code-button-border: rgba(255,255,255,0.18);
                }
                .bubble.assistant-card {
                  background: var(--surface-assistant); display: flex; flex-direction: column; gap: 8px;
                }
                .card-section { border-radius: 8px; padding: 8px 10px; }
                .card-section.thinking { background: var(--surface-thinking); }
                .card-section.tool { background: var(--surface-tool); }
                .bubble.summary { background: var(--surface-summary); border: 1px solid rgba(255,149,0,0.28); }
                .bubble-footer {
                  display: flex; align-items: center; gap: 8px; font-size: 11px; color: var(--muted);
                  margin-top: 8px; padding-top: 8px; border-top: 1px solid var(--border);
                  min-height: 28px;
                }
                .bubble.user .bubble-footer { border-top-color: rgba(255,255,255,0.2); color: rgba(255,255,255,0.7); }
                .type-tag {
                  display: inline-block; padding: 1px 7px; border-radius: 4px;
                  font-size: 9px; font-weight: 600; line-height: 1.4;
                }
                .type-tag.user-tag { background: rgba(255,255,255,0.18); color: #fff; }
                .type-tag.assistant-tag { background: rgba(151,71,255,0.25); }
                .type-tag.summary-tag { background: rgba(255,149,0,0.25); color: #ff9500; }
                .section-title, .summary-title { font-size: 12px; font-weight: 600; color: var(--muted); margin-bottom: 6px; }
                .summary-title { color: #ff9500; }
                .meta, .header-row, .topbar { font-size: 11px; color: var(--muted); }
                .header-row { display: flex; gap: 8px; align-items: center; flex-wrap: wrap; }
                .header-row.left { justify-content: flex-start; }
                .assistant-header {
                  display: flex; align-items: center; gap: 10px; min-height: 20px; padding: 0 2px;
                }
                .assistant-title { font-size: 12px; font-weight: 700; color: var(--muted); line-height: 1; }
                .bubble-footer .spacer { flex: 1; }
                .pill {
                  display: inline-block; padding: 4px 10px; border-radius: 999px;
                  background: var(--button); color: inherit; text-decoration: none; line-height: 1.2; cursor: pointer;
                }
                .plain-text { white-space: pre-wrap; word-break: break-word; }
                .plain-pre {
                  margin: 0.6em 0; white-space: pre-wrap; word-break: break-word;
                  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
                  font-size: 12px; line-height: 1.5; background: var(--code-bg); border-radius: 10px; padding: 12px;
                }
                .markdown { overflow-wrap: anywhere; word-break: break-word; }
                .markdown > :first-child { margin-top: 0; }
                .markdown > :last-child { margin-bottom: 0; }
                .markdown p, .markdown ul, .markdown ol, .markdown pre, .markdown blockquote, .markdown table, .markdown hr { margin: 0.7em 0; }
                .markdown ul, .markdown ol { padding-left: 1.4em; }
                .markdown li + li { margin-top: 0.2em; }
                .markdown h1, .markdown h2, .markdown h3, .markdown h4 { line-height: 1.25; margin: 0.9em 0 0.45em; }
                .markdown h1 { font-size: 1.35em; }
                .markdown h2 { font-size: 1.18em; }
                .markdown h3 { font-size: 1.05em; }
                .markdown :not(pre) > code {
                  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
                  background: var(--code-bg); padding: 0.15em 0.4em; border-radius: 6px;
                }
                .markdown blockquote {
                  margin: 0.75em 0; padding-left: 12px; border-left: 3px solid var(--border); color: var(--muted);
                }
                .markdown pre { background: var(--code-bg); border-radius: 10px; padding: 12px; overflow-x: auto; }
                .markdown pre code { padding: 0; }
                .markdown table { width: 100%; border-collapse: collapse; margin: 0.6em 0; table-layout: fixed; }
                .markdown th, .markdown td { border: 1px solid var(--border); padding: 6px 8px; text-align: left; vertical-align: top; }
                .markdown a { color: inherit; text-decoration: underline; }
                .bubble.user .markdown :not(pre) > code, .bubble.user .markdown pre, .bubble.assistant-card .card-section .markdown pre { background: rgba(255,255,255,0.16); }
                .bubble.user .summary-title, .bubble.user .markdown blockquote { color: rgba(255,255,255,0.82); }
                .bubble.assistant-card .card-section .markdown :not(pre) > code { background: var(--code-bg); }
                */
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

                /* INLINE_LEGACY_SHELL_JS
                function decodeMarkdownBase64(source) {
                    return decodeURIComponent(escape(window.atob(source)));
                }

                function renderMarkdownIn(root) {
                    if (typeof marked === 'undefined') { return; }
                    root.querySelectorAll('[data-markdown-base64]').forEach(function(node) {
                        if (node.dataset.mdRendered === '1') { return; }
                        var source = node.getAttribute('data-markdown-base64') || '';
                        if (!source) { return; }
                        try {
                            node.innerHTML = marked.parse(decodeMarkdownBase64(source));
                            node.dataset.mdRendered = '1';
                        } catch (e) {
                            console.error('markdown render failed', e);
                        }
                    });
                }

                function highlightCodeBlocksIn(root) {
                    if (typeof hljs === 'undefined') { return; }
                    root.querySelectorAll('pre code').forEach(function(block) {
                        if (block.dataset.hlRendered === '1') { return; }
                        try {
                            hljs.highlightElement(block);
                            block.dataset.hlRendered = '1';
                        } catch (e) {
                            console.error('highlight failed', e);
                        }
                    });
                }

                function isNearBottom() {
                    return window.innerHeight + window.scrollY >= document.documentElement.scrollHeight - \(Int(Self.followBottomThreshold));
                }

                var scrollState = { followingBottom: true, ticking: false };

                function emitScrollState() {
                    var following = isNearBottom();
                    if (following !== scrollState.followingBottom) {
                        scrollState.followingBottom = following;
                        window.webkit.messageHandlers.ccreader.postMessage({
                            action: 'scrollState',
                            following: following
                        });
                    }
                }

                window.addEventListener('scroll', function() {
                    if (scrollState.ticking) { return; }
                    scrollState.ticking = true;
                    window.requestAnimationFrame(function() {
                        scrollState.ticking = false;
                        emitScrollState();
                    });
                }, { passive: true });

                // Initial render
                renderMarkdownIn(document);
                highlightCodeBlocksIn(document);
                enhanceCodeBlocks(document);
                enhanceMessageCopyButtons(document);
                window.scrollTo(0, document.body.scrollHeight);
                */
              </script>
            </body>
            </html>
            """
        }

        // MARK: - Message rendering (shared between shell and incremental)

        private func renderMessage(_ message: TimelineMessageDisplayData, labels: TimelineWebLabels) -> String {
            if message.type == .user {
                return renderUserMessage(message, labels: labels)
            }
            return renderAssistantMessage(message, labels: labels)
        }

        private func renderUserMessage(_ message: TimelineMessageDisplayData, labels: TimelineWebLabels) -> String {
            let domId = escapeHTML(messageDOMId(for: message.uuid))
            let copyButton = messageRawDataButtonHTML(for: message, labels: labels)
            let time = escapeHTML(Self.timeFormatter.string(from: message.timestamp))

            let bubble: String
            if isSummaryMessage(message) {
                let tag = "<span class=\"type-tag summary-tag\">\(escapeHTML(labels.legendSummary))</span>"
                let footer = "<div class=\"bubble-footer\"><span>\(time)</span>\(tag)<span class=\"spacer\"></span>\(copyButton)</div>"
                bubble = "<div class=\"bubble summary\"><div class=\"summary-title\">\(escapeHTML(labels.summaryLabel))</div>\(messageBodyHTML(message.content ?? ""))\(footer)</div>"
            } else {
                let tag = "<span class=\"type-tag user-tag\">\(escapeHTML(labels.legendUser))</span>"
                let footer = "<div class=\"bubble-footer\"><span>\(time)</span>\(tag)<span class=\"spacer\"></span>\(copyButton)</div>"
                bubble = "<div class=\"bubble user\">\(messageBodyHTML(message.content ?? ""))\(footer)</div>"
            }
            return "<div class=\"row user\" id=\"\(domId)\"><div class=\"stack\">\(bubble)</div></div>"
        }

        private func renderAssistantMessage(_ message: TimelineMessageDisplayData, labels: TimelineWebLabels) -> String {
            var sections: [String] = []
            let domId = escapeHTML(messageDOMId(for: message.uuid))

            let headerTitle = escapeHTML(labels.assistant)
            let model = modelTitle(message.model).map { "<span class=\"pill\">\(escapeHTML($0))</span>" } ?? ""
            sections.append("<div class=\"assistant-header\"><span class=\"assistant-title\">\(headerTitle)</span>\(model)</div>")

            if let thinking = message.thinking, !thinking.isEmpty {
                let title = escapeHTML(thinkingTitle(for: message) ?? labels.thinking)
                sections.append("<div class=\"card-section thinking\"><div class=\"section-title\">\(title)</div>\(messageBodyHTML(thinking))</div>")
            }

            if !message.toolUses.isEmpty {
                sections.append(renderToolUses(message, labels: labels))
            }

            if let content = message.content, !content.isEmpty {
                sections.append("<div class=\"card-section\">\(messageBodyHTML(content))</div>")
            }

            let copyButton = messageRawDataButtonHTML(for: message, labels: labels)
            let time = escapeHTML(Self.timeFormatter.string(from: message.timestamp))
            let tag = "<span class=\"type-tag assistant-tag\">\(escapeHTML(labels.legendAssistant))</span>"
            sections.append("<div class=\"bubble-footer\"><span>\(time)</span>\(tag)<span class=\"spacer\"></span>\(copyButton)</div>")

            return "<div class=\"row assistant\" id=\"\(domId)\"><div class=\"stack\"><div class=\"bubble assistant-card\">\(sections.joined())</div></div></div>"
        }

        private func renderToolUses(_ message: TimelineMessageDisplayData, labels: TimelineWebLabels) -> String {
            let body = message.toolUses.map { tool in
                let title = escapeHTML(toolTitle(tool))
                let content = toolBody(tool: tool, messageId: message.uuid).map { "<pre class=\"plain-pre\">\(escapeHTML($0))</pre>" } ?? ""
                return "<div><div class=\"section-title\">\(title)</div>\(content)</div>"
            }.joined()
            return "<div class=\"card-section tool\"><div class=\"section-title\">\(escapeHTML(labels.context))</div>\(body)</div>"
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
            if let previous = snapshot.prevTimestampMap[message.uuid] {
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
            let fallback = escapeHTML(text).replacingOccurrences(of: "\n", with: "<br>")
            let encoded = encodeBase64(text)
            return "<div class=\"markdown\" data-markdown-base64=\"\(encoded)\"><div class=\"plain-text\">\(fallback)</div></div>"
        }

        private func messageRawDataButtonHTML(for message: TimelineMessageDisplayData, labels: TimelineWebLabels) -> String {
            let dump = rawDataDump(for: message)
            guard !dump.isEmpty else { return "" }
            let encoded = encodeBase64(dump)
            let rawLabel = escapeHTML(labels.rawData)
            return "<button type=\"button\" class=\"message-copy-button\" data-message-copy-base64=\"\(encoded)\" data-copy-label=\"\(rawLabel)\">\(rawLabel)</button>"
        }

        private func rawDataDump(for message: TimelineMessageDisplayData) -> String {
            message.rawJsonString
        }

        private func encodeBase64(_ text: String) -> String {
            Data(text.utf8).base64EncodedString()
        }

        private func messageDOMId(for messageId: String) -> String {
            "msg-\(messageId)"
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

        private static let timeFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            formatter.dateStyle = .none
            return formatter
        }()
    }
}

private struct TimelineWebLabels {
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
