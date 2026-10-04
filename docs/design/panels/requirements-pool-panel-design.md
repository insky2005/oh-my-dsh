# 需求池面板设计（含想法收件箱与拆解器）

> 状态：**已实现**（`feature/requirements-pool-panel`）· 日期：2026-10-04
> 关联（模型 / 存储）：`docs/research/ai-native-workflow-architecture.md`（§2 / §3.1 / §4.1 / §8）、`docs/design/panels/requirements-workstream-store-design.md`（REQ/WS/REG schema、派生、Phase B 写入所有权）、`.dsh/ai-native-workflow-spec.md`（R5 / R6 / R10）、`docs/design/panels/workstream-handoff-prompt-design.md`、`docs/usage/ai-native-workflow-manual.md`
> 关联（面板体例）：`docs/design/panels/projects-panel-design.md`、`docs/design/panels/task-todo-skill-design.md`、`docs/design/shell/ui-color-scheme.md`
> 实现：`platforms/macos/src/RequirementsCore.swift`（纯模型）、`platforms/macos/src/RequirementsAPI.swift`（`/api/requirements/*` 纯路由）、`platforms/macos/src/RequirementsPanel.swift`（UI）、`platforms/macos/src/BrowserAPI.swift`（路由拦截 + 桥）、`platforms/macos/src/main.swift`（接线）；技能 `.dsh/skills/requirement-pool/SKILL.md` + `SkillInstaller.swift`；测试 `tests/requirements-panel/`

---

## 1. 目标与非目标

### 1.1 目标

把 AI 原生工作流的**前端三件**从「手动模式」升级为壳层能力，且**不修改 dsh 源码**：

1. **想法收件箱**：把对话里的想法落成需求卡片（`.dsh/requirements/REQ-*.md`，`state: candidate`）；
2. **需求池面板**：需求的家——收集 / 评估 / 拆分 / 丢弃，按**有效状态**展示，并展示每个需求拆出的子事项及其阶段；
3. **拆解器**：agent 出「1 需求 → 1..N 事项」方案（`propose`），**人工在面板确认**（`confirm`）后生成事项卡，留下需求 → 事项映射。

面板入口：右栏面板槽第 10 个成员（`RightPanel.requirements`）、活动栏末位图标（`tray.full`）、视图菜单、快捷键 **⌥⌘I**。

### 1.2 非目标

- **不做**规划 / 设计 / 任务 / 验收 / 交付阶段的面板（那是后续事项；本设计只服务需求池）；
- **不做**交付追踪与 `delivery.outcome` 的网络派生（仍由 `node .dsh/tools/derive-status.mjs` 承担，见 §3.4）；
- **不做**编辑卡片正文 / 改事项阶段（面板只提供需求池动作：收件、状态、拆解；事项卡只读展示）；
- **不改** dsh 源码、不改 `.dsh/ai-native-workflow-spec.md`。

### 1.3 已定决策（前置）

| # | 决策 | 说明 |
|---|---|---|
| D1 | **一卡一文件、文件是权威** | 面板是写者之一，不是第二权威；任何写入前先重读盘面（read-modify-write，见 §8） |
| D2 | **派生不落字段** | `split` / `closed` 运行时算；需求卡只写人工 `state`（`candidate` / `evaluating` / `suspended` / `discarded`） |
| D3 | **拆解 = agent 提案 + 人确认** | 方案先落成「待确认提案」（正文 `## 拆解` 的 `json proposal` 代码块）；确认才建 WS 卡；R10 |
| D4 | **收件箱默认 candidate** | 新需求不带 `state` 之外的人工判断；有效状态由派生给 |
| D5 | **写走壳层 API / 面板** | agent 不直接改需求卡，改走 `/api/requirements/*`（Phase B，沿用任务面板形状） |
| D6 | **工作区范围 = 当前工作区** | 面板只读 / 写**当前工作区**的 `.dsh/requirements`、`.dsh/workstreams`；跨工作区总览不在本期 |
| D7 | **需求关闭只认卡片缓存** | `closed` 用 `delivery.outcome`（派生缓存）；无缓存 = 未终结；不联网 |

---

## 2. 概念与默认值

- **需求（Requirement）**：一条尚未确定做法的诉求，一卡一文件；只有池状态，不套事项阶段机（R6）。
- **有效状态（effective_state）**：派生优先级 `discarded > closed > split > state || candidate`（与 `.dsh/tools/derive-status.mjs` 一致）。
- **子事项（children）**：`WS.requirement == REQ.id` 的事项；`REQ.workstreams` 是派生缓存，面板不信它、只信 `WS.requirement` 正向指针。
- **提案（proposal）**：拆解器的中间产物，住在需求卡正文 `## 拆解` 段的一个 `json proposal` 围栏代码块；面板显示为「待确认」。
- **确认（confirm）**：人工动作。确认后为每条提案建一张 `WS-*.md`，并把代码块替换为确认后的映射表 + 确认记录。
- **工作区根**：`<workspace>/.dsh`。卡片路径固定为 `<workspace>/.dsh/requirements/REQ-*.md` 与 `<workspace>/.dsh/workstreams/WS-*.md`。

---

## 3. 数据模型（RequirementsCore.swift）

纯 Foundation、无 AppKit、不联网；面板与 API 都经它读写。测试 `tests/requirements-panel/model-tests.swift`。

### 3.1 类型

```swift
enum ReqEffectiveState: String { case candidate, evaluating, suspended, discarded, split, closed }

struct RequirementCard: Equatable {
    var id: String            // REQ-<n>，不可变
    var title: String
    var state: String?        // 人工判断；nil 视为 candidate
    var source: String
    var created: String
    var updated: String
    var path: String
    var body: String          // frontmatter 之后的正文
}

struct WorkstreamSummary: Equatable {
    var id: String            // WS-<n>
    var title: String
    var requirement: String?  // 0..1
    var stage: String         // planning/design/task/acceptance/delivery
    var outcome: String?      // delivery.outcome 派生缓存（只读）
    var path: String
}

struct BreakdownItem: Equatable {   // 提案的一条
    var title: String
    var boundary: String
    var dependsOn: [String]
}

struct PoolItem: Equatable {
    var requirement: RequirementCard
    var effectiveState: ReqEffectiveState
    var children: [WorkstreamSummary]
    var proposal: [BreakdownItem]?     // 待确认提案（nil = 无）
}
```

### 3.2 frontmatter 解析（RequirementsCore.parseFrontmatter）

- 取首个 `---` 与下一个 `---` 之间的块；
- 顶层键 `key: value`；缩进块收进子对象（覆盖 `delivery:`）；
- **列表支持两种**：行内 `[a, b]` 与缩进 `- a`（`covered` / `workstreams`）；
- 值保留原文（String），不做 token 截断——不重复 `derive-status.mjs` 只取首 token 的旧缺陷；
- 解析失败返回空字典，卡片进「无法解析」列表而不崩。

### 3.3 读取与写入

```swift
static func load(workspace: String) -> PoolSnapshot
static func createRequirement(workspace:title:body:source:today:) throws -> RequirementCard
static func setState(workspace:id:state:today:) throws -> RequirementCard
static func propose(workspace:id:items:today:) throws -> RequirementCard
static func confirm(workspace:id:today:) throws -> [WorkstreamSummary]
static func reject(workspace:id:today:) throws -> RequirementCard
```

- **派生**：
  - `terminal(ws) = stage == "delivery" && outcome ∈ {merged, closed, abandoned}`；
  - `split(req) = children ≠ ∅`；
  - `closed(req) = children ≠ ∅ 且 ∀ terminal(ws)`，或 `state == discarded`（显式放弃优先显示 discarded）；
  - `effective = discarded > closed > split > (state || candidate)`。
- **id 分配**：扫描目录取最大数字 + 1，三位零填充（`REQ-008` / `WS-009`）；无卡片从 001 起。
- **工作区守卫**：workspace 为空或不存在 → `throws PoolError.noWorkspace`；`<workspace>/.dsh` 不存在时**创建 `requirements`/`workstreams`**（幂等），不创建卡片。

### 3.4 终态的网络派生不在本期

`closed` 只读卡片里 `delivery.outcome` 的**派生缓存**。若 PR 已 merged 但缓存未写，面板显示 `split`（未关闭），这是**已知限制**：网络派生仍由 `node .dsh/tools/derive-status.mjs` 完成（REQ-006 / WS-004），面板不联网、不假装成功。

### 3.5 写入（原子、追加安全）

- **原子写**：写临时文件 `<name>.tmp-<pid>` 后 `rename`（同目录），避免半截 YAML（存储设计 §7.1）；
- **只改本卡**：`propose` / `confirm` / `reject` 只触碰目标 REQ 卡的 `## 拆解` 段；`setState` 只改 `state` 行；
- **幂等**：`confirm` 对已确认（无 proposal）返回 `noProposal`；`propose` 覆盖旧提案；
- **不改别人**：不触碰其它 REQ/WS 卡、不写 `local.json`。

### 3.6 提案的正文格式（拆解器契约）

待确认：

```markdown
## 拆解（agent 提案 / 人工确认）

~~~json proposal
[{"title":"...","boundary":"...","dependsOn":["..."]}]
~~~
```

确认后同一段替换为：

```markdown
## 拆解（agent 提案 / 人工确认）

| 事项 | 边界 | 依赖 |
|---|---|---|
| WS-009 标题 | 边界 | — |

确认记录（2026-10-04）：人确认拆解，生成 WS-009、WS-010。
```

- 存在 `json proposal` 围栏代码块 ⇒ 有待确认提案（磁盘上规范用三个反引号，解析器同时接受 `~~~`；上面的代码块为了嵌套在 markdown 里用 `~~~` 展示）；
- 无 `## 拆解` 段或段内无提案 ⇒ 未拆解（`split` 由子事项推出，与提案无关）。

### 3.7 事项卡模板（confirm 生成）

```markdown
---
id: WS-<n>
title: <提案标题>
requirement: <REQ-id>
stage: planning
created: <today>
updated: <today>
---

# WS-<n> <提案标题>

## 规划

- 目标：<提案 boundary>
- 依赖：<dependsOn 原文，或「无」>

## 备注

- 由需求池面板拆解自 <REQ-id>（确认 <today>）。
```

> 只铺卡骨架；规划四件套（目标 / 边界 / 验收标准 / 裁剪声明）由人在事项会话里补齐（R10 规划确认门）。

---

## 4. API 契约（/api/requirements/*）

与任务面板**同一壳层服务、同一端口、同一信任模型**（`BrowserAPIServer`，`127.0.0.1`，端口见 `$DSH_HOME/oh-my-dsh/shell-api.port`）。路由在 `BrowserAPIRouter.route` 前缀拦截（照 `/api/tasks/*`），纯模型在 `RequirementsAPI.swift`，桥接在 `BrowserAPIBridge`，主线程串行。

| 方法 / 路径 | 请求体 | 说明 |
|---|---|---|
| GET `/api/requirements/list` | `?workspace=<路径>` | `{ok, workspace, requirements:[{id,title,state,effectiveState,source,created,updated,children:[{id,title,stage,outcome}],proposal:[…]}]}` |
| POST `/api/requirements/create` | `{"workspace":"…","title":"…","body":"…","source":"…","focus":true}` | 收件箱：新建 `REQ-*.md`（`state: candidate`）；返回 `{ok, requirement:{…}}` |
| POST `/api/requirements/state` | `{"workspace":"…","id":"REQ-003","state":"evaluating"}` | 改人工状态；`state ∈ {candidate,evaluating,suspended,discarded}`；返回 `{ok, requirement:{…}}` |
| POST `/api/requirements/breakdown/propose` | `{"workspace":"…","id":"REQ-003","items":[{"title":"…","boundary":"…","dependsOn":["…"]}]}` | 拆解器第 1 步：写待确认提案（覆盖旧提案） |
| POST `/api/requirements/breakdown/confirm` | `{"workspace":"…","id":"REQ-003"}` | 拆解器第 2 步（**人确认后**）：建 `WS-*.md`，替换提案为映射表 |
| POST `/api/requirements/breakdown/reject` | `{"workspace":"…","id":"REQ-003"}` | 驳回：清除待确认提案 |

- `workspace` 缺省 = 面板当前工作区；传 `pwd` 时按「精确 / 最近祖先」解析（规则与 `TasksAPIWorkspace` 一致，纯路由独立实现以免测试耦合任务模型）；
- 错误码：`missing-body` / `missing-title` / `missing-id` / `no-items` / `unknown-state`（400）、`unknown-requirement`（404）、`no-proposal`（409）、`no-workspace`（400）、`panel-unavailable`（503）；
- `focus` 默认 `true`：切到该工作区并展开需求池面板（与任务面板同语义）；
- **不提供**「直接写卡片」端点：写只走上述语义化动作。

---

## 5. 面板结构与交互

```text
需求池面板（右栏槽第 10 个，活动栏末位 tray.full，⌥⌘I）
├─ 头部（DynamicFillView + HeaderLabel「需求池」）   [＋ 新建需求] [⟳] [✕]
├─ 内容（NSScrollView）  需求卡片 × N
│    └─ 卡片
│         ├─ 第一行：[有效状态徽标] REQ-008 标题            [状态 ▾] [拆解]
│         ├─ 第二行：来源 · 更新日期
│         ├─ 第三行：子事项 WS-009 规划 · WS-010 设计   （或「尚未拆解」）
│         └─ （有待确认提案时）提案区
│              ├─ 「待确认拆解（N 个事项）」
│              ├─ · 标题 — 边界
│              └─ [确认拆解] [驳回]
└─ 状态行（成功 5s 清空；失败保留）
```

### 5.1 头部

| 控件 | 行为 |
|---|---|
| 标题「需求池」 | `HeaderLabel`，固定显示面板名 |
| `plus` 新建需求 | 收件箱：弹表单（标题 + 诉求），确定 → `createRequirement`（`state: candidate`） |
| `arrow.clockwise` | 重读盘面并重绘 |
| `xmark` | `onRequestHide` → 收起右栏 |

### 5.2 卡片与动作

- **状态徽标**：`candidate` / `evaluating` / `suspended` / `discarded` / `split` / `closed`；`split` 用 accent，`closed` / `discarded` 用次要色。
- **「状态 ▾」菜单**：候选 / 评估中 / 挂起 / 丢弃 → 调 `setState`。
- **「拆解」按钮**：**复制拆解提示词**到剪贴板（无论有没有待确认提案），状态行提示「已复制拆解提示词；在会话里运行 `/requirement-pool 拆解 <id>`」——agent 侧入口；有提案时提案区就地给出确认 / 驳回。
- **提案区**：`确认拆解` → `confirm`（建 WS 卡）；`驳回` → `reject`。
- **子事项行**：只读展示 `WS-id stage`；点击经 `onOpenWorkstream` 在文件面板打开该卡。

### 5.3 空态与状态行

- 目录空：居中「还没有需求。点「＋」把一条想法记进来。」+「＋ 新建需求」按钮；
- 无工作区：提示「请先选择一个工作区」（不弹模态）；
- 状态行：`已创建 REQ-008` / `候选 → 评估中` / `已生成 3 个事项` / `找不到该需求` / `没有待确认的拆解提案`；成功 5s 清空，失败保留到下次操作。

### 5.4 新建需求表单

照 `FilePanel.promptForNewItem`：`NSAlert` + `NSView` accessory（标题单行 + 诉求多行），`beginSheetModal`；标题必填、诉求可空（空则回退标题）。无窗口时只记日志、不弹。

### 5.5 配色

一律 `PanelSurface`（面板底）+ `PanelControl`（卡片 / 按钮两档），不新增颜色令牌（`docs/design/shell/ui-color-scheme.md`）。

---

## 6. 拆解器工作流（端到端）

```text
面板「拆解」按钮 ──复制提示词──► 用户在会话里运行 /requirement-pool 拆解 REQ-xxx
                                        │
                     agent 读 REQ 卡 + 子事项，提出 1..N 个事项（标题/边界/依赖）
                                        │
                    POST /api/requirements/breakdown/propose   （待确认提案落卡）
                                        │
面板刷新显示「待确认拆解」 ◄────────────┘
                                        │
                       人 Review：确认 / 驳回（R10 不可由 agent 自签）
                                        │
              confirm ──► 建 WS-*.md + 映射表        reject ──► 清提案
```

- **agent 侧**：内置技能 `requirement-pool`（§7.2）负责读卡、组织提案、调 `propose`；**绝不**调 `confirm`（人工确认门）。
- **人侧**：面板「确认拆解」是唯一 `confirm` 入口。
- **回退**：驳回即回到「未拆解」，可再次 `propose`；已确认的映射表**不追溯修改**（重开另起需求，R5 / 原则 15）。

---

## 7. 想法收件箱

### 7.1 面板入口

头部 `＋`，或空态的「新建需求」；写 `state: candidate` 的 REQ 卡。默认来源 `panel`，带当时日期。

### 7.2 Agent 入口：内置技能 requirement-pool

- 目录 `.dsh/skills/requirement-pool/`，App 启动安装到 `$DSH_HOME/skills/requirement-pool/SKILL.md`（`SkillInstaller`，受管更新，仓库副本与内嵌副本**字节一致**）；
- 两个动作：
  1. **收件**：用户明确说「记个想法 / 落成需求」→ `POST /api/requirements/create`；
  2. **拆解**：用户明确说「拆解 REQ-xxx」→ 读卡 + 子事项 → `POST /api/requirements/breakdown/propose`，**停下等人确认**；
- 硬规则同 `task-todo`：只在用户明确要求时执行；不直接写 `.dsh` 文件；App 没运行时报错、不绕过。

---

## 8. 写入所有权与竞态（延续存储设计 §7）

- **单一写者**：面板 / API 在**主线程**串行写入（`BrowserAPIBridge.onMain`）；agent 只调 API；
- **内存是投影**：`PoolItem` 每次读取时从盘上重算，渲染缓存不含权威状态；
- **写前重读**：每个写动作先 `load` 目标卡，再改、再原子写（read-modify-write）；
- **文件监听**：本期不做 FSEvents 热重载（无外部写者，agent 走 API）；若将来放开直写文件，再补监听重载。

---

## 9. L10n 文案表（main.swift 的 L10n.table，中英成对）

| key | zh | en |
|---|---|---|
| `bar.requirements` | 需求池 | Requirements |
| `menu.toggleRequirements` | 显示/隐藏 需求池面板 | Toggle Requirements Panel |
| `requirements.title` | 需求池 | Requirements |
| `requirements.new` | 新建需求 | New Requirement |
| `requirements.formTitle` | 新建需求 | New Requirement |
| `requirements.formTitlePrompt` | 标题 | Title |
| `requirements.formBodyPrompt` | 诉求 | Statement |
| `requirements.create` | 创建 | Create |
| `requirements.cancel` | 取消 | Cancel |
| `requirements.empty` | 还没有需求。点「＋」把一条想法记进来。 | No requirements yet. Click + to capture an idea. |
| `requirements.children` | %d 个事项 | %d workstreams |
| `requirements.noChildren` | 尚未拆解 | Not broken down |
| `requirements.state.candidate` | 候选 | Candidate |
| `requirements.state.evaluating` | 评估中 | Evaluating |
| `requirements.state.suspended` | 挂起 | Suspended |
| `requirements.state.discarded` | 丢弃 | Discarded |
| `requirements.state.split` | 已拆分 | Split |
| `requirements.state.closed` | 已关闭 | Closed |
| `requirements.set.state` | 状态 | State |
| `requirements.breakdown` | 拆解 | Break down |
| `requirements.breakdownPromptCopied` | 已复制拆解提示词；在会话里运行 /requirement-pool 拆解 %@ | Breakdown prompt copied; run /requirement-pool breakdown %@ in a session |
| `requirements.proposal` | 待确认拆解（%d 个事项） | Proposed breakdown (%d workstreams) |
| `requirements.confirm` | 确认拆解 | Confirm |
| `requirements.reject` | 驳回 | Reject |
| `requirements.confirmed` | 已生成 %d 个事项 | Created %d workstreams |
| `requirements.rejected` | 已驳回拆解提案 | Proposal dismissed |
| `requirements.created` | 已创建 %@ | Created %@ |
| `requirements.stateChanged` | %@ → %@ | %@ → %@ |
| `requirements.error.notFound` | 找不到该需求 | Requirement not found |
| `requirements.error.noProposal` | 没有待确认的拆解提案 | No proposal to confirm |
| `requirements.error.unknownState` | 无效的状态 | Invalid state |
| `requirements.error.generic` | 操作失败：%@ | Failed: %@ |
| `requirements.needsWorkspace` | 请先选择一个工作区 | Select a workspace first |
| `requirements.openWorkstream` | 打开事项卡 | Open workstream card |

---

## 10. 测试计划

`tests/requirements-panel/run.sh`（无头，swiftc）：

1. **模型段**：`RequirementsCore.swift` + `model-tests.swift`（纯 Foundation）——frontmatter 解析（标量 / 行内列表 / 缩进列表 / `delivery` 块）、有效状态优先级、`closed` 谓词（子空守卫 / 部分终态）、`createRequirement` 的 id 分配与模板、`setState`、`propose` / `confirm` / `reject` 的正文往返、原子写（临时文件不残留）、错误码；
2. **API 段**：`RequirementsCore.swift` + `RequirementsAPI.swift` + `api-tests.swift`（自带 HTTP stand-in + Fake delegate，无 AppKit）——路由命中 / 非本面板路径返回 nil / 参数校验 / 错误码映射 / 503。

新增用例必须满足「门要能自证」：至少一条负例断言失败路径（缺 proposal 时 confirm → 409）。

---

## 11. 手工验收清单

- [ ] ⌥⌘I 打开需求池；活动栏图标高亮；再次按下收起；
- [ ] 「＋」新建需求 → 盘上出现 `REQ-<n>.md`（`state: candidate`），面板出现卡片；
- [ ] 对现有 REQ-001…007 的展示：有效状态与 `node .dsh/tools/derive-status.mjs` 一致（除未缓存 outcome 的差异）；
- [ ] 对某需求运行 `/requirement-pool 拆解 REQ-xxx` → 面板出现「待确认拆解」；
- [ ] 「确认拆解」→ 生成 `WS-*.md`（`requirement` 指向该 REQ、`stage: planning`），提案区变为映射表；
- [ ] 「驳回」→ 提案消失，未生成任何 WS；
- [ ] 无 App 时 curl API → 连接失败（技能提示先打开 App），不写盘；
- [ ] 语言切换后面板文案与 tooltip 全部刷新。

---

## 12. 决策记录

| # | 决策 | 理由 |
|---|---|---|
| 1 | 面板名「需求池」、槽位第 10、活动栏末位、⌥⌘I | 不打扰既有九面板的顺序与快捷键；`I` = Idea Pool |
| 2 | 拆解提案落**需求卡正文**，不另立文件 | 一卡一文件；提案是需求的一部分；随仓库提交、可追溯 |
| 3 | 提案用 `json proposal` 代码块 | 机器可解析、人可读；无需 YAML 多行 |
| 4 | 拆解**不自动建会话** | 可靠性差（blank 会话语义、DOM 桥）；V1 用「复制提示词 + 技能」，人显式在会话里执行 |
| 5 | 面板只读缓存 outcome | 不在 UI 线程联网；网络派生仍归 `derive-status.mjs` |
| 6 | 路径解析规则与 `TasksAPIWorkspace` 一致，但独立实现 | 同一壳层、同一语义；又让 API 测试不必编译任务模型 |

---

## 13. 范围外（只拆不胀）

以下**不并入**本设计，需要时各起需求卡：

| 候选 | 关联 |
|---|---|
| 规划 / 设计 / 验收工作台面板 | 架构 §4.2 / §4.5 |
| 交付追踪与 `delivery.outcome` 面板内派生 | 架构 §4.6、REQ-006 |
| 需求池跨工作区总览 | 架构 §9 Q11 |
| FSEvents 热重载 / 外部写者支持 | 存储设计 §7 |
| 事项卡编辑（改 stage / 补规划） | 架构 §4.2 |

---

## 14. 实现顺序

1. `RequirementsCore.swift`（纯模型）→ `tests/requirements-panel` 模型段跑绿；
2. `RequirementsAPI.swift`（纯路由）→ API 段跑绿；
3. `RequirementsPanel.swift`（UI）；
4. `BrowserAPI.swift` 路由拦截 + 桥；`main.swift` 接线 + L10n；
5. 技能 `requirement-pool`（仓库副本 + `SkillInstaller` 内嵌 + 技能测试）；
6. 文档同步：本文件、`docs/usage/panels.md`、`docs/README.md`、`README.md`、`CHANGELOG.md`、`scripts/local-ci.sh`。
