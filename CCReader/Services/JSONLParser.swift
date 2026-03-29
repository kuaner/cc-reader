import Foundation

final class JSONLParser: @unchecked Sendable {
    // Track file offsets for incremental parsing.
    private var fileOffsets: [URL: UInt64] = [:]
    private let lock = NSLock()

    // Parse a whole file from the beginning.
    func parseFile(url: URL) throws -> [RawMessageData] {
        let data = try Data(contentsOf: url)
        return parseData(data)
    }

    // Parse only the newly appended data.
    func parseNewLines(url: URL) throws -> [RawMessageData] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        // Determine the current file size.
        try handle.seekToEnd()
        let fileSize = try handle.offset()

        // Load the stored offset and reset it if the file shrank.
        lock.lock()
        var currentOffset = fileOffsets[url] ?? 0
        lock.unlock()

        if currentOffset > fileSize {
            // Reset when the file has been truncated.
            currentOffset = 0
        }

        try handle.seek(toOffset: currentOffset)
        let newData = handle.readDataToEndOfFile()

        // Record the new end-of-file offset.
        lock.lock()
        fileOffsets[url] = fileSize
        lock.unlock()

        return parseData(newData)
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
        let decoder = JSONDecoder()

        // Split the Data directly to avoid String -> Data round-trips.
        for lineSlice in data.split(separator: newline, omittingEmptySubsequences: true) {
            let lineData = Data(lineSlice)
            do {
                var message = try decoder.decode(RawMessageData.self, from: lineData)
                message.originalLineData = lineData
                messages.append(message)
            } catch {
                if ProcessInfo.processInfo.environment["CCREADER_DEBUG_JSONL_DECODE"] == "1",
                   let lineStr = String(data: lineData, encoding: .utf8) {
                    let preview = lineStr.prefix(200)
                    print("[cc-reader][JSONLParser] Skipped line (decode failed): \(preview)…")
                }
            }
        }

        return messages
    }
}

// MARK: - Helper Extensions

extension JSONLParser {
    // Derive a display name from the project path.
    static func displayName(from path: String) -> String {
        // "-Users-toro-myapp-Mugendesk" -> "Mugendesk"
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
