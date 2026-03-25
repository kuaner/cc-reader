# cc-reader

[English](README.md) | 日本語 | [简体中文](README.zh-Hans.md)

[Claude Code](https://docs.anthropic.com/en/docs/claude-code) のセッション履歴を閲覧・管理するための macOS アプリ。

`~/.claude/projects/` 配下の JSONL ファイルを監視し、会話タイムライン・思考プロセス・ツール使用状況をリッチな UI で表示します。

![cc-reader demo](assets/screenshot.gif)

> **⚠️ 注意**
> これは**非公式**のサードパーティツールです。Claude Code の JSONL フォーマットは公開 API ではなく、予告なく変更される可能性があります。一部の管理操作はローカルのセッションファイルを変更する場合があります。バックアップを必ず保持してください。

## 機能

- **セッションリーダー** — Markdown レンダリング・シンタックスハイライト・コードブロック操作・メッセージ単位コピー対応の WKWebView タイムライン
- **リアルタイム同期** — FSEvents でファイル変更を検出、差分パースで即座に反映
- **セッション管理** — サイドバーからセッション名変更や削除が可能
- **マルチペイン** — 最大12ペインで複数セッションを同時監視
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
open CCReader.xcodeproj
```

Xcode で `Cmd + R` でビルド＆実行。

## ローカルビルドコマンド

リポジトリ直下の [Makefile](Makefile) で、ローカルビルド・universal バイナリ生成・パッケージングをまとめて実行できます。

```bash
# Xcode プロジェクトを生成
make gen

# universal Debug / Release アプリをビルド
make debug
make release

# ビルド済みアプリを起動
make run CONFIG=Release

# Release を DMG にパッケージ
make dmg
```

デフォルトの出力先:

- App bundle: `build/DerivedData/Build/Products/Release/CC Reader.app`
- DMG: `build/cc-reader.dmg`

Makefile はデフォルトで universal macOS バイナリ（`arm64` + `x86_64`）を生成します。

## リリースフロー

バージョン更新とタグ作成はローカルの Makefile で行います。

```bash
# project.yml の MARKETING_VERSION を更新
make version VERSION=0.2.0 BUILD_NUMBER=2

# バージョン更新、リリースコミット作成、v0.2.0 タグ作成
make release-tag VERSION=0.2.0 BUILD_NUMBER=2

# 上記に加えてブランチとタグを GitHub に push
make publish VERSION=0.2.0 BUILD_NUMBER=2
```

`make publish` で release tag を GitHub に push すると、GitHub Actions が universal Release アプリをビルドし、DMG を生成して GitHub Releases にアップロードします。

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

[Mutafika/Opuswap](https://github.com/Mutafika/Opuswap) から fork したリポジトリです（MIT License）。

## ライセンス

[MIT](LICENSE)
