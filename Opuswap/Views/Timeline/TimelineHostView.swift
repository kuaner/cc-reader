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
        let webView = WKWebView(frame: .zero)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        context.coordinator.attach(to: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.apply(snapshot: snapshot)
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.navigationDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private static let renderBatchSize = 200

        private weak var webView: WKWebView?
        private var snapshot = TimelineRenderSnapshot()
        private var renderedMessageRange: Range<Int> = 0..<0
        private var lastDocumentFingerprint = ""
        private var shouldScrollToBottomAfterRender = true

        func attach(to webView: WKWebView) {
            self.webView = webView
        }

        func apply(snapshot: TimelineRenderSnapshot) {
            self.snapshot = snapshot

            updateRenderedRangeIfNeeded()
            let document = makeDocumentHTML()
            guard document != lastDocumentFingerprint else { return }
            lastDocumentFingerprint = document
            webView?.loadHTMLString(document, baseURL: nil)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            guard url.scheme == "opuswap" else {
                if ["http", "https"].contains(url.scheme?.lowercased()) {
                    NSWorkspace.shared.open(url)
                    decisionHandler(.cancel)
                    return
                }
                decisionHandler(.allow)
                return
            }

            handle(url: url)
            decisionHandler(.cancel)
        }

        private func handle(url: URL) {
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
            let host = components.host ?? ""

            if host == "load-older" {
                loadOlderMessages()
            }
        }

        private func updateRenderedRangeIfNeeded() {
            let totalCount = snapshot.visibleMessages.count
            guard totalCount > 0 else {
                renderedMessageRange = 0..<0
                return
            }

            if renderedMessageRange.upperBound == totalCount,
               renderedMessageRange.lowerBound >= 0,
               renderedMessageRange.lowerBound < renderedMessageRange.upperBound {
                return
            }

            let lowerBound = max(0, totalCount - Self.renderBatchSize)
            renderedMessageRange = lowerBound..<totalCount
        }

        private func loadOlderMessages() {
            guard renderedMessageRange.lowerBound > 0 else { return }
            renderedMessageRange = max(0, renderedMessageRange.lowerBound - Self.renderBatchSize)..<renderedMessageRange.upperBound
            lastDocumentFingerprint = ""
            shouldScrollToBottomAfterRender = false
            guard let webView else { return }
            let document = makeDocumentHTML()
            lastDocumentFingerprint = document
            webView.loadHTMLString(document, baseURL: nil)
        }

        private func makeDocumentHTML() -> String {
            let messages = currentRenderedMessages()
            let hasOlder = renderedMessageRange.lowerBound > 0
            let waiting = snapshot.visibleMessages.last?.type == .user
            let labels = TimelineWebLabels.localized()

            let messageHTML = messages.map { renderMessage($0, labels: labels) }.joined(separator: "\n")
            let loadOlderHTML = hasOlder ? "<div class=\"topbar\"><a class=\"pill\" href=\"opuswap://load-older\">\(escapeHTML(labels.loadOlder))</a></div>" : ""
            let waitingHTML = waiting ? "<div class=\"row assistant\"><div class=\"stack\"><div class=\"bubble assistant\">\(escapeHTML(labels.waiting))</div></div></div>" : ""
            let renderScript = makeRenderScript(markedJS: MarkedJavaScriptLoader.script)

            return """
            <!DOCTYPE html>
            <html>
            <head>
              <meta charset=\"utf-8\" />
              <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\" />
              <style>
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
                  }
                }
                * { box-sizing: border-box; }
                html, body { margin: 0; padding: 0; background: transparent; color: var(--text); }
                body {
                  font-family: -apple-system, BlinkMacSystemFont, \"SF Pro Text\", sans-serif;
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
                .bubble { border-radius: 14px; padding: 10px 12px; overflow-wrap: anywhere; word-break: break-word; }
                .bubble.user { background: var(--surface-user); color: var(--surface-user-text); }
                .bubble.assistant { background: var(--surface-assistant); }
                .bubble.thinking { background: var(--surface-thinking); }
                .bubble.tool { background: var(--surface-tool); }
                .bubble.summary { background: var(--surface-summary); border: 1px solid rgba(255,149,0,0.28); }
                                .section-title, .summary-title { font-size: 12px; font-weight: 600; color: var(--muted); margin-bottom: 6px; }
                .summary-title { color: #ff9500; }
                                .meta, .footer, .header-row, .topbar { font-size: 11px; color: var(--muted); }
                                .header-row, .footer { display: flex; gap: 8px; align-items: center; flex-wrap: wrap; }
                                .header-row.left { justify-content: flex-start; }
                                .assistant-header {
                                    display: flex;
                                    align-items: center;
                                    gap: 10px;
                                    min-height: 28px;
                                    padding: 0 2px;
                                }
                                .assistant-title {
                                    font-size: 12px;
                                    font-weight: 700;
                                    color: var(--muted);
                                    line-height: 1;
                                }
                .footer .spacer { flex: 1; }
                .pill {
                  display: inline-block;
                  padding: 4px 10px;
                  border-radius: 999px;
                  background: var(--button);
                  color: inherit;
                  text-decoration: none;
                                    line-height: 1.2;
                }
                                .plain-text {
                                    white-space: pre-wrap;
                                    word-break: break-word;
                                }
                                .plain-pre {
                  margin: 0.6em 0;
                  white-space: pre-wrap;
                  word-break: break-word;
                  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
                  font-size: 12px;
                  line-height: 1.5;
                  background: var(--code-bg);
                  border-radius: 10px;
                  padding: 12px;
                }
                                .markdown {
                                    overflow-wrap: anywhere;
                                    word-break: break-word;
                                }
                                .markdown > :first-child { margin-top: 0; }
                                .markdown > :last-child { margin-bottom: 0; }
                                .markdown p,
                                .markdown ul,
                                .markdown ol,
                                .markdown pre,
                                .markdown blockquote,
                                .markdown table,
                                .markdown hr { margin: 0.7em 0; }
                                .markdown ul,
                                .markdown ol { padding-left: 1.4em; }
                                .markdown li + li { margin-top: 0.2em; }
                                .markdown h1,
                                .markdown h2,
                                .markdown h3,
                                .markdown h4 {
                                    line-height: 1.25;
                                    margin: 0.9em 0 0.45em;
                                }
                                .markdown h1 { font-size: 1.35em; }
                                .markdown h2 { font-size: 1.18em; }
                                .markdown h3 { font-size: 1.05em; }
                .markdown code {
                  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
                  background: var(--code-bg);
                  padding: 0.15em 0.4em;
                  border-radius: 6px;
                }
                .markdown blockquote {
                  margin: 0.75em 0;
                  padding-left: 12px;
                  border-left: 3px solid var(--border);
                  color: var(--muted);
                }
                                .markdown pre {
                                    background: var(--code-bg);
                                    border-radius: 10px;
                                    padding: 12px;
                                    overflow-x: auto;
                                }
                                .markdown pre code {
                                    background: transparent;
                                    padding: 0;
                                }
                                .markdown table { width: 100%; border-collapse: collapse; margin: 0.6em 0; }
                                .markdown th, .markdown td { border: 1px solid var(--border); padding: 6px 8px; text-align: left; vertical-align: top; }
                                .markdown a { color: inherit; text-decoration: underline; }
                                .bubble.user .markdown code,
                                .bubble.user .markdown pre { background: rgba(255,255,255,0.16); }
                                .bubble.user .summary-title,
                                .bubble.user .markdown blockquote { color: rgba(255,255,255,0.82); }
              </style>
            </head>
            <body>
                            <div class=\"timeline\">\(loadOlderHTML)\(messageHTML)\(waitingHTML)</div>
                            \(renderScript)
            </body>
            </html>
            """
        }

                private func makeRenderScript(markedJS: String) -> String {
                        let renderMarkdown = markedJS.isEmpty ? "" : """
                            \(markedJS)
                            document.querySelectorAll('[data-markdown-base64]').forEach(function(node) {
                                const source = node.getAttribute('data-markdown-base64') || '';
                                if (!source) { return; }
                                try {
                                    const markdown = decodeURIComponent(escape(window.atob(source)));
                                    node.innerHTML = marked.parse(markdown);
                                } catch (error) {
                                    console.error('timeline markdown render failed', error);
                                }
                            });
                        """

                        let scrollToBottom = shouldScrollToBottomAfterRender ? "window.scrollTo(0, document.body.scrollHeight);" : ""
                        shouldScrollToBottomAfterRender = true
                        return """
                        <script>
                            window.addEventListener('load', function() {
                                \(renderMarkdown)
                                \(scrollToBottom)
                            });
                        </script>
                        """
                }

        private func currentRenderedMessages() -> [TimelineMessageDisplayData] {
            let total = snapshot.visibleMessages
            let lowerBound = min(max(renderedMessageRange.lowerBound, 0), total.count)
            let upperBound = min(max(renderedMessageRange.upperBound, lowerBound), total.count)
            return Array(total[lowerBound..<upperBound])
        }

        private func renderMessage(_ message: TimelineMessageDisplayData, labels: TimelineWebLabels) -> String {
            if message.type == .user {
                return renderUserMessage(message, labels: labels)
            }
            return renderAssistantMessage(message, labels: labels)
        }

        private func renderUserMessage(_ message: TimelineMessageDisplayData, labels: TimelineWebLabels) -> String {
            let bubble: String
            if isSummaryMessage(message) {
                bubble = "<div class=\"bubble summary\"><div class=\"summary-title\">\(escapeHTML(labels.summaryLabel))</div>\(messageBodyHTML(message.content ?? ""))</div>"
            } else {
                bubble = "<div class=\"bubble user\">\(messageBodyHTML(message.content ?? ""))</div>"
            }
            let meta = "<div class=\"meta\" style=\"text-align:right\">\(escapeHTML(Self.timeFormatter.string(from: message.timestamp)))</div>"
            return "<div class=\"row user\"><div class=\"stack\">\(bubble)\(meta)</div></div>"
        }

        private func renderAssistantMessage(_ message: TimelineMessageDisplayData, labels: TimelineWebLabels) -> String {
            var sections: [String] = []

            let headerTitle = escapeHTML(labels.assistant)
            let model = modelTitle(message.model).map { "<span class=\"pill\">\(escapeHTML($0))</span>" } ?? ""
            sections.append("<div class=\"assistant-header\"><span class=\"assistant-title\">\(headerTitle)</span>\(model)</div>")

            if let thinking = message.thinking, !thinking.isEmpty {
                let title = escapeHTML(thinkingTitle(for: message) ?? labels.thinking)
                sections.append("<div class=\"stack\"><div class=\"section-title\">\(title)</div><div class=\"bubble thinking\">\(messageBodyHTML(thinking))</div></div>")
            }

            if !message.toolUses.isEmpty {
                sections.append(renderToolUses(message, labels: labels))
            }

            if let content = message.content, !content.isEmpty {
                sections.append("<div class=\"bubble assistant\">\(messageBodyHTML(content))</div>")
            }

            let footer = "<div class=\"footer\"><span class=\"spacer\"></span><span>\(escapeHTML(Self.timeFormatter.string(from: message.timestamp)))</span></div>"
            sections.append(footer)
            return "<div class=\"row assistant\"><div class=\"stack\">\(sections.joined())</div></div>"
        }

        private func renderToolUses(_ message: TimelineMessageDisplayData, labels: TimelineWebLabels) -> String {
            let body = message.toolUses.map { tool in
                let title = escapeHTML(toolTitle(tool))
                let content = toolBody(tool: tool, messageId: message.uuid).map { "<pre class=\"plain-pre\">\(escapeHTML($0))</pre>" } ?? ""
                return "<div><div class=\"section-title\">\(title)</div>\(content)</div>"
            }.joined()
            return "<div class=\"bubble tool\"><div class=\"section-title\">\(escapeHTML(labels.context))</div>\(body)</div>"
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
            return String(format: String(localized: "timeline.thinking.seconds"), duration)
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

        private func encodeBase64(_ text: String) -> String {
            Data(text.utf8).base64EncodedString()
        }

        private func escapeHTML(_ text: String) -> String {
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
}

private struct TimelineWebLabels {
    let summaryLabel: String
    let context: String
    let assistant: String
    let thinking: String
    let waiting: String
    let loadOlder: String

    static func localized() -> TimelineWebLabels {
        TimelineWebLabels(
            summaryLabel: String(localized: "timeline.summary.label"),
            context: String(localized: "timeline.context.label"),
            assistant: String(localized: "timeline.claude.label"),
            thinking: String(localized: "timeline.thinking.label"),
            waiting: String(localized: "timeline.thinking.label") + "...",
            loadOlder: "Load older messages"
        )
    }
}
