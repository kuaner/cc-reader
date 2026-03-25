# cc-reader

[English](README.md) | [日本語](README.ja.md) | 简体中文

一个用于阅读和管理 [Claude Code](https://docs.anthropic.com/en/docs/claude-code) 会话历史的 macOS 应用。

它会监控 `~/.claude/projects/` 下的 JSONL 文件，并以原生 UI 展示会话时间线、思考过程和工具使用记录。

> **⚠️ 免责声明**
> 这是一个**非官方**第三方工具。Claude Code 的 JSONL 格式并非公开 API，可能在无通知的情况下变化。部分管理操作可能会修改本地会话文件，请务必保留备份。

## 功能

- **会话阅读器** — 基于 WKWebView 的时间线，支持 Markdown 渲染、语法高亮、代码块操作和单条消息复制
- **实时同步** — 使用 FSEvents 监听文件变化，增量解析 JSONL
- **会话管理** — 支持在侧边栏中重命名或删除会话
- **多窗格布局** — 最多 12 个窗格同时监控多个会话
- **上下文面板** — 一眼查看 Claude 的理解状态以及已读/已编辑文件
- **长时间线优化** — 窗口化渲染 + 接近顶部自动加载更早消息

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
make version VERSION=0.2.0 BUILD_NUMBER=2

# 更新版本、创建发布提交并打 v0.2.0 tag
make release-tag VERSION=0.2.0 BUILD_NUMBER=2

# 同时推送分支和 tag 到 GitHub
make publish VERSION=0.2.0 BUILD_NUMBER=2
```

执行 `make publish` 后，GitHub Actions 会在收到 release tag 时自动构建 universal Release app、生成 DMG，并上传到 GitHub Releases。

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
数据源: ~/.claude/projects/**/*.jsonl
    ↓ FSEvents
FileWatcherService → SyncService → JSONLParser (增量解析)
    ↓
SwiftData ModelContext
    ↓
SessionMessagesView（快照构建）
    ↓
TimelineHostView（单一 WKWebView，窗口化渲染）
```

完整规格请见 [docs/SPEC.md](docs/SPEC.md)。

## 文档

- [架构与规格说明](docs/SPEC.md)

## 致谢

本仓库 fork 自 [Mutafika/Opuswap](https://github.com/Mutafika/Opuswap)，原项目采用 MIT License。

## 许可证

[MIT](LICENSE)
