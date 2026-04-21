import Foundation
import SwiftUI

struct TimelineRenderSnapshot {
    var generation = 0
    var visibleMessages: [Message] = []
    /// True when earlier messages exist outside `visibleMessages` and must be fetched on demand.
    var hasMoreBeforeLoaded = false
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
    var commandItems: [ContextItem] = []
    var searchItems: [ContextItem] = []
    var toolItems: [ContextItem] = []
}

struct ContextItem: Identifiable, Hashable {
    let id: String
    let toolName: String
    let filePath: String?
    let command: String?
    let inputSummary: String?
    let content: String
    let isError: Bool

    var displayTitle: String {
        if let path = filePath {
            return (path as NSString).lastPathComponent
        }
        if let cmd = command {
            return String(cmd.prefix(30))
        }
        if let inputSummary, !inputSummary.isEmpty {
            return String(inputSummary.prefix(42))
        }
        return toolName
    }

    var color: Color {
        switch toolName {
        case "Read": return .blue
        case "Edit": return .orange
        case "Write": return .green
        case "Bash": return .purple
        case "WebSearch": return .cyan
        default: return .gray
        }
    }

    var icon: String {
        switch toolName {
        case "Read": return "doc.text"
        case "Edit": return "pencil"
        case "Write": return "doc.badge.plus"
        case "Bash": return "terminal"
        case "WebSearch": return "magnifyingglass"
        default: return "wrench"
        }
    }
}
