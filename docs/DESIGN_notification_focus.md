# 確認要求検出 & フォーカス機能 設計書

## 概要

Claude Codeを複数並列実行している際に「確認が必要なメッセージ」を自動検出し、
ワンクリックで該当セッションにジャンプできる機能。

---

## UI設計

```
┌────────────────────────────────────────────────────────┐
│ Opuswap                                                │
├──────────────┬─────────────────────────────────────────┤
│ Sessions     │ Timeline                                │
│              │                                         │
│ ⭐ Project A │ 🔔 Claude                               │
│   📍3件      │ ビルドが完了しました。                   │
│              │ 確認してください → [フォーカス]          │
│ Project B    │                                         │
│              │ 💬 User                                 │
│ ⭐ Project C │ npm run build                           │
│   📍1件      │                                         │
└──────────────┴─────────────────────────────────────────┘
```

### サイドバー表示
- `⭐` = ピン留めされたメッセージがあるセッション
- `📍N件` = 未確認の確認要求バッジ数

### タイムライン表示
- `🔔` = 確認要求が検出されたメッセージ
- `[フォーカス]` ボタン = 該当ターミナルにジャンプ

---

## データモデル変更

### Message.swift への追加

```swift
@Model
class Message {
    // 既存プロパティ...

    // === 新規追加 ===

    /// ユーザーによる手動ピン
    var isPinned: Bool = false

    /// 確認要求として検出されたか（自動）
    var isConfirmationRequest: Bool = false

    /// ユーザーが確認済みか
    var isAcknowledged: Bool = false

    /// 検出されたキーワード（デバッグ/表示用）
    var detectedKeyword: String?
}
```

### Session.swift への追加

```swift
@Model
class Session {
    // 既存プロパティ...

    // === Computed Properties ===

    /// ピン留めメッセージ数
    var pinnedCount: Int {
        messages.filter { $0.isPinned }.count
    }

    /// 未確認の確認要求数
    var unacknowledgedCount: Int {
        messages.filter { $0.isConfirmationRequest && !$0.isAcknowledged }.count
    }

    /// 注目が必要か（サイドバーでハイライト）
    var needsAttention: Bool {
        pinnedCount > 0 || unacknowledgedCount > 0
    }
}
```

---

## 確認要求の自動検出

### ConfirmationDetector.swift (新規)

```swift
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

    struct DetectionResult {
        let isConfirmationRequest: Bool
        let category: Category
        let matchedKeyword: String?

        enum Category: String {
            case none
            case confirmation  // 確認依頼
            case success       // 成功報告
            case error         // エラー報告
            case question      // 質問
        }
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
```

### SyncService への統合

```swift
// SyncService.swift - addMessage() 内

func addMessage(_ raw: RawMessageData, to session: Session) {
    // 既存のメッセージ作成処理...
    let message = Message(...)

    // === 確認要求の自動検出 ===
    if raw.message?.role == "assistant",
       let content = message.content {
        let result = ConfirmationDetector.detect(in: content)
        message.isConfirmationRequest = result.isConfirmationRequest
        message.detectedKeyword = result.matchedKeyword
    }

    session.messages.append(message)
}
```

---

## フォーカス機能

### FocusService.swift (新規)

```swift
import AppKit

@MainActor
class FocusService {

    // MARK: - Terminal Focus

    /// 内蔵ターミナルの場合: cwdでタブを特定してフォーカス
    func focusInternalTerminal(cwd: String, tabManager: TerminalTabManager) {
        if let tab = tabManager.tabs.first(where: { $0.cwd == cwd }) {
            tabManager.selectedTab = tab
        }
    }

    /// 外部ターミナルの場合: AppleScript経由でフォーカス
    func focusExternalTerminal(app: TerminalApp = .terminal) {
        let script: String

        switch app {
        case .terminal:
            script = """
                tell application "Terminal"
                    activate
                end tell
            """
        case .iterm:
            script = """
                tell application "iTerm"
                    activate
                end tell
            """
        case .warp:
            script = """
                tell application "Warp"
                    activate
                end tell
            """
        }

        runAppleScript(script)
    }

    /// Finderで作業ディレクトリを開く
    func revealInFinder(cwd: String) {
        let url = URL(fileURLWithPath: cwd)
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
    }

    /// Cursorで開く
    func openInCursor(cwd: String) {
        let script = """
            do shell script "open -a 'Cursor' '\(cwd)'"
        """
        runAppleScript(script)
    }

    // MARK: - Private

    private func runAppleScript(_ script: String) {
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&error)
            if let error = error {
                print("AppleScript error: \(error)")
            }
        }
    }

    enum TerminalApp {
        case terminal
        case iterm
        case warp
    }
}
```

---

## UI実装

### MessageRow.swift への変更

```swift
// MessageRow内のアシスタントメッセージ部分

HStack(alignment: .top, spacing: 8) {
    // 確認要求バッジ
    if message.isConfirmationRequest && !message.isAcknowledged {
        Image(systemName: "bell.fill")
            .foregroundColor(.orange)
            .font(.caption)
    }

    VStack(alignment: .leading, spacing: 4) {
        // 既存のメッセージ内容表示...

        // フォーカスボタン（確認要求の場合のみ）
        if message.isConfirmationRequest {
            HStack(spacing: 8) {
                Button("フォーカス") {
                    focusService.focusInternalTerminal(
                        cwd: message.session?.cwd ?? "",
                        tabManager: tabManager
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("確認済み") {
                    message.isAcknowledged = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
    }
}

// ピン留めのコンテキストメニュー
.contextMenu {
    Button(message.isPinned ? "ピン解除" : "ピン留め") {
        message.isPinned.toggle()
    }

    if message.isConfirmationRequest {
        Button(message.isAcknowledged ? "未確認に戻す" : "確認済みにする") {
            message.isAcknowledged.toggle()
        }
    }
}
```

### ProjectListView.swift への変更

```swift
// SessionRow内

HStack {
    // セッション名
    Text(session.displayTitle)

    Spacer()

    // バッジ表示
    if session.needsAttention {
        HStack(spacing: 4) {
            if session.pinnedCount > 0 {
                Label("\(session.pinnedCount)", systemImage: "pin.fill")
                    .font(.caption2)
                    .foregroundColor(.yellow)
            }

            if session.unacknowledgedCount > 0 {
                Label("\(session.unacknowledgedCount)", systemImage: "bell.fill")
                    .font(.caption2)
                    .foregroundColor(.orange)
            }
        }
    }
}
```

---

## macOS通知（v0.3）

### NotificationService.swift (新規)

```swift
import UserNotifications

class NotificationService {

    static let shared = NotificationService()

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if granted {
                print("通知許可: OK")
            }
        }
    }

    func sendConfirmationNotification(session: Session, message: Message, keyword: String) {
        let content = UNMutableNotificationContent()
        content.title = "確認が必要です"
        content.subtitle = session.displayTitle
        content.body = "「\(keyword)」- \(message.content?.prefix(50) ?? "")"
        content.sound = .default
        content.userInfo = [
            "sessionId": session.sessionId,
            "messageUuid": message.uuid
        ]

        let request = UNNotificationRequest(
            identifier: message.uuid,
            content: content,
            trigger: nil  // 即時
        )

        UNUserNotificationCenter.current().add(request)
    }
}
```

---

## フェーズ別実装計画

### v0.1 - 履歴ビューア強化
- [ ] Message に `isPinned`, `isConfirmationRequest`, `isAcknowledged` 追加
- [ ] ConfirmationDetector 実装
- [ ] SyncService で自動検出を統合
- [ ] MessageRow にバッジ・ピン表示
- [ ] 右クリックメニューでピン操作
- [ ] SessionRow にバッジ数表示

### v0.2 - マルチペインレイアウト
- [ ] WorkspaceLayout / LayoutNode モデル実装
- [ ] LayoutManager 実装
- [ ] LayoutView / PaneView 実装
- [ ] プリセットレイアウト（1/2/4ペイン）
- [ ] キーボードショートカット
- [ ] ドラッグ&ドロップでセッション割り当て
- [ ] レイアウト状態の永続化

### v0.3 - フォーカス機能
- [ ] FocusService 実装
- [ ] 内蔵ターミナルへのフォーカス（ペイン単位）
- [ ] 外部ターミナル（Terminal.app/iTerm/Warp）へのフォーカス
- [ ] Cursor/Finderで開く

### v0.4 - 通知統合
- [ ] NotificationService 実装
- [ ] 通知許可リクエスト
- [ ] バッジ検出時にmacOS通知
- [ ] 通知クリックで該当ペインを開く
- [ ] 設定画面（通知ON/OFF、検出キーワードのカスタマイズ）

---

## ファイル構成（新規追加）

```
Opuswap/
├── Models/
│   ├── Message.swift              # isPinned等追加
│   ├── Session.swift              # computed properties追加
│   └── WorkspaceLayout.swift      # 新規 - レイアウトモデル
├── Services/
│   ├── ConfirmationDetector.swift # 新規
│   ├── LayoutManager.swift        # 新規 - ペイン管理
│   ├── FocusService.swift         # 新規
│   └── NotificationService.swift  # 新規 (v0.4)
└── Views/
    ├── Layout/
    │   ├── LayoutView.swift       # 新規 - レイアウトルート
    │   ├── PaneView.swift         # 新規 - 個別ペイン
    │   ├── PaneHeaderView.swift   # 新規 - ペインヘッダー
    │   └── EmptyPaneView.swift    # 新規 - 空ペイン
    ├── Timeline/
    │   └── MessageRow.swift       # バッジ・フォーカスボタン追加
    └── Sidebar/
        └── ProjectListView.swift  # バッジ数表示・ドラッグ追加
```

---

## マルチペインレイアウト

### 概要

複数のセッションを同時に監視するため、「タイムライン + ターミナル」のセットを
分割表示できるレイアウト機能。

### レイアウトパターン

```
【1ペイン（現状）】
┌──────────┬─────────────────────────────┐
│ Sessions │ Timeline A                  │
│          ├─────────────────────────────┤
│          │ Terminal A                  │
└──────────┴─────────────────────────────┘

【2ペイン（横分割）】
┌──────────┬──────────────┬──────────────┐
│ Sessions │ Timeline A   │ Timeline B   │
│          ├──────────────┼──────────────┤
│          │ Terminal A   │ Terminal B   │
└──────────┴──────────────┴──────────────┘

【3ペイン】
┌──────────┬──────────────┬──────────────┐
│ Sessions │ Timeline A   │ Timeline B   │
│          ├──────────────┼──────────────┤
│          │ Terminal A   │ Timeline C   │
│          │              ├──────────────┤
│          │              │ Terminal C   │
└──────────┴──────────────┴──────────────┘

【4ペイン（グリッド）】
┌──────────┬──────────────┬──────────────┐
│ Sessions │ Timeline A   │ Timeline B   │
│          ├──────────────┼──────────────┤
│          │ Terminal A   │ Terminal B   │
│          ├──────────────┼──────────────┤
│          │ Timeline C   │ Timeline D   │
│          ├──────────────┼──────────────┤
│          │ Terminal C   │ Terminal D   │
└──────────┴──────────────┴──────────────┘
```

### データモデル

#### WorkspaceLayout.swift (新規)

```swift
import Foundation

/// ペインの配置方向
enum SplitDirection: String, Codable {
    case horizontal  // 横に分割
    case vertical    // 縦に分割
}

/// 個別のペイン
struct Pane: Identifiable, Codable {
    let id: UUID
    var sessionId: String?      // 表示中のセッション（nilなら空）
    var showTerminal: Bool      // ターミナル表示するか

    init(sessionId: String? = nil, showTerminal: Bool = true) {
        self.id = UUID()
        self.sessionId = sessionId
        self.showTerminal = showTerminal
    }
}

/// レイアウトツリー（再帰構造）
indirect enum LayoutNode: Codable {
    case pane(Pane)
    case split(direction: SplitDirection, first: LayoutNode, second: LayoutNode, ratio: CGFloat)
}

/// ワークスペース全体
struct WorkspaceLayout: Codable {
    var root: LayoutNode
    var name: String?

    /// 1ペインの初期状態
    static var single: WorkspaceLayout {
        WorkspaceLayout(root: .pane(Pane()))
    }

    /// 2ペイン横分割
    static var twoColumn: WorkspaceLayout {
        WorkspaceLayout(root: .split(
            direction: .horizontal,
            first: .pane(Pane()),
            second: .pane(Pane()),
            ratio: 0.5
        ))
    }

    /// 4ペイングリッド
    static var grid2x2: WorkspaceLayout {
        WorkspaceLayout(root: .split(
            direction: .vertical,
            first: .split(direction: .horizontal, first: .pane(Pane()), second: .pane(Pane()), ratio: 0.5),
            second: .split(direction: .horizontal, first: .pane(Pane()), second: .pane(Pane()), ratio: 0.5),
            ratio: 0.5
        ))
    }
}
```

#### LayoutManager.swift (新規)

```swift
import SwiftUI

@MainActor
class LayoutManager: ObservableObject {
    @Published var layout: WorkspaceLayout = .single
    @Published var focusedPaneId: UUID?

    // MARK: - Pane Operations

    /// 新しいペインを追加（現在のペインを分割）
    func splitPane(_ paneId: UUID, direction: SplitDirection) {
        layout.root = splitNode(layout.root, targetId: paneId, direction: direction)
    }

    /// ペインを閉じる
    func closePane(_ paneId: UUID) {
        if let newRoot = removeNode(layout.root, targetId: paneId) {
            layout.root = newRoot
        }
    }

    /// ペインにセッションを割り当て
    func assignSession(_ sessionId: String, to paneId: UUID) {
        layout.root = updateNode(layout.root, targetId: paneId) { pane in
            var newPane = pane
            newPane.sessionId = sessionId
            return newPane
        }
    }

    /// 全ペインを取得
    func allPanes() -> [Pane] {
        collectPanes(layout.root)
    }

    // MARK: - Private Helpers

    private func splitNode(_ node: LayoutNode, targetId: UUID, direction: SplitDirection) -> LayoutNode {
        switch node {
        case .pane(let pane):
            if pane.id == targetId {
                return .split(
                    direction: direction,
                    first: .pane(pane),
                    second: .pane(Pane()),
                    ratio: 0.5
                )
            }
            return node

        case .split(let dir, let first, let second, let ratio):
            return .split(
                direction: dir,
                first: splitNode(first, targetId: targetId, direction: direction),
                second: splitNode(second, targetId: targetId, direction: direction),
                ratio: ratio
            )
        }
    }

    private func removeNode(_ node: LayoutNode, targetId: UUID) -> LayoutNode? {
        switch node {
        case .pane(let pane):
            return pane.id == targetId ? nil : node

        case .split(let dir, let first, let second, let ratio):
            let newFirst = removeNode(first, targetId: targetId)
            let newSecond = removeNode(second, targetId: targetId)

            switch (newFirst, newSecond) {
            case (nil, nil): return nil
            case (let n, nil): return n
            case (nil, let n): return n
            case (let f?, let s?):
                return .split(direction: dir, first: f, second: s, ratio: ratio)
            }
        }
    }

    private func updateNode(_ node: LayoutNode, targetId: UUID, transform: (Pane) -> Pane) -> LayoutNode {
        switch node {
        case .pane(let pane):
            return pane.id == targetId ? .pane(transform(pane)) : node

        case .split(let dir, let first, let second, let ratio):
            return .split(
                direction: dir,
                first: updateNode(first, targetId: targetId, transform: transform),
                second: updateNode(second, targetId: targetId, transform: transform),
                ratio: ratio
            )
        }
    }

    private func collectPanes(_ node: LayoutNode) -> [Pane] {
        switch node {
        case .pane(let pane):
            return [pane]
        case .split(_, let first, let second, _):
            return collectPanes(first) + collectPanes(second)
        }
    }
}
```

### UI実装

#### LayoutView.swift (新規)

```swift
import SwiftUI

struct LayoutView: View {
    @EnvironmentObject var layoutManager: LayoutManager
    @EnvironmentObject var coordinator: AppCoordinator

    var body: some View {
        renderNode(layoutManager.layout.root)
    }

    @ViewBuilder
    private func renderNode(_ node: LayoutNode) -> some View {
        switch node {
        case .pane(let pane):
            PaneView(pane: pane)

        case .split(let direction, let first, let second, let ratio):
            switch direction {
            case .horizontal:
                HSplitView {
                    renderNode(first)
                    renderNode(second)
                }
            case .vertical:
                VSplitView {
                    renderNode(first)
                    renderNode(second)
                }
            }
        }
    }
}
```

#### PaneView.swift (新規)

```swift
import SwiftUI

struct PaneView: View {
    let pane: Pane
    @EnvironmentObject var layoutManager: LayoutManager
    @Query var sessions: [Session]

    var body: some View {
        VStack(spacing: 0) {
            // ヘッダー（セッション選択 + 操作）
            PaneHeaderView(pane: pane)

            // メインコンテンツ
            if let sessionId = pane.sessionId,
               let session = sessions.first(where: { $0.sessionId == sessionId }) {
                VSplitView {
                    // タイムライン
                    SessionMessagesView(session: session)

                    // ターミナル（オプション）
                    if pane.showTerminal {
                        TerminalView(cwd: session.cwd)
                    }
                }
            } else {
                // 未選択状態
                EmptyPaneView(pane: pane)
            }
        }
        .background(layoutManager.focusedPaneId == pane.id ? Color.accentColor.opacity(0.1) : Color.clear)
        .onTapGesture {
            layoutManager.focusedPaneId = pane.id
        }
    }
}

struct PaneHeaderView: View {
    let pane: Pane
    @EnvironmentObject var layoutManager: LayoutManager

    var body: some View {
        HStack {
            // セッション選択ドロップダウン
            SessionPicker(selectedSessionId: Binding(
                get: { pane.sessionId },
                set: { newId in
                    if let id = newId {
                        layoutManager.assignSession(id, to: pane.id)
                    }
                }
            ))

            Spacer()

            // 分割ボタン
            Menu {
                Button("横に分割") {
                    layoutManager.splitPane(pane.id, direction: .horizontal)
                }
                Button("縦に分割") {
                    layoutManager.splitPane(pane.id, direction: .vertical)
                }
                Divider()
                Button("ペインを閉じる", role: .destructive) {
                    layoutManager.closePane(pane.id)
                }
            } label: {
                Image(systemName: "rectangle.split.3x1")
            }
            .menuStyle(.borderlessButton)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

struct EmptyPaneView: View {
    let pane: Pane
    @EnvironmentObject var layoutManager: LayoutManager
    @Query var sessions: [Session]

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "plus.rectangle.on.rectangle")
                .font(.largeTitle)
                .foregroundColor(.secondary)

            Text("セッションを選択")
                .foregroundColor(.secondary)

            // 最近のセッションをクイック選択
            VStack(alignment: .leading, spacing: 8) {
                ForEach(sessions.prefix(5)) { session in
                    Button {
                        layoutManager.assignSession(session.sessionId, to: pane.id)
                    } label: {
                        HStack {
                            if session.needsAttention {
                                Image(systemName: "bell.fill")
                                    .foregroundColor(.orange)
                            }
                            Text(session.displayTitle)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

### ペイン数の上限

最大12ペインまで対応。ペインヘッダーの分割メニューから自由に追加可能。

```swift
extension LayoutManager {
    static let maxPanes = 12

    func canSplit() -> Bool {
        allPanes().count < Self.maxPanes
    }
}
```

### 動的サイズ変更

ドラッグでペイン境界をリサイズ可能。ratioは自動保存。

```swift
struct ResizableSplitView<First: View, Second: View>: View {
    let direction: SplitDirection
    @Binding var ratio: CGFloat
    let first: First
    let second: Second
    let onRatioChanged: (CGFloat) -> Void

    var body: some View {
        GeometryReader { geo in
            let isHorizontal = direction == .horizontal
            let total = isHorizontal ? geo.size.width : geo.size.height

            if isHorizontal {
                HStack(spacing: 0) {
                    first.frame(width: total * ratio)
                    Divider()
                        .frame(width: 4)
                        .background(Color.gray.opacity(0.01))
                        .gesture(dragGesture(total: total, isHorizontal: true))
                        .onHover { NSCursor.resizeLeftRight.set() }
                    second
                }
            } else {
                VStack(spacing: 0) {
                    first.frame(height: total * ratio)
                    Divider()
                        .frame(height: 4)
                        .gesture(dragGesture(total: total, isHorizontal: false))
                        .onHover { NSCursor.resizeUpDown.set() }
                    second
                }
            }
        }
    }

    private func dragGesture(total: CGFloat, isHorizontal: Bool) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let delta = isHorizontal ? value.translation.width : value.translation.height
                let newRatio = max(0.1, min(0.9, ratio + delta / total * 0.01))
                ratio = newRatio
            }
            .onEnded { _ in
                onRatioChanged(ratio)  // 永続化トリガー
            }
    }
}
```

### サイドバーからのドラッグ&ドロップ

```swift
// ProjectListView のセッション行に追加

SessionRow(session: session)
    .draggable(session.sessionId) // ドラッグ元

// PaneView に追加

.dropDestination(for: String.self) { sessionIds, _ in
    if let sessionId = sessionIds.first {
        layoutManager.assignSession(sessionId, to: pane.id)
        return true
    }
    return false
}
```

### 状態の永続化

```swift
// UserDefaults または SwiftData で保存

extension LayoutManager {
    private static let layoutKey = "workspace.layout"

    func save() {
        if let data = try? JSONEncoder().encode(layout) {
            UserDefaults.standard.set(data, forKey: Self.layoutKey)
        }
    }

    func restore() {
        if let data = UserDefaults.standard.data(forKey: Self.layoutKey),
           let saved = try? JSONDecoder().decode(WorkspaceLayout.self, from: data) {
            layout = saved
        }
    }
}
```

---

## 考慮事項

### パフォーマンス
- 検出はメッセージ追加時のみ（1回）
- computed properties は必要時のみ計算
- 大量メッセージ時は `@Query` で絞り込み

### UX
- 誤検出を減らすため、キーワードは慎重に選定
- ユーザーが「確認済み」にできることで、ノイズを減らせる
- ピン機能は完全に手動なので、重要なものを自分でマーク可能

### 拡張性
- キーワードリストは将来的に設定画面でカスタマイズ可能に
- カテゴリ（error/success/question/confirmation）で色分けも可能
