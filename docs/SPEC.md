# cc-reader — Architecture & Specification

## Overview

**cc-reader** is a macOS desktop app for reading and managing Claude Code session history. It monitors and parses JSONL files under `~/.claude/projects/`, displaying conversation timelines, tool usage, thinking/context information, and session metadata in a native UI optimized for long sessions.

Key capabilities: multi-pane session monitoring, real-time incremental sync, sidebar-based session management, and a single-WKWebView timeline tuned for large histories.

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
│  ┌──────────────┐  ┌──────────────┐                      │
│  │ ContentView  │  │ LayoutView   │                      │
│  │ (Main UI)    │  │ (Multi-pane) │                      │
│  └──────┬───────┘  └──────┬───────┘                      │
│         │                 │                               │
│  ┌──────┴──────────────────┴──────────────────────────┐  │
│  │              Views Layer (SwiftUI)                  │  │
│  │  ProjectListView / SessionMessagesView / PaneView  │  │
│  │  TimelineHostView / MarkdownRenderView             │  │
│  │  ContextPanel / LayoutView                         │  │
│  └────────────────────┬───────────────────────────────┘  │
│                       │                                  │
│  ┌────────────────────┴───────────────────────────────┐  │
│  │             Services Layer                          │  │
│  │  AppCoordinator / SyncService / LayoutManager      │  │
│  │  FileWatcherService / JSONLParser / JSONLWriter     │  │
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
│  │  ~/.claude/projects/**/*.jsonl (FSEvents)          │  │
│  └────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────┘
```

---

## Data Models

### Project

Represents a project directory under `~/.claude/projects/`.

| Field | Type | Description |
|-------|------|-------------|
| `path` | `String` (unique) | Directory name (`-Users-yourname-projects-...`) |
| `displayName` | `String` | Display name |
| `sessions` | `[Session]` | Sessions under this project |
| `createdAt` | `Date` | Created timestamp |
| `updatedAt` | `Date` | Last updated timestamp |

### Session

Represents a single Claude Code session (one JSONL file).

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

**Computed:**
- `displayTitle` — Priority: slug > cachedTitle > timestamp
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
- `toolUses` — Tool calls (name, filePath, command, oldString, newString)
- `toolResults` — Tool execution results
- `toolUseResultsWithPatch` — Structured patches for Edit diffs

**Behavioral Notes:**
- Decoding is lazy and cached in transient in-memory fields
- `preload()` is used to shift decoding work out of critical scrolling paths

### WorkspaceLayout (Value Type)

Recursive tree structure for multi-pane layout. Persisted in UserDefaults.

- `LayoutNode` — `.pane(Pane)` / `.split(direction, first, second, ratio)`
- `Pane` — `id`, `sessionId?`
- `SplitDirection` — `.horizontal` / `.vertical`
- Presets: `single`, `twoColumn`, `grid2x2`, `grid(columns:rows:)`

---

## Data Flow

### Sync Flow

```
~/.claude/projects/**/*.jsonl
    │
    │ FSEvents
    ▼
FileWatcherService
    │
    │ Callback (debounce 0.5s)
    ▼
AppCoordinator
    │
    ├── fullSync()          ← First launch imports only sessions not yet in SwiftData
    └── incrementalSync()   ← File watcher / manual refresh path
    ▼
SyncService
    │
    ├── JSONLParser.parseFile()      ← Initial import path
    ├── JSONLParser.parseNewLines()  ← Read delta from file offset
    │
    ├── getOrCreateProject()         ← SwiftData upsert
    ├── getOrCreateSession()         ← Merge by matching slug
    └── addMessageWithoutCheck()     ← Create Message + update caches
        │
        ▼
    SwiftData ModelContext (drives @Query updates)
```

Notes:
- Full sync intentionally imports only sessions that do not already exist in the local database.
- Incremental sync relies on per-file offsets stored in `JSONLParser`.
- Session merges are based on matching `slug` within the same project path.

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
    └── Written files
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
│   │   ├── JSONLParser.swift           # Incremental JSONL parser
│   │   ├── JSONLWriter.swift           # JSONL writer utilities
│   │   ├── FileWatcherService.swift    # FSEvents file watcher
│   │   ├── LayoutManager.swift         # Pane layout management
│   │   ├── TokenEstimator.swift        # Token count estimator
│   │   ├── ConfirmationDetector.swift  # Confirmation request detection
│   │   └── IgnoredSessionManager.swift # Deleted session tracking
│   ├── Views/
│   │   ├── ContentView.swift           # Main layout
│   │   ├── Sidebar/
│   │   │   └── ProjectListView.swift   # Project/session list
│   │   ├── Timeline/
│   │   │   ├── SessionMessagesView.swift   # Timeline orchestration + Context panel
│   │   │   ├── TimelineHostView.swift      # Single WKWebView timeline host
│   │   │   ├── TimelineModels.swift        # Value snapshots for rendering boundary
│   │   │   ├── MarkdownRenderView.swift    # Markdown preview WebView
│   │   │   └── WebRenderAssets.swift       # Bundled JS/CSS loaders and web chrome
│   │   └── Layout/
│   │       ├── LayoutView.swift        # Multi-pane renderer
│   │       └── PaneView.swift          # Individual pane
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
    └── SPEC.md                         # This document
```

---

## Design Decisions

### Raw JSON Preservation

Messages store the original JSON as `Data` in SwiftData, decoded on demand via computed properties. Rationale:
- JSONL structure may change across Claude Code versions
- Local file editing features require faithful editing and restoration of original data
- In-memory caching mitigates repeated decoding cost

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

### JSONL Format (Unofficial)

Claude Code's JSONL format is not a public API. The parser handles known structures and gracefully skips unknown fields. See `JSONLParser.swift` and `Message.swift` for the current parsing logic.
