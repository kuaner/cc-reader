# Opuswap

English | [日本語](README.ja.md) | [简体中文](README.zh-Hans.md)

A macOS app for real-time visualization and management of [Claude Code](https://docs.anthropic.com/en/docs/claude-code) session history.

Monitors JSONL files under `~/.claude/projects/` and displays conversation timelines, thinking processes, and tool usage in a rich native UI.

> **⚠️ Disclaimer**
> This is an **unofficial** third-party tool. Claude Code's JSONL format is not a public API and may change without notice. Surgery Mode directly edits session files — **use at your own risk**. Always keep backups.

## Features

- **Session Viewer** — Timeline display of thinking / tool use / diffs with syntax highlighting
- **Real-time Sync** — FSEvents file monitoring with incremental JSONL parsing
- **Multi-pane Layout** — Up to 12 panes for simultaneous session monitoring
- **Surgery Mode** — Directly edit JSONL to optimize context tokens (bulk delete, rollback, summary editing)
- **Context Panel** — View Claude's understanding, loaded/edited files at a glance

## Requirements

- macOS 14.0+
- Xcode 15.0+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## Getting Started

```bash
# Install XcodeGen if needed
brew install xcodegen

# Clone and build
git clone https://github.com/Mutafika/Opuswap.git
cd Opuswap
xcodegen
open Opuswap.xcodeproj
```

Build & Run with `Cmd + R` in Xcode.

## Tech Stack

| Category | Technology |
|----------|-----------|
| UI | SwiftUI |
| Database | [SQLite.swift](https://github.com/nicklama/SQLite.swift) |
| File Watching | FSEvents |
| Build | XcodeGen (`project.yml`) |

## Architecture

```
Data Source: ~/.claude/projects/**/*.jsonl
    ↓ FSEvents
FileWatcherService → SyncService → JSONLParser (incremental)
    ↓
StorageManager (SQLite.swift)
    ↓
SwiftUI Views (ContentView / LayoutView)
```

See [docs/SPEC.md](docs/SPEC.md) for the full specification.

## Documentation

- [Architecture & Specification](docs/SPEC.md)

## License

[MIT](LICENSE)
