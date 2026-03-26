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
    let toolUses: [ToolUseInfo]
    let toolResults: [ToolResultData]?
    let rawJsonString: String

    var id: String { uuid }

    init(message: Message) {
        self.uuid = message.uuid
        self.rawFingerprint = message.rawJson.hashValue
        self.type = message.type
        self.timestamp = message.timestamp
        self.content = message.content
        self.thinking = message.thinking
        self.model = message.model
        self.toolUses = message.toolUses
        self.toolResults = message.toolResults
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
        lhs.toolUses.map(\.id) == rhs.toolUses.map(\.id) &&
        lhs.toolResults?.map(\.tool_use_id) == rhs.toolResults?.map(\.tool_use_id) &&
        lhs.toolResults?.map(\.content) == rhs.toolResults?.map(\.content) &&
        lhs.toolResults?.map(\.is_error) == rhs.toolResults?.map(\.is_error)
    }
}

struct TimelineRenderSnapshot {
    var generation = 0
    var visibleMessages: [TimelineMessageDisplayData] = []
    var prevTimestampMap: [String: Date] = [:]
    var derivedPatchMap: [String: [StructuredPatchHunk]] = [:]
    var derivedContextMap: [String: ContextItem] = [:]
    var hasSummaryThinking = false
    var rowPatchesMap: [String: [String: [StructuredPatchHunk]]] = [:]
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