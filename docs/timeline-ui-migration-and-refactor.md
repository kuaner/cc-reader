# Timeline Web 栈：已完成工作与后续重构备忘

本文档总结 **cc-reader** 中将时间线 / Markdown 预览从「Swift 内联 Web 资源」迁到 **`timeline-ui`（Vite + Preact + TypeScript）** 的主要变更，并列出 **`timeline-ui` 下一步可重构方向**，便于你规划迭代。

---

## 一、已完成的工作（架构与职责）

### 1. 双产物构建

- **时间线壳**：`npm run build` 第一步产出 `timeline-shell.js` + `timeline-shell.css`，由 `main.tsx` 入口打包（Preact、Tailwind、marked、highlight.js、`ccreaderBridge` 等）。
- **Markdown 独立预览**：第二步使用 `vite.preview.config.ts` 产出 `markdown-preview.js` + `markdown-preview.css`，入口为 `markdownPreview.ts`（无 Preact）。
- **静态 HTML 模板**：`timeline-ui/public/` 下的 `timeline-shell.html`、`markdown-preview.html` 在构建时复制到 `CCReader/Resources/`，与上述静态资源同目录。

### 2. Swift 侧瘦身

- **不再**在 Swift 中维护大段 HTML/CSS/JS 字符串来注入 marked、highlight、时间线样式。
- **`WebRenderAssets.swift`** 收敛为 **`WebRenderResourceLoader`**：统一 `Bundle.module` / `Bundle.main`、`resourceDirectoryURL`（供 `loadHTMLString` 解析相对路径）、按文件名读取文本模板。
- **时间线**：`TimelineHostView` 读取 `timeline-shell.html`，仅替换 `<!-- CCREADER_TIMELINE_BODY -->`；**boot 参数**（`__CCREADER_I18N__`、`__FOLLOW_BOTTOM_THRESHOLD__`）通过 **`WKUserScript`（`atDocumentStart`）** 注入，HTML 模板中无 boot 占位。
- **Markdown 预览**：`MarkdownRenderView` 读取 `markdown-preview.html`，仅替换占位符 **`__CCREADER_MD_B64__`**（UTF-8 内容的 Base64）。

### 3. 前端侧能力迁移（原 `WebRenderChrome`）

- **样式**：`styles/web-chrome.css`（代码块头部、复制按钮、消息复制按钮等）。
- **逻辑**：`webChrome.ts`（`copyCodeText`、`enhanceCodeBlocks`、`enhanceMessageCopyButtons`）；`markdown.ts` 中 `enhanceSubtree` 直接引用，不再依赖 Swift 注入的全局函数字符串。
- **时间线 i18n**：`window.__CCREADER_I18N__` 由 Swift 的 `WKUserScript` 设置；`webChrome.ts` 在运行时读取。

### 4. Markdown 与代码高亮

- **marked**：npm 依赖 + `ccreaderMarkedConfig.ts`（renderer 安全策略等）。
- **时间线**：`hljsThemes.ts` 使用 highlight 的 CSS（`?raw`）按 `prefers-color-scheme` 注入 `<style>`。
- **Markdown 预览**：`markdownHljs.css` 使用带媒体条件的 `@import` 引入 light/dark 主题，打进 `markdown-preview.css`。
- **Markdown 预览 fallback**：仅在 **`marked` 不可用或解析/增强流程抛错** 时，在 `markdownPreview.ts` 中退回纯文本（`.plain-text`）；**不在** HTML 里先塞 fallback 再被覆盖。

### 5. 构建与资源安全

- **`vite.config.ts`** 中 **`emptyOutDir: false`**，避免清空整个 `CCReader/Resources`，误删 `Assets.xcassets`、`*.lproj` 等。
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

1. **highlight.js 主题策略分裂**  
   - 时间线：`hljsThemes.ts`（运行时注入 `<style>` + `?raw`）。  
   - 预览：`markdownHljs.css`（构建期 CSS `@import` + `prefers-color-scheme`）。  
   - **方向**：二选一或抽一层「主题加载」接口，减少两套行为与体积心智负担（注意与 Tailwind 时间线 bundle 的体积取舍）。

2. **Base64 解码**  
   - `markdown.ts` / `markdownPreview.ts` 等处若存在 `decodeMarkdownBase64` 重复，可抽到 **`lib/decodeMarkdownBase64.ts`** 单测。

3. **Vite 配置重复**  
   - `vite.config.ts` 与 `vite.preview.config.ts` 共享 `outDir`、`emptyOutDir`、`rollupOptions.output.assetFileNames` 等。  
   - **方向**：`defineConfig` 工厂函数或 `mergeConfig`，降低改一处漏一处的风险。

### B. 结构与可维护性

4. **`ccreaderBridge.tsx` 体积**  
   - 集滚动、Preact 状态、`ccreader` API 等。  
   - **方向**：拆为 `scroll.ts`、`bridgeApi.ts`、`timelineState.ts` 或类似，保持单文件职责单一。

5. **组件与 `MessageRow` 相关**  
   - 随功能增长，可按「消息类型 / 行内工具 / 原始数据」等继续拆子组件或 hooks，避免单文件过长。

6. **`marked` / `ccreaderMarkedConfig`**  
   - 若规则变多，可考虑与「预览入口」共享配置的单测或快照测试。

### C. 开发体验与工程化

7. **`npm run dev`（`vite build --watch`）**  
   - 当前 watch 仅覆盖主配置时，**预览 bundle** 不会自动重建。  
   - **方向**：双 `watch` 脚本、`concurrently`，或文档中明确「改预览需跑第二段 build」。

8. **类型与全局**  
   - `globals.d.ts` 中 `Window` 扩展与 `webChrome` 等保持同步；可考虑收紧 `any` 与 `window as unknown as` 的用法。

9. **测试**  
   - 为 `webChrome`（复制、DOM 包装）、`decodeMarkdownBase64`、`ccreaderMarkedConfig` 的 renderer 行为增加轻量单元测试（Vitest 等），需视项目是否引入测试运行器而定。

### D. 产物与仓库策略

10. **`CCReader/Resources` 下的构建产物**  
    - 是否提交由团队约定；若 CI 负责 `npm run build`，可在文档中说明 **发布前必须构建**，避免 Swift 侧读到旧 `timeline-shell.js`。

---

## 四、相关路径一览

| 路径 | 说明 |
|------|------|
| `timeline-ui/` | 前端工程与 `public/*.html` 源模板 |
| `CCReader/Resources/` | 构建输出（含 `*.html`、`*-shell.js/css`、`markdown-preview.*`） |
| `CCReader/Views/Timeline/WebRenderAssets.swift` | 资源读取与 `baseURL` |
| `CCReader/Views/Timeline/TimelineHostView.swift` | 时间线 WKWebView、`WKUserScript`、模板占位 |
| `CCReader/Views/Timeline/MarkdownRenderView.swift` | 预览 WKWebView、Base64 占位 |
| `Package.swift` | `CCReaderKit` 资源列表 |

---

*文档生成于迁移与后续讨论整理；若实现变更，请同步更新本节与「二、资源与加载顺序」。*
