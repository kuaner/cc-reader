# Opuswap — Architecture & Specification

## Overview

**Opuswap** is a macOS desktop app for real-time visualization and management of Claude Code session history. It monitors and parses JSONL files under `~/.claude/projects/`, displaying conversation timelines, tool usage, and context information in a rich native UI.

Key capabilities: multi-pane session monitoring, surgical context editing (Surgery Mode), and a built-in terminal.

---

## Tech Stack

| Category | Technology |
|----------|-----------|
| Platform | macOS 14.0+ |
| Language | Swift 5.9 |
| UI | SwiftUI |
| Database | SQLite.swift |
| Terminal | Custom ANSIParser |
| Build | Xcode + XcodeGen (`project.yml`) |

---

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│                      OpuswapApp                          │
│                     (@main Entry)                        │
├──────────────────────────────────────────────────────────┤
│                                                          │
│  ┌──────────────┐  ┌──────────────┐  ┌───────────────┐  │
│  │ ContentView  │  │ LayoutView   │  │ TerminalView  │  │
│  │ (Main UI)    │  │ (Multi-pane) │  │ (Terminal)    │  │
│  └──────┬───────┘  └──────┬───────┘  └───────────────┘  │
│         │                 │                              │
│  ┌──────┴──────────────────┴──────────────────────────┐  │
│  │              Views Layer (SwiftUI)                  │  │
│  │  ProjectListView / SessionMessagesView / MessageRow │  │
│  │  PaneView / ContextPanel / SurgeryToolbar          │  │
│  └────────────────────┬───────────────────────────────┘  │
│                       │                                  │
│  ┌────────────────────┴───────────────────────────────┐  │
│  │             Services Layer                          │  │
│  │  AppCoordinator / SyncService / LayoutManager      │  │
│  │  FileWatcherService / JSONLParser / JSONLWriter     │  │
│  │  TokenEstimator / ConfirmationDetector             │  │
│  │  ExternalTerminalLauncher / IgnoredSessionManager  │  │
│  └────────────────────┬───────────────────────────────┘  │
│                       │                                  │
│  ┌────────────────────┴───────────────────────────────┐  │
│  │             Models Layer                            │  │
│  │  Project / Session / Message / WorkspaceLayout     │  │
│  └────────────────────┬───────────────────────────────┘  │
│                       │                                  │
│  ┌────────────────────┴───────────────────────────────┐  │
│  │             Storage Layer (SQLite.swift)            │  │
│  │  StorageManager / DatabaseSchema                   │  │
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
- `Pane` — `id`, `sessionId?`, `showTerminal`
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
    ├── getOrCreateProject()         ← SQLite upsert
    ├── getOrCreateSession()         ← Merge by matching slug
    └── addMessage()                 ← Create Message + update caches
        │
        ▼
    StorageManager (SQLite.swift → @Published for UI updates)
```

### Surgery Mode Flow

```
User action
    │
    ├── Bulk delete  → JSONLWriter.deleteMessages()      → StorageManager.delete()
    ├── Rewind       → JSONLWriter.deleteMessagesAfter() → StorageManager.delete()
    └── Edit summary → JSONLWriter.updateMessageContent()
        │
        ├── Auto-backup (.bak file)
        └── Direct JSONL file rewrite
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
│   │   ├── ExternalTerminalLauncher.swift  # External terminal launcher
│   │   └── IgnoredSessionManager.swift # Deleted session tracking
│   ├── Storage/
│   │   ├── StorageManager.swift        # SQLite wrapper (@MainActor)
│   │   └── DatabaseSchema.swift        # Table definitions
│   ├── Views/
│   │   ├── ContentView.swift           # Main layout
│   │   ├── Sidebar/
│   │   │   └── ProjectListView.swift   # Project/session list
│   │   ├── Timeline/
│   │   │   ├── SessionMessagesView.swift   # Timeline + Surgery Mode
│   │   │   └── MessageRow.swift        # Message row
│   │   ├── Layout/
│   │   │   ├── LayoutView.swift        # Multi-pane renderer
│   │   │   └── PaneView.swift          # Individual pane
│   │   └── Terminal/
│   │       └── TerminalView.swift      # Built-in ANSI terminal
│   ├── Resources/
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

Messages store the original JSON as `Data` in SQLite, decoded on demand via computed properties. Rationale:
- JSONL structure may change across Claude Code versions
- Surgery Mode requires faithful editing and restoration of original data
- In-memory caching mitigates repeated decoding cost

### Session Merging

Sessions with the same slug but different sessionIds are merged into one. Claude Code's plan mode and subagents generate separate sessionIds. Tracked via `additionalSessionIds`.

### Token Estimation

Uses a simple heuristic (3 characters ≈ 1 token). A tiktoken-equivalent in Swift would be costly to implement, and the approximation is sufficient for relative comparisons in Surgery Mode.

### JSONL Format (Unofficial)

Claude Code's JSONL format is not a public API. The parser handles known structures and gracefully skips unknown fields. See `JSONLParser.swift` and `Message.swift` for the current parsing logic.
