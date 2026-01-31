import Foundation
import SwiftData

/// メッセージのトークン数を推定するサービス
struct TokenEstimator {
    static let charsPerToken: Double = 3.0

    static func estimateTokens(for message: Message) -> Int {
        let thinkingTokens = estimateTokens(for: message.thinking)
        let contentTokens = estimateTokens(for: message.content)
        let toolResultTokens = (message.toolResults ?? [])
            .compactMap { $0.content }
            .map { estimateTokens(for: $0) }
            .reduce(0, +)
        let metadataTokens = max(50, message.rawJson.count / 20)
        return thinkingTokens + contentTokens + toolResultTokens + metadataTokens
    }

    static func estimateTokens(for text: String?) -> Int {
        guard let text = text, !text.isEmpty else { return 0 }
        return Int(ceil(Double(text.count) / charsPerToken))
    }

    static func totalTokens(for messages: [Message]) -> Int {
        messages.map { estimateTokens(for: $0) }.reduce(0, +)
    }

    static func formatTokens(_ tokens: Int) -> String {
        if tokens >= 1000 {
            return String(format: "%.1fK", Double(tokens) / 1000.0)
        }
        return "\(tokens)"
    }

    static func percentage(used: Int, limit: Int) -> Double {
        guard limit > 0 else { return 0 }
        return min(1.0, Double(used) / Double(limit))
    }
}
