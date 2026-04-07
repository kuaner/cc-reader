# CCReader 时间线 / Markdown 预览 — 主题（Theme）

## 机制概览

- **颜色**：由 `timeline-ui/src/styles/cc-theme-colors.css` 聚合 `@import './themes/<id>.css'`，按 `html[data-cc-theme="…"]` 提供语义变量（`--text`、`--surface-assistant` 等）。浅色 / 深色仍跟随系统 `prefers-color-scheme`，每个主题各有一套 light + dark。
- **排版**：字号、行高等在 `timeline-ui/src/styles/design-tokens.css` 的 `:root`（`--cc-type-*`）。若某主题需要更大正文，可在同一 `data-cc-theme` 选择器里覆写这些变量。
- **持久化**：`localStorage` 键名 **`ccreader.themeId`**，值为主题 id（如 `ledger`、`tokyo-night`）。未设置或无效时默认 **`everforest`**（与 `CC_DEFAULT_THEME` 一致）。
- **防闪烁**：`timeline-shell.html` / `markdown-preview.html`（含 `CCReader/Resources/` 与 `timeline-ui/public/`）在 `<head>` 最前用内联脚本读取 `localStorage` 并设置 `data-cc-theme`，再加载 CSS。

## 内置主题

每个主题一个文件：`timeline-ui/src/styles/themes/<id>.css`，并在 `cc-theme-colors.css` 中 `@import`。

| id | 说明 |
|----|------|
| `ledger` | 暖色纸墨 + 青绿强调（原 Session Ledger 配色）。 |
| `slate` | 冷色靛蓝 / slate 灰。 |
| `nord` | Nord 极地蓝灰系。 |
| `dracula` | Dracula 暗紫系。 |
| `catppuccin` | Catppuccin 柔和粉彩系。 |
| `gruvbox` | Gruvbox 复古棕黄系。 |
| `tokyo-night` | Tokyo Night 深蓝紫系。 |
| `everforest` | **应用默认**：Everforest 森林绿系。 |
| `rose-pine` | Rosé Pine 玫瑰粉紫系。 |
| `solarized` | Solarized 经典双模式色板。 |
| `one-dark` | Atom One Dark 系深色代码风。 |

## macOS 菜单

在菜单栏 **显示**（View）中，**侧边栏**相关项之后有 **主题** 子菜单（父项带调色板图标），列出全部内置主题；子项为**英文固定文案**（`WebColorTheme.menuTitleEnglish`），不本地化。与 `WebColorTheme.broadcast()` 相同：写入 `UserDefaults` 并向所有时间线、Markdown 预览 `WKWebView` 广播。

## 在 App 里切换（WKWebView）

脚本加载完成后，`window.ccreader` 上提供：

- **`getTheme()`** → 当前 id（见上表）
- **`setTheme(id)`** → 切换并写入 `localStorage`，并派发 `CustomEvent('ccreader:themechange', { detail: id })`
- **`cycleTheme()`** → 在内置主题间按 `CC_THEME_IDS` 顺序轮换，返回新 id
- **`listThemes()`** → 只读 id 列表

无效 id 时 `setTheme` 会打 `console.warn` 且不修改当前主题。

## 如何新增一个主题

**单一事实来源**：`timeline-ui/src/styles/themes/<id>.css` 文件名（不含 `.css`）即主题 id。添加或删除主题文件后，在 **`timeline-ui`** 目录执行 **`npm run sync-themes`**（或 **`npm run build`**，会通过 `prebuild` 自动执行），将同步生成：

- `src/lib/ccTheme.generated.ts`（`CC_THEME_IDS`）
- `src/styles/cc-theme-colors.css`（`@import` 列表）
- `CCReader/Services/WebColorTheme.generated.swift`（`WebColorTheme` 枚举 + 菜单英文标题，由 id 推导，如 `tokyo-night` → `Tokyo Night`）
- 四处 HTML 内联 **`ok`** 白名单

默认主题 id 为 **`everforest`**：若改名，需同时改 `ccTheme.ts` 的 **`CC_DEFAULT_THEME`** 与 `scripts/sync-themes.mjs` 里的 **`DEFAULT_THEME_ID`**（以及 Swift 里 `WebColorTheme.stored` 的回退值）。

### 1. CSS

在 `timeline-ui/src/styles/themes/` 新建 **`你的id.css`**，为 **`[data-cc-theme='你的id']`** 写齐与现有主题 **相同名称** 的语义变量（可复制 `slate.css` 再改色），并在 **`@media (prefers-color-scheme: dark)`** 下写 dark 覆盖。

注意：未带 `data-cc-theme` 时，`:root` 仍匹配 ledger 的浅色定义；只有显式属性才会走到新主题。

### 2. 同步与构建

执行 **`npm run sync-themes`**，再 **`npm run build`**，确认产物写入 `CCReader/Resources/`；在真机 / 模拟器上切换 light/dark 各看一遍新主题。

### 3. 可选：仅改排版、不改色

若只做「大号字」等，可在对应 `[data-cc-theme]` 块内增加 `--cc-type-root`、`--cc-type-md-max` 等覆写，无需新 id（也可与颜色主题组合在同一 `data-cc-theme` 块内）。

## 事件与多 WebView

切换主题时会 `dispatchEvent` **`ccreader:themechange`**。同源的其它 frame 不会自动同步；若多标签共用偏好，可依赖 `localStorage` 的 **`storage`** 事件（`initCcTheme` 已监听并同步 `data-cc-theme`）。

## 相关文件

| 文件 | 作用 |
|------|------|
| `timeline-ui/scripts/sync-themes.mjs` | 扫描 `themes/*.css`，生成下列产物 |
| `timeline-ui/src/lib/ccTheme.generated.ts` | 生成的 `CC_THEME_IDS`（勿手改） |
| `CCReader/Services/WebColorTheme.generated.swift` | 生成的 `WebColorTheme` 枚举（勿手改） |
| `timeline-ui/src/styles/cc-theme-colors.css` | 生成的 `@import` 各主题文件 |
| `timeline-ui/src/styles/themes/*.css` | 单主题颜色变量（**事实来源**） |
| `timeline-ui/src/styles/design-tokens.css` | 排版 token + `@import` 颜色表 |
| `timeline-ui/src/lib/ccTheme.ts` | 默认主题、`initCcTheme`、`setCcTheme` |
| `CCReader/Services/WebColorTheme.swift` | `broadcast` / `apply` / JS 片段 |
| `timeline-ui/src/timeline-shell/bridge/themeApi.ts` | 挂到 `window.ccreader` |
| `timeline-ui/src/globals.d.ts` | `ccreader` 类型声明 |
