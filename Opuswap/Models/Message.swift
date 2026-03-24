import Foundation
import SwiftData

enum MessageType: String, Codable {
    case user
    case assistant
}

@Model
class Message {
    @Attribute(.unique) var uuid: String
    var session: Session?
    var parentUuid: String?
    var type: MessageType
    var timestamp: Date
    var rawJson: Data

    // --- 解码済みキャッシュ（@Transient: メモリのみ、DBに保存しない）---
    // rawJson が変わらない限り再解码不要。全プロパティが ensureDecoded() 経由で一度だけ解码される。
    @Transient private var _decoded = false
    @Transient private var _content: String?
    @Transient private var _thinking: String?
    @Transient private var _model: String?
    @Transient private var _toolUses: [ToolUseInfo] = []
    @Transient private var _toolResults: [ToolResultData]?
    @Transient private var _patchMap: [String: [StructuredPatchHunk]]?

    var content: String? { ensureDecoded(); return _content }
    var thinking: String? { ensureDecoded(); return _thinking }
    var model: String? { ensureDecoded(); return _model }
    var toolUses: [ToolUseInfo] { ensureDecoded(); return _toolUses }
    var toolResults: [ToolResultData]? { ensureDecoded(); return _toolResults }
    var toolUseResultsWithPatch: [String: [StructuredPatchHunk]]? { ensureDecoded(); return _patchMap }

    // 全フィールドを一度だけ解码して全キャッシュに格納する
    private func ensureDecoded() {
        guard !_decoded else { return }
        _decoded = true

        guard let raw = try? Self.sharedDecoder.decode(RawMessageData.self, from: rawJson),
              let message = raw.message else { return }

        _model = message.model

        if let str = message.contentString {
            _content = str
        } else if let blocks = message.content {
            let textSegments = blocks.compactMap { block -> String? in
                // 標準 text block
                if block.type == "text", let text = block.text, !text.isEmpty {
                    return text
                }
                // 将来追加される text-like block への兜底
                if block.type != "thinking",
                   block.type != "tool_use",
                   block.type != "tool_result",
                   let text = block.text,
                   !text.isEmpty {
                    return text
                }
                // content に文字列が入るケースへの兜底
                if let contentText = Self.extractText(from: block.content?.value), !contentText.isEmpty {
                    return contentText
                }
                return nil
            }
            let mergedText = textSegments.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            _content = mergedText.isEmpty ? nil : mergedText
            _thinking = blocks.first(where: { $0.type == "thinking" })?.thinking

            // toolUses（assistant）
            _toolUses = blocks.compactMap { block -> ToolUseInfo? in
                guard block.type == "tool_use", let name = block.name else { return nil }
                var filePath: String?
                var command: String?
                var oldString: String?
                var newString: String?
                var inputSummary: String?
                if let input = block.input?.value as? [String: Any] {
                    filePath = input["file_path"] as? String
                    command = input["command"] as? String
                    oldString = input["old_string"] as? String
                    newString = input["new_string"] as? String
                    if filePath == nil && command == nil {
                        inputSummary = (input["description"] as? String)
                            ?? (input["prompt"] as? String)
                            ?? (input["query"] as? String)
                            ?? (input["content"] as? String)
                            ?? (input["text"] as? String)
                            ?? (input["pattern"] as? String)
                    }
                }
                return ToolUseInfo(id: block.id ?? "", name: name, filePath: filePath, command: command, oldString: oldString, newString: newString, inputSummary: inputSummary)
            }

            // toolResults（user）
            let results: [ToolResultData] = blocks.compactMap { block in
                guard block.type == "tool_result", let toolUseId = block.tool_use_id else { return nil }
                var contentStr: String?
                if let s = block.content?.value as? String {
                    contentStr = s
                } else if let arr = block.content?.value as? [[String: Any]] {
                    contentStr = arr.compactMap { $0["text"] as? String }.joined(separator: "\n")
                }
                return ToolResultData(type: block.type, tool_use_id: toolUseId, content: contentStr, is_error: block.is_error)
            }
            _toolResults = results.isEmpty ? nil : results

            // patchMap（user の tool_result に含まれる structuredPatch）
            var pMap: [String: [StructuredPatchHunk]] = [:]
            for block in blocks where block.type == "tool_result" {
                guard let toolUseId = block.tool_use_id,
                      let dict = block.content?.value as? [String: Any],
                      let tur = dict["toolUseResult"] as? [String: Any],
                      let arr = tur["structuredPatch"] as? [[String: Any]] else { continue }
                let hunks = arr.compactMap { d -> StructuredPatchHunk? in
                    guard let os = d["oldStart"] as? Int, let ol = d["oldLines"] as? Int,
                          let ns = d["newStart"] as? Int, let nl = d["newLines"] as? Int,
                          let lines = d["lines"] as? [String] else { return nil }
                    return StructuredPatchHunk(oldStart: os, oldLines: ol, newStart: ns, newLines: nl, lines: lines)
                }
                if !hunks.isEmpty { pMap[toolUseId] = hunks }
            }
            _patchMap = pMap.isEmpty ? nil : pMap
        }
    }

    /// 全プロパティを事前にデコードしてキャッシュに格納する（スクロール時のメインスレッドデコードを防ぐ）
    func preload() { ensureDecoded() }

    /// デコード済みかどうか（外部からの軽量チェック用）
    var isDecoded: Bool { _decoded }

    func invalidateCache() {
        _decoded = false
        _content = nil; _thinking = nil; _model = nil
        _toolUses = []; _toolResults = nil; _patchMap = nil
    }

    private static let sharedDecoder = JSONDecoder()
    private static func extractText(from raw: Any?) -> String? {
        switch raw {
        case let str as String:
            return str
        case let dict as [String: Any]:
            if let text = dict["text"] as? String, !text.isEmpty {
                return text
            }
            if let content = dict["content"] as? String, !content.isEmpty {
                return content
            }
            return nil
        case let arr as [[String: Any]]:
            let pieces = arr.compactMap { item -> String? in
                if let text = item["text"] as? String, !text.isEmpty { return text }
                if let content = item["content"] as? String, !content.isEmpty { return content }
                return nil
            }
            return pieces.isEmpty ? nil : pieces.joined(separator: "\n")
        default:
            return nil
        }
    }

    init(uuid: String, type: MessageType, timestamp: Date, rawJson: Data, parentUuid: String? = nil) {
        self.uuid = uuid
        self.type = type
        self.timestamp = timestamp
        self.rawJson = rawJson
        self.parentUuid = parentUuid
    }
}

// MARK: - JSON Decoding Structures

struct RawMessageData: Codable {
    var type: String
    var uuid: String
    var parentUuid: String?
    var sessionId: String
    var timestamp: String
    var cwd: String?
    var gitBranch: String?
    var slug: String?
    var message: RawMessageContent?
    // JSONL 元行のバイト列（DB保存時に再エンコードを回避するため）
    var originalLineData: Data?

    enum CodingKeys: String, CodingKey {
        case type, uuid, parentUuid, sessionId, timestamp, cwd, gitBranch, slug, message
    }

    init(
        type: String,
        uuid: String,
        parentUuid: String?,
        sessionId: String,
        timestamp: String,
        cwd: String?,
        gitBranch: String?,
        slug: String?,
        message: RawMessageContent?,
        originalLineData: Data? = nil
    ) {
        self.type = type
        self.uuid = uuid
        self.parentUuid = parentUuid
        self.sessionId = sessionId
        self.timestamp = timestamp
        self.cwd = cwd
        self.gitBranch = gitBranch
        self.slug = slug
        self.message = message
        self.originalLineData = originalLineData
    }
}

struct RawMessageContent: Codable {
    var role: String
    var content: [ContentBlock]?
    var contentString: String?  // contentが文字列の場合
    var model: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decode(String.self, forKey: .role)
        model = try container.decodeIfPresent(String.self, forKey: .model)

        // contentは文字列か配列か
        if let stringContent = try? container.decode(String.self, forKey: .content) {
            contentString = stringContent
            content = nil
        } else {
            content = try container.decodeIfPresent([ContentBlock].self, forKey: .content)
            contentString = nil
        }
    }

    enum CodingKeys: String, CodingKey {
        case role, content, model
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        try container.encodeIfPresent(model, forKey: .model)
        if let stringContent = contentString {
            try container.encode(stringContent, forKey: .content)
        } else {
            try container.encodeIfPresent(content, forKey: .content)
        }
    }
}

struct ContentBlock: Codable {
    var type: String
    var text: String?
    var thinking: String?
    var id: String?
    var name: String?
    var input: AnyCodable?
    // tool_result用
    var tool_use_id: String?
    var content: AnyCodable?  // 文字列または配列
    var is_error: Bool?
}

struct ToolResultData: Codable {
    var type: String?
    var tool_use_id: String?
    var content: String?
    var is_error: Bool?
}

// MARK: - StructuredPatch (Edit結果の差分情報)

struct StructuredPatchHunk: Codable, Equatable {
    var oldStart: Int
    var oldLines: Int
    var newStart: Int
    var newLines: Int
    var lines: [String]
}

struct ToolUseResultData: Codable {
    var filePath: String?
    var structuredPatch: [StructuredPatchHunk]?
}

struct ToolUseInfo: Identifiable {
    var id: String
    var name: String           // "Read", "Edit", "Bash" etc.
    var filePath: String?      // ファイルパス（Read, Edit, Write）
    var command: String?       // コマンド（Bash）
    var oldString: String?     // Edit用: 置換前
    var newString: String?     // Edit用: 置換後
    var inputSummary: String?  // filePath/command が無いツール向けの入力要約（Agent, Task 等）
}

// Helper for decoding arbitrary JSON
struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intVal = try? container.decode(Int.self) {
            value = intVal
        } else if let doubleVal = try? container.decode(Double.self) {
            value = doubleVal
        } else if let boolVal = try? container.decode(Bool.self) {
            value = boolVal
        } else if let stringVal = try? container.decode(String.self) {
            value = stringVal
        } else if let arrayVal = try? container.decode([AnyCodable].self) {
            value = arrayVal.map { $0.value }
        } else if let dictVal = try? container.decode([String: AnyCodable].self) {
            value = dictVal.mapValues { $0.value }
        } else {
            value = NSNull()
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let intVal as Int:
            try container.encode(intVal)
        case let doubleVal as Double:
            try container.encode(doubleVal)
        case let boolVal as Bool:
            try container.encode(boolVal)
        case let stringVal as String:
            try container.encode(stringVal)
        case let arrayVal as [Any]:
            try container.encode(arrayVal.map { AnyCodable($0) })
        case let dictVal as [String: Any]:
            try container.encode(dictVal.mapValues { AnyCodable($0) })
        default:
            try container.encodeNil()
        }
    }
}
