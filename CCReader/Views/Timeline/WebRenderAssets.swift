import Foundation

private let resourceBundle: Bundle = {
    #if SWIFT_PACKAGE
    return Bundle.module
    #else
    return Bundle.main
    #endif
}()

enum WebRenderResourceLoader {
    /// Base URL for `loadHTMLString` so `timeline-shell.css` / `.js` resolve from the same bundle folder.
    static var resourceDirectoryURL: URL? {
        resourceBundle.resourceURL
    }

    static func text(named name: String, extension ext: String) -> String {
        guard let url = resourceBundle.url(forResource: name, withExtension: ext),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return ""
        }
        return text
    }
}
