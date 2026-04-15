import Foundation
import SwiftUI
import WebKit

struct MarkdownRenderView: NSViewRepresentable {
    let markdown: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        context.coordinator.render(markdown, into: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.lastMarkdown != markdown else { return }
        context.coordinator.render(markdown, into: webView)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        fileprivate var lastMarkdown: String?
        private weak var webView: WKWebView?
        private var themeObserver: NSObjectProtocol?

        func render(_ markdown: String, into webView: WKWebView) {
            lastMarkdown = markdown
            self.webView = webView
            if themeObserver == nil {
                themeObserver = NotificationCenter.default.addObserver(
                    forName: .ccReaderWebThemeDidChange,
                    object: nil,
                    queue: .main
                ) { [weak self] note in
                    guard let raw = note.userInfo?["themeId"] as? String,
                        let theme = WebColorTheme(rawValue: raw),
                        let wv = self?.webView
                    else { return }
                    WebColorTheme.apply(theme, to: wv)
                }
            }
            var template = WebRenderResourceLoader.text(named: "markdown-preview", extension: "html")
            let encodedMarkdown = Data(markdown.utf8).base64EncodedString()
            template = template.replacingOccurrences(of: "__CCREADER_MD_B64__", with: encodedMarkdown)
            if let resourceDirectoryURL = WebRenderResourceLoader.resourceDirectoryURL
            {
                do {
                    let tempDirectoryURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent("cc-reader-markdown-preview-\(UUID().uuidString)", isDirectory: true)
                    try FileManager.default.createDirectory(
                        at: tempDirectoryURL, withIntermediateDirectories: true)

                    for resourceName in ["markdown-preview.css", "markdown-preview.js"] {
                        let sourceURL = resourceDirectoryURL.appendingPathComponent(resourceName)
                        let destinationURL = tempDirectoryURL.appendingPathComponent(resourceName)
                        try? FileManager.default.removeItem(at: destinationURL)
                        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                    }

                    let tempHTMLURL = tempDirectoryURL.appendingPathComponent("markdown-preview.html")
                    try template.write(to: tempHTMLURL, atomically: true, encoding: .utf8)
                    webView.loadFileURL(tempHTMLURL, allowingReadAccessTo: tempDirectoryURL)
                    return
                } catch {
                    // Fall back to `loadHTMLString` if the temp staging area cannot be prepared.
                }
            }
            webView.loadHTMLString(template, baseURL: WebRenderResourceLoader.resourceDirectoryURL)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            WebColorTheme.apply(WebColorTheme.stored, to: webView)
        }

        deinit {
            if let themeObserver {
                NotificationCenter.default.removeObserver(themeObserver)
            }
        }
    }
}
