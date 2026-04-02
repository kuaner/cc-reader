import SwiftUI

@MainActor
class LayoutManager: ObservableObject {
    @Published var layout: WorkspaceLayout = .single
    @Published var focusedPaneId: UUID?
    @Published var sidebarVisible: Bool = true

    /// The window this LayoutManager is attached to.
    weak var window: NSWindow?

    // MARK: - Window Registry

    private static var windowRegistry: [ObjectIdentifier: LayoutManager] = [:]

    /// The LayoutManager for the currently focused window (key window).
    static var active: LayoutManager? {
        guard let window = NSApp.keyWindow else { return nil }
        return windowRegistry[ObjectIdentifier(window)]
    }

    func registerWindow(_ window: NSWindow) {
        self.window = window
        Self.windowRegistry[ObjectIdentifier(window)] = self
    }

    func unregisterWindow() {
        if let window {
            Self.windowRegistry.removeValue(forKey: ObjectIdentifier(window))
        }
        self.window = nil
    }

    // MARK: - Sidebar

    func toggleSidebar() {
        withAnimation(.easeInOut(duration: 0.2)) {
            sidebarVisible.toggle()
        }
    }

    /// The kind of picker action the user has requested.
    enum PickerAction: Identifiable {
        case splitPane(direction: SplitDirection)
        case switchSession

        var id: String {
            switch self {
            case .splitPane(let d): return "split-\(d.rawValue)"
            case .switchSession: return "switch"
            }
        }
    }

    /// Set this to present the SessionPicker.
    @Published var pendingPickerAction: PickerAction?

    static let maxPanes = 12

    // MARK: - Pane Operations

    func canSplit() -> Bool {
        allPanes().count < Self.maxPanes
    }

    func splitPane(_ paneId: UUID, direction: SplitDirection, sessionId: String? = nil) {
        guard canSplit() else { return }
        objectWillChange.send()
        layout.root = splitNode(layout.root, targetId: paneId, direction: direction, sessionId: sessionId)
    }

    /// Split the focused pane and assign a session to the new pane.
    func splitFocusedPane(direction: SplitDirection, sessionId: String) {
        guard let paneId = focusedPaneId else { return }
        // Prevent duplicate session
        if allPanes().contains(where: { $0.sessionId == sessionId }) { return }
        splitPane(paneId, direction: direction, sessionId: sessionId)
        // Focus the newly created pane.
        let panes = allPanes()
        if let newPane = panes.last(where: { $0.sessionId == sessionId && $0.id != paneId }) {
            focusedPaneId = newPane.id
        }
    }

    func closePane(_ paneId: UUID) {
        let panes = allPanes()
        if panes.count <= 1 {
            // Last pane — close this window/tab (like Ghostty's closeTabImmediately)
            window?.close()
            return
        }
        objectWillChange.send()
        if let newRoot = removeNode(layout.root, targetId: paneId) {
            layout.root = newRoot
            if focusedPaneId == paneId {
                focusedPaneId = collectPanes(layout.root).first?.id
            }
        }
    }

    /// Close the focused pane, or close the window if it's the last pane.
    func closeFocused() {
        let paneId = focusedPaneId ?? allPanes().first?.id
        if let paneId {
            closePane(paneId)
        }
    }

    /// Focus the previous pane in traversal order (⌘[ like Ghostty).
    func focusPreviousPane() { focusPane(offset: -1) }

    /// Focus the next pane in traversal order (⌘] like Ghostty).
    func focusNextPane() { focusPane(offset: 1) }

    private func focusPane(offset: Int) {
        let panes = allPanes()
        guard panes.count > 1 else { return }
        let current = focusedPaneId
        if let idx = panes.firstIndex(where: { $0.id == current }) {
            focusedPaneId = panes[(idx + offset + panes.count) % panes.count].id
        } else {
            focusedPaneId = offset < 0 ? panes.last?.id : panes.first?.id
        }
    }

    func assignSession(_ sessionId: String, to paneId: UUID) {
        // Prevent duplicate: if this session is already open in another pane, refuse
        let existing = allPanes().first { $0.sessionId == sessionId }
        if let existing, existing.id != paneId { return }
        objectWillChange.send()
        layout.root = updateNode(layout.root, targetId: paneId) { pane in
            var newPane = pane
            newPane.sessionId = sessionId
            return newPane
        }
    }

    func allPanes() -> [Pane] {
        collectPanes(layout.root)
    }

    func findPane(for sessionId: String) -> Pane? {
        allPanes().first { $0.sessionId == sessionId }
    }

    /// Focus the pane showing a session, or assign it to the focused pane.
    func focusOrAssignSession(_ sessionId: String) {
        if let pane = findPane(for: sessionId) {
            focusedPaneId = pane.id
        } else {
            let targetPaneId = focusedPaneId ?? allPanes().first?.id
            if let paneId = targetPaneId {
                focusedPaneId = paneId
                assignSession(sessionId, to: paneId)
            }
        }
    }

    func updateRatio(at nodeId: UUID, newRatio: CGFloat) {
        layout.root = updateRatioInNode(layout.root, targetPaneId: nodeId, newRatio: newRatio)
    }

    // MARK: - Picker Triggers

    func requestSplitFocused(direction: SplitDirection) {
        guard canSplit(), focusedPaneId != nil else { return }
        pendingPickerAction = .splitPane(direction: direction)
    }

    func requestSwitchSession() {
        guard focusedPaneId != nil else { return }
        pendingPickerAction = .switchSession
    }

    /// Called when the user picks a session from the SessionPicker.
    func handlePickerSelection(sessionId: String) {
        guard let action = pendingPickerAction else { return }
        pendingPickerAction = nil

        switch action {
        case .splitPane(let direction):
            splitFocusedPane(direction: direction, sessionId: sessionId)
        case .switchSession:
            if let paneId = focusedPaneId {
                assignSession(sessionId, to: paneId)
            }
        }
    }

    func cancelPicker() {
        pendingPickerAction = nil
    }

    // MARK: - Persistence (via @SceneStorage in ContentView)

    func encodeLayout() -> String? {
        guard let data = try? JSONEncoder().encode(layout) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func restoreLayout(from json: String?) {
        guard let json, let data = json.data(using: .utf8),
              let saved = try? JSONDecoder().decode(WorkspaceLayout.self, from: data) else { return }
        layout = saved
        focusedPaneId = collectPanes(layout.root).first?.id
    }

    /// Migrate legacy data from UserDefaults (old TabGroup or single layout).
    func migrateFromUserDefaults() {
        // Try old TabGroup format — extract active tab's layout
        if let data = UserDefaults.standard.data(forKey: "workspace.tabGroup") {
            // Decode just the active layout from the legacy structure
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tabs = json["tabs"] as? [[String: Any]],
               let activeId = json["activeTabId"] as? String,
               let activeTab = tabs.first(where: { ($0["id"] as? String) == activeId }) ?? tabs.first,
               let layoutData = try? JSONSerialization.data(withJSONObject: activeTab["layout"] ?? [:]),
               let migratedLayout = try? JSONDecoder().decode(WorkspaceLayout.self, from: layoutData) {
                layout = migratedLayout
            }
            UserDefaults.standard.removeObject(forKey: "workspace.tabGroup")
            return
        }
        // Try old single-layout format
        if let data = UserDefaults.standard.data(forKey: "workspace.layout"),
           let saved = try? JSONDecoder().decode(WorkspaceLayout.self, from: data) {
            layout = saved
            UserDefaults.standard.removeObject(forKey: "workspace.layout")
        }
    }

    func reset() {
        objectWillChange.send()
        layout = .single
        focusedPaneId = nil
    }

    // MARK: - Private Helpers

    private func splitNode(_ node: LayoutNode, targetId: UUID, direction: SplitDirection, sessionId: String? = nil) -> LayoutNode {
        switch node {
        case .pane(let pane):
            if pane.id == targetId {
                return .split(
                    direction: direction,
                    first: .pane(pane),
                    second: .pane(Pane(sessionId: sessionId)),
                    ratio: 0.5
                )
            }
            return node

        case .split(let dir, let first, let second, let ratio):
            return .split(
                direction: dir,
                first: splitNode(first, targetId: targetId, direction: direction, sessionId: sessionId),
                second: splitNode(second, targetId: targetId, direction: direction, sessionId: sessionId),
                ratio: ratio
            )
        }
    }

    private func removeNode(_ node: LayoutNode, targetId: UUID) -> LayoutNode? {
        switch node {
        case .pane(let pane):
            return pane.id == targetId ? nil : node

        case .split(let dir, let first, let second, let ratio):
            let newFirst = removeNode(first, targetId: targetId)
            let newSecond = removeNode(second, targetId: targetId)

            switch (newFirst, newSecond) {
            case (nil, nil): return nil
            case (let n, nil): return n
            case (nil, let n): return n
            case (let f?, let s?):
                return .split(direction: dir, first: f, second: s, ratio: ratio)
            }
        }
    }

    private func updateNode(_ node: LayoutNode, targetId: UUID, transform: (Pane) -> Pane) -> LayoutNode {
        switch node {
        case .pane(let pane):
            return pane.id == targetId ? .pane(transform(pane)) : node

        case .split(let dir, let first, let second, let ratio):
            return .split(
                direction: dir,
                first: updateNode(first, targetId: targetId, transform: transform),
                second: updateNode(second, targetId: targetId, transform: transform),
                ratio: ratio
            )
        }
    }

    private func collectPanes(_ node: LayoutNode) -> [Pane] {
        switch node {
        case .pane(let pane):
            return [pane]
        case .split(_, let first, let second, _):
            return collectPanes(first) + collectPanes(second)
        }
    }

    private func updateRatioInNode(_ node: LayoutNode, targetPaneId: UUID, newRatio: CGFloat) -> LayoutNode {
        switch node {
        case .pane:
            return node
        case .split(let dir, let first, let second, let ratio):
            let firstPanes = collectPanes(first)
            let secondPanes = collectPanes(second)

            if firstPanes.contains(where: { $0.id == targetPaneId }) || secondPanes.contains(where: { $0.id == targetPaneId }) {
                return .split(direction: dir, first: first, second: second, ratio: newRatio)
            }

            return .split(
                direction: dir,
                first: updateRatioInNode(first, targetPaneId: targetPaneId, newRatio: newRatio),
                second: updateRatioInNode(second, targetPaneId: targetPaneId, newRatio: newRatio),
                ratio: ratio
            )
        }
    }
}
