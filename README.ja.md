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

## Swift Package (CCReaderKit)

cc-reader は Swift Package として他の macOS アプリに組み込むこともできます。

### 依存関係を追加

Xcode で：**File → Add Package Dependencies…** → リポジトリ URL を入力：

```
https://github.com/kuaner/cc-reader.git
```

または `Package.swift` に追加：

```swift
dependencies: [
    .package(url: "https://github.com/kuaner/cc-reader.git", from: "0.1.0"),
]
```

ターゲットに `CCReaderKit` を追加：

```swift
.target(
    name: "YourApp",
    dependencies: [
        .product(name: "CCReaderKit", package: "cc-reader"),
    ]
)
```

### 使い方

#### クイックスタート — 独立ウィンドウ

最もシンプルな方法、1行で CC Reader を開けます：

```swift
import CCReaderKit

CCReaderKit.open()
```

ウィンドウはシングルトンとして管理され、再度呼び出すと既存のウィンドウが再利用されます。

#### フルインテグレーション — NSWindow + Toolbar

ウィンドウのライフサイクルを完全に制御する必要があるアプリ（メニューバーアプリなど）では、`CCReaderKit.makeView()` を使って `NSWindow` を自分で作成・管理します：

```swift
import SwiftUI
import CCReaderKit

class AppDelegate: NSObject, NSApplicationDelegate {
    private var readerWindow: NSWindow?

    func openReader() {
        if readerWindow == nil {
            let readerView = CCReaderKit.makeView()
            readerWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            readerWindow?.title = "CC Reader"

            // 必須：NSToolbar + .unified スタイルにより、SwiftUI の toolbar items
            //（パス、Resume、更新ボタン）がタイトルバーに表示されます。
            let toolbar = NSToolbar(identifier: "CCReaderToolbar")
            toolbar.displayMode = .iconOnly
            readerWindow?.toolbar = toolbar
            readerWindow?.toolbarStyle = .unified

            readerWindow?.contentViewController = NSHostingController(rootView: readerView)
            readerWindow?.setContentSize(NSSize(width: 1200, height: 800))
            readerWindow?.center()
            readerWindow?.isReleasedWhenClosed = false
        }
        readerWindow?.makeKeyAndOrderFront(nil)
    }
}
```

> **ポイント：**
> - SwiftUI の toolbar を正しくブリッジするには、`NSHostingView` ではなく `NSHostingController` を使用してください。
> - `NSToolbar` を追加し `.unified` スタイルを設定すると、toolbar items がタイトルバーに表示されます。
> - `styleMask` に `.fullSizeContentView` を含めると、`NavigationSplitView` のレイアウトが正しく動作します。
> - `isReleasedWhenClosed = false` を設定してウィンドウインスタンスを再利用してください。

> macOS 14.0+ が必要です。marked.js、highlight.js、ローカライズリソースはパッケージに同梱されています。

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
