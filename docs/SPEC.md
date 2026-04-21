# cc-reader — Architecture & Specification

## Overview

**cc-reader** is a macOS desktop app for reading and managing Claude Code and Codex session history. It monitors and parses JSONL files under `~/.claude/projects/` and `~/.codex/sessions/`, displaying conversation timelines, tool usage, thinking/context information, and session metadata in a native UI optimized for long sessions.

Key capabilities: multi-tab & multi-pane session monitoring, source-separated Claude/Codex session lists, lightweight first-launch indexing, real-time incremental sync, sidebar-based session management, and a single-WKWebView timeline tuned for large histories.

---

## Tech Stack

| Category | Technology |
|----------|-----------|
| Platform | macOS 14.0+ |
| Language | Swift 5.9 |
| UI | SwiftUI + WKWebView (timeline + markdown preview) |
| Persistence | SwiftData (ModelContainer) |
| Web Rendering | marked.js + highlight.js (bundled locally) |
| File Watching | FSEvents |
| Build | Xcode + XcodeGen (`project.yml`) |

---

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│                      CCReaderApp                         │
│                     (@main Entry)                        │
├──────────────────────────────────────────────────────────┤
│                                                          │
│  ┌──────────────────────────────────────────────────┐    │
│  │  ContentView (per-tab) ← @SceneStorage persistence│    │
│  │  ├── NavigationSplitView (sidebar)                │    │
│  │  └── LayoutView ← LayoutManager (pane tree)       │    │
│  │      ├── PaneView ── SessionMessagesView           │    │
│  │      │              └── TimelineHostView           │    │
│  │      └── PaneView ── ...                           │    │
│  └──────────────────────┬───────────────────────────┘    │
│                         │                                 │
│  ┌──────────────────────┴───────────────────────────┐    │
│  │              Views Layer (SwiftUI)                │    │
│  │  ProjectListView / SessionPickerView / PaneView  │    │
│  │  SessionMessagesView / TimelineHostView          │    │
│  │  ContextPanel / LayoutView / ResizableSplitView  │    │
│  └────────────────────┬─────────────────────────────┘    │
│                       │                                  │
│  ┌────────────────────┴───────────────────────────────┐  │
│  │             Services Layer                          │  │
│  │  AppCoordinator / SyncService / LayoutManager      │  │
│  │  FileWatcherService / SessionTranscriptParser       │  │
│  │  JSONLParser / JSONLWriter                          │  │
│  │  TokenEstimator / ConfirmationDetector             │  │
│  │  IgnoredSessionManager                             │  │
│  └────────────────────┬───────────────────────────────┘  │
│                       │                                  │
│  ┌────────────────────┴───────────────────────────────┐  │
│  │             Models Layer (SwiftData)               │  │
│  │  Project / Session / Message / WorkspaceLayout     │  │
│  └────────────────────┬───────────────────────────────┘  │
│                       │                                  │
│  ┌────────────────────┴───────────────────────────────┐  │
│  │             Data Source                             │  │
│  │  ~/.claude/projects/**/*.jsonl                      │  │
│  │  ~/.codex/sessions/**/*.jsonl      (FSEvents)       │  │
│  └────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────┘
```

---

## Data Models

### Project

Represents a logical project/workspace. For Claude sessions this is derived from the directory under `~/.claude/projects/`; for Codex sessions it is derived from parsed metadata when available, falling back to the transcript location.

| Field | Type | Description |
|-------|------|-------------|
| `path` | `String` (unique) | Directory name (`-Users-yourname-projects-...`) |
| `displayName` | `String` | Display name |
| `sessions` | `[Session]` | Sessions under this project |
| `createdAt` | `Date` | Created timestamp |
| `updatedAt` | `Date` | Last updated timestamp |

### Session

Represents a single assistant session (one JSONL file).

| Field | Type | Description |
|-------|------|-------------|
| `sessionId` | `String` (unique) | UUID |
| `slug` | `String?` | Session name (`streamed-skipping-tarjan`) |
| `additionalSessionIds` | `[String]` | Merged session IDs (plan/subagent) |
| `cwd` | `String` | Working directory |
| `gitBranch` | `String?` | Git branch name |
| `startedAt` | `Date` | Session start time |
| `updatedAt` | `Date` | Last updated time |
| `isCompacted` | `Bool` | Auto-compaction detected |
| `lastUserMessageAt` | `Date?` | Latest user message timestamp |
| `needsAttention` | `Bool` | Unread response flag |
| `cachedTurnCount` | `Int` | User turn count cache |
| `cachedTitle` | `String?` | Session title cache |
| `cachedUnacknowledgedCount` | `Int` | Cached unread assistant count |
| `source` | `String?` | Transcript provider, for example `claude` or `codex` |
| `transcriptPath` | `String?` | Absolute JSONL path; needed because sources are not all derivable from project + id |

**Computed:**
- `displayTitle` — Priority: custom title > slug > cached title > AI title > timestamp/session id
- `jsonlFileURL` — Path to the corresponding JSONL file
- `unacknowledgedCount` — UI-facing unread assistant count

### Message

Represents a single line in the JSONL file. Stores the original JSON in `rawJson` and decodes on demand via computed properties.

| Field | Type | Description |
|-------|------|-------------|
| `uuid` | `String` (unique) | Message UUID |
| `parentUuid` | `String?` | Parent message UUID |
| `type` | `MessageType` | `.user` / `.assistant` |
| `timestamp` | `Date` | Timestamp |
| `rawJson` | `Data` | Original JSON blob |

**Computed (decoded from rawJson):**
- `thinking` — Assistant's thinking process
- `content` — Text body
- `model` — Model name
- `toolUses` — Tool calls (name, filePath, command, oldString, newString, inputSummary)
- `toolResults` — Tool execution results
- `toolUseResultsWithPatch` — Structured patches for Edit diffs

**Behavioral Notes:**
- Decoding is lazy and cached in transient in-memory fields
- `preload()` is used to shift decoding work out of critical scrolling paths

### WorkspaceLayout (Value Type)

Recursive tree structure for multi-pane layout. Persisted per-tab via `@SceneStorage` (JSON-encoded). See [docs/layout-system.md](layout-system.md) for full details.

- `LayoutNode` — `.pane(Pane)` / `.split(direction, first, second, ratio)`
- `Pane` — `id`, `sessionId?`
- `SplitDirection` — `.horizontal` / `.vertical`
- Presets: `single`, `twoColumn`, `grid2x2`, `grid(columns:rows:)`

---

## Data Flow

### Sync Flow

```
~/.claude/projects/**/*.jsonl
~/.codex/sessions/**/*.jsonl
    │
    │ FSEvents
    ▼
FileWatcherService
    │
    │ Callback (debounce 0.5s)
    ▼
AppCoordinator
    │
    ├── initialSync()             ← First launch creates lightweight session rows only
    ├── warmupSessionMetadata()   ← Background metadata warmup, newest files first
    └── incrementalSync()         ← File watcher / manual refresh path
    ▼
SyncService
    │
    ├── SessionTranscriptParserRegistry
    │   ├── ClaudeTranscriptParser
    │   └── CodexTranscriptParser
    │
    ├── ensureSessionIndex()         ← Create/update lightweight rows from paths + cheap metadata
    ├── rebuildSessionIndex()        ← Parse one changed/opened file to refresh metadata caches
    ├── JSONLParser.parseFile()      ← Uses the registered parser for each transcript source
    │
    ├── getOrCreateProject()         ← SwiftData upsert
    ├── getOrCreateSession()         ← Merge Claude sessions by matching slug where applicable
    └── updateSessionCaches()        ← Refresh title/turn/unread/context metadata
        │
        ▼
    SwiftData ModelContext (drives @Query updates)
```

Notes:
- First launch does not parse every message from every transcript. It indexes session rows from file paths and cheap metadata so the sidebar can appear quickly.
- Metadata warmup is intentionally ordered by file modification time descending so recent/visible sessions become useful first.
- Message rows are parsed for a session when the timeline needs them, or when a changed file must refresh its index.
- Transcript source handling is centralized through `SessionTranscriptParserRegistry`; Codex-specific parsing should live in `CodexTranscriptParser`, not as scattered conditionals in UI or sync code.
- Session merges are based on matching `slug` within the same project path for Claude-style sessions.

### Timeline Render Flow

```
SwiftData Message (@Query)
    ↓
SessionMessagesView.rebuildDerivedData()
    ↓
TimelineRenderSnapshot / TimelineMessageDisplayData / ContextPanelSnapshot
    ↓
TimelineHostView (single WKWebView)
    ├── Windowed rendering (recent batch, default 200)
    ├── Auto-load older messages near top (+ manual fallback action)
    ├── Markdown progressive enhancement (marked.min.js)
    ├── Syntax highlight (highlight.js, bundled)
    ├── Per-message copy actions (user/assistant)
    └── Scroll-follow state bridged through a custom URL scheme

ContextPanel
    ├── Latest thinking summary
    ├── Read files
    ├── Edited files
    ├── Written files
    ├── Executed commands
    ├── Searches
    └── Other tools
```

### Local File Mutation Flow

```
User session-management action
    │
    ├── Rename session        → Update Session.slug / Session.isSlugManual
    ├── Delete session        → Remove JSONL + .bak + delete SwiftData rows
    ├── Bulk delete sessions  → Same as delete, across selected rows
    └── Restore / edit helpers → JSONLWriter backup / restore / rewrite helpers
```

---

## Directory Structure

```
cc-reader/
├── CCReader/
│   ├── CCReaderApp.swift               # @main entry point
│   ├── Models/
│   │   ├── Project.swift               # Project model
│   │   ├── Session.swift               # Session model
│   │   ├── Message.swift               # Message model + JSON structs
│   │   └── WorkspaceLayout.swift       # Layout model (value type)
│   ├── Services/
│   │   ├── AppCoordinator.swift        # App lifecycle management
│   │   ├── SyncService.swift           # JSONL sync service
│   │   ├── SessionTranscriptParser.swift # Source parser protocol, registry, Claude parser
│   │   ├── CodexTranscriptParser.swift # Codex JSONL adapter/parser
│   │   ├── JSONLParser.swift           # Source-aware JSONL parser
│   │   ├── JSONLWriter.swift           # JSONL writer utilities
│   │   ├── FileWatcherService.swift    # FSEvents file watcher
│   │   ├── LayoutManager.swift         # Per-window pane tree + split/focus/assign
│   │   ├── TokenEstimator.swift        # Token count estimator
│   │   ├── ConfirmationDetector.swift  # Confirmation request detection
│   │   └── IgnoredSessionManager.swift # Deleted session tracking
│   ├── Views/
│   │   ├── ContentView.swift           # Per-tab root (NavigationSplitView + persistence)
│   │   ├── Sidebar/
│   │   │   ├── ProjectListView.swift   # Session list sidebar
│   │   │   └── SessionPickerView.swift # Session search/assign picker sheet
│   │   ├── Timeline/
│   │   │   ├── SessionMessagesView.swift   # Timeline orchestration + Context panel
│   │   │   ├── TimelineHostView.swift      # Single WKWebView timeline host
│   │   │   ├── TimelineModels.swift        # Value snapshots for rendering boundary
│   │   │   ├── MarkdownRenderView.swift    # Markdown preview WebView
│   │   │   └── WebRenderAssets.swift       # Bundled JS/CSS loaders and web chrome
│   │   └── Layout/
│   │       ├── LayoutView.swift        # Recursive pane tree renderer
│   │       └── PaneView.swift          # Individual pane (header + timeline)
│   ├── Resources/
│   │   ├── marked.min.js
│   │   ├── highlight.min.js
│   │   ├── highlight-light.css
│   │   ├── highlight-dark.css
│   │   ├── en.lproj/Localizable.strings
│   │   ├── ja.lproj/Localizable.strings
│   │   ├── zh-Hans.lproj/Localizable.strings
│   │   └── Assets.xcassets/
│   └── CCReader.entitlements
├── CCReader.xcodeproj/
├── project.yml                         # XcodeGen config
└── docs/
    ├── SPEC.md                         # This document
    ├── adding-transcript-parser.md     # How to add a new transcript source/parser
    ├── layout-system.md                # Multi-tab/pane layout system design
    ├── timeline-incremental-dom.md     # Incremental DOM update strategy
    ├── timeline-rendering-architecture.md
    └── timeline-scroll-optimization-notes.md
```

---

## Design Decisions

### Raw JSON Preservation

Messages store the original JSON as `Data` in SwiftData, decoded on demand via computed properties. Rationale:
- JSONL structure may change across Claude Code or Codex versions
- Local file editing features require faithful editing and restoration of original data
- In-memory caching mitigates repeated decoding cost

### Transcript Source Abstraction

Claude and Codex use different JSONL shapes and directory layouts. Source-specific logic is isolated behind `SessionTranscriptParser`:

- `ClaudeTranscriptParser` handles `~/.claude/projects/**/*.jsonl`.
- `CodexTranscriptParser` handles `~/.codex/sessions/**/*.jsonl`.
- `SessionTranscriptParserRegistry` provides root paths for file watching and picks the parser for a URL.

This keeps sync, timeline rendering, and sidebar UI working with normalized `Session` / `Message` models instead of branching on transcript provider throughout the codebase.

### Session Merging

Sessions with the same slug but different sessionIds are merged into one. Claude Code's plan mode and subagents can generate separate sessionIds for work that still belongs to the same logical thread. Merged IDs are tracked in `additionalSessionIds`.

### Timeline Rendering Strategy

The timeline is rendered in a single `WKWebView` instead of a SwiftUI row-by-row list.

Rationale:
- More stable scrolling for very long conversations
- Better handling for large Markdown/code content
- Clear render boundary via value snapshots (`TimelineRenderSnapshot`)
- Progressive enhancement fallback (plain text first, then markdown/highlight)
- Web-layer enhancements can be shared with markdown preview rendering

### Snapshot Boundary

`SessionMessagesView` converts `Message` models into value snapshots before rendering:

- `TimelineMessageDisplayData` carries decoded per-message UI payload
- `TimelineRenderSnapshot` carries visible rows plus derived patch/context maps
- `ContextPanelSnapshot` isolates the side panel from live model decoding

This keeps `WKWebView` updates and SwiftUI updates driven by plain values instead of directly traversing live SwiftData objects during render.

### Token Estimation

Uses a simple heuristic (4 bytes ≈ 1 token). A tokenizer equivalent to Anthropic's production behavior would be costly to maintain in Swift, and the approximation is sufficient for relative comparisons in the UI.

### Lightweight Indexing

The sidebar should not require a full transcript import. `initialSync()` creates or updates lightweight `Session` rows from file paths and cheap metadata. `warmupSessionMetadata()` then refreshes richer metadata in newest-first order, and timeline parsing happens on demand.

This avoids first-launch stalls when hundreds of sessions exist locally while still allowing the visible/recent list to become informative quickly.

### JSONL Format (Unofficial)

Claude Code and Codex JSONL formats are not public APIs. Parsers handle known structures and gracefully skip unknown fields. See `SessionTranscriptParser.swift`, `CodexTranscriptParser.swift`, `JSONLParser.swift`, and `Message.swift` for the current parsing logic.
