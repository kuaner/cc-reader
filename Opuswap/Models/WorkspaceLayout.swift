import Foundation

/// ペインの配置方向
enum SplitDirection: String, Codable {
    case horizontal  // 横に分割
    case vertical    // 縦に分割
}

/// 個別のペイン
struct Pane: Identifiable, Codable, Equatable {
    let id: UUID
    var sessionId: String?      // 表示中のセッション（nilなら空）
    var showTerminal: Bool      // ターミナル表示するか

    init(id: UUID = UUID(), sessionId: String? = nil, showTerminal: Bool = true) {
        self.id = id
        self.sessionId = sessionId
        self.showTerminal = showTerminal
    }
}

/// レイアウトツリー（再帰構造）
indirect enum LayoutNode: Codable, Equatable {
    case pane(Pane)
    case split(direction: SplitDirection, first: LayoutNode, second: LayoutNode, ratio: CGFloat)

    /// ratioを更新
    func withRatio(_ newRatio: CGFloat) -> LayoutNode {
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

    init(from decoder: Decoder) throws {
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

    func encode(to encoder: Encoder) throws {
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

/// ワークスペース全体
struct WorkspaceLayout: Codable, Equatable {
    var root: LayoutNode
    var name: String?

    /// 1ペインの初期状態
    static var single: WorkspaceLayout {
        WorkspaceLayout(root: .pane(Pane()))
    }

    /// 2ペイン横分割
    static var twoColumn: WorkspaceLayout {
        WorkspaceLayout(root: .split(
            direction: .horizontal,
            first: .pane(Pane()),
            second: .pane(Pane()),
            ratio: 0.5
        ))
    }

    /// 4ペイングリッド
    static var grid2x2: WorkspaceLayout {
        WorkspaceLayout(root: .split(
            direction: .vertical,
            first: .split(direction: .horizontal, first: .pane(Pane()), second: .pane(Pane()), ratio: 0.5),
            second: .split(direction: .horizontal, first: .pane(Pane()), second: .pane(Pane()), ratio: 0.5),
            ratio: 0.5
        ))
    }

    /// NxMグリッド生成
    static func grid(columns: Int, rows: Int) -> WorkspaceLayout {
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
