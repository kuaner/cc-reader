# timeline-ui 配色方案（语义 Token）

时间线气泡、标签、代码块外壳等 UI 颜色由 **CSS 自定义属性** 集中管理，便于换肤或对齐设计系统。

## 设计基准

当前实现为 **Session Ledger**：暖色中性「档案纸」感；用户消息用**赭/褐面板** + **`--bubble-user-accent` 左边线**区分。深色下 **助手为偏冷板岩（`#252a2e`）**、**用户为暖褐（`#4a372e`）**，色相拉开；浅色下助手为 **淡暖灰纸（`#faf8f5`）**、用户为 **锈橙**，避免与纯白糊在一起。设计意图见 [`.impeccable.md`](../.impeccable.md)。

- **浅色**：`#faf8f5` 助手面板、锈橙用户侧（`:root`）
- **深色**：板岩助手 + 暖褐用户（`@media (prefers-color-scheme: dark)`）

**字体**：`--font-ui` / `--font-read` 均使用 **Apple 系统栈**（`-apple-system` / SF Pro，见 [`design-tokens.css`](../timeline-ui/src/styles/design-tokens.css)），不加载网络字体；Markdown 正文与 UI 一致，便于与 macOS 原生观感对齐。

## 如何修改配色

1. 打开 [`timeline-ui/src/styles/design-tokens.css`](../timeline-ui/src/styles/design-tokens.css)（**语义色与字体的唯一来源**）。
2. 在 **`:root { ... }`** 中改浅色变量；在 **`@media (prefers-color-scheme: dark) { :root { ... } }`** 中改深色变量。`tailwind.css` 通过 `@import` 引用该文件；布局与组件样式仍在 `tailwind.css`。
3. 在 `timeline-ui` 目录执行 **`npm run build`**，将产物同步到 `CCReader/Resources/`（若团队不提交构建产物，则发布流水线需包含该步骤）。

**原则**：组件内应使用 `var(--token-name)` 或已在 `tailwind.css` 中绑定的工具类；**不要**在 TSX 里写死 `#rrggbb` 或 `bg-red-500` 这类与主题无关的 Tailwind 色阶（历史代码已迁到 token）。

**用户气泡正文**：不要使用 `prose-invert`。用户气泡为 **暖褐/赭底 + 与模式匹配的对比色字**（`--surface-user-text`；深色为奶油色字而非纯黑）。助手/摘要使用 **`markdown-prose-assistant`** 与 `--tw-prose-*` token（见 `tailwind.css`）；用户侧为 **`markdown-prose-user`**。入口在 [`MessageBody.tsx`](../timeline-ui/src/components/MessageBody.tsx)。

---

## 变量清单（主源：`design-tokens.css`）

下列变量均在 `design-tokens.css` 中定义；浅色 / 深色各一套，名称相同，值随 `prefers-color-scheme` 切换。`markdown-preview` 与 `timeline-shell` 共用该文件，避免两套 `:root` 漂移。

### 全局与正文

| 变量 | 用途 |
|------|------|
| `--text` | 页面默认正文色 |
| `--muted` | 次要说明、助手标题等 |
| `--border` | 通用描边 |
| `--button` | Pill、模型名等中性底 |
| `--ring` | 焦点环（按钮、链接 `:focus-visible`） |
| `--accent-link` / `--accent-link-hover` | 助手 Markdown 内链接（与用户侧暖色区分） |
| `--font-ui` / `--font-read` | UI 与 Markdown 正文字体栈（见 `design-tokens.css`） |

### 气泡表面

| 变量 | 用途 |
|------|------|
| `--surface-user` | 用户消息气泡背景 |
| `--surface-user-text` | 用户气泡内主文字（及 prose 正文） |
| `--bubble-user-accent` | 用户气泡左侧强调条（与 `--surface-user` 同系、更低饱和） |
| `--bubble-user-rim` | 用户气泡其余描边 |
| `--bubble-user-link` | 用户气泡内链接色 |
| `--bubble-user-blockquote-border` | 用户气泡引用左边框 |
| `--bubble-user-inline-code-bg` / `--bubble-user-inline-code-fg` | 用户气泡行内 `code` |
| `--bubble-user-footer-border` / `--bubble-user-footer-muted` | 用户气泡底栏分隔线与时间戳次要色 |
| `--bubble-user-control-*` | 用户气泡内「复制 / 原数据」等控件（fg / bg / hover / border / focus-ring） |
| `--surface-assistant` | 助手卡片背景 |
| `--bubble-assistant-border` | 助手卡片描边 |
| `--surface-thinking` | Thinking 区块背景 |
| `--surface-tool` | 工具结果区背景 |
| `--surface-summary` / `--border-summary` / `--accent-summary-fg` | 摘要类气泡 |
| `--accent-error-bg` / `--accent-error-border` / `--accent-error-fg` | API 错误气泡 |
| `--bubble-dispatch-*` | `agent_dispatch` 卡片（bg / border / inset / header-border） |
| `--bubble-assistant-hover-border` / `--bubble-dispatch-hover-border` | 助手 / dispatch 卡片 hover 描边加亮 |
| `--bubble-user-rim-hover` / `--bubble-user-accent-hover` | 用户气泡 hover 外框与左侧强调条加亮 |
| `--attachment-bg` | 用户消息内嵌图片容器背景 |

### 标签与徽章（TypeTags / SummaryTag / ErrorTag）

| 变量 | 用途 |
|------|------|
| `--tag-tool-use-*` | 非用户行 `tool_use`（bg / border / text） |
| `--tag-tool-result-*` | 用户行 `tool_result` |
| `--tag-user-bg` / `--tag-user-text` | 用户行默认 meta 标签 |
| `--tag-dispatch-*` | dispatch 角色标签 |
| `--tag-assistant-*` | 助手默认标签 |
| `--tag-summary-*` / `--tag-error-*` | 摘要 / 错误小标签 |
| `--pill-special-*` | `.pill.special`（如 specialTag） |
| `--usage-token-bg` / `--usage-token-text` | 用量 token 徽章 |

### 代码块外壳（非语法高亮色）

| 变量 | 用途 |
|------|------|
| `--code-bg` | `pre` / 代码块区域底（助手侧等） |
| `--code-block-border` / `--code-header-*` | 代码块容器与头部条 |
| `--code-button-*` / `--message-button-*` | 代码复制、消息复制按钮默认态 |
| `--chrome-copy-success-fg` / `--chrome-copy-success-border` | 复制成功 `.is-copied` 状态 |

### 选区与交互

| 变量 | 用途 |
|------|------|
| `--selection-assistant` / `--selection-user` | `::selection` 高亮背景 |

---

## 其他样式文件中的颜色（与主盘关系）

| 文件 | 说明 |
|------|------|
| [`timeline-ui/src/styles/web-chrome.css`](../timeline-ui/src/styles/web-chrome.css) | 代码块布局、复制按钮；**颜色均引用** `tailwind.css` 中的变量（含 `--chrome-copy-success-*`、`--ring`）。 |
| [`timeline-ui/src/styles/hljs-user-bubble.css`](../timeline-ui/src/styles/hljs-user-bubble.css) | **仅用户气泡内** Monokai 语法高亮（token 色为固定十六进制）。换整体 UI 主题时一般**不必**改；若需统一品牌，可整段替换为另一套 hljs 主题并仍用 `.bubble.user .markdown` 作用域。 |
| [`hljs-shared-base.css`](../timeline-ui/src/styles/hljs-shared-base.css)、[`hljs-runtime-themes.css`](../timeline-ui/src/styles/hljs-runtime-themes.css)、[`markdownHljs.css`](../timeline-ui/src/markdownHljs.css) | GitHub 风格 hljs + Session Ledger 助手覆盖；时间线另含用户气泡 hljs；与主盘 token **独立**，见迁移文档。 |
| [`timeline-ui/src/markdownPreviewPage.css`](../timeline-ui/src/markdownPreviewPage.css) | 独立 **markdown-preview** bundle **不经过** `tailwind.css`，需在此重复声明与 UI 相关的变量（如 `--text`、`--code-bg`、`--ring`、`--chrome-copy-success-*`）；改主盘后请**同步**此处，避免预览页与 timeline 脱节。 |

---

## 未放入 `:root` 的配色（有意保留）

1. **语法高亮（hljs）**  
   - 助手/预览：GitHub Light/Dark（npm `highlight.js/styles`）。  
   - 用户气泡：Monokai 衍生 **暖色余烬托盘**（[`hljs-user-bubble.css`](../timeline-ui/src/styles/hljs-user-bubble.css)），与用户暖褐底同温、左侧强调条与 `--surface-user` 混色；**不是** 语义 token 盘的一部分。

2. **Tailwind Typography 默认色阶**  
   [`MessageBody.tsx`](../timeline-ui/src/components/MessageBody.tsx) 中助手侧仍可能使用 `text-neutral-900`、`dark:prose-invert` 等与 Typography 插件搭配的 utility；**用户气泡**已通过 `.bubble.user .markdown.prose` 覆盖 `--tw-prose-*`。若全面改为「全部只认 token」，可再收一版仅保留 `prose` + `text-[color:var(--text)]` 等。

3. **极少量装饰性 rgba**  
   `tailwind.css` 内助手卡片 hover 的 `0 1px 0 rgba(0,0,0,0.04)` 等阴影为结构用中性色，未单独提成变量；若需严格「零硬编码」，可再抽 `--shadow-assistant-line` 等。

---

## 验收建议

改色后至少在 **浅色 / 深色** 下检查：用户气泡长文、助手卡片、代码块、错误/摘要气泡、标签与复制成功态。
