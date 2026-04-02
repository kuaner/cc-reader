import Foundation

/// Split direction for a layout node.
public enum SplitDirection: String, Codable {
    case horizontal  // Split side by side
    case vertical    // Split top and bottom
}

/// A single pane in the workspace.
public struct Pane: Identifiable, Codable, Equatable {
    public let id: UUID
    public var sessionId: String?

    public init(id: UUID = UUID(), sessionId: String? = nil) {
        self.id = id
        self.sessionId = sessionId
    }
}

/// Recursive workspace layout tree.
public indirect enum LayoutNode: Codable, Equatable {
    case pane(Pane)
    case split(direction: SplitDirection, first: LayoutNode, second: LayoutNode, ratio: CGFloat)

    /// Return a copy with an updated split ratio.
    public func withRatio(_ newRatio: CGFloat) -> LayoutNode {
        switch self {
        case .pane:
            return self
        case .split(let dir, let first, let second, _):
            return .split(direction: dir, first: first, second: second, ratio: newRatio)
        }
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case type, pane, direction, first, second, ratio
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "pane":
            let pane = try container.decode(Pane.self, forKey: .pane)
            self = .pane(pane)
        case "split":
            let direction = try container.decode(SplitDirection.self, forKey: .direction)
            let first = try container.decode(LayoutNode.self, forKey: .first)
            let second = try container.decode(LayoutNode.self, forKey: .second)
            let ratio = try container.decode(CGFloat.self, forKey: .ratio)
            self = .split(direction: direction, first: first, second: second, ratio: ratio)
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown type")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .pane(let pane):
            try container.encode("pane", forKey: .type)
            try container.encode(pane, forKey: .pane)
        case .split(let direction, let first, let second, let ratio):
            try container.encode("split", forKey: .type)
            try container.encode(direction, forKey: .direction)
            try container.encode(first, forKey: .first)
            try container.encode(second, forKey: .second)
            try container.encode(ratio, forKey: .ratio)
        }
    }
}

/// Whole workspace layout state.
public struct WorkspaceLayout: Codable, Equatable {
    public var root: LayoutNode
    public var name: String?

    /// Default single-pane layout.
    public static var single: WorkspaceLayout {
        WorkspaceLayout(root: .pane(Pane()))
    }

    /// Two-column layout.
    public static var twoColumn: WorkspaceLayout {
        WorkspaceLayout(root: .split(
            direction: .horizontal,
            first: .pane(Pane()),
            second: .pane(Pane()),
            ratio: 0.5
        ))
    }

    /// 2x2 grid layout.
    public static var grid2x2: WorkspaceLayout {
        WorkspaceLayout(root: .split(
            direction: .vertical,
            first: .split(direction: .horizontal, first: .pane(Pane()), second: .pane(Pane()), ratio: 0.5),
            second: .split(direction: .horizontal, first: .pane(Pane()), second: .pane(Pane()), ratio: 0.5),
            ratio: 0.5
        ))
    }

    /// Build an N by M grid layout.
    public static func grid(columns: Int, rows: Int) -> WorkspaceLayout {
        func makeRow(count: Int) -> LayoutNode {
            if count == 1 { return .pane(Pane()) }
            return .split(
                direction: .horizontal,
                first: .pane(Pane()),
                second: makeRow(count: count - 1),
                ratio: 1.0 / CGFloat(count)
            )
        }

        func makeGrid(rows: Int, columns: Int) -> LayoutNode {
            if rows == 1 { return makeRow(count: columns) }
            return .split(
                direction: .vertical,
                first: makeRow(count: columns),
                second: makeGrid(rows: rows - 1, columns: columns),
                ratio: 1.0 / CGFloat(rows)
            )
        }

        return WorkspaceLayout(root: makeGrid(rows: rows, columns: columns))
    }
}


