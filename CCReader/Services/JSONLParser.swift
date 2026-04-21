import Foundation

struct TimelineFileMessage: Sendable {
    let uuid: String
    let type: MessageType
    let timestamp: Date
    let rawJson: Data
    let parentUuid: String?

    func makeMessage() -> Message {
        Message(
            uuid: uuid,
            type: type,
            timestamp: timestamp,
            rawJson: rawJson,
            parentUuid: parentUuid
        )
    }
}

struct TimelineFilePage: Sendable {
    let messages: [TimelineFileMessage]
    let startOffset: UInt64
    let endOffset: UInt64
    let hasMoreBefore: Bool
}

final class JSONLParser: @unchecked Sendable {
    // Track file offsets for incremental parsing.
    private var fileOffsets: [URL: UInt64] = [:]
    private let lock = NSLock()

    private static let sharedEncoder = JSONEncoder()
    private static let timestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // Parse a whole file from the beginning.
    func parseFile(url: URL) throws -> [RawMessageData] {
        let data = try Data(contentsOf: url)
        return parseData(data)
    }

    // Parse only the newly appended data.
    func parseNewLines(url: URL) throws -> [RawMessageData] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        try handle.seekToEnd()
        let fileSize = try handle.offset()

        lock.lock()
        var currentOffset = fileOffsets[url] ?? 0
        lock.unlock()

        if currentOffset > fileSize {
            currentOffset = 0
        }

        try handle.seek(toOffset: currentOffset)
        let newData = handle.readDataToEndOfFile()

        lock.lock()
        fileOffsets[url] = fileSize
        lock.unlock()

        return parseData(newData)
    }

    func parseTimelineMessages(url: URL) throws -> [TimelineFileMessage] {
        buildTimelineMessages(from: try parseFile(url: url))
    }

    func parseTimelineMessages(url: URL, afterOffset: UInt64) throws -> ([TimelineFileMessage], UInt64) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        try handle.seekToEnd()
        let fileSize = try handle.offset()
        let startOffset = min(afterOffset, fileSize)
        try handle.seek(toOffset: startOffset)
        let newData = handle.readDataToEndOfFile()
        return (buildTimelineMessages(from: parseData(newData)), fileSize)
    }

    func parseTimelinePage(url: URL, beforeOffset: UInt64? = nil, limit: Int) throws -> TimelineFilePage {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        try handle.seekToEnd()
        let fileSize = try handle.offset()
        let endOffset = min(beforeOffset ?? fileSize, fileSize)
        guard limit > 0, endOffset > 0 else {
            return TimelineFilePage(messages: [], startOffset: 0, endOffset: endOffset, hasMoreBefore: false)
        }

        var cursor = endOffset
        var leadingPartial = Data()
        var selected: [(offset: UInt64, message: TimelineFileMessage)] = []
        var seenUuids: Set<String> = []

        while cursor > 0 && selected.count < limit {
            let chunkStart = max(UInt64(0), cursor - 64 * 1024)
            let chunkLength = Int(cursor - chunkStart)
            try handle.seek(toOffset: chunkStart)
            let chunk = handle.readData(ofLength: chunkLength)

            var combined = chunk
            combined.append(leadingPartial)

            let split = splitLines(
                in: combined,
                baseOffset: chunkStart,
                includeLeadingPartial: chunkStart == 0
            )
            leadingPartial = split.leadingPartial

            for line in split.lines.reversed() {
                guard let raw = decodeLine(line.data),
                      let message = Self.makeTimelineMessage(from: raw) else {
                    continue
                }
                if seenUuids.insert(message.uuid).inserted {
                    selected.append((line.startOffset, message))
                    if selected.count == limit { break }
                }
            }

            cursor = chunkStart
        }

        if cursor == 0,
           !leadingPartial.isEmpty,
           selected.count < limit,
           let raw = decodeLine(leadingPartial),
           let message = Self.makeTimelineMessage(from: raw),
           seenUuids.insert(message.uuid).inserted {
            selected.append((0, message))
        }

        let pageMessages = selected.reversed().map(\.message)
        let startOffset = selected.last?.offset ?? endOffset
        return TimelineFilePage(
            messages: pageMessages,
            startOffset: startOffset,
            endOffset: endOffset,
            hasMoreBefore: startOffset > 0
        )
    }

    // Reset the offset for one file.
    func resetOffset(for url: URL) {
        lock.lock()
        fileOffsets.removeValue(forKey: url)
        lock.unlock()
    }

    // Reset offsets for every tracked file.
    func resetAllOffsets() {
        lock.lock()
        fileOffsets.removeAll()
        lock.unlock()
    }

    // Read the stored offset for a file.
    func currentOffset(for url: URL) -> UInt64 {
        lock.lock()
        let offset = fileOffsets[url] ?? 0
        lock.unlock()
        return offset
    }

    // Persist a new offset value.
    func setOffset(_ offset: UInt64, for url: URL) {
        lock.lock()
        fileOffsets[url] = offset
        lock.unlock()
    }

    // MARK: - Private

    private func parseData(_ data: Data) -> [RawMessageData] {
        var messages: [RawMessageData] = []
        let newline = UInt8(ascii: "\n")

        for lineSlice in data.split(separator: newline, omittingEmptySubsequences: true) {
            let lineData = Data(lineSlice)
            if let message = decodeLine(lineData) {
                messages.append(message)
            }
        }

        return messages
    }

    private func decodeLine(_ lineData: Data) -> RawMessageData? {
        let decoder = JSONDecoder()
        do {
            var message = try decoder.decode(RawMessageData.self, from: lineData)
            message.originalLineData = lineData
            return message
        } catch {
            if ProcessInfo.processInfo.environment["CCREADER_DEBUG_JSONL_DECODE"] == "1",
               let lineStr = String(data: lineData, encoding: .utf8) {
                let preview = lineStr.prefix(200)
                print("[cc-reader][JSONLParser] Skipped line (decode failed): \(preview)…")
            }
            return nil
        }
    }

    private func buildTimelineMessages(from rawMessages: [RawMessageData]) -> [TimelineFileMessage] {
        var orderedIds: [String] = []
        var messagesById: [String: TimelineFileMessage] = [:]
        orderedIds.reserveCapacity(rawMessages.count)

        for raw in rawMessages {
            guard let message = Self.makeTimelineMessage(from: raw) else { continue }
            if messagesById[message.uuid] == nil {
                orderedIds.append(message.uuid)
            }
            messagesById[message.uuid] = message
        }

        return orderedIds
            .compactMap { messagesById[$0] }
            .sorted {
                if $0.timestamp == $1.timestamp {
                    return $0.uuid < $1.uuid
                }
                return $0.timestamp < $1.timestamp
            }
    }

    private func splitLines(
        in data: Data,
        baseOffset: UInt64,
        includeLeadingPartial: Bool
    ) -> (leadingPartial: Data, lines: [(startOffset: UInt64, data: Data)]) {
        let bytes = [UInt8](data)
        let newline = UInt8(ascii: "\n")
        var lines: [(startOffset: UInt64, data: Data)] = []
        var carry = Data()
        var lineStart = 0

        if !includeLeadingPartial {
            guard let firstNewline = bytes.firstIndex(of: newline) else {
                return (data, [])
            }
            carry = Data(bytes[0..<firstNewline])
            lineStart = firstNewline + 1
        }

        var cursor = lineStart
        while cursor < bytes.count {
            if bytes[cursor] == newline {
                if cursor > lineStart {
                    let slice = Data(bytes[lineStart..<cursor])
                    lines.append((baseOffset + UInt64(lineStart), slice))
                }
                lineStart = cursor + 1
            }
            cursor += 1
        }

        if lineStart < bytes.count {
            let slice = Data(bytes[lineStart..<bytes.count])
            lines.append((baseOffset + UInt64(lineStart), slice))
        }

        return (carry, lines)
    }
}

// MARK: - Helper Extensions

extension JSONLParser {
    static func makeTimelineMessage(from raw: RawMessageData) -> TimelineFileMessage? {
        guard raw.entryType?.isTranscriptMessage == true else { return nil }
        guard let uuid = raw.uuid, !uuid.isEmpty else { return nil }
        guard let messageType = resolveMessageType(from: raw) else { return nil }

        let timestamp = raw.timestamp.flatMap(parseTimestamp) ?? Date()
        let rawJson: Data
        if let original = raw.originalLineData {
            rawJson = original
        } else if let encoded = try? sharedEncoder.encode(raw) {
            rawJson = encoded
        } else {
            return nil
        }

        return TimelineFileMessage(
            uuid: uuid,
            type: messageType,
            timestamp: timestamp,
            rawJson: rawJson,
            parentUuid: raw.parentUuid
        )
    }

    static func resolveMessageType(from raw: RawMessageData) -> MessageType? {
        switch raw.type.lowercased() {
        case "user":
            return .user
        case "assistant":
            return .assistant
        case "system":
            return .system
        case "attachment":
            return .attachment
        default:
            return nil
        }
    }

    static func parseTimestamp(_ string: String) -> Date? {
        timestampFormatter.date(from: string)
    }

    // Derive a display name from the project path.
    static func displayName(from path: String) -> String {
        let components = path.split(separator: "-")
        return String(components.last ?? Substring(path))
    }

    // Extract the sessionId from the file name (including agent-*.jsonl subagent transcripts).
    static func sessionId(from url: URL) -> String? {
        let filename = url.deletingPathExtension().lastPathComponent
        guard !filename.isEmpty else { return nil }
        return filename
    }
}
