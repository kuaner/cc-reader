import AppKit
import Foundation
import UniformTypeIdentifiers

/// Exports a session's source JSONL transcript to a user-chosen file.
enum SessionJSONLExporter {

    @MainActor
    static func export(_ session: Session) {
        guard let fileURL = session.jsonlFileURL else {
            presentFailure(L("error.sessionFile.notFound"))
            return
        }

        let panel = NSSavePanel()
        panel.title = L("session.export")
        panel.nameFieldStringValue = fileURL.lastPathComponent
        panel.allowedContentTypes = [.data]
        panel.canCreateDirectories = true

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try Data(contentsOf: fileURL).write(to: url, options: .atomic)
            } catch {
                presentFailure(String(format: L("error.save.failed"), error.localizedDescription))
            }
        }
    }

    @MainActor
    private static func presentFailure(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.runModal()
    }
}
