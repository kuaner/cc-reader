# Adding a Transcript Parser

This document describes how to add a new transcript source, for example another local agent that writes JSONL session logs.

The current architecture is intentionally small: provider-specific logic should live in one `SessionTranscriptParser` implementation, then be registered once. Sync, file watching, sidebar filtering, and timeline rendering should continue to use normalized `Session` / `Message` data.

## Parser Contract

Add a parser when the new source has a different directory layout or JSONL shape from Claude/Codex.

Every parser must implement:

| API | Purpose |
|-----|---------|
| `source` | Stable provider id stored on `Session.source` |
| `rootPath` | Directory watched by `FileWatcherService` and scanned at startup |
| `matches(_:)` | Returns true for files owned by this provider |
| `sessionId(from:)` | Returns a stable app-wide unique session id |
| `readMetadata(from:)` | Cheap metadata read used during first-launch indexing |
| `parseLine(_:sourceURL:)` | Converts one provider JSONL line into normalized `RawMessageData` |

The key rule: `readMetadata` must stay cheap. It should usually read the first line, a small sidecar file, or a known metadata entry. Do not parse the whole transcript there.

## Implementation Steps

1. Add a new source case in `SessionTranscriptSource`.

```swift
enum SessionTranscriptSource: String, Sendable {
    case claude
    case codex
    case myAgent
}
```

2. Create a parser file under `CCReader/Services/`, for example `MyAgentTranscriptParser.swift`.

```swift
import Foundation

struct MyAgentTranscriptParser: SessionTranscriptParser {
    var source: SessionTranscriptSource { .myAgent }

    var rootPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.my-agent/sessions"
    }

    func matches(_ url: URL) -> Bool {
        url.path.contains("/.my-agent/sessions/")
    }

    func sessionId(from url: URL) -> String? {
        let filename = url.deletingPathExtension().lastPathComponent
        return filename.isEmpty ? nil : "myagent-\(filename)"
    }

    func readMetadata(from url: URL) -> SessionTranscriptMetadata? {
        // Keep this cheap. Prefer one metadata line over full-file parsing.
        nil
    }

    func parseLine(_ lineData: Data, sourceURL: URL) -> RawMessageData? {
        // Decode one provider-specific JSONL event and normalize it.
        nil
    }
}
```

3. Register the parser in `SessionTranscriptParserRegistry.shared`.

```swift
static let shared = SessionTranscriptParserRegistry(parsers: [
    MyAgentTranscriptParser(),
    CodexTranscriptParser(),
    ClaudeTranscriptParser()
])
```

Parser order matters if two `matches(_:)` implementations can match the same path. Put the more specific parser first.

4. Add the new file to the build.

If the project file is generated from `project.yml`, run:

```bash
make gen
```

Then confirm the new Swift file appears in `CCReader.xcodeproj/project.pbxproj` if the project file is committed.

5. Add localization/UI source labels if needed.

Today the sidebar scope control and pane source badge know about Claude and Codex. If the new provider should be user-selectable as a separate tab, update the source filter UI in:

- `CCReader/Views/Sidebar/SessionSidebarView.swift`
- `CCReader/Views/Sidebar/SessionPickerView.swift`
- `CCReader/Views/Layout/PaneView.swift`

For a third source, avoid adding more one-off `if source == ...` checks. Prefer converting source display metadata into a small helper, for example:

```swift
struct SessionSourcePresentation {
    let title: String
    let icon: String
    let resumeCommandPrefix: String?
}
```

## Normalization Rules

`parseLine` should map provider events into `RawMessageData` so the rest of the app can stay provider-neutral.

Use these conventions:

- User text becomes `RawMessageData(type: "user", message.role: "user")`.
- Assistant text becomes `RawMessageData(type: "assistant", message.role: "assistant")`.
- Thinking/reasoning becomes an assistant message with a `ContentBlock(type: "thinking", thinking: text)`.
- Tool calls become assistant messages with `ContentBlock(type: "tool_use", ...)`.
- Tool outputs become user messages with `ContentBlock(type: "tool_result", ...)`.
- Metadata-only lines can become system entries when sync needs them, or return `nil` when they are not useful.
- Unknown provider events should return `nil`, not throw.

Preserve the original JSON line whenever possible:

```swift
var raw = RawMessageData(...)
raw.originalLineData = lineData
return raw
```

This matters because `Message.rawJson` is intentionally preserved for future parser changes and debugging.

## Stable IDs

Session ids and message UUIDs must be stable across app launches.

For sessions:

- Prefix provider ids when the provider can collide with Claude/Codex ids, for example `myagent-<id>`.
- Prefer an id from transcript metadata over a filename if the filename can change.
- Keep `Session.transcriptPath` set through sync; do not assume `project + sessionId` can reconstruct the file path.

For messages:

- Use a provider event id when available.
- If there is no event id, derive one from the source file, timestamp, event kind, and a content fingerprint.
- Avoid random UUIDs in parsers. Random ids break deduplication and incremental timeline updates.

See `CodexTranscriptParser.stableUUID(...)` for the current pattern.

## Metadata and First-Launch Performance

First launch uses `SyncService.initialSync()` to create lightweight `Session` rows. It calls:

```swift
SessionTranscriptParserRegistry.shared.parser(for: fileURL)
parser.sessionId(from: fileURL)
parser.readMetadata(from: fileURL)
```

This path must not scan entire large transcripts. If a provider has no cheap metadata, return `nil` and let `warmupSessionMetadata()` / timeline parsing fill details later.

`warmupSessionMetadata()` runs newest-first, so a parser should make recently modified files useful quickly without blocking on old sessions.

## File Watching

`FileWatcherService` automatically watches every registered `rootPath`.

No watcher changes are needed if:

- `rootPath` points to the top-level directory containing provider JSONL files.
- Provider session files use the `.jsonl` extension.
- `matches(_:)` returns true for those files.

If a provider does not use `.jsonl`, update `FileWatcherService.existingJSONLFiles()` and the FSEvents callback naming/filters. Prefer generalizing the method names at the same time.

## Timeline and Context Panel

The timeline reads normalized `Message` computed properties, not provider events directly. If the parser fills common fields correctly, most UI works without changes.

Fields that improve the context panel:

- `ToolUse.name`
- `ToolUse.filePath`
- `ToolUse.command`
- `ToolUse.inputSummary`
- `ToolUse.rawInput`
- `ToolResult.toolUseId`
- `ToolResult.content`
- `ToolResult.isError`

Map provider-specific tool names to UI names when it improves readability. For example Codex maps shell execution to `Bash`, patch application to `Edit`, and web search to `WebSearch`.

## Resume Commands

If the provider has a resume command, add it to the pane toolbar behavior. Current behavior:

- Claude: `claude --resume <sessionId>`
- Codex: `codex resume <sessionId>`

For additional providers, do not keep expanding conditional UI logic. Move resume command generation behind a source presentation/helper first, then add the provider there.

## Tests

Add parser tests under `Tests/CCReaderKitTests/`.

Minimum test coverage:

- `sessionId(from:)` returns a stable prefixed id.
- `readMetadata(from:)` extracts cwd/branch/model/timestamp without full parsing.
- User and assistant messages normalize into timeline messages.
- Tool calls and tool outputs populate fields used by the context panel.
- Unknown event lines are skipped safely.

Run:

```bash
swift test
swift build
git diff --check
```

If the parser adds Xcode project files or resources, also run:

```bash
make build
```

## Checklist

- Add `SessionTranscriptSource` case.
- Implement `SessionTranscriptParser`.
- Register the parser in `SessionTranscriptParserRegistry.shared`.
- Keep `readMetadata` cheap.
- Use stable session ids and message UUIDs.
- Preserve raw JSON line data where possible.
- Add source UI/resume presentation only if the provider should be visible as a separate source.
- Add parser tests.
- Update `docs/SPEC.md` and this guide if the parser requires new architecture behavior.
