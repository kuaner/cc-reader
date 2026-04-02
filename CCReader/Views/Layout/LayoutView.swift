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

        case .split(let id, let direction, let first, let second, let ratio):
            return AnyView(ResizableSplitView(
                direction: direction,
                ratio: ratio,
                onRatioChanged: { newRatio in
                    layoutManager.updateRatio(at: id, newRatio: newRatio)
                },
                first: { renderNode(first) },
                second: { renderNode(second) }
            ))
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
            let dividerWidth: CGFloat = 8
            let available = total - dividerWidth

            ZStack(alignment: .topLeading) {
                // Panes — sizes only update on drag END, no jitter
                if isHorizontal {
                    HStack(spacing: 0) {
                        first()
                            .frame(width: available * currentRatio)
                        Spacer(minLength: 0)
                            .frame(width: dividerWidth)
                        second()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 0) {
                        first()
                            .frame(height: available * currentRatio)
                        Spacer(minLength: 0)
                            .frame(height: dividerWidth)
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
        let offset = available * liveRatio

        ZStack {
            // Wide transparent hit area
            Color.clear
                .frame(
                    width: isHorizontal ? 8 : nil,
                    height: isHorizontal ? nil : 8
                )
                .contentShape(Rectangle())

            // 4pt visual line with accent tint
            Rectangle()
                .fill(
                    isDragging
                        ? Color.accentColor
                        : isHovered
                            ? Color.accentColor.opacity(0.5)
                            : Color.accentColor.opacity(0.2)
                )
                .frame(
                    width: isHorizontal ? 4 : nil,
                    height: isHorizontal ? nil : 4
                )
                .animation(.easeInOut(duration: 0.1), value: isHovered)
        }
        .frame(
            width: isHorizontal ? 8 : nil,
            height: isHorizontal ? nil : 8,
            alignment: .topLeading
        )
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
