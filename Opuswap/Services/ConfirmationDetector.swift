import Foundation

struct ConfirmationDetector {

    // MARK: - Detection Keywords

    /// 確認を求めるキーワード
    static let confirmationKeywords: [String] = [
        // 日本語
        "確認してください",
        "確認お願いします",
        "ご確認ください",
        "確認をお願い",
        "レビューをお願い",
        "チェックしてください",
        // 英語
        "please review",
        "please confirm",
        "please check",
        "let me know",
        "what do you think",
        "does this look",
    ]

    /// 成功を示すキーワード（通知価値あり）
    static let successKeywords: [String] = [
        "BUILD SUCCEEDED",
        "build succeeded",
        "Build Succeeded",
        "All tests passed",
        "successfully",
        "完了しました",
        "成功しました",
    ]

    /// エラー/失敗を示すキーワード（即座に注意が必要）
    static let errorKeywords: [String] = [
        "BUILD FAILED",
        "build failed",
        "Build Failed",
        "error:",
        "Error:",
        "ERROR:",
        "failed",
        "エラーが発生",
        "失敗しました",
        "見つかりません",
    ]

    /// 質問を示すキーワード（応答待ち）
    static let questionKeywords: [String] = [
        "どちらがいいですか",
        "どうしますか",
        "どのように",
        "which approach",
        "should I",
        "would you like",
        "do you want",
    ]

    // MARK: - Detection

    enum Category: String {
        case none
        case confirmation  // 確認依頼
        case success       // 成功報告
        case error         // エラー報告
        case question      // 質問
    }

    struct DetectionResult {
        let isConfirmationRequest: Bool
        let category: Category
        let matchedKeyword: String?
    }

    static func detect(in content: String) -> DetectionResult {
        let lowercased = content.lowercased()

        // エラーは最優先
        if let keyword = errorKeywords.first(where: { lowercased.contains($0.lowercased()) }) {
            return DetectionResult(isConfirmationRequest: true, category: .error, matchedKeyword: keyword)
        }

        // 質問
        if let keyword = questionKeywords.first(where: { lowercased.contains($0.lowercased()) }) {
            return DetectionResult(isConfirmationRequest: true, category: .question, matchedKeyword: keyword)
        }

        // 確認依頼
        if let keyword = confirmationKeywords.first(where: { lowercased.contains($0.lowercased()) }) {
            return DetectionResult(isConfirmationRequest: true, category: .confirmation, matchedKeyword: keyword)
        }

        // 成功報告
        if let keyword = successKeywords.first(where: { lowercased.contains($0.lowercased()) }) {
            return DetectionResult(isConfirmationRequest: true, category: .success, matchedKeyword: keyword)
        }

        return DetectionResult(isConfirmationRequest: false, category: .none, matchedKeyword: nil)
    }
}
