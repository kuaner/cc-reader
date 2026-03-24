import Foundation
import SwiftData

/// メッセージのトークン数を推定するサービス
struct TokenEstimator {
    // Claude のトークナイザは英語で ~4 chars/token, 日本語で ~1.5 chars/token
    // rawJson はほぼ英語+JSON構文なのでバイト数ベースで安全に近似できる
    private static let bytesPerToken: Double = 4.0

    /// rawJson のバイト長だけで推定（JSON 解码不要）
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
