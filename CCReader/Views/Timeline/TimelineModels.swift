import Foundation
import SwiftUI

struct TimelineMessageDisplayData: Identifiable, Equatable {
    let uuid: String
    let rawFingerprint: Int
    let type: MessageType
    let timestamp: Date
    let content: String?
    let thinking: String?
    let model: String?
    let role: String?
    let entryType: String?
    let blockTypes: [String]
    let toolUses: [ToolUseInfo]
    let toolResults: [ToolResultData]?
    let toolResultImages: [ToolResultImage]
    let rawJsonString: String

    var id: String { uuid }

    /// DOM `id` for timeline rows (`#msg-<uuid>`), must match `timeline-shell.js` / incremental payload `domId`.
    var timelineDOMId: String { "msg-\(uuid)" }

    init(message: Message) {
        self.uuid = message.uuid
        self.rawFingerprint = message.rawJson.hashValue
        self.type = message.type
        self.timestamp = message.timestamp
        self.content = message.content
        self.thinking = message.thinking
        self.model = message.model
        self.role = message.role
        self.entryType = message.entryType
        self.blockTypes = message.blockTypes
        self.toolUses = message.toolUses
        self.toolResults = message.toolResults
        self.toolResultImages = message.toolResultImages
        // Avoid expensive JSON parsing/pretty-printing on the main thread during session switches.
        // rawJsonString is used for "Raw Data" copy/export; preserving the raw JSON bytes is sufficient.
        self.rawJsonString = String(data: message.rawJson, encoding: .utf8) ?? ""
    }

    static func == (lhs: TimelineMessageDisplayData, rhs: TimelineMessageDisplayData) -> Bool {
        lhs.uuid == rhs.uuid &&
        lhs.rawFingerprint == rhs.rawFingerprint &&
        lhs.type == rhs.type &&
        lhs.timestamp == rhs.timestamp &&
        lhs.content == rhs.content &&
        lhs.thinking == rhs.thinking &&
        lhs.model == rhs.model &&
        lhs.role == rhs.role &&
        lhs.entryType == rhs.entryType &&
        lhs.blockTypes == rhs.blockTypes &&
        lhs.toolUses.map(\.id) == rhs.toolUses.map(\.id) &&
        lhs.toolResults?.map(\.tool_use_id) == rhs.toolResults?.map(\.tool_use_id) &&
        lhs.toolResults?.map(\.content) == rhs.toolResults?.map(\.content) &&
        lhs.toolResults?.map(\.is_error) == rhs.toolResults?.map(\.is_error) &&
        lhs.toolResultImages.map { "\($0.mediaType):\($0.base64.count)" } ==
        rhs.toolResultImages.map { "\($0.mediaType):\($0.base64.count)" }
    }
}

struct TimelineRenderSnapshot {
    var generation = 0
    var visibleMessages: [TimelineMessageDisplayData] = []
    /// When non-zero, `visibleMessages` is only `visible[tailStartIndex..<totalVisibleCount)` (suffix-first paint).
    var tailStartIndex = 0
    /// Total logical message count for windowing; 0 means use `visibleMessages.count`.
    var totalVisibleCount = 0
    var prevTimestampMap: [String: Date] = [:]
    var derivedPatchMap: [String: [StructuredPatchHunk]] = [:]
    var derivedContextMap: [String: ContextItem] = [:]
    var hasSummaryThinking = false
    var rowPatchesMap: [String: [String: [StructuredPatchHunk]]] = [:]

    /// Logical row count for `TimelineHostView` windowing (full session length when suffix-only snapshot is used).
    var effectiveVisibleCount: Int {
        totalVisibleCount > 0 ? totalVisibleCount : visibleMessages.count
    }
}

struct ContextPanelSnapshot: Equatable {
    var latestThinking: String? = nil
    var readFiles: [ContextItem] = []
    var editedFiles: [ContextItem] = []
    var writtenFiles: [ContextItem] = []
}

struct ContextItem: Identifiable, Hashable {
    let id: String
    let toolName: String
    let filePath: String?
    let command: String?
    let content: String
    let isError: Bool

    var displayTitle: String {
        if let path = filePath {
            return (path as NSString).lastPathComponent
        }
        if let cmd = command {
            return String(cmd.prefix(30))
        }
        return toolName
    }

    var color: Color {
        switch toolName {
        case "Read": return .blue
        case "Edit": return .orange
        case "Write": return .green
        case "Bash": return .purple
        default: return .gray
        }
    }

    var icon: String {
        switch toolName {
        case "Read": return "doc.text"
        case "Edit": return "pencil"
        case "Write": return "doc.badge.plus"
        case "Bash": return "terminal"
        default: return "wrench"
        }
    }
}