import Foundation
import WebKit

/// 主题 id 枚举由 `WebColorTheme.generated.swift`（`timeline-ui/scripts/sync-themes.mjs`）根据 `themes/*.css` 生成。

extension WebColorTheme {
    static let storageKey = "ccreader.themeId"

    static var stored: WebColorTheme {
        let raw = UserDefaults.standard.string(forKey: storageKey) ?? ""
        return WebColorTheme(rawValue: raw) ?? .everforest
    }

    /// 写入 UserDefaults 并通知所有 WKWebView 执行 JS（时间线走 `ccreader.setTheme`，预览页走 DOM + localStorage）。
    func broadcast() {
        UserDefaults.standard.set(rawValue, forKey: Self.storageKey)
        NotificationCenter.default.post(
            name: .ccReaderWebThemeDidChange,
            object: nil,
            userInfo: ["themeId": rawValue]
        )
    }

    /// 在单页内应用（不广播）。用于导航完成后的与 UserDefaults 对齐。
    static func apply(_ theme: WebColorTheme, to webView: WKWebView) {
        let js = theme.javaScriptSnippet
        webView.evaluateJavaScript(js) { _, error in
            if let error {
                print("[WebColorTheme] evaluateJavaScript: \(error)")
            }
        }
    }

    fileprivate var javaScriptSnippet: String {
        let id = rawValue
        let key = Self.storageKey
        // 与内联 HTML 脚本、TypeScript `CC_THEME_STORAGE_KEY` 保持一致。
        return """
            (function(){
              try {
                if (window.ccreader && typeof window.ccreader.setTheme === 'function') {
                  window.ccreader.setTheme('\(id)');
                } else {
                  document.documentElement.setAttribute('data-cc-theme','\(id)');
                  try { localStorage.setItem('\(key)','\(id)'); } catch(e) {}
                }
              } catch (e) {}
            })();
            """
    }
}

extension Notification.Name {
    /// 菜单或外部逻辑切换主题时发出；`userInfo["themeId"]` 为主题 id 字符串（与 `WebColorTheme.rawValue` 一致）。
    static let ccReaderWebThemeDidChange = Notification.Name("ccReaderWebThemeDidChange")
}
