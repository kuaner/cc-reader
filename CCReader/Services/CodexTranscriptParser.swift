import Foundation

struct CodexTranscriptParser: SessionTranscriptParser {
    private struct Event: Codable {
        var type: String
        var timestamp: String?
        var payload: AnyCodable?
    }

    var source: SessionTranscriptSource { .codex }

    var rootPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.codex/sessions"
    }

    func matches(_ url: URL) -> Bool {
        url.path.contains("/.codex/sessions/")
    }

    func sessionId(from url: URL) -> String? {
        if let id = readCodexMetadata(from: url)?.id, !id.isEmpty {
            return "codex-\(id)"
        }

        let filename = url.deletingPathExtension().lastPathComponent
        guard !filename.isEmpty else { return nil }
        if let uuid = filename.split(separator: "-").suffix(5).map(String.init).joined(separator: "-").nilIfEmpty {
            return "codex-\(uuid)"
        }
        return "codex-\(filename)"
    }

    func readMetadata(from url: URL) -> SessionTranscriptMetadata? {
        guard let metadata = readCodexMetadata(from: url) else { return nil }
        return SessionTranscriptMetadata(
            cwd: metadata.cwd,
            gitBranch: metadata.gitBranch,
            title: nil,
            model: metadata.model,
            timestamp: metadata.timestamp
        )
    }

    func parseLine(_ lineData: Data, sourceURL: URL) -> RawMessageData? {
        guard let event = Self.decodeEvent(lineData) else { return nil }
        switch event.type {
        case "session_meta":
            return Self.metadataMessage(from: event, sourceURL: sourceURL)
        case "response_item":
            return Self.responseItemMessage(from: event, sourceURL: sourceURL)
        case "compacted":
            return Self.compactedMessage(from: event, sourceURL: sourceURL)
        default:
            return nil
        }
    }

    private struct CodexMetadata: Sendable {
        let id: String?
        let cwd: String?
        let gitBranch: String?
        let model: String?
        let timestamp: String?
    }

    private func readCodexMetadata(from url: URL) -> CodexMetadata? {
        guard let line = Self.firstLine(from: url),
              let event = Self.decodeEvent(line),
              event.type == "session_meta",
              let payload = event.payload?.value as? [String: Any] else {
            return nil
        }

        let git = payload["git"] as? [String: Any]
        return CodexMetadata(
            id: payload["id"] as? String,
            cwd: payload["cwd"] as? String,
            gitBranch: git?["branch"] as? String,
            model: payload["model"] as? String,
            timestamp: (payload["timestamp"] as? String) ?? event.timestamp
        )
    }

    private static func metadataMessage(from event: Event, sourceURL: URL) -> RawMessageData? {
        guard let payload = event.payload?.value as? [String: Any] else { return nil }
        var raw = RawMessageData(
            type: "system",
            uuid: stableUUID(sourceURL: sourceURL, timestamp: event.timestamp, discriminator: "session-meta"),
            timestamp: event.timestamp,
            cwd: payload["cwd"] as? String,
            gitBranch: (payload["git"] as? [String: Any])?["branch"] as? String,
            message: RawMessageContent(
                type: "message",
                role: "system",
                content: [
                    ContentBlock(type: "text", text: "Codex session started")
                ]
            )
        )
        raw.subtype = "codex_session_meta"
        return raw
    }

    private static func responseItemMessage(from event: Event, sourceURL: URL) -> RawMessageData? {
        guard let payload = event.payload?.value as? [String: Any],
              let payloadType = payload["type"] as? String else {
            return nil
        }

        switch payloadType {
        case "message":
            return messageItem(from: event, payload: payload, sourceURL: sourceURL)
        case "reasoning":
            return reasoningItem(from: event, payload: payload, sourceURL: sourceURL)
        case "function_call", "custom_tool_call":
            return toolCallItem(from: event, payload: payload, sourceURL: sourceURL)
        case "function_call_output", "custom_tool_call_output":
            return toolCallOutputItem(from: event, payload: payload, sourceURL: sourceURL)
        case "web_search_call":
            return webSearchCallItem(from: event, payload: payload, sourceURL: sourceURL)
        default:
            return nil
        }
    }

    private static func messageItem(from event: Event, payload: [String: Any], sourceURL: URL) -> RawMessageData? {
        guard let role = payload["role"] as? String else { return nil }
        guard role == "user" || role == "assistant" else { return nil }

        let blocks = contentBlocks(from: payload["content"], role: role)
        guard !blocks.isEmpty else { return nil }
        if role == "user", blocks.allSatisfy({ isSyntheticCodexUserText($0.text) }) {
            return nil
        }

        return RawMessageData(
            type: role,
            uuid: stableUUID(
                sourceURL: sourceURL,
                timestamp: event.timestamp,
                discriminator: payload["id"] as? String ?? "\(role)-\(fingerprint(payload["content"]))"
            ),
            timestamp: event.timestamp,
            message: RawMessageContent(
                type: "message",
                role: role,
                model: payload["model"] as? String,
                content: blocks
            )
        )
    }

    private static func reasoningItem(from event: Event, payload: [String: Any], sourceURL: URL) -> RawMessageData? {
        let text = extractText(from: payload["content"])
            ?? extractText(from: payload["summary"])
            ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        return RawMessageData(
            type: "assistant",
            uuid: stableUUID(
                sourceURL: sourceURL,
                timestamp: event.timestamp,
                discriminator: payload["id"] as? String ?? "reasoning-\(fingerprint(payload))"
            ),
            timestamp: event.timestamp,
            message: RawMessageContent(
                type: "message",
                role: "assistant",
                content: [
                    ContentBlock(type: "thinking", thinking: text)
                ]
            )
        )
    }

    private static func toolCallItem(from event: Event, payload: [String: Any], sourceURL: URL) -> RawMessageData? {
        let callId = (payload["call_id"] as? String) ?? (payload["id"] as? String) ?? "tool-call"
        let name = (payload["name"] as? String) ?? (payload["tool_name"] as? String) ?? "tool"
        let namespace = payload["namespace"] as? String
        let input = toolInput(name: name, payload: payload)

        return RawMessageData(
            type: "assistant",
            uuid: stableUUID(sourceURL: sourceURL, timestamp: event.timestamp, discriminator: callId),
            timestamp: event.timestamp,
            message: RawMessageContent(
                type: "message",
                role: "assistant",
                content: [
                    ContentBlock(type: "tool_use", id: callId, name: codexToolName(name, namespace: namespace), input: AnyCodable(input))
                ]
            )
        )
    }

    private static func toolCallOutputItem(from event: Event, payload: [String: Any], sourceURL: URL) -> RawMessageData? {
        let callId = (payload["call_id"] as? String) ?? (payload["id"] as? String) ?? "tool-output"
        let output = extractText(from: payload["output"])
            ?? extractText(from: payload["content"])
            ?? prettyJSON(payload)
            ?? ""

        return RawMessageData(
            type: "user",
            uuid: stableUUID(sourceURL: sourceURL, timestamp: event.timestamp, discriminator: "\(callId)-output"),
            timestamp: event.timestamp,
            message: RawMessageContent(
                type: "message",
                role: "user",
                content: [
                    ContentBlock(
                        type: "tool_result",
                        tool_use_id: callId,
                        content: AnyCodable(output),
                        is_error: payload["is_error"] as? Bool
                    )
                ]
            )
        )
    }

    private static func webSearchCallItem(from event: Event, payload: [String: Any], sourceURL: URL) -> RawMessageData? {
        let callId = (payload["call_id"] as? String)
            ?? (payload["id"] as? String)
            ?? stableUUID(sourceURL: sourceURL, timestamp: event.timestamp, discriminator: "web-search-call")
        var input: [String: Any] = [:]
        if let action = payload["action"] as? [String: Any] {
            input = action
        }
        if let status = payload["status"] as? String {
            input["status"] = status
        }

        return RawMessageData(
            type: "assistant",
            uuid: stableUUID(sourceURL: sourceURL, timestamp: event.timestamp, discriminator: callId),
            timestamp: event.timestamp,
            message: RawMessageContent(
                type: "message",
                role: "assistant",
                content: [
                    ContentBlock(type: "tool_use", id: callId, name: "WebSearch", input: AnyCodable(input))
                ]
            )
        )
    }

    private static func compactedMessage(from event: Event, sourceURL: URL) -> RawMessageData? {
        var raw = RawMessageData(
            type: "summary",
            uuid: stableUUID(sourceURL: sourceURL, timestamp: event.timestamp, discriminator: "compacted"),
            timestamp: event.timestamp
        )
        raw.summary = "Codex compacted the conversation context."
        return raw
    }

    private static func contentBlocks(from rawContent: Any?, role: String) -> [ContentBlock] {
        guard let items = rawContent as? [[String: Any]] else {
            if let text = extractText(from: rawContent), !text.isEmpty {
                return [ContentBlock(type: "text", text: text)]
            }
            return []
        }

        return items.compactMap { item in
            guard let type = item["type"] as? String else { return nil }
            switch type {
            case "input_text", "output_text", "text":
                guard let text = item["text"] as? String, !text.isEmpty else { return nil }
                return ContentBlock(type: "text", text: text)
            default:
                guard let text = extractText(from: item), !text.isEmpty else { return nil }
                return ContentBlock(type: "text", text: text)
            }
        }
    }

    private static func isSyntheticCodexUserText(_ text: String?) -> Bool {
        guard let text else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("<environment_context>")
    }

    private static func decodeArguments(_ value: Any?) -> [String: Any]? {
        if let dict = value as? [String: Any] { return dict }
        guard let string = value as? String, let data = string.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func toolInput(name: String, payload: [String: Any]) -> [String: Any] {
        if name == "apply_patch", let patch = payload["input"] as? String {
            var input: [String: Any] = ["patch": patch, "content": patch]
            if let filePath = firstPatchFilePath(in: patch) {
                input["file_path"] = filePath
            }
            return input
        }

        if let decoded = decodeArguments(payload["arguments"]) {
            return normalizedToolInput(decoded, for: name)
        }
        if let rawInput = payload["input"] as? [String: Any] {
            return normalizedToolInput(rawInput, for: name)
        }
        if let rawInput = payload["input"] as? String {
            return ["content": rawInput]
        }
        return payload
    }

    private static func firstPatchFilePath(in patch: String) -> String? {
        for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            for prefix in ["*** Update File: ", "*** Add File: ", "*** Delete File: "] {
                if text.hasPrefix(prefix) {
                    let path = String(text.dropFirst(prefix.count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !path.isEmpty { return path }
                }
            }
        }
        return nil
    }

    private static func normalizedToolInput(_ input: [String: Any], for name: String) -> [String: Any] {
        var normalized = input
        if name == "exec_command", normalized["command"] == nil, let cmd = normalized["cmd"] as? String {
            normalized["command"] = cmd
        }
        return normalized
    }

    private static func codexToolName(_ name: String, namespace: String? = nil) -> String {
        switch name {
        case "exec_command":
            return "Bash"
        case "apply_patch":
            return "Edit"
        default:
            if let namespace, namespace == "mcp__codex_apps__github" {
                return "GitHub \(name.trimmingCharacters(in: CharacterSet(charactersIn: "_")))"
            }
            if name.hasPrefix("mcp__codex_apps__github") {
                let stripped = name
                    .replacingOccurrences(of: "mcp__codex_apps__github_", with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
                return stripped.isEmpty ? "GitHub" : "GitHub \(stripped)"
            }
            return name
        }
    }

    private static func extractText(from raw: Any?) -> String? {
        switch raw {
        case let text as String:
            return text
        case let array as [[String: Any]]:
            let pieces = array.compactMap { item -> String? in
                if let text = item["text"] as? String { return text }
                if let content = item["content"] as? String { return content }
                return nil
            }
            return pieces.isEmpty ? nil : pieces.joined(separator: "\n")
        case let dict as [String: Any]:
            if let text = dict["text"] as? String { return text }
            if let content = dict["content"] as? String { return content }
            if let message = dict["message"] as? String { return message }
            return prettyJSON(dict)
        default:
            return nil
        }
    }

    private static func stableUUID(sourceURL: URL, timestamp: String?, discriminator: String) -> String {
        let source = sourceURL.deletingPathExtension().lastPathComponent
        return "\(source)-\(timestamp ?? "no-ts")-\(discriminator)".stableIdentifier
    }

    private static func decodeEvent(_ data: Data) -> Event? {
        try? JSONDecoder().decode(Event.self, from: data)
    }

    private static func firstLine(from url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var data = Data()
        while true {
            let byte = handle.readData(ofLength: 1)
            guard !byte.isEmpty else { break }
            if byte.first == UInt8(ascii: "\n") { break }
            data.append(byte)
        }
        return data.isEmpty ? nil : data
    }

    private static func prettyJSON(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func fingerprint(_ value: Any?) -> String {
        guard let value else { return "nil" }
        if let text = prettyJSON(value) ?? (value as? String) {
            return text.stableIdentifier
        }
        return String(describing: value).stableIdentifier
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }

    var stableIdentifier: String {
        let data = Data(utf8)
        let hash = data.reduce(UInt64(1469598103934665603)) { partial, byte in
            (partial ^ UInt64(byte)) &* 1099511628211
        }
        return String(hash, radix: 16)
    }
}
