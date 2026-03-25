# Timeline 性能优化现状与当前架构

> 日期: 2026-03-25
> 状态: 当前实现基线

## 当前结论

Timeline 的主问题已经解决，当前方案已经从多轮实验收束为单一路径：

1. 主时间线使用单个 `WKWebView` 承载
2. SwiftUI 只负责快照生成和外层页面结构
3. Markdown 使用 bundled `marked.min.js` 做渐进增强，纯文本作为兜底
4. 代码块高亮通过本地 bundled 的 highlight.js 资源完成，不依赖网络

这份文档只描述现在仍然生效的实现，不保留已经废弃的 AppKit `NSTableView` / `MessageRow` / `TimelineListView` 路径。

## 当前实现

### 1. 主滚动容器

- Timeline 主滚动路径已经切到单个 `WKWebView`
- 主承接文件为 `TimelineHostView.swift`
- 渲染方式是 Swift 直接生成整段 HTML，再交给 WebKit 展示
- 这样做的核心目标是把超长消息排版、滚动复用、Markdown 布局从 SwiftUI 主线程热点里移出去

### 2. 数据渲染层

- Timeline 通过值类型快照驱动渲染，而不是直接绑定 `SwiftData @Model`
- 当前核心快照类型：
  - `TimelineRenderSnapshot`
  - `TimelineMessageDisplayData`
  - `ContextPanelSnapshot`
- `SessionMessagesView` 负责把 `Message` 派生成稳定快照，并缓存 `TimelineMessageDisplayData`
- 目标是切断滚动过程中不必要的 observation、解码和派生数据重建

### 3. 窗口化渲染策略

- `TimelineHostView` 只渲染最近一段消息窗口，默认批次为 200 条
- 更早的消息仍保留顶部 `Load older messages` 作为兜底入口，但主路径已升级为接近顶部自动加载
- 自动加载更早消息时，会把当前窗口的首条已渲染消息作为锚点，避免加载后直接跳回底部
- 普通刷新只在用户仍处于底部附近时自动贴底；如果用户正在浏览历史，新消息不会强制打断

### 4. Markdown 策略

- Timeline 消息正文先以内联纯文本 HTML 输出，确保任何情况下都能显示内容
- 页面加载完成后，再由 `marked.min.js` 把带 `data-markdown-base64` 的节点升级为 Markdown
- Markdown 升级完成后，再对 `pre code` 代码块执行 highlight.js 高亮
- 高亮后的代码块会进一步套上统一的 code block chrome，包括语言标签和复制按钮
- 如果 `marked` 加载失败或渲染异常，页面仍保留纯文本兜底，不会出现中间整块空白
- 如果高亮脚本失败，页面仍保留未高亮的 Markdown 代码块，不影响内容可见性
- 同一套 `marked` 和 highlight.js 资源加载器也被 `MarkdownRenderView.swift` 复用，用于上下文面板和文件预览中的 Markdown 展示

### 5. 宽度与布局策略

- 消息列宽不再写死，而是使用响应式范围：`clamp(560px, 72vw, 980px)`
- 窗口放大时，气泡会跟随变宽；窗口缩小时，仍会自动收缩
- 助手头部单独使用 `assistant-header` 样式，避免标签与模型 pill 因通用 heading margin 产生错位

### 6. 右侧上下文面板

- 右侧上下文面板仍由 SwiftUI 渲染
- 其数据来源已经收束为 `ContextPanelSnapshot`
- 显式宽度动画已移除，避免 Timeline 因侧栏动画频繁触发重排

## 当前已移除的旧方案

以下路径已经明确废弃，不再作为兼容层保留：

1. `TimelineListView`
2. `MessageRow.swift`
3. Timeline 内部的删除/回滚/摘要编辑动作链路
4. 文档中基于 `NSTableView` 的旧架构描述

这些内容已经不再参与当前 UI，也不再是后续优化基础。

## 当前剩余问题

当前剩余问题属于尾部体验问题，而不是架构性故障：

1. 右侧上下文面板切换时，仍可能有轻微布局感知
2. 极长 Markdown 内容首次进入可见区域时，仍会有一次 WebKit 内部排版与代码高亮成本
3. 自动加载更早消息目前仍是批量扩展，不是无限连续虚拟滚动
4. 代码块目前只做基础高亮，还没有语言标签、复制按钮和更强的编辑器式样式
4. 代码块已经有语言标签和复制按钮，但距离完整编辑器体验仍缺少更细的主题、行号和语言特化样式

## 当前不建议再做的方向

以下方向不建议再回头：

1. 回到基于 `MessageRow` 的 SwiftUI 主列表
2. 回到 `NSTableView` + 大量测高/缓存/同步刷新控制的复杂路径
3. 为了保留旧功能入口继续维持无 UI 消费的动作兼容层
4. 再次引入复杂的 JS 运行时状态管理和多段注入链路

## 后续优化优先级

如果未来继续做，建议按下面顺序推进。

### P1. 自动加载更早消息

目标：

- 继续细化当前已实现的接近顶部自动扩展逻辑，降低位置漂移风险

预期收益：

- 让当前窗口化方案更接近连续时间线体验

### P2. Markdown 渲染分级

目标：

- 对 assistant 内容保留完整 Markdown
- 对 user 内容默认保持纯文本或轻量 Markdown

预期收益：

- 在不影响主要阅读价值的前提下，继续降低渲染成本

### P3. 更精细的滚动位置保持

目标：

- 新消息、加载更早消息、切换 session 三种场景分别采用不同的滚动策略

预期收益：

- 进一步减少“被强制拉到底部”或“加载更早后位置跳动”的风险

### P4. 代码块样式升级

目标：

- 在现有高亮基础上增加语言标签、复制按钮和更接近编辑器的代码块样式

预期收益：

- 提升可读性，但不改变当前架构

## 建议的停止点

如果当前体感已经达到“明显流畅，结构也足够简单”，本轮可以在这里停止。

原因：

1. 主要性能问题已经解决
2. 当前实现复杂度比之前显著更低
3. 后续优化已经是体验打磨，不再是架构救火
