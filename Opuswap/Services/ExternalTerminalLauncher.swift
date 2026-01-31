import Foundation
import AppKit

enum TerminalApp: String, CaseIterable, Identifiable {
    case terminal = "Terminal"
    case iterm = "iTerm"
    case warp = "Warp"
    case alacritty = "Alacritty"

    var id: String { rawValue }

    var bundleIdentifier: String {
        switch self {
        case .terminal: return "com.apple.Terminal"
        case .iterm: return "com.googlecode.iterm2"
        case .warp: return "dev.warp.Warp-Stable"
        case .alacritty: return "org.alacritty"
        }
    }

    var icon: String {
        switch self {
        case .terminal: return "terminal"
        case .iterm: return "terminal.fill"
        case .warp: return "bolt.horizontal"
        case .alacritty: return "rectangle.on.rectangle"
        }
    }
}

class ExternalTerminalLauncher {

    /// インストール済みのターミナルアプリを検出
    static func availableTerminals() -> [TerminalApp] {
        TerminalApp.allCases.filter { app in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleIdentifier) != nil
        }
    }

    /// 指定ディレクトリでターミナルを開く
    static func open(_ app: TerminalApp, at directory: String) {
        switch app {
        case .terminal:
            openTerminalApp(at: directory)
        case .iterm:
            openITerm(at: directory)
        case .warp:
            openWarp(at: directory)
        case .alacritty:
            openAlacritty(at: directory)
        }
    }

    // MARK: - Terminal.app

    private static func openTerminalApp(at directory: String) {
        let script = """
        tell application "Terminal"
            activate
            do script "cd '\(directory.replacingOccurrences(of: "'", with: "'\\''"))'"
        end tell
        """
        runAppleScript(script)
    }

    // MARK: - iTerm2

    private static func openITerm(at directory: String) {
        let script = """
        tell application "iTerm"
            activate
            if (count of windows) = 0 then
                create window with default profile
            end if
            tell current session of current window
                write text "cd '\(directory.replacingOccurrences(of: "'", with: "'\\''"))'"
            end tell
        end tell
        """
        runAppleScript(script)
    }

    // MARK: - Warp

    private static func openWarp(at directory: String) {
        // Warpはディレクトリを引数として開ける
        let url = URL(fileURLWithPath: directory)
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: NSWorkspace.shared.urlForApplication(withBundleIdentifier: TerminalApp.warp.bundleIdentifier)!,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    // MARK: - Alacritty

    private static func openAlacritty(at directory: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Alacritty", "--args", "--working-directory", directory]
        try? process.run()
    }

    // MARK: - Helper

    private static func runAppleScript(_ script: String) {
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&error)
            if let error = error {
                print("AppleScript error: \(error)")
            }
        }
    }
}
