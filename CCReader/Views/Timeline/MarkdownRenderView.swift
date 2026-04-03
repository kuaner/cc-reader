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
            var template = WebRenderResourceLoader.text(named: "markdown-preview", extension: "html")
            let encodedMarkdown = Data(markdown.utf8).base64EncodedString()
            template = template.replacingOccurrences(of: "__CCREADER_MD_B64__", with: encodedMarkdown)
            webView.loadHTMLString(template, baseURL: WebRenderResourceLoader.resourceDirectoryURL)
        }
    }
}
