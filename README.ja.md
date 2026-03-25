# cc-reader

[English](README.md) | 日本語 | [简体中文](README.zh-Hans.md)

[Claude Code](https://docs.anthropic.com/en/docs/claude-code) のセッション履歴をリアルタイムで可視化・管理する macOS アプリ。

`~/.claude/projects/` 配下の JSONL ファイルを監視し、会話タイムライン・思考プロセス・ツール使用状況をリッチな UI で表示します。

> **⚠️ 注意**
> これは**非公式**のサードパーティツールです。Claude Code の JSONL フォーマットは公開 API ではなく、予告なく変更される可能性があります。Surgery Mode はセッションファイルを直接編集します — **自己責任でご利用ください**。バックアップを必ず保持してください。

## 機能

- **セッションビューア** — Markdown レンダリング・シンタックスハイライト・メッセージ単位コピー対応の WKWebView タイムライン
- **リアルタイム同期** — FSEvents でファイル変更を検出、差分パースで即座に反映
- **マルチペイン** — 最大12ペインで複数セッションを同時監視
- **Surgery Mode** — JSONL を直接編集してコンテキストのトークンを最適化（一括削除・巻き戻し・要約編集）
- **コンテキストパネル** — Claude の理解状況、読み込み/編集済みファイルを一覧表示
- **長大タイムライン最適化** — ウィンドウ化レンダリング + 上端付近での過去メッセージ自動ロード

## 必要環境

- macOS 14.0+
- Xcode 15.0+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## セットアップ

```bash
# XcodeGen が未インストールの場合
brew install xcodegen

# クローンしてビルド
git clone https://github.com/kuaner/cc-reader.git
cd cc-reader
xcodegen
open Opuswap.xcodeproj
```

Xcode で `Cmd + R` でビルド＆実行。

## 技術スタック

| カテゴリ | 技術 |
|---------|------|
| UI | SwiftUI + WKWebView（Timeline） |
| 永続化 | SwiftData |
| ファイル監視 | FSEvents |
| Web レンダリング | marked.js + highlight.js（バンドル） |
| ビルド | XcodeGen (`project.yml`) |

## アーキテクチャ

```
データソース: ~/.claude/projects/**/*.jsonl
    ↓ FSEvents
FileWatcherService → SyncService → JSONLParser（差分パース）
    ↓
SwiftData ModelContext
    ↓
SessionMessagesView（スナップショット構築）
    ↓
TimelineHostView（単一 WKWebView / ウィンドウ化レンダリング）
```

詳細は [docs/SPEC.md](docs/SPEC.md) を参照。

## ドキュメント

- [Architecture & Specification](docs/SPEC.md)

## 謝辞

このリポジトリは [Mutafika/Opuswap](https://github.com/Mutafika/Opuswap) をベースにしています。
原プロジェクトは MIT License で提供されています。

## ライセンス

[MIT](LICENSE)
