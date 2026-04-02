# Layout System — Multi-Tab & Multi-Pane

## Overview

cc-reader supports native macOS window tabbing with per-tab split pane layouts. Each tab gets its own `LayoutManager` instance that manages a recursive tree of panes, similar to terminal emulators like Ghostty or iTerm2.

## Architecture

### Window Registry

`LayoutManager` uses a static `windowRegistry` keyed by `ObjectIdentifier(NSWindow)` to map each native window to its manager instance. This allows menu commands (defined in `CCReaderApp`) to resolve the active manager via `LayoutManager.active`.

```
NSApp.keyWindow → ObjectIdentifier → windowRegistry → LayoutManager
```

Each tab gets a separate `ContentView` instance (via SwiftUI's `WindowGroup`), which creates its own `@StateObject` `LayoutManager`. The `WindowConfigurator` (NSViewRepresentable) registers/unregisters the window on appear/disappear.

### Pane Tree

The layout is a recursive binary tree:

```
LayoutNode
├── .pane(Pane)                    — leaf: displays a single session
└── .split(id, direction, first, second, ratio)
   ├── id: UUID                   — stable identifier for this split divider
   ├── first: LayoutNode          — left/top child
   └── second: LayoutNode         — right/bottom child
```

`WorkspaceLayout` is a `Codable` value type wrapping the root `LayoutNode`.

## Key Components

### LayoutManager (`Services/LayoutManager.swift`)

Central orchestrator for all layout operations. Marked `@MainActor` and conforms to `ObservableObject`.

**Published state:**
- `layout: WorkspaceLayout` — the pane tree
- `focusedPaneId: UUID?` — currently focused pane
- `sidebarVisible: Bool` — sidebar toggle state
- `pendingPickerAction: PickerAction?` — drives the session picker sheet

**Core operations:**
| Method | Description |
|--------|-------------|
| `focusOrAssignSession(_:)` | Focus pane showing session, or assign to focused pane |
| `splitFocusedPane(direction:sessionId:)` | Split and assign session to new pane |
| `closePane(_:)` / `closeFocused()` | Close pane (last pane closes window) |
| `focusPreviousPane()` / `focusNextPane()` | Cycle pane focus (delegates to `focusPane(offset:)`) |
| `assignSession(_:to:)` | Assign session to a pane (prevents duplicates) |
| `requestSplitFocused(direction:)` | Set `pendingPickerAction` to trigger picker |
| `requestSwitchSession()` | Set `pendingPickerAction` to trigger picker |
| `handlePickerSelection(sessionId:)` | Dispatch picker result to split or switch |
| `updateRatio(at:newRatio:)` | Move a split divider |

**Persistence:**
- `encodeLayout()` — JSON-encode the layout tree for `@SceneStorage`
- `restoreLayout(from:)` — decode and restore
- `migrateFromUserDefaults()` — one-time migration from legacy global storage

### ContentView (`Views/ContentView.swift`)

Per-tab root view. Bridges layout state with the view hierarchy:

- `@SceneStorage("windowLayoutJSON")` — persists layout per tab
- `@StateObject` `LayoutManager` — one per tab instance
- Synchronizes `sidebarVisible` ↔ `NavigationSplitViewVisibility` (with change-detection guards to prevent feedback loops)
- Merges `selectedSession` changes: routes to `focusOrAssignSession` and triggers `coordinator.syncSession` in a single `onChange`
- `navigateToSession` notification handler uses array lookup instead of Core Data fetch

### LayoutView (`Views/Layout/LayoutView.swift`)

Renders the `LayoutNode` tree recursively using `LayoutNodeView`, avoiding `AnyView` type erasure so each pane preserves its underlying `WKWebView` identity. Delegates to `ResizableSplitView` for `.split` nodes and `PaneView` for `.pane` nodes.

### ResizableSplitView

A ZStack-based split view with an overlay divider:

1. **Panes layer** — `HStack`/`VStack` with fixed-size first child, spacer gap, and flexible second child. Sizes only update on drag-end (no jitter).
2. **Divider handle** — Absolutely positioned overlay with:
   - 8pt transparent hit area
   - 4pt visual line with accent tint (0.2/0.5/1.0 opacity states)
   - `DragGesture(minimumDistance: 0)` for immediate feedback
   - `pendingRatio` state for live preview during drag, committed to `currentRatio` on release
   - Hover cursor management with `onDisappear` cleanup to prevent cursor stack leaks

### PaneView (`Views/Layout/PaneView.swift`)

Renders a single pane: header + timeline, or an empty placeholder with a "Select Session" button.

**PaneHeaderView** shows:
- Session title (with attention bell indicator)
- Per-session actions: open CWD, resume copy, refresh
- Context panel toggle (per-pane, independent across panes)
- Switch session button (triggers picker)
- Split/close menu

### SessionPickerView (`Views/Sidebar/SessionPickerView.swift`)

A sheet for searching and selecting sessions. Used for both splitting (assign session to new pane) and switching (assign to focused pane).

Features:
- Full-text search across title, git branch, session tag, and CWD (case-insensitive)
- Keyboard navigation: arrow keys + Enter to confirm, Escape to cancel
- Dimmed rows for sessions already open in other panes (prevents duplicates)
- Open session ID set computed once outside `ForEach` (not per-row)

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `⌘T` | New tab |
| `⌘W` | Close pane (last pane closes tab) |
| `⌘D` | Split horizontally → open picker |
| `⌘⇧D` | Split vertically → open picker |
| `⌘E` | Open session picker (switch/assign) |
| `⌘B` | Toggle sidebar |
| `⌘[` | Focus previous pane |
| `⌘]` | Focus next pane |
| `⌘1`–`⌘9` | Switch to tab 1–9 |

## Persistence

Layout state is persisted per-tab using `@SceneStorage`. On app launch:

1. If `@SceneStorage` has data → restore layout from JSON
2. Else → attempt migration from legacy `UserDefaults`:
   - Try old `workspace.tabGroup` format (extract active tab's layout)
   - Fall back to old `workspace.layout` format
   - Clean up the migrated key

Each tab stores its own layout independently, so closing one tab does not affect others.

## Design Decisions

### Per-Tab LayoutManager (not Global)

Each tab gets its own `LayoutManager` instead of sharing one globally. This keeps pane trees, focus state, and picker actions fully independent. The window registry is only used for menu command dispatch (`LayoutManager.active`).

### Session Picker Sheet (not Drag-and-Drop)

Split panes previously used drag-and-drop for session assignment. The refactor replaced this with a picker sheet triggered by keyboard shortcut or button. Rationale:
- Keyboard-first workflow (⌘E → type → Enter)
- Duplicate session prevention is explicit
- Works well with the Ghostty-style shortcut conventions

### ZStack Overlay Divider

The divider handle lives in a ZStack overlay rather than being an inline element between panes. This means pane sizes are computed independently of the divider's geometry, and the divider's visual position is purely cosmetic during drag (only committed on release). This eliminates layout jitter that occurred with the previous inline approach.

### Sidebar Visibility via LayoutManager

Sidebar toggle is managed through `LayoutManager.sidebarVisible` instead of SwiftUI's `NavigationSplitViewVisibility` directly. This allows the shortcut (`⌘B`) to work through the menu system, and the bidirectional sync with `columnVisibility` includes change-detection guards to prevent redundant re-renders.

### Duplicate Session Prevention

`LayoutManager.assignSession` and `splitFocusedPane` both enforce that the same session cannot appear in multiple panes. The session picker dims already-open sessions and blocks selection. This prevents confusion when the same session is being synced independently in multiple panes.
