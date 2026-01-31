# Opuswap 3層アーキテクチャ設計 — リモート + Android対応

## 概要

macOS版Opuswap + 内蔵WebSocketサーバー + Androidアプリの3層構成。
Tailscale VPN経由でインターネット越しにClaude Codeセッションをリモート監視。

```
┌─────────────────┐                    ┌─────────────────┐
│  Opuswap macOS  │    Tailscale VPN   │  Android App    │
│  + WebSocket    │◄══════════════════►│  スワイプUI       │
│  サーバー (9820)  │    WireGuard暗号化  │  (リモートビューア) │
└─────────────────┘                    └─────────────────┘
        │
        ▼
  ~/.claude/projects/**/*.jsonl
```

### ネットワーク: Tailscale
- Mac/Android両方にTailscaleインストール → 同一VPN上に
- WireGuardベースでエンドツーエンド暗号化 → WebSocket側のTLS不要
- Tailscale認証で保護 → ペアリングコード不要
- Android側はTailscale IPアドレス (`100.x.y.z:9820`) で接続
- 無料プランで個人利用は十分

---

## Layer 1: macOS内蔵WebSocketサーバー

### 方式
- macOSアプリ内に **Network.framework (`NWListener`)** でWebSocketサーバー組み込み
- ポート: `9820` (設定で変更可)
- バインド: `0.0.0.0` (Tailscale含む全インターフェースでリッスン)
- アプリ起動と同時にサーバーも起動

### プロトコル (WebSocket一本)

接続直後にスナップショット送信、以降はリアルタイムdelta配信。

```
Client → Server:
  { "type": "subscribe", "lastSeq": 0 }            // 初回 (フルスナップ要求)
  { "type": "subscribe", "lastSeq": 1542 }         // 再接続 (差分から)
  { "type": "action", "action": "toggle_pin", "messageUuid": "..." }

Server → Client:
  { "type": "welcome", "deviceName": "MacBook Pro", "seq": 1542 }
  { "type": "snapshot", "projects": [...], "sessions": [...], "seq": 1542 }
  { "type": "delta", "event": "message_added", "data": {...}, "seq": 1543 }
  { "type": "delta", "event": "session_updated", "data": {...}, "seq": 1544 }
```

### Delta イベント種別
| event | 内容 |
|-------|------|
| `project_added` | 新規プロジェクト検出 |
| `session_added` | 新規セッション開始 |
| `session_updated` | メタデータ変更 (updatedAt等) |
| `message_added` | 新メッセージ追加 |
| `message_updated` | ピン/確認ステータス変更 |

### DTO設計 (rawJsonは送らない、パース済み構造体を送信)

```json
// SessionDTO
{
  "sessionId": "uuid",
  "projectPath": "-Users-toro-myapp-...",
  "projectName": "Mugendesk",
  "slug": "streamed-skipping-tarjan",
  "cwd": "/Users/toro/myapp/...",
  "gitBranch": "main",
  "startedAt": "2026-01-27T10:00:00Z",
  "updatedAt": "2026-01-27T10:30:00Z",
  "messageCount": 42,
  "pinnedCount": 2,
  "unacknowledgedCount": 1,
  "needsAttention": true
}

// MessageDTO
{
  "uuid": "msg-uuid",
  "sessionId": "session-uuid",
  "type": "assistant",
  "timestamp": "2026-01-27T10:15:00Z",
  "content": "テキスト本文",
  "thinking": "思考内容...",
  "model": "claude-opus-4-5-20251101",
  "toolUses": [
    { "name": "Edit", "target": "src/main.swift" },
    { "name": "Bash", "target": "npm test" }
  ],
  "isPinned": false,
  "isConfirmationRequest": true,
  "isAcknowledged": false,
  "detectedKeyword": "error:",
  "category": "error"
}
```

### シーケンス番号 (seq)
- サーバー側でグローバルに単調増加整数を採番
- 各deltaにseq付与、クライアントは最後のseqを記憶
- 再接続時にlastSeq送信 → サーバーはそれ以降のdeltaを再送
- リングバッファ(直近1000件)保持、古すぎる場合はフルスナップショット再送

### macOS側 実装ファイル
| ファイル | 責務 |
|---------|------|
| `Opuswap/Services/RelayProtocol.swift` | DTO定義 + Codable (Server/Client共通) |
| `Opuswap/Services/RelayServer.swift` | NWListener WebSocketサーバー + delta配信 |

---

## Layer 2: Androidアプリ

### 技術スタック
- **Language**: Kotlin
- **UI**: Jetpack Compose + Material 3
- **Architecture**: MVVM (ViewModel + Repository)
- **WebSocket**: OkHttp WebSocket
- **DB**: Room (オフラインキャッシュ)
- **DI**: Hilt
- **JSON**: kotlinx.serialization

### スワイプUI設計

```
┌──────────────────────────────┐
│ [< Project名] [🔔 3]  [⚙]  │  ← ヘッダー
├──────────────────────────────┤
│  ● ● ○ ● ●                  │  ← ページインジケーター (●=attention)
├──────────────────────────────┤
│                              │
│  ◄ スワイプ  Session Card  ► │  ← HorizontalPager
│                              │
│  ┌────────────────────────┐  │
│  │ session slug           │  │
│  │ main branch · 42 turns │  │
│  ├────────────────────────┤  │
│  │ 📌 2  🔔 1             │  │
│  ├────────────────────────┤  │
│  │                        │  │
│  │  メッセージタイムライン    │  │  ← LazyColumn (縦スクロール)
│  │  [user] こんにちは       │  │
│  │  [assistant]            │  │
│  │    💭 thinking...       │  │
│  │    🔧 Edit: main.swift  │  │
│  │    修正しました          │  │
│  │                        │  │
│  └────────────────────────┘  │
└──────────────────────────────┘
```

### 操作体系
| ジェスチャー | 動作 |
|------------|------|
| 左右スワイプ | セッション切り替え |
| 縦スクロール | タイムライン閲覧 |
| タップ (thinking) | 展開/折りたたみ |
| タップ (ツール) | 詳細表示 |
| 長押し (メッセージ) | ピン/確認マーク → macOS側に同期 |
| プルダウン | 最新に更新 |

### ページインジケーター
- attention状態: **赤●**
- 通常: **グレー●**
- 現在表示中: **白●**
- 多数セッション時はスクロール可能ドット

### 接続画面
- 初回: Tailscale IPアドレス手入力 (`100.x.y.z`)
- 接続成功後: デバイス名を記憶して次回自動接続
- 設定画面でIP変更可

### オフライン・再接続
- Room DBにセッション/メッセージをキャッシュ
- 接続断: 最終データ表示 + 「接続切断」バナー
- 再接続: lastSeqで差分同期
- バックグラウンド復帰時: 自動再接続

### Androidプロジェクト構成
```
OpuswapRemote/  (← Opuswapリポジトリ内にサブディレクトリ)
├── app/src/main/java/com/opuswap/remote/
│   ├── data/
│   │   ├── remote/
│   │   │   ├── OpuswapWebSocket.kt      # OkHttp WebSocket接続管理
│   │   │   └── RelayProtocol.kt         # DTO (kotlinx.serialization)
│   │   ├── local/
│   │   │   ├── OpuswapDatabase.kt       # Room DB
│   │   │   ├── SessionDao.kt
│   │   │   └── MessageDao.kt
│   │   └── repository/
│   │       └── SessionRepository.kt     # Remote + Local 統合
│   ├── ui/
│   │   ├── theme/
│   │   │   └── OpuswapTheme.kt          # Material 3 Dark テーマ
│   │   ├── connect/
│   │   │   └── ConnectScreen.kt         # IP入力 + 接続UI
│   │   ├── home/
│   │   │   ├── HomeScreen.kt            # HorizontalPager + インジケーター
│   │   │   └── HomeViewModel.kt
│   │   ├── session/
│   │   │   ├── SessionCard.kt           # セッションカード
│   │   │   ├── MessageItem.kt           # メッセージ行
│   │   │   ├── ThinkingSection.kt       # 思考展開UI
│   │   │   └── ToolUseChip.kt           # ツール使用チップ
│   │   └── components/
│   │       ├── AttentionIndicator.kt     # ページインジケーター
│   │       └── ConnectionBanner.kt       # 接続状態バナー
│   └── di/
│       └── AppModule.kt                  # Hilt DI
```

---

## 双方向操作 (Android → macOS)

```json
{ "type": "action", "action": "toggle_pin", "messageUuid": "..." }
{ "type": "action", "action": "acknowledge", "messageUuid": "..." }
```

macOS側で処理 → SwiftData更新 → delta配信で全クライアントに反映。

---

## 実装順序

### Phase 1: macOS側サーバー組み込み
1. `RelayProtocol.swift` — DTO + Codable定義
2. `RelayServer.swift` — NWListener WebSocketサーバー + seq管理 + delta配信
3. AppCoordinatorにサーバー起動/停止を統合
4. 既存SyncServiceのメッセージ追加時にRelayServerへdelta通知

### Phase 2: Androidプロジェクト作成
1. プロジェクト初期構築 (Kotlin + Compose + Hilt + Room)
2. `RelayProtocol.kt` — DTO定義
3. `OpuswapWebSocket.kt` — OkHttp接続 + 自動再接続
4. `ConnectScreen.kt` — Tailscale IP入力 + 接続

### Phase 3: Android スワイプUI
1. Room DB + DAO
2. `SessionRepository.kt` — WebSocket → Room → UI のFlow
3. `HomeScreen.kt` — HorizontalPager + ページインジケーター
4. `SessionCard.kt` — セッションカード
5. `MessageItem.kt` / `ThinkingSection.kt` / `ToolUseChip.kt`

### Phase 4: 双方向操作 + 仕上げ
1. Android → macOS アクション送信
2. オフラインキャッシュ + 再接続ロジック
3. Material 3 ダークテーマ仕上げ

---

## 検証方法
1. macOS: サーバー起動 → `websocat ws://localhost:9820` でローカル接続確認
2. Tailscale: Mac/Android両方接続 → `ping 100.x.y.z` で疎通確認
3. Android: Tailscale IP入力 → セッション一覧表示
4. リアルタイム: Claude Codeで操作 → Android側に即座に反映
5. 再接続: Android機内モード ON/OFF → 差分同期で復旧
