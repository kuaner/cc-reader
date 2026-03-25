import Foundation
import SwiftData

/// Estimates token counts for messages.
struct TokenEstimator {
    // Claude tokenization is roughly 4 chars/token for English and ~1.5 for Japanese.
    // rawJson is mostly English plus JSON syntax, so a byte-based estimate is a safe approximation.
    private static let bytesPerToken: Double = 4.0

    /// Estimate using rawJson byte length only without decoding the JSON payload.
    static func estimateTokens(for message: Message) -> Int {
        max(1, Int(ceil(Double(message.rawJson.count) / bytesPerToken)))
    }

    static func estimateTokens(for text: String?) -> Int {
        guard let text = text, !text.isEmpty else { return 0 }
        return Int(ceil(Double(text.utf8.count) / bytesPerToken))
    }

    static func totalTokens(for messages: [Message]) -> Int {
        messages.reduce(0) { $0 + estimateTokens(for: $1) }
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
