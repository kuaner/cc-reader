# Opuswap

[English](README.md) | [日本語](README.ja.md) | 简体中文

一个用于实时可视化和管理 [Claude Code](https://docs.anthropic.com/en/docs/claude-code) 会话历史的 macOS 应用。

它会监控 `~/.claude/projects/` 下的 JSONL 文件，并以原生 UI 展示会话时间线、思考过程和工具使用记录。

> **⚠️ 免责声明**
> 这是一个**非官方**第三方工具。Claude Code 的 JSONL 格式并非公开 API，可能在无通知的情况下变化。Surgery Mode 会直接修改会话文件 —— **请自行承担风险**，并务必保留备份。

## 功能

- **会话查看器** — 以时间线形式展示 thinking / 工具调用 / diff（含语法高亮）
- **实时同步** — 使用 FSEvents 监听文件变化，增量解析 JSONL
- **多窗格布局** — 最多 12 个窗格同时监控多个会话
- **Surgery Mode** — 直接编辑 JSONL 优化上下文 token（批量删除、回滚、摘要编辑）
- **上下文面板** — 一眼查看 Claude 的理解状态以及已读/已编辑文件

## 环境要求

- macOS 14.0+
- Xcode 15.0+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## 快速开始

```bash
# 如未安装 XcodeGen
brew install xcodegen

# 克隆并构建
git clone https://github.com/Mutafika/Opuswap.git
cd Opuswap
xcodegen
open Opuswap.xcodeproj
```

在 Xcode 中按 `Cmd + R` 构建并运行。

## 技术栈

| 类别 | 技术 |
|------|------|
| UI | SwiftUI |
| 数据库 | [SQLite.swift](https://github.com/nicklama/SQLite.swift) |
| 文件监听 | FSEvents |
| 构建 | XcodeGen (`project.yml`) |

## 架构

```
数据源: ~/.claude/projects/**/*.jsonl
    ↓ FSEvents
FileWatcherService → SyncService → JSONLParser (增量解析)
    ↓
StorageManager (SQLite.swift)
    ↓
SwiftUI Views (ContentView / LayoutView)
```

完整规格请见 [docs/SPEC.md](docs/SPEC.md)。

## 文档

- [架构与规格说明](docs/SPEC.md)

## 许可证

[MIT](LICENSE)
