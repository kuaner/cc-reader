import SwiftUI

@MainActor
class LayoutManager: ObservableObject {
    @Published var layout: WorkspaceLayout = .single
    @Published var focusedPaneId: UUID?

    static let maxPanes = 12
    private static let layoutKey = "workspace.layout"

    init() {
        restore()
    }

    // MARK: - Pane Operations

    /// Whether another split can be added.
    func canSplit() -> Bool {
        allPanes().count < Self.maxPanes
    }

    /// Split the current pane and add a new one.
    func splitPane(_ paneId: UUID, direction: SplitDirection) {
        guard canSplit() else { return }
        objectWillChange.send()
        layout.root = splitNode(layout.root, targetId: paneId, direction: direction)
        save()
    }

    /// Close a pane.
    func closePane(_ paneId: UUID) {
        // Keep at least one pane alive.
        guard allPanes().count > 1 else { return }
        objectWillChange.send()
        if let newRoot = removeNode(layout.root, targetId: paneId) {
            layout.root = newRoot
            save()
        }
    }

    /// Assign a session to a pane.
    func assignSession(_ sessionId: String, to paneId: UUID) {
        objectWillChange.send()
        layout.root = updateNode(layout.root, targetId: paneId) { pane in
            var newPane = pane
            newPane.sessionId = sessionId
            return newPane
        }
        save()
    }

    /// Return every pane in the current layout.
    func allPanes() -> [Pane] {
        collectPanes(layout.root)
    }

    /// Find the pane that shows a specific session.
    func findPane(for sessionId: String) -> Pane? {
        allPanes().first { $0.sessionId == sessionId }
    }

    /// Update the ratio for the split nearest to the target pane.
    func updateRatio(at nodeId: UUID, newRatio: CGFloat) {
        layout.root = updateRatioInNode(layout.root, path: [], targetPaneId: nodeId, newRatio: newRatio)
        save()
    }

    // MARK: - Persistence

    func save() {
        if let data = try? JSONEncoder().encode(layout) {
            UserDefaults.standard.set(data, forKey: Self.layoutKey)
        }
    }

    func restore() {
        if let data = UserDefaults.standard.data(forKey: Self.layoutKey),
           let saved = try? JSONDecoder().decode(WorkspaceLayout.self, from: data) {
            layout = saved
        }
    }

    func setLayout(_ newLayout: WorkspaceLayout) {
        objectWillChange.send()
        layout = newLayout
        save()
    }

    func reset() {
        setLayout(.single)
    }

    // MARK: - Private Helpers

    private func splitNode(_ node: LayoutNode, targetId: UUID, direction: SplitDirection) -> LayoutNode {
        switch node {
        case .pane(let pane):
            if pane.id == targetId {
                return .split(
                    direction: direction,
                    first: .pane(pane),
                    second: .pane(Pane()),
                    ratio: 0.5
                )
            }
            return node

        case .split(let dir, let first, let second, let ratio):
            return .split(
                direction: dir,
                first: splitNode(first, targetId: targetId, direction: direction),
                second: splitNode(second, targetId: targetId, direction: direction),
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

    private func updateRatioInNode(_ node: LayoutNode, path: [Int], targetPaneId: UUID, newRatio: CGFloat) -> LayoutNode {
        switch node {
        case .pane:
            return node
        case .split(let dir, let first, let second, let ratio):
            // Update this split if the target pane is in either branch.
            let firstPanes = collectPanes(first)
            let secondPanes = collectPanes(second)

            if firstPanes.contains(where: { $0.id == targetPaneId }) || secondPanes.contains(where: { $0.id == targetPaneId }) {
                // This is the nearest split that owns the target pane.
                return .split(direction: dir, first: first, second: second, ratio: newRatio)
            }

            return .split(
                direction: dir,
                first: updateRatioInNode(first, path: path + [0], targetPaneId: targetPaneId, newRatio: newRatio),
                second: updateRatioInNode(second, path: path + [1], targetPaneId: targetPaneId, newRatio: newRatio),
                ratio: ratio
            )
        }
    }
}
