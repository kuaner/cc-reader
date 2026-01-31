import SwiftUI
import SwiftData

struct LayoutView: View {
    @EnvironmentObject var layoutManager: LayoutManager
    @Binding var selectedSession: Session?

    var body: some View {
        renderNode(layoutManager.layout.root)
    }

    private func renderNode(_ node: LayoutNode) -> AnyView {
        switch node {
        case .pane(let pane):
            return AnyView(PaneView(pane: pane, selectedSession: $selectedSession))

        case .split(let direction, let first, let second, let ratio):
            return AnyView(ResizableSplitView(
                direction: direction,
                ratio: ratio,
                onRatioChanged: { newRatio in
                    // 最初の子ペインIDを使ってratioを更新
                    if let firstPaneId = getFirstPaneId(from: first) {
                        layoutManager.updateRatio(at: firstPaneId, newRatio: newRatio)
                    }
                },
                first: { renderNode(first) },
                second: { renderNode(second) }
            ))
        }
    }

    private func getFirstPaneId(from node: LayoutNode) -> UUID? {
        switch node {
        case .pane(let pane):
            return pane.id
        case .split(_, let first, _, _):
            return getFirstPaneId(from: first)
        }
    }
}

// MARK: - Resizable Split View

struct ResizableSplitView<First: View, Second: View>: View {
    let direction: SplitDirection
    @State private var currentRatio: CGFloat
    let onRatioChanged: (CGFloat) -> Void
    @ViewBuilder let first: () -> First
    @ViewBuilder let second: () -> Second

    @State private var isDragging = false

    init(direction: SplitDirection, ratio: CGFloat, onRatioChanged: @escaping (CGFloat) -> Void, @ViewBuilder first: @escaping () -> First, @ViewBuilder second: @escaping () -> Second) {
        self.direction = direction
        self._currentRatio = State(initialValue: ratio)
        self.onRatioChanged = onRatioChanged
        self.first = first
        self.second = second
    }

    var body: some View {
        GeometryReader { geo in
            let isHorizontal = direction == .horizontal
            let total = isHorizontal ? geo.size.width : geo.size.height

            if isHorizontal {
                HStack(spacing: 0) {
                    first()
                        .frame(width: total * currentRatio)
                    divider(total: total, isHorizontal: true)
                    second()
                }
            } else {
                VStack(spacing: 0) {
                    first()
                        .frame(height: total * currentRatio)
                    divider(total: total, isHorizontal: false)
                    second()
                }
            }
        }
    }

    @ViewBuilder
    private func divider(total: CGFloat, isHorizontal: Bool) -> some View {
        Rectangle()
            .fill(isDragging ? Color.accentColor : Color.gray.opacity(0.3))
            .frame(width: isHorizontal ? 4 : nil, height: isHorizontal ? nil : 4)
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        isDragging = true
                        let delta = isHorizontal ? value.translation.width : value.translation.height
                        let newRatio = currentRatio + (delta / total) * 0.02
                        currentRatio = min(max(newRatio, 0.1), 0.9)
                    }
                    .onEnded { _ in
                        isDragging = false
                        onRatioChanged(currentRatio)
                    }
            )
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
    }
}
