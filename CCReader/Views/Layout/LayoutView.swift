import SwiftUI
import SwiftData

struct LayoutView: View {
    @EnvironmentObject var layoutManager: LayoutManager
    @Binding var selectedSession: Session?

    var body: some View {
        LayoutNodeView(node: layoutManager.layout.root, selectedSession: $selectedSession)
    }
}

/// Recursive view that renders a `LayoutNode` tree without AnyView type-erasure,
/// preserving SwiftUI's structural identity so WKWebView instances survive layout mutations.
struct LayoutNodeView: View {
    let node: LayoutNode
    @Binding var selectedSession: Session?
    @EnvironmentObject var layoutManager: LayoutManager

    var body: some View {
        switch node {
        case .pane(let pane):
            PaneView(pane: pane, selectedSession: $selectedSession)

        case .split(_, let direction, let first, let second, _):
            if direction == .horizontal {
                HSplitView {
                    LayoutNodeView(node: first, selectedSession: $selectedSession)
                    LayoutNodeView(node: second, selectedSession: $selectedSession)
                }
            } else {
                VSplitView {
                    LayoutNodeView(node: first, selectedSession: $selectedSession)
                    LayoutNodeView(node: second, selectedSession: $selectedSession)
                }
            }
        }
    }
}
