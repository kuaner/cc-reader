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

        case .split(let id, let direction, let first, let second, let ratio):
            ResizableSplitView(
                direction: direction,
                ratio: ratio,
                onRatioChanged: { newRatio in
                    layoutManager.updateRatio(at: id, newRatio: newRatio)
                },
                first: { LayoutNodeView(node: first, selectedSession: $selectedSession) },
                second: { LayoutNodeView(node: second, selectedSession: $selectedSession) }
            )
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
    @State private var dragStartRatio: CGFloat = 0.5
    @State private var pendingRatio: CGFloat? = nil  // overlay position during drag, nil when idle

    init(direction: SplitDirection, ratio: CGFloat, onRatioChanged: @escaping (CGFloat) -> Void, @ViewBuilder first: @escaping () -> First, @ViewBuilder second: @escaping () -> Second) {
        self.direction = direction
        self._currentRatio = State(initialValue: ratio)
        self._dragStartRatio = State(initialValue: ratio)
        self.onRatioChanged = onRatioChanged
        self.first = first
        self.second = second
    }

    var body: some View {
        GeometryReader { geo in
            let isHorizontal = direction == .horizontal
            let total = isHorizontal ? geo.size.width : geo.size.height
            let dividerWidth: CGFloat = 0
            let available = total - dividerWidth
            let liveRatio = pendingRatio ?? currentRatio

            ZStack(alignment: .topLeading) {
                // Panes — live resize while dragging, persist ratio on drag end.
                if isHorizontal {
                    HStack(spacing: 0) {
                        first()
                            .frame(width: available * liveRatio)
                        second()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 0) {
                        first()
                            .frame(height: available * liveRatio)
                        second()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                // Divider handle — lives on top so it doesn't affect pane layout
                dividerHandle(available: available, isHorizontal: isHorizontal)
            }
        }
    }

    @State private var isHovered = false

    @ViewBuilder
    private func dividerHandle(available: CGFloat, isHorizontal: Bool) -> some View {
        let liveRatio = pendingRatio ?? currentRatio
        let hitArea: CGFloat = 14
        let offset = available * liveRatio - hitArea / 2

        ZStack {
            // Keep a wide invisible hit-area for easy dragging.
            Color.clear
                .contentShape(Rectangle())

            // Minimal handle style: center icon + short guide lines.
            if isHorizontal {
                VStack(spacing: 4) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.25))
                        .frame(width: 1, height: 20)
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Color.secondary.opacity(isDragging || isHovered ? 0.85 : 0.55))
                        .rotationEffect(.degrees(90))
                    Capsule()
                        .fill(Color.secondary.opacity(0.25))
                        .frame(width: 1, height: 20)
                }
            } else {
                HStack(spacing: 4) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.25))
                        .frame(width: 20, height: 1)
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Color.secondary.opacity(isDragging || isHovered ? 0.85 : 0.55))
                    Capsule()
                        .fill(Color.secondary.opacity(0.25))
                        .frame(width: 20, height: 1)
                }
            }
        }
        .frame(
            width: isHorizontal ? hitArea : nil,
            height: isHorizontal ? nil : hitArea,
            alignment: .center
        )
        .contentShape(Rectangle())
        .offset(
            x: isHorizontal ? offset : 0,
            y: isHorizontal ? 0 : offset
        )
        .frame(maxWidth: isHorizontal ? nil : .infinity,
               maxHeight: isHorizontal ? .infinity : nil,
               alignment: .topLeading)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if !isDragging {
                        isDragging = true
                        dragStartRatio = currentRatio
                    }
                    let delta = isHorizontal ? value.translation.width : value.translation.height
                    pendingRatio = min(max(dragStartRatio + delta / available, 0.1), 0.9)
                }
                .onEnded { _ in
                    isDragging = false
                    if let ratio = pendingRatio {
                        currentRatio = ratio
                        onRatioChanged(ratio)
                    }
                    pendingRatio = nil
                }
        )
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                if isHorizontal { NSCursor.resizeLeftRight.push() }
                else { NSCursor.resizeUpDown.push() }
            } else {
                NSCursor.pop()
            }
        }
        .onDisappear {
            if isHovered { NSCursor.pop() }
        }
    }
}
