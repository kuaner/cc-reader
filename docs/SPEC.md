# Opuswap — Architecture & Specification

## Overview

**Opuswap** is a macOS desktop app for real-time visualization and management of Claude Code session history. It monitors and parses JSONL files under `~/.claude/projects/`, displaying conversation timelines, tool usage, and context information in a rich native UI.

Key capabilities: multi-pane session monitoring and surgical context editing (Surgery Mode).

---

## Tech Stack

| Category | Technology |
|----------|-----------|
| Platform | macOS 14.0+ |
| Language | Swift 5.9 |
| UI | SwiftUI + WKWebView (Timeline rendering) |
| Persistence | SwiftData (ModelContainer) |
| Build | Xcode + XcodeGen (`project.yml`) |

---

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│                      OpuswapApp                          │
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
│  │  TimelineHostView (WKWebView) / ContextPanel       │  │
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
| `needsAttention` | `Bool` | Unread response flag |
| `cachedTurnCount` | `Int` | User turn count cache |
| `cachedTitle` | `String?` | Session title cache |

**Computed:**
- `displayTitle` — Priority: slug > cachedTitle > timestamp
- `jsonlFileURL` — Path to the corresponding JSONL file

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
    │ incrementalSync(fileURL:)
    ▼
SyncService
    │
    ├── JSONLParser.parseNewLines()  ← Read delta from file offset
    │
    ├── getOrCreateProject()         ← SwiftData upsert
    ├── getOrCreateSession()         ← Merge by matching slug
    └── addMessage()                 ← Create Message + update caches
        │
        ▼
    SwiftData ModelContext (drives @Query updates)
```

### Surgery Mode Flow

```
User action
    │
    ├── Bulk delete  → JSONLWriter.deleteMessages()      → SwiftData delete/save
    ├── Rewind       → JSONLWriter.deleteMessagesAfter() → SwiftData delete/save
    └── Edit summary → JSONLWriter.updateMessageContent()
        │
        ├── Auto-backup (.bak file)
        └── Direct JSONL file rewrite

### Timeline Render Flow

```
SwiftData Message (@Query)
    ↓
SessionMessagesView.rebuildDerivedData()
    ↓
TimelineRenderSnapshot / TimelineMessageDisplayData (value snapshots)
    ↓
TimelineHostView (single WKWebView)
    ├── Windowed rendering (recent batch, default 200)
    ├── Auto-load older messages near top (+ manual fallback action)
    ├── Markdown progressive enhancement (marked.min.js)
    ├── Syntax highlight (highlight.js, bundled)
    └── Per-message copy actions (user/assistant)
```
```

---

## Directory Structure

```
Opuswap/
├── Opuswap/
│   ├── OpuswapApp.swift                # @main entry point
│   ├── Models/
│   │   ├── Project.swift               # Project model
│   │   ├── Session.swift               # Session model
│   │   ├── Message.swift               # Message model + JSON structs
│   │   └── WorkspaceLayout.swift       # Layout model (value type)
│   ├── Services/
│   │   ├── AppCoordinator.swift        # App lifecycle management
│   │   ├── SyncService.swift           # JSONL sync service
│   │   ├── JSONLParser.swift           # Incremental JSONL parser
│   │   ├── JSONLWriter.swift           # JSONL writer (Surgery Mode)
│   │   ├── FileWatcherService.swift    # FSEvents file watcher
│   │   ├── LayoutManager.swift         # Pane layout management
│   │   ├── TokenEstimator.swift        # Token count estimator
│   │   ├── ConfirmationDetector.swift  # Confirmation request detection
│   │   └── IgnoredSessionManager.swift # Deleted session tracking
│   ├── Storage/
│   │   ├── StorageManager.swift        # SQLite wrapper (@MainActor)
│   │   └── DatabaseSchema.swift        # Table definitions
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
│   │   └── Assets.xcassets/
│   └── Opuswap.entitlements
├── Opuswap.xcodeproj/
├── project.yml                         # XcodeGen config
└── docs/
    └── SPEC.md                         # This document
```

---

## Design Decisions

### Raw JSON Preservation

Messages store the original JSON as `Data` in SwiftData, decoded on demand via computed properties. Rationale:
- JSONL structure may change across Claude Code versions
- Surgery Mode requires faithful editing and restoration of original data
- In-memory caching mitigates repeated decoding cost

### Session Merging

Sessions with the same slug but different sessionIds are merged into one. Claude Code's plan mode and subagents generate separate sessionIds. Tracked via `additionalSessionIds`.

### Timeline Rendering Strategy

The timeline is rendered in a single `WKWebView` instead of a SwiftUI row-by-row list.

Rationale:
- More stable scrolling for very long conversations
- Better handling for large Markdown/code content
- Clear render boundary via value snapshots (`TimelineRenderSnapshot`)
- Progressive enhancement fallback (plain text first, then markdown/highlight)

### Token Estimation

Uses a simple heuristic (3 characters ≈ 1 token). A tiktoken-equivalent in Swift would be costly to implement, and the approximation is sufficient for relative comparisons in Surgery Mode.

### JSONL Format (Unofficial)

Claude Code's JSONL format is not a public API. The parser handles known structures and gracefully skips unknown fields. See `JSONLParser.swift` and `Message.swift` for the current parsing logic.
