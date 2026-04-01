import Foundation
import SwiftData

// MARK: - JSONL Entry Type (aligned with Claude Code official Entry union)
//
// Reference: claude-code src/types/logs.ts — `export type Entry = ...`
// The `type` field is the sole discriminator. No fallback to message.role needed.

public enum JSONLEntryType: String, Codable, CaseIterable {
    // Transcript messages (participate in parentUuid chain)
    case user
    case assistant
    case system
    case attachment

    // Session metadata
    case summary
    case customTitle = "custom-title"
    case aiTitle = "ai-title"
    case lastPrompt = "last-prompt"
    case taskSummary = "task-summary"
    case tag

    // Agent metadata
    case agentName = "agent-name"
    case agentColor = "agent-color"
    case agentSetting = "agent-setting"

    // Integration
    case prLink = "pr-link"

    // Session state
    case mode
    case worktreeState = "worktree-state"

    // Attribution & history (internal, typically skipped for display)
    case fileHistorySnapshot = "file-history-snapshot"
    case attributionSnapshot = "attribution-snapshot"

    // Content management (internal)
    case contentReplacement = "content-replacement"

    // Context collapse (internal, obfuscated names)
    case contextCollapseCommit = "marble-origami-commit"
    case contextCollapseSnapshot = "marble-origami-snapshot"

    // Performance
    case speculationAccept = "speculation-accept"

    // Queue operations
    case queueOperation = "queue-operation"

    /// Whether this entry type is a transcript message (user/assistant/system/attachment).
    /// Aligned with official `isTranscriptMessage()`.
    var isTranscriptMessage: Bool {
        switch self {
        case .user, .assistant, .system, .attachment:
            return true
        default:
            return false
        }
    }

    /// Whether this entry type is a conversation message (user/assistant).
    /// These participate in the parentUuid chain and form the dialogue.
    var isConversationMessage: Bool {
        self == .user || self == .assistant
    }

    /// Whether this entry type carries session-scoped metadata.
    var isSessionMetadata: Bool {
        switch self {
        case .customTitle, .aiTitle, .tag, .agentName, .agentColor,
             .agentSetting, .prLink, .mode, .worktreeState:
            return true
        default:
            return false
        }
    }
}

/// Message types persisted to SwiftData. Expanded from official transcript types.
public enum MessageType: String, Codable {
    case user
    case assistant
    case system
    case attachment
}

@Model
public class Message {
    @Attribute(.unique) public var uuid: String
    public var session: Session?
    public var parentUuid: String?
    public var type: MessageType
    public var timestamp: Date
    public var rawJson: Data

    // --- Decoded cache (@Transient: memory only, never persisted) ---
    // As long as rawJson stays unchanged, ensureDecoded() only decodes once.
    @Transient private var _decoded = false
    @Transient private var _content: String?
    @Transient private var _thinking: String?
    @Transient private var _model: String?
    @Transient private var _role: String?
    @Transient private var _entryType: String?
    @Transient private var _blockTypes: [String] = []
    @Transient private var _toolUses: [ToolUseInfo] = []
    @Transient private var _toolResults: [ToolResultData]?
    @Transient private var _toolResultImages: [ToolResultImage] = []
    @Transient private var _patchMap: [String: [StructuredPatchHunk]]?

    public var content: String? { ensureDecoded(); return _content }
    public var thinking: String? { ensureDecoded(); return _thinking }
    public var model: String? { ensureDecoded(); return _model }
    public var role: String? { ensureDecoded(); return _role }
    public var entryType: String? { ensureDecoded(); return _entryType }
    public var blockTypes: [String] { ensureDecoded(); return _blockTypes }
    public var toolUses: [ToolUseInfo] { ensureDecoded(); return _toolUses }
    public var toolResults: [ToolResultData]? { ensureDecoded(); return _toolResults }
    public var toolResultImages: [ToolResultImage] { ensureDecoded(); return _toolResultImages }
    public var toolUseResultsWithPatch: [String: [StructuredPatchHunk]]? { ensureDecoded(); return _patchMap }

    // Decode all fields once and populate every cache slot.
    private func ensureDecoded() {
        guard !_decoded else { return }
        _decoded = true

        guard let raw = try? Self.sharedDecoder.decode(RawMessageData.self, from: rawJson),
              let message = raw.message else { return }

        _model = message.model
        _role = message.role
        _entryType = message.type

        if let str = message.contentString {
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            _content = (trimmed.isEmpty || trimmed == "[]" || trimmed == "\"\"") ? nil : str
        } else if let blocks = message.content {
            var seenBlockTypes = Set<String>()
            var orderedBlockTypes: [String] = []
            for block in blocks {
                if seenBlockTypes.insert(block.type).inserted {
                    orderedBlockTypes.append(block.type)
                }
            }
            _blockTypes = orderedBlockTypes
            let isAssistantRole = message.role.lowercased() == "assistant"
            let textSegments = blocks.compactMap { block -> String? in
                // Non-user-facing blocks should never become assistant message body text.
                // For user role, keep `tool_result` text so command outputs/files remain visible.
                if block.type == "tool_use" { return nil }
                if block.type == "thinking" { return nil }
                if isAssistantRole && block.type == "tool_result" {
                    return nil
                }
                // Standard text block.
                if block.type == "text", let text = block.text, !text.isEmpty {
                    return text
                }
                // Fallback for future text-like block variants.
                if let text = block.text,
                   !text.isEmpty {
                    return text
                }
                // Fallback when content itself contains a string payload.
                if let contentText = Self.extractText(from: block.content?.value), !contentText.isEmpty {
                    return contentText
                }
                return nil
            }
            let mergedText = textSegments.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            _content = mergedText.isEmpty ? nil : mergedText
            _thinking = blocks.first(where: { $0.type == "thinking" })?.thinking

            // toolUses from assistant messages.
            _toolUses = blocks.compactMap { block -> ToolUseInfo? in
                guard block.type == "tool_use", let name = block.name else { return nil }
                var filePath: String?
                var command: String?
                var oldString: String?
                var newString: String?
                var prompt: String?
                var inputSummary: String?
                if let input = block.input?.value as? [String: Any] {
                    filePath = input["file_path"] as? String
                    command = input["command"] as? String
                    oldString = input["old_string"] as? String
                    newString = input["new_string"] as? String
                    prompt = input["prompt"] as? String
                    if name == "Agent" || name == "Task" || name == "Subagent" {
                        inputSummary = (input["prompt"] as? String)
                            ?? (input["description"] as? String)
                    } else {
                        inputSummary = (input["description"] as? String)
                            ?? (input["prompt"] as? String)
                    }
                    inputSummary = inputSummary
                        ?? (input["query"] as? String)
                        ?? (input["content"] as? String)
                        ?? (input["text"] as? String)
                        ?? (input["pattern"] as? String)
                }
                let rawInput: String? = {
                    guard let input = block.input?.value as? [String: Any] else { return nil }
                    guard let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .prettyPrinted]),
                          let str = String(data: data, encoding: .utf8) else { return nil }
                    return str
                }()
                return ToolUseInfo(id: block.id ?? "", name: name, filePath: filePath, command: command, oldString: oldString, newString: newString, prompt: prompt, inputSummary: inputSummary, rawInput: rawInput)
            }

            // toolResults from user messages.
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

            let images: [ToolResultImage] = blocks.compactMap { block in
                guard block.type == "tool_result" else { return nil }
                guard let arr = block.content?.value as? [[String: Any]] else { return nil }
                for item in arr {
                    guard (item["type"] as? String) == "image",
                          let source = item["source"] as? [String: Any],
                          (source["type"] as? String) == "base64",
                          let data = source["data"] as? String,
                          !data.isEmpty else { continue }
                    let mediaType = (source["media_type"] as? String) ?? "image/png"
                    return ToolResultImage(mediaType: mediaType, base64: data)
                }
                return nil
            }
            _toolResultImages = images

            // patchMap from structuredPatch values embedded in tool_result content.
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

    /// Preload all decoded properties to avoid doing work on the main thread while scrolling.
    public func preload() { ensureDecoded() }

    /// Lightweight external check for whether decoding already happened.
    public var isDecoded: Bool { _decoded }

    func invalidateCache() {
        _decoded = false
        _content = nil; _thinking = nil; _model = nil; _role = nil; _entryType = nil; _blockTypes = []
        _toolUses = []; _toolResults = nil; _toolResultImages = []; _patchMap = nil
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

    public init(uuid: String, type: MessageType, timestamp: Date, rawJson: Data, parentUuid: String? = nil) {
        self.uuid = uuid
        self.type = type
        self.timestamp = timestamp
        self.rawJson = rawJson
        self.parentUuid = parentUuid
    }
}

// MARK: - JSON Decoding Structures

public struct RawMessageData: Codable {
    public var type: String
    public var uuid: String?
    public var parentUuid: String?
    public var sessionId: String?
    public var timestamp: String?
    public var cwd: String?
    public var gitBranch: String?
    public var slug: String?
    public var message: RawMessageContent?
    public var originalLineData: Data?

    // --- Metadata entry fields (decoded as optional, absent on transcript messages) ---
    /// summary / custom-title / ai-title
    public var summary: String?
    public var leafUuid: String?
    public var customTitle: String?
    public var aiTitle: String?
    public var lastPrompt: String?
    // task-summary reuses `summary` field — distinguished by type == "task-summary"

    // --- tag / agent-name / agent-color / agent-setting ---
    public var tag: String?
    public var agentName: String?
    public var agentColor: String?
    public var agentSetting: String?

    // --- pr-link ---
    public var prNumber: Int?
    public var prUrl: String?
    public var prRepository: String?

    // --- mode ---
    public var mode: String?

    // --- system message subtype ---
    public var subtype: String?
    public var level: String?

    // --- worktree-state ---
    // Storing as raw JSON string; decoding on demand is not needed for display.
    public var worktreeSession: AnyCodable?

    // --- content-replacement ---
    public var replacements: AnyCodable?

    // --- context-collapse (marble-origami) ---
    public var collapseId: String?
    public var summaryUuid: String?
    public var summaryContent: String?
    public var firstArchivedUuid: String?
    public var lastArchivedUuid: String?

    // --- file-history-snapshot / attribution-snapshot ---
    public var messageId: String?

    // --- speculation-accept ---
    public var timeSavedMs: Int?

    // --- system init / informational ---
    public var content: AnyCodable?
    public var isMeta: Bool?
    public var preventContinuation: Bool?

    // --- compact boundary ---
    public var compactMetadata: AnyCodable?

    enum CodingKeys: String, CodingKey {
        case type, uuid, parentUuid, sessionId, timestamp, cwd, gitBranch, slug, message
        case summary, leafUuid, customTitle, aiTitle, lastPrompt
        case tag, agentName, agentColor, agentSetting
        case prNumber, prUrl, prRepository, mode
        case subtype, level
        case worktreeSession, replacements
        case collapseId, summaryUuid, summaryContent, firstArchivedUuid, lastArchivedUuid
        case messageId, timeSavedMs
        case content, isMeta, preventContinuation, compactMetadata
    }

    /// Resolved entry type. Returns nil for unknown/unparseable types.
    public var entryType: JSONLEntryType? {
        JSONLEntryType(rawValue: type.lowercased())
    }

    public init(
        type: String,
        uuid: String? = nil,
        parentUuid: String? = nil,
        sessionId: String? = nil,
        timestamp: String? = nil,
        cwd: String? = nil,
        gitBranch: String? = nil,
        slug: String? = nil,
        message: RawMessageContent? = nil,
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

public struct RawMessageContent: Codable {
    public var type: String?
    public var role: String
    public var content: [ContentBlock]?
    public var contentString: String?
    public var model: String?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        role = try container.decode(String.self, forKey: .role)
        model = try container.decodeIfPresent(String.self, forKey: .model)

        // content may be either a string or an array of blocks.
        if let stringContent = try? container.decode(String.self, forKey: .content) {
            contentString = stringContent
            content = nil
        } else {
            content = try container.decodeIfPresent([ContentBlock].self, forKey: .content)
            contentString = nil
        }
    }

    enum CodingKeys: String, CodingKey {
        case type, role, content, model
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(type, forKey: .type)
        try container.encode(role, forKey: .role)
        try container.encodeIfPresent(model, forKey: .model)
        if let stringContent = contentString {
            try container.encode(stringContent, forKey: .content)
        } else {
            try container.encodeIfPresent(content, forKey: .content)
        }
    }
}

public struct ContentBlock: Codable {
    public var type: String
    public var text: String?
    public var thinking: String?
    public var id: String?
    public var name: String?
    public var input: AnyCodable?
    public var tool_use_id: String?
    public var content: AnyCodable?
    public var is_error: Bool?
}

public struct ToolResultData: Codable {
    public var type: String?
    public var tool_use_id: String?
    public var content: String?
    public var is_error: Bool?
}

public struct ToolResultImage: Codable, Equatable {
    public var mediaType: String
    public var base64: String
}

// MARK: - StructuredPatch (diff metadata from Edit results)

public struct StructuredPatchHunk: Codable, Equatable {
    public var oldStart: Int
    public var oldLines: Int
    public var newStart: Int
    public var newLines: Int
    public var lines: [String]
}

public struct ToolUseResultData: Codable {
    public var filePath: String?
    public var structuredPatch: [StructuredPatchHunk]?
}

public struct ToolUseInfo: Identifiable {
    public var id: String
    public var name: String
    public var filePath: String?
    public var command: String?
    public var oldString: String?
    public var newString: String?
    public var prompt: String?
    public var inputSummary: String?
    public var rawInput: String?
}

// Helper for decoding arbitrary JSON
public struct AnyCodable: Codable {
    public let value: Any

    public init(_ value: Any) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
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

    public func encode(to encoder: Encoder) throws {
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
