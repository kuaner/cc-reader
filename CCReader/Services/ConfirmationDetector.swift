import Foundation

struct ConfirmationDetector {

    // MARK: - Detection Keywords

    /// Keywords that indicate the assistant is asking for confirmation.
    static let confirmationKeywords: [String] = [
        // Japanese
        "確認してください",
        "確認お願いします",
        "ご確認ください",
        "確認をお願い",
        "レビューをお願い",
        "チェックしてください",
        // Chinese
        "请确认",
        "请帮我确认",
        "请检查",
        "请审阅",
        "你怎么看",
        // English
        "please review",
        "please confirm",
        "please check",
        "let me know",
        "what do you think",
        "does this look",
    ]

    /// Keywords that indicate a successful outcome worth notifying about.
    static let successKeywords: [String] = [
        "BUILD SUCCEEDED",
        "build succeeded",
        "Build Succeeded",
        "All tests passed",
        "successfully",
        "完了しました",
        "成功しました",
        "已完成",
        "完成了",
        "成功了",
    ]

    /// Keywords that indicate an error or failure that needs immediate attention.
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
        "发生错误",
        "失败了",
        "未找到",
    ]

    /// Keywords that indicate a question waiting for user input.
    static let questionKeywords: [String] = [
        "どちらがいいですか",
        "どうしますか",
        "どのように",
        "你觉得哪个更好",
        "要怎么做",
        "你希望我怎么做",
        "which approach",
        "should I",
        "would you like",
        "do you want",
    ]

    // MARK: - Detection

    enum Category: String {
        case none
        case confirmation  // Confirmation request
        case success       // Success report
        case error         // Error report
        case question      // Question
    }

    struct DetectionResult {
        let isConfirmationRequest: Bool
        let category: Category
        let matchedKeyword: String?
    }

    static func detect(in content: String) -> DetectionResult {
        let lowercased = content.lowercased()

        // Errors take precedence over every other category.
        if let keyword = errorKeywords.first(where: { lowercased.contains($0.lowercased()) }) {
            return DetectionResult(isConfirmationRequest: true, category: .error, matchedKeyword: keyword)
        }

        // Questions
        if let keyword = questionKeywords.first(where: { lowercased.contains($0.lowercased()) }) {
            return DetectionResult(isConfirmationRequest: true, category: .question, matchedKeyword: keyword)
        }

        // Confirmation requests
        if let keyword = confirmationKeywords.first(where: { lowercased.contains($0.lowercased()) }) {
            return DetectionResult(isConfirmationRequest: true, category: .confirmation, matchedKeyword: keyword)
        }

        // Success reports
        if let keyword = successKeywords.first(where: { lowercased.contains($0.lowercased()) }) {
            return DetectionResult(isConfirmationRequest: true, category: .success, matchedKeyword: keyword)
        }

        return DetectionResult(isConfirmationRequest: false, category: .none, matchedKeyword: nil)
    }
}
