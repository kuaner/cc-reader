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
    var rawJson: Data                          // 元のJSONを保持

    // デコード結果のキャッシュ（@Transientでpersistしない）
    @Transient private var _cachedRaw: RawMessageData?
    @Transient private var _isCacheValid: Bool = false

    // Computed properties from rawJson
    var thinking: String? {
        guard let content = decodedContent else { return nil }
        return content.filter { $0.type == "thinking" }.first?.thinking
    }

    var content: String? {
        guard let message = decodedMessage else { return nil }
        // contentが文字列の場合（ユーザー入力）
        if let stringContent = message.contentString {
            return stringContent
        }
        // contentが配列の場合
        guard let content = message.content else { return nil }
        return content.filter { $0.type == "text" }.compactMap { $0.text }.joined(separator: "\n")
    }

    var model: String? {
        guard let decoded = decodedMessage else { return nil }
        return decoded.model
    }

    var toolResults: [ToolResultData]? {
        guard let content = decodedContent else { return nil }
        let results = content
            .filter { $0.type == "tool_result" }
            .compactMap { block -> ToolResultData? in
                guard let toolUseId = block.tool_use_id else { return nil }
                // contentは文字列または配列
                var contentStr: String? = nil
                if let strContent = block.content?.value as? String {
                    contentStr = strContent
                } else if let arrContent = block.content?.value as? [[String: Any]] {
                    // 配列の場合、textを結合
                    contentStr = arrContent.compactMap { $0["text"] as? String }.joined(separator: "\n")
                }
                return ToolResultData(
                    type: block.type,
                    tool_use_id: toolUseId,
                    content: contentStr,
                    is_error: block.is_error
                )
            }
        return results.isEmpty ? nil : results
    }

    /// tool_resultからstructuredPatchを取得（tool_use_idをキーにマップ）
    var toolUseResultsWithPatch: [String: [StructuredPatchHunk]]? {
        guard let content = decodedContent else { return nil }
        var map: [String: [StructuredPatchHunk]] = [:]

        for block in content where block.type == "tool_result" {
            guard let toolUseId = block.tool_use_id else { continue }

            // tool_resultのcontentがオブジェクトでtoolUseResultを含む場合
            if let contentDict = block.content?.value as? [String: Any],
               let toolUseResult = contentDict["toolUseResult"] as? [String: Any],
               let patchesArray = toolUseResult["structuredPatch"] as? [[String: Any]] {

                let patches = patchesArray.compactMap { patchDict -> StructuredPatchHunk? in
                    guard let oldStart = patchDict["oldStart"] as? Int,
                          let oldLines = patchDict["oldLines"] as? Int,
                          let newStart = patchDict["newStart"] as? Int,
                          let newLines = patchDict["newLines"] as? Int,
                          let lines = patchDict["lines"] as? [String] else {
                        return nil
                    }
                    return StructuredPatchHunk(
                        oldStart: oldStart,
                        oldLines: oldLines,
                        newStart: newStart,
                        newLines: newLines,
                        lines: lines
                    )
                }

                if !patches.isEmpty {
                    map[toolUseId] = patches
                }
            }
        }

        return map.isEmpty ? nil : map
    }

    // ツール使用情報を取得
    var toolUses: [ToolUseInfo] {
        guard let content = decodedContent else { return [] }
        return content
            .filter { $0.type == "tool_use" }
            .compactMap { block -> ToolUseInfo? in
                guard let name = block.name else { return nil }
                var filePath: String?
                var command: String?
                var oldString: String?
                var newString: String?

                if let input = block.input?.value as? [String: Any] {
                    filePath = input["file_path"] as? String
                    command = input["command"] as? String
                    oldString = input["old_string"] as? String
                    newString = input["new_string"] as? String
                }

                return ToolUseInfo(id: block.id ?? "", name: name, filePath: filePath, command: command, oldString: oldString, newString: newString)
            }
    }

    // Private helpers
    private var decodedRaw: RawMessageData? {
        if _isCacheValid {
            return _cachedRaw
        }
        _cachedRaw = try? JSONDecoder().decode(RawMessageData.self, from: rawJson)
        _isCacheValid = true
        return _cachedRaw
    }

    /// キャッシュを無効化（rawJsonが更新された場合に呼ぶ）
    func invalidateCache() {
        _isCacheValid = false
        _cachedRaw = nil
    }

    private var decodedMessage: RawMessageContent? {
        decodedRaw?.message
    }

    private var decodedContent: [ContentBlock]? {
        decodedMessage?.content
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

struct StructuredPatchHunk: Codable {
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

struct ToolUseInfo {
    var id: String
    var name: String           // "Read", "Edit", "Bash" etc.
    var filePath: String?      // ファイルパス（Read, Edit, Write）
    var command: String?       // コマンド（Bash）
    var oldString: String?     // Edit用: 置換前
    var newString: String?     // Edit用: 置換後
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
