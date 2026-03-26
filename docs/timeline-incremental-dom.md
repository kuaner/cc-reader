# Timeline 增量 DOM 渲染方案

## 当前架构结论

Timeline 已统一为「Swift 组装 payload + JS 渲染 DOM」模型：

- Swift (`TimelineHostView.Coordinator`) 负责窗口状态、diff 检测、命令派发。
- JS (`timeline-shell.js`) 负责消息渲染、DOM patch、滚动策略、事件上报。
- 首屏、切换会话、增量更新、加载更早消息均走 payload 渲染入口。

`TimelineHTMLRenderer` 已移除，不再在 Swift 侧拼接消息 HTML。

## 生命周期与状态机

```swift
enum ShellState { case notLoaded, loading, loaded }
```

- `notLoaded`：调用 `loadShellAndRenderInitial()`，先加载空 `.timeline` shell。
- `loading`：等待 `webView(_:didFinish:)`。
- `loaded`：在 `didFinish` 中调用 `replaceTimelineFromPayloads` 填充首屏，再继续增量更新。

这样可避免 `loadHTMLString` 异步导致的时序问题。

## 统一渲染入口

### Swift 侧入口

- `replaceTimelineForSession()` -> `replaceTimelineContentViaPayloads(updatingCoordinatorState: true)`
- `loadOlderMessages()` -> `prependOlderFromPayloads(...)`
- `incrementalUpdate()`：
  - 更新消息：`replaceMessagesFromPayload(...)`
  - 新增消息：`appendMessagesFromPayload(...)`

### JS 侧入口

- `ccreader.replaceTimelineFromPayloads(opts)`
- `ccreader.prependOlderFromPayloads(opts)`
- `ccreader.replaceMessagesFromPayload(payloads)`
- `ccreader.appendMessagesFromPayload(payloads)`
- 底层共享：`ccreaderRenderMessageFromPayload(payload)`

## payload 契约（核心字段）

每条消息 payload（由 `messagePayload(...)` 生成）：

```json
{
  "uuid": "message-uuid",
  "domId": "msg-message-uuid",
  "isUser": true,
  "isSummary": false,
  "timeLabel": "10:24",
  "content": "...",
  "thinking": "...",
  "thinkingTitle": "...",
  "modelTitle": "...",
  "assistantLabel": "...",
  "contextLabel": "...",
  "summaryLabel": "...",
  "legendUser": "...",
  "legendAssistant": "...",
  "legendSummary": "...",
  "rawData": "...",
  "rawDataLabel": "...",
  "tools": [{ "title": "...", "body": "..." }]
}
```

容器 envelope：

- replace 全量：`{ messages, loadOlderBarHTML, waitingHTML }`
- prepend older：`{ messages, removeOlderBar }`

## 增量更新策略

- 新消息检测：`renderedMessageSet`。
- 内容变化检测：`renderedFingerprints[uuid]` 对比 `rawFingerprint`。
- 等待指示器：`hasWaitingIndicator` 与末条消息类型对齐。
- 加载更早条：`hasOlderIndicator` 与窗口下界（`renderedMessageRange.lowerBound > 0`）对齐。

## 滚动与交互

- Swift 通过 JS 消息 `scrollState` 维护 `isFollowingBottom`。
- 追加消息时仅在接近底部才自动滚动。
- prepend older 通过 `scrollHeight` 差值补偿保持视觉位置。
- `loadOlder` 点击事件通过 `WKScriptMessageHandler("ccreader")` 回传给 Swift。

## Markdown 与安全策略

`timeline-shell.js` 中 `marked` 采用统一配置：

- 禁用 markdown 内嵌原始 HTML（按文本转义输出）。
- markdown 图片渲染为链接（避免 WKWebView 图像解码问题与布局抖动）。

## 相关文件

| 文件 | 作用 |
|------|------|
| `CCReader/Views/Timeline/TimelineHostView.swift` | shell 生命周期、状态机、payload 派发 |
| `CCReader/Views/Timeline/TimelineModels.swift` | timeline 视图数据模型与 `timelineDOMId` |
| `CCReader/Views/Timeline/WebRenderAssets.swift` | marked/highlight 与增强脚本资源 |
| `CCReader/Resources/timeline-shell.js` | 渲染函数、DOM patch、滚动与桥接事件 |
| `CCReader/Resources/timeline-shell.css` | timeline 样式与 markdown 样式 |

## 维护约束

- 新增消息展示字段时，必须同时更新：
  - Swift `messagePayload(...)`
  - JS `ccreaderRenderMessageFromPayload(...)`
  - 文档中的 payload 契约
- 新增 DOM patch API 时，优先复用 payload 入口，避免新增 HTML 字符串直传路径。
