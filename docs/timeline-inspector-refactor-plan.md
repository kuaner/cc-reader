# 时间线 / 预览：Inspector 导向重构规划

本文档在 **[`.impeccable.md`](../.impeccable.md)** 设计上下文已确定的前提下，把 **「会话检视器」** 目标落实为**可分批交付的重构路线**。与 [timeline-ui-migration-and-refactor.md](./timeline-ui-migration-and-refactor.md) 互补：后者偏**架构与路径**，本文偏**产品语义、体验与优先级**。

---

## 1. 设计北极星（不可动摇）

| 维度 | 要求 |
|------|------|
| **产品隐喻** | **Inspector / 运行记录**，不是阅读器、不是聊天产品皮肤。 |
| **成功体验** | 用户能**快速扫 session**、**对照工具 / thinking / 用户输入**、**复制与排错**。 |
| **密度** | 默认**紧凑、高信息密度**；长文可读性让位于扫视（仍满足基本对比度）。 |
| **视觉禁区** | 见 `.impeccable.md` 与 frontend-design：无蓝紫霓虹、无玻璃拟态欢迎、无「沉浸式阅读」主文案。 |

---

## 2. 非目标（明确不做）

- 不把时间线改成「长文阅读模式」为主（字号全面放大、行长无限拉宽等）。
- 不上线**阻断式**多步新手教程或全屏「欢迎使用阅读体验」。
- 不为「好看」单独引入与 token 体系割裂的硬编码色面。

---

## 3. 现状摘要（基线）

- **timeline-ui** 已独立构建：`timeline-shell.*`、`markdown-preview.*`；样式主源 `timeline-app.css`；组件以 `MessageRow` 为核心。
- **语义色与紧凑密度**已多轮迭代；**用户消息靠右**、**报头与模型 chip 对齐**等已落地。
- **空状态**：`.impeccable.md` 要求无消息时由 **Swift 注入**可本地化短文案；若尚未实现，为本规划 **Phase 1** 缺口。

---

## 4. 分阶段路线图

### Phase 1 — 宿主与文案（Inspector 语义闭环）

**目的**：用户在任何「空 / 等待 / 失败」时刻，看到的都是**工具向**说明，而非阅读向。

| 任务 | 说明 | 验收 |
|------|------|------|
| **空时间线 HTML** | `messageHTML` 为空时注入简短说明（选择会话 / 无消息等），**Localizable** | 无消息时页面不空白；文案不出现「阅读」「沉浸」 |
| **加载 / 失败** | 与现有 `waitingIndicator`、错误路径一致；语气与 `.impeccable.md` 表格一致 | 可重试、不指责用户 |
| **字符串审计** | 扫 `TimelineWebLabels` / 相关 `.strings`，将明显「阅读器」口吻改为检视向（若有） | 与 `.impeccable.md`「文案原则」一致 |

**主要触点**：`TimelineHostView.swift`（`makeShellHTML`、拼接 body）、本地化资源。

---

### Phase 2 — 时间线 Web：检视能力加强（仍 token 驱动）

**目的**：在**不推翻** Session Ledger 的前提下，让「工具 / 角色 / 元数据」更易扫。

| 任务 | 说明 | 验收 |
|------|------|------|
| **结构层级** | 评估 `thinking` / `tool` / `dispatch` / 主内容区的**视觉阶**是否足够；必要时仅调 token（间距、边框、字号档） | 一屏内可区分块类型 |
| **MessageRow 拆分** | 按消息类型或「报头 / 正文 / 页脚」拆子组件，降低单文件心智负担 | 单文件行数下降；行为不变 |
| **高密度开关（可选）** | 若未来需要「更紧一档」，用 **CSS 变量或 `data-density`** 切换，而非复制一套样式 | 一种 token 源；构建一次 |

**主要触点**：`timeline-ui/src/components/*`、`timeline-app.css`。

---

### Phase 3 — 工程化与一致性

**目的**：降低长期维护成本，与迁移文档中的「建议重构项」对齐。

| 任务 | 说明 | 验收 |
|------|------|------|
| **hljs 策略** | ~~运行时注入~~ 已收敛：时间线与预览均走构建期 CSS（`hljs-shared-base` / `hljs-runtime-themes`） | 与 `timeline-shell.css` 外链一致 |
| **测试** | 为纯函数与 renderer 扩展现有 Vitest；DOM 行为再议 `jsdom` | CI 可跑 |
| **文档** | `timeline-ui-color-tokens.md` 开篇增加一句 **Inspector 定位**（与阅读器区分） | 与 `.impeccable.md` 不矛盾 |

**主要触点**：`hljs-shared-base.css`、`hljs-runtime-themes.css`、`markdown-preview.css` / `markdown-shared.css`、`vite.config.ts`、文档。

---

### Phase 4 — 验证与发布

| 任务 | 说明 |
|------|------|
| **对照 `.impeccable.md` 验收清单** | Onboarding 三节自测 + 设计原则 1～7 |
| **构建** | `timeline-ui` 下 `npm run build`；按团队约定同步 `CCReader/Resources` |
| **回归** | 浅色 / 深色；长 session；含 tool_result / dispatch / 错误气泡 |

---

## 5. 风险与依赖

- **WKWebView 与字体**：Google Fonts 离线可能不可用；已有系统回退，Inspector 目标不依赖在线字体。
- **Swift / Web 双端**：空状态与 i18n 必须以 **Swift 为源**，避免 CSS `content` 写死文案。

---

## 6. 文档关系

| 文档 | 作用 |
|------|------|
| [`.impeccable.md`](../.impeccable.md) | 设计上下文与原则（唯一「为什么」） |
| 本文 | **重构阶段与验收**（「做什么、先做什么」） |
| [timeline-ui-migration-and-refactor.md](./timeline-ui-migration-and-refactor.md) | 架构、路径、构建命令 |
| [timeline-ui-color-tokens.md](./timeline-ui-color-tokens.md) | Token 清单与例外 |

---

*随阶段推进请更新「现状摘要」与勾选完成情况；重大设计变更先改 `.impeccable.md`，再改实现与本规划。*
