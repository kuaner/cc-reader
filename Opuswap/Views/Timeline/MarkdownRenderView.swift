import Foundation
import SwiftUI
import WebKit

enum MarkedJavaScriptLoader {
    private static var cachedScript: String?

    static var script: String {
        if let cachedScript {
            return cachedScript
        }
        if let url = Bundle.main.url(forResource: "marked.min", withExtension: "js"),
           let script = try? String(contentsOf: url, encoding: .utf8) {
            cachedScript = script
            return script
        }
        cachedScript = ""
        return ""
    }
}

struct MarkdownRenderView: NSViewRepresentable {
    let markdown: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.render(markdown, into: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.lastMarkdown != markdown else { return }
        context.coordinator.render(markdown, into: webView)
    }

    final class Coordinator {
        fileprivate var lastMarkdown: String?

        func render(_ markdown: String, into webView: WKWebView) {
            lastMarkdown = markdown
            let fallback = markdown
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\n", with: "<br>")
            let encodedMarkdown = Data(markdown.utf8).base64EncodedString()

            let html = """
            <!DOCTYPE html>
            <html>
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <style>
              :root {
                color-scheme: light dark;
                --text: #1d1d1f;
                --code-bg: rgba(60,60,67,0.08);
                --border: rgba(60,60,67,0.20);
              }
              @media (prefers-color-scheme: dark) {
                :root {
                  --text: #f5f5f7;
                  --code-bg: rgba(255,255,255,0.08);
                  --border: rgba(255,255,255,0.12);
                }
              }
              body {
                font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
                font-size: 14px;
                line-height: 1.6;
                padding: 16px;
                margin: 0;
                color: var(--text);
                background: transparent;
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
              .markdown hr { margin: 0.75em 0; }
              .markdown ul,
              .markdown ol { padding-left: 1.4em; }
              .markdown h1,
              .markdown h2,
              .markdown h3,
              .markdown h4 {
                line-height: 1.25;
                margin: 0.9em 0 0.45em;
              }
              .markdown h1 { font-size: 1.45em; }
              .markdown h2 { font-size: 1.2em; }
              .markdown h3 { font-size: 1.05em; }
              .markdown code {
                font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
                font-size: 0.92em;
                background: var(--code-bg);
                padding: 0.15em 0.4em;
                border-radius: 6px;
              }
              .markdown pre {
                background: var(--code-bg);
                padding: 12px;
                border-radius: 10px;
                overflow-x: auto;
              }
              .markdown pre code {
                background: transparent;
                padding: 0;
              }
              .markdown blockquote {
                border-left: 3px solid var(--border);
                margin-left: 0;
                padding-left: 12px;
                color: color-mix(in srgb, var(--text) 65%, transparent);
              }
              .markdown table {
                border-collapse: collapse;
                width: 100%;
              }
              .markdown th,
              .markdown td {
                border: 1px solid var(--border);
                padding: 6px 12px;
                text-align: left;
                vertical-align: top;
              }
              .markdown img { max-width: 100%; }
              .markdown a { color: inherit; text-decoration: underline; }
              .plain-text {
                white-space: pre-wrap;
                word-break: break-word;
              }
            </style>
            </head>
            <body>
            <div id="content" class="markdown" data-markdown-base64="\(encodedMarkdown)"><div class="plain-text">\(fallback)</div></div>
            <script>\(MarkedJavaScriptLoader.script)</script>
            <script>
              (function() {
                const node = document.getElementById('content');
                const source = node.getAttribute('data-markdown-base64') || '';
                if (!source || typeof marked === 'undefined') { return; }
                try {
                  const markdown = decodeURIComponent(escape(window.atob(source)));
                  node.innerHTML = marked.parse(markdown);
                } catch (error) {
                  console.error('markdown render failed', error);
                }
              })();
            </script>
            </body>
            </html>
            """

            webView.loadHTMLString(html, baseURL: nil)
        }
    }
}