# cc-reader

English | [日本語](README.ja.md) | [简体中文](README.zh-Hans.md)

A macOS app for reading and managing [Claude Code](https://docs.anthropic.com/en/docs/claude-code) session history.

Monitors JSONL files under `~/.claude/projects/` and displays conversation timelines, thinking processes, and tool usage in a rich native UI.

![cc-reader demo](assets/screenshot.gif)

> **⚠️ Disclaimer**
> This is an **unofficial** third-party tool. Claude Code's JSONL format is not a public API and may change without notice. Some management actions may modify local session files. Always keep backups.

## Features

- **Session Reader** — WKWebView timeline with markdown rendering, syntax highlighting, code block tools, and per-message copy actions
- **Real-time Sync** — FSEvents file monitoring with incremental JSONL parsing
- **Session Management** — Rename or delete sessions from the sidebar
- **Multi-pane Layout** — Up to 12 panes for simultaneous session monitoring
- **Context Panel** — View Claude's understanding, loaded/edited files at a glance
- **Long Timeline Optimization** — Windowed rendering + near-top auto-load for older messages

## Requirements

- macOS 14.0+
- Xcode 15.0+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## Getting Started

```bash
# Install XcodeGen if needed
brew install xcodegen

# Clone and build
git clone https://github.com/kuaner/cc-reader.git
cd cc-reader
xcodegen
open CCReader.xcodeproj
```

Build & Run with `Cmd + R` in Xcode.

## Local Build Commands

The repository includes a root [Makefile](Makefile) for local builds, universal binaries, and packaging.

```bash
# Generate the Xcode project
make gen

# Build universal Debug / Release apps
make debug
make release

# Open the built app
make run CONFIG=Release

# Package Release as a DMG
make dmg
```

Default output locations:

- App bundle: `build/DerivedData/Build/Products/Release/CC Reader.app`
- DMG: `build/cc-reader.dmg`

The Makefile builds universal macOS binaries by default (`arm64` + `x86_64`).

## Release Flow

Version updates and tagging are handled locally through the Makefile.

```bash
# Update project.yml marketing version
make version VERSION=1.0.0 BUILD_NUMBER=2

# Update version metadata, create a release commit, and tag it as v1.0.0
make release-tag VERSION=1.0.0 BUILD_NUMBER=2

# Do the same and push branch + tag to GitHub
make publish VERSION=1.0.0 BUILD_NUMBER=2
```

`make publish` pushes the release tag to GitHub, which triggers the release workflow. The workflow builds a universal Release app, packages it as a DMG, and uploads it to GitHub Releases.

## Swift Package (CCReaderKit)

cc-reader can also be embedded in other macOS apps as a Swift Package.

### Add Dependency

In Xcode: **File → Add Package Dependencies…** → enter the repository URL:

```
https://github.com/kuaner/cc-reader.git
```

Or add it to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/kuaner/cc-reader.git", from: "0.1.0"),
]
```

Then add `CCReaderKit` to your target:

```swift
.target(
    name: "YourApp",
    dependencies: [
        .product(name: "CCReaderKit", package: "cc-reader"),
    ]
)
```

### Usage

#### Quick Start — Standalone Window

The simplest way to open CC Reader — one line of code:

```swift
import CCReaderKit

CCReaderKit.open()
```

The window is managed as a singleton and reuses the existing instance on subsequent calls.

#### Full Integration — NSWindow with Toolbar

For apps that need full control over window lifecycle (e.g., menu bar apps), create and manage the `NSWindow` yourself using `CCReaderKit.makeView()`:

```swift
import SwiftUI
import CCReaderKit

class AppDelegate: NSObject, NSApplicationDelegate {
    private var readerWindow: NSWindow?

    func openReader() {
        if readerWindow == nil {
            let readerView = CCReaderKit.makeView()
            readerWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            readerWindow?.title = "CC Reader"

            // Required: NSToolbar + .unified style enables SwiftUI toolbar
            // items (cwd path, Resume, refresh) to render in the title bar.
            let toolbar = NSToolbar(identifier: "CCReaderToolbar")
            toolbar.displayMode = .iconOnly
            readerWindow?.toolbar = toolbar
            readerWindow?.toolbarStyle = .unified

            readerWindow?.contentViewController = NSHostingController(rootView: readerView)
            readerWindow?.setContentSize(NSSize(width: 1200, height: 800))
            readerWindow?.center()
            readerWindow?.isReleasedWhenClosed = false
        }
        readerWindow?.makeKeyAndOrderFront(nil)
    }
}
```

> **Key points:**
> - Use `NSHostingController` (not `NSHostingView`) for proper SwiftUI toolbar bridging.
> - Add an `NSToolbar` with `.unified` style so toolbar items appear in the title bar.
> - Include `.fullSizeContentView` in `styleMask` for correct `NavigationSplitView` layout.
> - Set `isReleasedWhenClosed = false` to reuse the window instance.

> Requires macOS 14.0+. The package bundles marked.js, highlight.js, and localization resources.

## Tech Stack

| Category | Technology |
|----------|-----------|
| UI | SwiftUI + WKWebView (Timeline) |
| Persistence | SwiftData |
| File Watching | FSEvents |
| Web Rendering | marked.js + highlight.js (bundled) |
| Build | XcodeGen (`project.yml`) |

## Architecture

```
Data Source: ~/.claude/projects/**/*.jsonl
    ↓ FSEvents
FileWatcherService → SyncService → JSONLParser (incremental)
    ↓
SwiftData ModelContext
    ↓
SessionMessagesView (snapshot builder)
    ↓
TimelineHostView (single WKWebView, windowed rendering)
```

See [docs/SPEC.md](docs/SPEC.md) for the full specification.

## Documentation

- [Architecture & Specification](docs/SPEC.md)

## Acknowledgement

Originally forked from [Mutafika/Opuswap](https://github.com/Mutafika/Opuswap), licensed under the MIT License.

## License

[MIT](LICENSE)
