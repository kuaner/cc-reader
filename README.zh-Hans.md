# cc-reader

[English](README.md) | [日本語](README.ja.md) | 简体中文

一个用于阅读和管理 Claude Code 与 Codex 会话历史的 macOS 应用。

它会监控 `~/.claude/projects/` 与 `~/.codex/sessions/` 下的 JSONL 文件，并以原生 UI 展示会话时间线、思考过程和工具使用记录。

![cc-reader demo](assets/screenshot.gif)

> **⚠️ 免责声明**
> 这是一个**非官方**第三方工具。Claude Code 与 Codex 的会话格式并非公开 API，可能在无通知的情况下变化。部分管理操作可能会修改本地会话文件，请务必保留备份。

## 功能

- **会话阅读器** — 基于 WKWebView 的时间线，支持 Markdown 渲染、语法高亮、代码块操作和单条消息复制
- **Claude + Codex 数据源** — 侧边栏和会话选择器按 Claude / Codex 分开显示，时间线复用同一套 UI
- **快速会话索引** — 首次启动只创建轻量 session 列表，随后按时间倒序预热元数据，打开会话时再解析消息
- **实时同步** — 使用 FSEvents 监听文件变化，对变更文件增量解析 JSONL
- **会话管理** — 支持在侧边栏中重命名或删除会话
- **多窗格布局** — 最多 12 个窗格同时监控多个会话
- **上下文面板** — 一眼查看助手上下文，包括已读/已编辑文件、已执行命令、搜索和工具记录
- **长时间线优化** — 窗口化渲染 + 接近顶部自动加载更早消息
- **Resume 命令复制** — 在窗格工具栏复制 `claude --resume <sessionId>` 或 `codex resume <sessionId>`

## 环境要求

- macOS 14.0+
- Xcode 15.0+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## 快速开始

```bash
# 如未安装 XcodeGen
brew install xcodegen

# 克隆并构建
git clone https://github.com/kuaner/cc-reader.git
cd cc-reader
xcodegen
open CCReader.xcodeproj
```

在 Xcode 中按 `Cmd + R` 构建并运行。

## 本地构建命令

仓库根目录提供了 [Makefile](Makefile)，用于本地构建、生成 universal 二进制和打包。

```bash
# 生成 Xcode 工程
make gen

# 构建 universal Debug / Release app
make debug
make release

# 打开构建好的 app
make run CONFIG=Release

# 将 Release 打包成 DMG
make dmg
```

默认输出位置：

- App bundle: `build/DerivedData/Build/Products/Release/CC Reader.app`
- DMG: `build/cc-reader.dmg`

Makefile 默认会构建 universal macOS 二进制（`arm64` + `x86_64`）。

## 发布流程

版本更新和打标签通过本地 Makefile 完成。

```bash
# 更新 project.yml 中的 MARKETING_VERSION
make version VERSION=1.0.0 BUILD_NUMBER=2

# 更新版本、创建发布提交并打 v1.0.0 tag
make release-tag VERSION=1.0.0 BUILD_NUMBER=2

# 同时推送分支和 tag 到 GitHub
make publish VERSION=1.0.0 BUILD_NUMBER=2
```

执行 `make publish` 后，GitHub Actions 会在收到 release tag 时自动构建 universal Release app、生成 DMG，并上传到 GitHub Releases。

## Swift Package (CCReaderKit)

cc-reader 也可以作为 Swift Package 嵌入到其他 macOS 应用中。

### 添加依赖

在 Xcode 中：**File → Add Package Dependencies…** → 输入仓库地址：

```
https://github.com/kuaner/cc-reader.git
```

或在 `Package.swift` 中添加：

```swift
dependencies: [
    .package(url: "https://github.com/kuaner/cc-reader.git", from: "0.1.0"),
]
```

然后在 target 中引用 `CCReaderKit`：

```swift
.target(
    name: "YourApp",
    dependencies: [
        .product(name: "CCReaderKit", package: "cc-reader"),
    ]
)
```

### 使用方式

#### 快速上手 — 独立窗口

最简单的打开方式，一行代码：

```swift
import CCReaderKit

CCReaderKit.open()
```

窗口以单例方式管理，重复调用会复用已有窗口。

#### 完整集成 — NSWindow + Toolbar

对于需要完全控制窗口生命周期的应用（如菜单栏应用），使用 `CCReaderKit.makeView()` 自行创建和管理 `NSWindow`：

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

            // 必须：NSToolbar + .unified 样式，SwiftUI 的 toolbar items
            //（来源标识、路径、Resume、刷新按钮）才能渲染到标题栏。
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

> **要点：**
> - 使用 `NSHostingController`（而非 `NSHostingView`），才能正确桥接 SwiftUI toolbar。
> - 添加 `NSToolbar` 并设置 `.unified` 样式，toolbar items 才会显示在标题栏。
> - `styleMask` 中包含 `.fullSizeContentView`，`NavigationSplitView` 布局才正确。
> - 设置 `isReleasedWhenClosed = false` 以复用窗口实例。

> 需要 macOS 14.0+。Package 内已打包 marked.js、highlight.js 及多语言资源。

## 技术栈

| 类别 | 技术 |
|------|------|
| UI | SwiftUI + WKWebView（Timeline） |
| 持久化 | SwiftData |
| 文件监听 | FSEvents |
| Web 渲染 | marked.js + highlight.js（本地打包） |
| 构建 | XcodeGen (`project.yml`) |

## 架构

```
数据源:
  - ~/.claude/projects/**/*.jsonl
  - ~/.codex/sessions/**/*.jsonl
    ↓ FSEvents
FileWatcherService → SyncService → SessionTranscriptParserRegistry → JSONLParser
    ↓
SwiftData ModelContext
    ↓
LayoutManager（每个窗口标签页的窗格树、分割、聚焦与会话分配）
    ↓
SessionMessagesView（快照构建）
    ↓
TimelineHostView（单一 WKWebView，窗口化渲染）
```

完整规格请见 [docs/SPEC.md](docs/SPEC.md)。

## 文档

- [架构与规格说明](docs/SPEC.md)
- [布局系统 — 多标签页与多窗格](docs/layout-system.md)
- [Timeline 渲染架构](docs/timeline-rendering-architecture.md)
- [Timeline Incremental DOM](docs/timeline-incremental-dom.md)
- [Timeline 滚动优化](docs/timeline-scroll-optimization-notes.md)

## 致谢

本仓库 fork 自 [Mutafika/Opuswap](https://github.com/Mutafika/Opuswap)，原项目采用 MIT License。

## 许可证

[MIT](LICENSE)
