import Foundation

class JSONLParser {
    // ファイルオフセットを記録（差分パース用）
    private var fileOffsets: [URL: UInt64] = [:]
    private let lock = NSLock()

    // ファイル全体をパース
    func parseFile(url: URL) throws -> [RawMessageData] {
        let data = try Data(contentsOf: url)
        return parseData(data)
    }

    // 差分のみパース（最終行から）
    func parseNewLines(url: URL) throws -> [RawMessageData] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        // ファイルサイズを取得
        try handle.seekToEnd()
        let fileSize = try handle.offset()

        // 現在のオフセットを取得（ファイルサイズより大きい場合はリセット）
        lock.lock()
        var currentOffset = fileOffsets[url] ?? 0
        lock.unlock()

        if currentOffset > fileSize {
            // ファイルが縮小された（削除などで）場合はリセット
            currentOffset = 0
        }

        try handle.seek(toOffset: currentOffset)
        let newData = handle.readDataToEndOfFile()

        // 新しいオフセットを記録
        lock.lock()
        fileOffsets[url] = fileSize
        lock.unlock()

        return parseData(newData)
    }

    // オフセットをリセット
    func resetOffset(for url: URL) {
        lock.lock()
        fileOffsets.removeValue(forKey: url)
        lock.unlock()
    }

    // 全オフセットをリセット
    func resetAllOffsets() {
        lock.lock()
        fileOffsets.removeAll()
        lock.unlock()
    }

    // 現在のオフセットを取得
    func currentOffset(for url: URL) -> UInt64 {
        lock.lock()
        let offset = fileOffsets[url] ?? 0
        lock.unlock()
        return offset
    }

    // オフセットを設定
    func setOffset(_ offset: UInt64, for url: URL) {
        lock.lock()
        fileOffsets[url] = offset
        lock.unlock()
    }

    // MARK: - Private

    private func parseData(_ data: Data) -> [RawMessageData] {
        guard let string = String(data: data, encoding: .utf8) else { return [] }

        let lines = string.components(separatedBy: .newlines)
        var messages: [RawMessageData] = []

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard let lineData = trimmed.data(using: .utf8) else { continue }

            do {
                let message = try decoder.decode(RawMessageData.self, from: lineData)
                messages.append(message)
            } catch {
                // パースできない行はスキップ（ログは必要に応じて）
                print("Failed to parse line: \(error)")
            }
        }

        return messages
    }
}

// MARK: - Helper Extensions

extension JSONLParser {
    // プロジェクトパスからディスプレイ名を生成
    static func displayName(from path: String) -> String {
        // "-Users-toro-myapp-Mugendesk" -> "Mugendesk"
        let components = path.split(separator: "-")
        return String(components.last ?? Substring(path))
    }

    // sessionIdをファイル名から抽出
    static func sessionId(from url: URL) -> String? {
        let filename = url.deletingPathExtension().lastPathComponent
        // agent-xxx.jsonl は除外
        if filename.hasPrefix("agent-") {
            return nil
        }
        return filename
    }
}
