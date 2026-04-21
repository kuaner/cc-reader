import Foundation
import Testing
@testable import CCReaderKit

struct CodexTranscriptParserTests {
    @Test
    func mapsCodexToolFieldsUsedByTimelineContext() throws {
        let url = try makeCodexTranscriptURL(lines: [
            #"{"timestamp":"2026-04-21T01:00:00.000Z","type":"session_meta","payload":{"id":"abc","cwd":"/tmp/project","git":{"branch":"main"},"timestamp":"2026-04-21T01:00:00.000Z"}}"#,
            #"{"timestamp":"2026-04-21T01:00:01.000Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","call_id":"call_shell","arguments":"{\"cmd\":\"git status --short\",\"workdir\":\"/tmp/project\"}"}}"#,
            #"{"timestamp":"2026-04-21T01:00:02.000Z","type":"response_item","payload":{"type":"custom_tool_call","name":"apply_patch","call_id":"call_patch","status":"completed","input":"*** Begin Patch\n*** Update File: Sources/App.swift\n@@\n-old\n+new\n*** End Patch\n"}}"#,
            #"{"timestamp":"2026-04-21T01:00:03.000Z","type":"response_item","payload":{"type":"function_call","name":"_fetch_pr","namespace":"mcp__codex_apps__github","call_id":"call_gh","arguments":"{\"repo_full_name\":\"owner/repo\",\"pr_number\":7}"}}"#,
            #"{"timestamp":"2026-04-21T01:00:04.000Z","type":"response_item","payload":{"type":"web_search_call","status":"completed","action":{"type":"search","query":"Apple notarize dmg"}}}"#
        ])

        let messages = try JSONLParser().parseTimelineMessages(url: url).map { $0.makeMessage() }
        let toolUses = messages.flatMap(\.toolUses)

        let shell = try #require(toolUses.first { $0.id == "call_shell" })
        #expect(shell.name == "Bash")
        #expect(shell.command == "git status --short")

        let edit = try #require(toolUses.first { $0.id == "call_patch" })
        #expect(edit.name == "Edit")
        #expect(edit.filePath == "Sources/App.swift")

        let github = try #require(toolUses.first { $0.id == "call_gh" })
        #expect(github.name == "GitHub fetch_pr")
        #expect(github.inputSummary == "owner/repo#7")

        let webSearch = try #require(toolUses.first { $0.name == "WebSearch" })
        #expect(webSearch.inputSummary == "Apple notarize dmg")
    }

    private func makeCodexTranscriptURL(lines: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026/04/21", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("rollout-test.jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
