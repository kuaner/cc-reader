import Foundation

enum SessionTranscriptSource: String, Sendable {
    case claude
    case codex
}

struct SessionTranscriptMetadata: Sendable {
    let cwd: String?
    let gitBranch: String?
    let title: String?
    let model: String?
    let timestamp: String?
}

protocol SessionTranscriptParser: Sendable {
    var source: SessionTranscriptSource { get }
    var rootPath: String { get }

    func matches(_ url: URL) -> Bool
    func sessionId(from url: URL) -> String?
    func readMetadata(from url: URL) -> SessionTranscriptMetadata?
    func parseLine(_ lineData: Data, sourceURL: URL) -> RawMessageData?
}

struct SessionTranscriptParserRegistry: Sendable {
    static let shared = SessionTranscriptParserRegistry(parsers: [
        CodexTranscriptParser(),
        ClaudeTranscriptParser()
    ])

    let parsers: [any SessionTranscriptParser]

    var rootPaths: [String] {
        parsers.map(\.rootPath)
    }

    func parser(for url: URL) -> (any SessionTranscriptParser)? {
        parsers.first { $0.matches(url) }
    }
}

struct ClaudeTranscriptParser: SessionTranscriptParser {
    var source: SessionTranscriptSource { .claude }

    var rootPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.claude/projects"
    }

    func matches(_ url: URL) -> Bool {
        url.path.contains("/.claude/projects/")
    }

    func sessionId(from url: URL) -> String? {
        let filename = url.deletingPathExtension().lastPathComponent
        return filename.isEmpty ? nil : filename
    }

    func readMetadata(from url: URL) -> SessionTranscriptMetadata? {
        nil
    }

    func parseLine(_ lineData: Data, sourceURL: URL) -> RawMessageData? {
        let decoder = JSONDecoder()
        do {
            var message = try decoder.decode(RawMessageData.self, from: lineData)
            message.originalLineData = lineData
            return message
        } catch {
            if ProcessInfo.processInfo.environment["CCREADER_DEBUG_JSONL_DECODE"] == "1",
               let lineStr = String(data: lineData, encoding: .utf8) {
                let preview = lineStr.prefix(200)
                print("[cc-reader][JSONLParser] Skipped line (decode failed): \(preview)…")
            }
            return nil
        }
    }
}
