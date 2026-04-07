# Timeline Web 栈：已完成工作与后续重构备忘

本文档总结 **cc-reader** 中将时间线 / Markdown 预览从「Swift 内联 Web 资源」迁到 **`timeline-ui`（Vite + Svelte 5 + TypeScript）** 的主要变更，并列出 **`timeline-ui` 下一步可重构方向**，便于你规划迭代。

**Inspector 导向的分阶段重构路线**（产品语义、优先级、验收）见：[timeline-inspector-refactor-plan.md](./timeline-inspector-refactor-plan.md)（设计上下文见根目录 [`.impeccable.md`](../.impeccable.md)）。

---

## 一、已完成的工作（架构与职责）

### 1. 双产物构建

- **时间线壳**：`npm run build` 第一步产出 `timeline-shell.js` + `timeline-shell.css`，由 [`src/timeline-shell/main.ts`](../timeline-ui/src/timeline-shell/main.ts) 入口打包（Svelte 5、Tailwind、marked、highlight.js、`src/bridge/*` 等）。
- **Markdown 独立预览**：第二步使用 `vite.config.ts` 的 `--mode markdown-preview` 产出 `markdown-preview.js` + `markdown-preview.css`，入口为 [`src/markdown-preview/main.ts`](../timeline-ui/src/markdown-preview/main.ts)（无 Svelte）。
- **静态 HTML 模板**：`timeline-ui/public/` 下的 `timeline-shell.html`、`markdown-preview.html` 在构建时复制到 `CCReader/Resources/`，与上述静态资源同目录。

### 2. Swift 侧瘦身

- **不再**在 Swift 中维护大段 HTML/CSS/JS 字符串来注入 marked、highlight、时间线样式。
- **`WebRenderAssets.swift`** 收敛为 **`WebRenderResourceLoader`**：统一 `Bundle.module` / `Bundle.main`、`resourceDirectoryURL`（供 `loadHTMLString` 解析相对路径）、按文件名读取文本模板。
- **时间线**：`TimelineHostView` 读取 `timeline-shell.html`，仅替换 `<!-- CCREADER_TIMELINE_BODY -->`；**boot 参数**（`__CCREADER_I18N__`、`__FOLLOW_BOTTOM_THRESHOLD__`）通过 **`WKUserScript`（`atDocumentStart`）** 注入，HTML 模板中无 boot 占位。
- **Markdown 预览**：`MarkdownRenderView` 读取 `markdown-preview.html`，仅替换占位符 **`__CCREADER_MD_B64__`**（UTF-8 内容的 Base64）。

### 3. 前端侧能力迁移（原 `WebRenderChrome`）

- **样式**：`styles/markdown-shared.css`（共用 Markdown 代码块 + hljs）；`styles/timeline.css`（仅时间线：原数据按钮、用户气泡代码）。
- **逻辑**：代码块外壳由 **`ccreaderMarkedConfig` 的 `code` renderer** 输出（仅语言条，**无**代码复制按钮）；剪贴板与 i18n 在 **`lib/clipboardCopy.ts`**（供「原数据」等）；**「原数据」** 在 **`RawDataButton.svelte`** 内 `onclick`。
- **时间线 i18n**：`window.__CCREADER_I18N__` 由 Swift 的 `WKUserScript` 设置；`clipboardCopy.getCcreaderI18n()` 在运行时读取。

### 4. Markdown 与代码高亮

- **marked**：npm 依赖 + `src/markdown-preview/ccreaderMarkedConfig.ts`（HTML 安全、图片、**围栏代码块 + chrome**）。
- **时间线**：`main.ts` 引入 `timeline-app` + `markdown-shared` + `timeline`，打进 **`timeline-shell.css`**。
- **Markdown 预览**：`markdown-preview.css`（`@import` tokens + `markdown-shared` + 本页 body/.markdown），打进 `markdown-preview.css`。
- **Markdown 预览 fallback**：仅在 **`marked` 不可用或解析/增强流程抛错** 时，在 `src/markdown-preview/main.ts` 中退回纯文本（`.plain-text`）；**不在** HTML 里先塞 fallback 再被覆盖。

### 5. 构建与资源安全

- **`vite.config.ts`** 内用 `mergeConfig` 固定 **`emptyOutDir: false`**、`outDir: CCReader/Resources`、`cssCodeSplit: false`，并以 **`--mode timeline-shell|markdown-preview`** 切换 library 入口；避免清空整个 `CCReader/Resources`，误删 `Assets.xcassets`、`*.lproj` 等。
- **`Package.swift` / Xcode**：将 `timeline-shell.*`、`markdown-preview.*`、对应 `.html` 等登记为资源；应用目标 **Resources** 与 SPM 一致。

### 6. 与旧文档的关系

- 旧文档中若仍写「Swift 内联 marked/highlight」「`timeline-shell.css` 仅由 Swift 引用」等，应以本文与 **当前仓库文件** 为准；必要时可更新 `docs/timeline-rendering-architecture.md`、`docs/timeline-incremental-dom.md` 中的交叉引用。

---

## 二、资源与加载顺序（速查）

| 场景 | 主要文件 | Swift 要点 |
|------|-----------|------------|
| 时间线 WKWebView | `timeline-shell.html` + `timeline-shell.css` + `timeline-shell.js` | `loadHTMLString(baseURL: resourceDirectoryURL)`；`WKUserScript` 注入 boot |
| Markdown 预览 WKWebView | `markdown-preview.html` + `markdown-preview.css` + `markdown-preview.js` | 同上 `baseURL`；模板替换 `__CCREADER_MD_B64__` |

---

## 三、`timeline-ui` 建议重构项（按优先级/主题）

以下为**代码审阅式**清单，便于你分阶段做；不必一次做完。

### A. 一致性与去重

1. **highlight.js 主题**  
   - **共享基座**：`src/styles/hljs-shared-base.css`（GitHub light/dark + `hljs-assistant-ledger`）。  
   - **时间线**：再叠 `hljs-user-bubble.css` → `hljs-runtime-themes.css` → `timeline-shell.css`。  
   - **预览**：仅 `hljs-shared-base.css` → `markdown-preview.css`。

2. **Base64 解码**  
   - **已做**：统一为 [`src/lib/decodeUtf8Base64.ts`](../timeline-ui/src/lib/decodeUtf8Base64.ts)，并有 Vitest 覆盖。

3. **Vite 配置重复**  
   - **已做**：单文件 [`vite.config.ts`](../timeline-ui/vite.config.ts) 内 `mergeConfig` 合并共享 `build` 与按 `mode` 切换的入口。

### B. 结构与可维护性

4. **`ccreaderBridge` 体积**  
   - **已做**：拆为 `src/bridge/`（`scroll.ts`、`timelineState.svelte.ts`、`ccreaderApi.ts`、`nativeHooks.ts`、`installCcreader.ts`）。

5. **组件与 `MessageRow` 相关**  
   - 随功能增长，可按「消息类型 / 行内工具 / 原始数据」等继续拆子组件或 hooks，避免单文件过长。

6. **`marked` / `ccreaderMarkedConfig`**  
   - 若规则变多，可考虑与「预览入口」共享配置的单测或快照测试。

### C. 开发体验与工程化

7. **开发 watch**  
   - **`npm run dev`**：仅主配置（时间线 `timeline-shell.*`）watch。  
   - **`npm run dev:preview`**：仅预览 bundle（`markdown-preview.*`）watch。  
   - **`npm run dev:all`**：`concurrently` 同时跑上述两段，改任一侧都会重建。

8. **类型与全局**  
   - `globals.d.ts` 中 `Window` 扩展与桥接 API 等保持同步；可考虑收紧 `any` 与 `window as unknown as` 的用法。

9. **测试**  
   - 已引入 **Vitest**：`npm test` 运行 `src/**/*.test.ts`（当前覆盖 `decodeUtf8Base64`、`ccreaderMarkedConfig` 的 renderer）。需 DOM 的测试可后续用 `happy-dom` / `jsdom` 补充。

### D. 产物与仓库策略

10. **`CCReader/Resources` 下的构建产物**  
    - 是否提交由团队约定；若 CI 负责 `npm run build`，可在文档中说明 **发布前必须构建**，避免 Swift 侧读到旧 `timeline-shell.js`。

---

## 四、配色方案（如何改主题色）

时间线 UI 使用 **Session Ledger 语义 token**（暖中性 + 琥珀用户侧），**唯一主源**为 [`timeline-ui/src/styles/design-tokens.css`](../timeline-ui/src/styles/design-tokens.css) 中 `:root` 与 `prefers-color-scheme: dark`；布局与 Tailwind 工具类入口为 [`timeline-app.css`](../timeline-ui/src/styles/timeline-app.css)。设计说明见 [`.impeccable.md`](../.impeccable.md)。修改后执行 `npm run build` 生成 `CCReader/Resources` 内样式。

**完整变量表**、**未纳入 token 的例外**（hljs 语法色、独立预览页同步等）、**用户气泡禁止 `prose-invert` 的原因**见：[timeline-ui-color-tokens.md](./timeline-ui-color-tokens.md)。

---

## 五、相关路径一览

| 路径 | 说明 |
|------|------|
| `timeline-ui/` | 前端工程与 `public/*.html` 源模板 |
| `timeline-ui/src/timeline-shell/main.ts` | 时间线 shell 入口（Vite 主配置 `entry`） |
| `timeline-ui/src/bridge/` | `window.ccreader` 桥接（滚动、状态、WK 消息等） |
| `timeline-ui/src/markdown-preview/` | `marked` 配置、管线、`main.ts`（markdown-preview 入口） |
| [`timeline-ui-color-tokens.md`](./timeline-ui-color-tokens.md) | 配色语义变量、修改方式、例外说明 |
| `CCReader/Resources/` | 构建输出（含 `*.html`、`*-shell.js/css`、`markdown-preview.*`） |
| `CCReader/Views/Timeline/WebRenderAssets.swift` | 资源读取与 `baseURL` |
| `CCReader/Views/Timeline/TimelineHostView.swift` | 时间线 WKWebView、`WKUserScript`、模板占位 |
| `CCReader/Views/Timeline/MarkdownRenderView.swift` | 预览 WKWebView、Base64 占位 |
| `Package.swift` | `CCReaderKit` 资源列表 |

---

*文档生成于迁移与后续讨论整理；若实现变更，请同步更新本节与「二、资源与加载顺序」。*
