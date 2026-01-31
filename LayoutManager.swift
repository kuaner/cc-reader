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

    /// 分割可能か
    func canSplit() -> Bool {
        allPanes().count < Self.maxPanes
    }

    /// 新しいペインを追加（現在のペインを分割）
    func splitPane(_ paneId: UUID, direction: SplitDirection) {
        guard canSplit() else { return }
        objectWillChange.send()
        layout.root = splitNode(layout.root, targetId: paneId, direction: direction)
        save()
    }

    /// ペインを閉じる
    func closePane(_ paneId: UUID) {
        // 最後の1つは閉じられない
        guard allPanes().count > 1 else { return }
        objectWillChange.send()
        if let newRoot = removeNode(layout.root, targetId: paneId) {
            layout.root = newRoot
            save()
        }
    }

    /// ペインにセッションを割り当て
    func assignSession(_ sessionId: String, to paneId: UUID) {
        objectWillChange.send()
        layout.root = updateNode(layout.root, targetId: paneId) { pane in
            var newPane = pane
            newPane.sessionId = sessionId
            return newPane
        }
        save()
    }

    /// ペインのターミナル表示を切り替え
    func toggleTerminal(for paneId: UUID) {
        objectWillChange.send()
        layout.root = updateNode(layout.root, targetId: paneId) { pane in
            var newPane = pane
            newPane.showTerminal.toggle()
            return newPane
        }
        save()
    }

    /// 全ペインを取得
    func allPanes() -> [Pane] {
        collectPanes(layout.root)
    }

    /// 特定のセッションが開いているペインを検索
    func findPane(for sessionId: String) -> Pane? {
        allPanes().first { $0.sessionId == sessionId }
    }

    /// セッションを再開（ターミナルでclaude --resumeを実行）
    func resumeSession(_ sessionId: String, cwd: String) {
        let command = "cd \"\(cwd)\" && claude --resume \(sessionId)"

        let targetPaneId = focusedPaneId ?? allPanes().first?.id
        guard let paneId = targetPaneId else { return }

        NotificationCenter.default.post(
            name: .executeTerminalCommand,
            object: nil,
            userInfo: ["paneId": paneId, "command": command]
        )
    }

    /// 特定のsplitノードのratioを更新
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
            // このsplitの子ペインにtargetがあればratioを更新
            let firstPanes = collectPanes(first)
            let secondPanes = collectPanes(second)

            if firstPanes.contains(where: { $0.id == targetPaneId }) || secondPanes.contains(where: { $0.id == targetPaneId }) {
                // このノードを更新対象とする（最も近いsplit）
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
