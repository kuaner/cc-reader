# Timeline 增量 DOM 渲染方案

## 架构概述

Shell HTML 一次加载 → `didFinish` 回调确认就绪 → 之后全部通过 `evaluateJavaScript()` 增量更新 DOM。

这与聊天类 Web 应用（Slack、Discord 等）的核心思路一致。

## 核心机制

### 1. 三态 ShellState

```swift
enum ShellState { case notLoaded, loading, loaded }
```

- `notLoaded` → 首次调用 `loadShellAndRenderInitial()` 时转为 `loading`
- `loading` → `webView(_:didFinish:)` 回调中转为 `loaded`
- `loaded` → 此后所有更新走 `evaluateJavaScript()`

解决了 `isShellLoaded` 布尔标记的时序竞态：`loadHTMLString` 是异步的，设置标记后立即调用 `evaluateJavaScript` 会在页面未就绪时执行。

### 2. 增量更新策略

| 场景 | 方法 | 说明 |
|------|------|------|
| 新消息追加 | `insertAdjacentHTML('beforeend', ...)` | 在 `.timeline` 末尾插入新节点 |
| 流式内容变更 | `outerHTML` 替换 | 通过 `rawFingerprint` 检测变化，原地替换整个消息 DOM |
| 加载更早消息 | `insertAdjacentHTML('afterbegin', ...)` | 在 `.timeline` 开头插入，配合 `scrollHeight` 差值补偿 |
| 等待指示器 | `insertAdjacentHTML` / `remove()` | 动态添加或移除 waiting indicator |

### 3. rawFingerprint 变更检测

```swift
let rawFingerprint = message.rawJson.hashValue
```

`renderedFingerprints` 字典记录每个 UUID 对应的 fingerprint。当 fingerprint 变化时（流式输出导致 `rawJson` 更新），对该消息执行 `outerHTML` 替换而非重新加载整个页面。

### 4. 滚动位置保持

#### 新消息追加
- `isFollowingBottom`：通过 JS→Swift 消息（`scrollState`）跟踪用户是否在底部
- 追加后若 `isFollowingBottom == true`，执行 `scrollTo(0, document.body.scrollHeight)`

#### 加载更早消息
```javascript
var oldH = document.body.scrollHeight;
timeline.insertAdjacentHTML('afterbegin', html);
// ... 后处理 ...
var newH = document.body.scrollHeight;
window.scrollTo(0, newH - oldH + window.scrollY);
```
保持视觉位置不跳动。

### 5. JS→Swift 通信

使用 `WKScriptMessageHandler`（name: `"ccreader"`），比 URL scheme 更可靠：

```javascript
window.webkit.messageHandlers.ccreader.postMessage({
    type: "scrollState",
    isAtBottom: ...,
    isNearTop: ...
});
```

- `scrollState`：报告滚动位置，触发 `isFollowingBottom` 更新和近顶部自动加载
- `loadOlder`：用户点击"加载更早消息"按钮

## 已完成的优化

### 1. loadOlderMessages UUID 列表操作简化

去掉了先 `insert(at:0)` 再 `filter` 重排的冗余代码，改为一行拼接：

```swift
renderedMessageUUIDs = olderUUIDs + renderedMessageUUIDs
```

### 2. 新消息后处理范围缩小

`renderMarkdownIn` / `highlightCodeBlocksIn` / `enhanceCodeBlocks` / `enhanceMessageCopyButtons` 只作用于新插入的节点，而非遍历整个 `.timeline` DOM：

```javascript
var newNodes = [];
tmpDiv.childNodes.forEach(function(n) {
    timeline.appendChild(n.cloneNode(true));
});
var allRows = timeline.querySelectorAll('.row');
for (var i = allRows.length - count; i < allRows.length; i++) {
    if (allRows[i]) newNodes.push(allRows[i]);
}
newNodes.forEach(function(node) {
    renderMarkdownIn(node);
    highlightCodeBlocksIn(node);
    enhanceCodeBlocks(node);
    enhanceMessageCopyButtons(node);
});
```

已渲染的 markdown 节点虽有 `mdRendered` 守卫跳过，但 `querySelectorAll` 遍历全量 DOM 是不必要的开销。

### 3. loadOlderMessages 后处理范围缩小（匹配增量更新）

`loadOlderMessages()` 插入的是一批“历史消息节点”。因此后续的 `renderMarkdownIn` / `highlightCodeBlocksIn` / `enhanceCodeBlocks` / `enhanceMessageCopyButtons` **只对这些新插入节点执行**，避免每次回填都对整棵 `.timeline` 做全量遍历，从而提升性能并减少行为不一致的风险。

### 4. JS 字符转义增强（escapeForJS 支持 U+2028/U+2029）

`evaluateJavaScript()` 会把字符串字面量解析为 JS 代码。若要插入的 HTML 中包含行分隔符字符 `U+2028` / `U+2029`，可能导致拼接出来的 JS 语法错误并出现静默失败。

因此在 `escapeForJS()` 中显式转义 `U+2028/U+2029`，提升低频内容下的稳定性。

### 5. makeShellHTML CSS/JS 提取到 Bundle 资源文件

将 Timeline 的静态 Shell 样式与初始化脚本（`timeline-shell.css` / `timeline-shell.js`）从 `TimelineHostView.makeShellHTML` 的大段字符串中抽离到 Bundle 资源文件中，再由 Swift 运行时读取拼接。

这样可显著降低 `TimelineHostView.swift` 的维护成本，并让后续对 Shell UI/行为的调整更安全。

### 6. 拆分 TimelineHTMLRenderer（消息渲染逻辑独立）

将消息 HTML 生成逻辑从 `TimelineHostView.Coordinator` 中抽离到 `TimelineHTMLRenderer`，让渲染规则与滚动/增量更新策略解耦。

后续补充单元测试时，可以直接验证渲染输出与转义策略，降低回归风险。

## 更激进的优化方向（当前不需要）

以下方案在当前 200 条 batch 的规模下完全不需要，仅供未来参考：

### 虚拟滚动
只渲染视口内 ± 缓冲区的消息 DOM 节点。适合万条消息级别。

### Web Worker 渲染 markdown
将 `marked.parse()` 放到 Worker 避免阻塞主线程。除非消息内容非常大，否则感知不到差异。

### DOM 回收池
复用移出视口的 DOM 节点。同上，当前规模完全不需要。

## 相关文件

| 文件 | 作用 |
|------|------|
| `CCReader/Views/Timeline/TimelineHostView.swift` | WKWebView 宿主、Shell HTML、增量更新逻辑、消息渲染 |
| `CCReader/Views/Timeline/TimelineModels.swift` | `TimelineMessageDisplayData`、`TimelineRenderSnapshot` |
| `CCReader/Views/Timeline/WebRenderAssets.swift` | marked.js/highlight.js 加载、代码块增强脚本 |
| `CCReader/Views/Timeline/SessionMessagesView.swift` | 快照构建、消息窗口管理 |
