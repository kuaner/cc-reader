import Foundation

enum JSONLWriter {
    static func backup(url: URL) async throws {
        try await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            let backupUrl = url.deletingPathExtension().appendingPathExtension("bak")
            if fileManager.fileExists(atPath: backupUrl.path) {
                try fileManager.removeItem(at: backupUrl)
            }
            try fileManager.copyItem(at: url, to: backupUrl)
        }.value
    }

    static func deleteMessages(uuids: [String], from url: URL) async throws {
        try await Task.detached(priority: .utility) {
            let uuidSet = Set(uuids)
            guard !uuidSet.isEmpty else { return }

            let content = try String(contentsOf: url, encoding: .utf8)
            let lines = content.components(separatedBy: .newlines)
            var filteredLines: [String] = []

            for line in lines {
                guard !line.isEmpty else { continue }
                if let data = line.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let uuid = json["uuid"] as? String {
                    if !uuidSet.contains(uuid) {
                        filteredLines.append(line)
                    }
                } else {
                    filteredLines.append(line)
                }
            }

            let newContent = filteredLines.joined(separator: "\n")
            try newContent.write(to: url, atomically: true, encoding: .utf8)
        }.value
    }

    static func restore(url: URL) async throws {
        try await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            let backupUrl = url.deletingPathExtension().appendingPathExtension("bak")
            guard fileManager.fileExists(atPath: backupUrl.path) else {
                throw JSONLWriterError.backupNotFound
            }
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
            try fileManager.copyItem(at: backupUrl, to: url)
        }.value
    }

    /// 特定メッセージのcontentを更新（要約編集用）
    static func updateMessageContent(uuid: String, newContent: String, in url: URL) async throws {
        try await Task.detached(priority: .utility) {
            let content = try String(contentsOf: url, encoding: .utf8)
            let lines = content.components(separatedBy: .newlines)
            var updatedLines: [String] = []

            for line in lines {
                guard !line.isEmpty else { continue }
                guard let data = line.data(using: .utf8),
                      var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let lineUuid = json["uuid"] as? String else {
                    updatedLines.append(line)
                    continue
                }

                if lineUuid == uuid {
                    if var message = json["message"] as? [String: Any] {
                        if var contentArray = message["content"] as? [[String: Any]] {
                            for i in contentArray.indices {
                                if contentArray[i]["type"] as? String == "text" {
                                    contentArray[i]["text"] = newContent
                                }
                            }
                            message["content"] = contentArray
                        } else if message["content"] is String {
                            message["content"] = newContent
                        }
                        json["message"] = message
                    }

                    if let updatedData = try? JSONSerialization.data(withJSONObject: json),
                       let updatedLine = String(data: updatedData, encoding: .utf8) {
                        updatedLines.append(updatedLine)
                    } else {
                        updatedLines.append(line)
                    }
                } else {
                    updatedLines.append(line)
                }
            }

            let newContentString = updatedLines.joined(separator: "\n")
            try newContentString.write(to: url, atomically: true, encoding: .utf8)
        }.value
    }

    /// 指定UUID以降のメッセージを全て削除（Rewind用）
    static func deleteMessagesAfter(uuid: String, from url: URL, inclusive: Bool = false) async throws {
        try await Task.detached(priority: .utility) {
            let content = try String(contentsOf: url, encoding: .utf8)
            let lines = content.components(separatedBy: .newlines)
            var filteredLines: [String] = []
            var foundTarget = false

            for line in lines {
                guard !line.isEmpty else { continue }

                if let data = line.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let lineUuid = json["uuid"] as? String {
                    if lineUuid == uuid {
                        foundTarget = true
                        if !inclusive {
                            filteredLines.append(line)
                        }
                        continue
                    }
                    if foundTarget {
                        continue // Skip messages after target
                    }
                }

                filteredLines.append(line)
            }

            let newContent = filteredLines.joined(separator: "\n")
            try newContent.write(to: url, atomically: true, encoding: .utf8)
        }.value
    }
}

enum JSONLWriterError: LocalizedError {
    case backupNotFound

    var errorDescription: String? {
        switch self {
        case .backupNotFound:
            return "バックアップファイルが見つかりません"
        }
    }
}
