# 事项面板 · 工作流（用户做什么 × Agent 做什么）

> 状态：草案 · 日期：2026-10-07
> 关联：`docs/design/panels/workstream-panel-design.md`（§5.1 三件事）、`docs/design/panels/workstream-handoff-prompt-design.md`、`docs/design/panels/panel-prompt-inventory.md`、`docs/usage/ai-native-workflow-manual.md`、`docs/usage/panels.md`
> 这份文档只回答一件事：**进入事项面板之后，一步步是谁做什么。**

## 0. 一句话

事项面板是「事项（WS）」的工作台：**人在面板上（或经会话明确授权后由 Agent 代发）发起 / 启动 / 确认，Agent 在会话里出第一版 / 执行**。面板是 `WS-*.md` 的**唯一写者**，Agent 一律走 `/api/workstreams/*`（`workstream-panel` 技能），**不直接改 `.dsh` 文件**。

角色对应：Agent = **Delegate**（出第一版 / 执行）；人 = **Review**（校验）/ **Own**（负责 + 签字）。**确认门由人签字**（R10）：人在阶段卡点按，或在会话中**明确授权**后由 Agent 代发 `stage/confirm` / `stage/reject`；两种来源都记进卡片 `## 阶段确认`（`source:panel` / `source:session <id>`），**Agent 绝不自签**。

## 1. 进入事项面板的三条路

| 路径 | 说明 |
|---|---|
| 从需求池过来 | 需求池「确认拆解」后**自动聚焦**事项面板；新事项**继承需求会话**作为主场会话，对话不断线 |
| 直接打开 | 活动栏「事项」/ `⌥⌘K`（紧邻「需求池」之后） |
| 从对话过来 | 让 Agent 按 `$DSH_SESSION_ID` 反查（`GET /api/workstreams/bound`）并 `focus` 高亮 |

进入后**默认只展开首个未处理的事项卡**（`runState != 完成`）；全部完成时不展开。

## 2. 面板上每个操作是谁点的

| 位置 | 按钮 | 谁点 | 效果 |
|---|---|---|---|
| **事项主卡** | **拆分任务** | 人 | 向**主场会话**发「（首个未处理阶段）请拆分任务」的提示词；Agent 据此建**等待态**任务 |
| **事项主卡** | **创建任务** | 人 | 打开抽屉：**选阶段 + 首行标题 / 其余内容** → 直接建等待态任务（不启动） |
| **事项主卡** | **启动事项** | 人 | 按**阶段顺序**（规划→设计→执行→验收→交付）执行该事项队列里的任务 |
| **事项主卡** | 打开卡 | 人 | 在文件面板打开 `WS-*.md` |
| **阶段卡** | **确认** | 人（或人在会话中明确授权 Agent） | 机检谓词通过 + 人签字 → 推进 `stage`；卡片 `## 阶段确认` 记来源（面板点按 `source:panel` / 会话授权 `source:session <id>`）；随后主场会话自动收到**下一阶段**提示词 |
| **阶段卡** | **退回** | 人（或人在会话中明确授权 Agent） | 填原因，把 `stage` 退回返工；卡片 `## 阶段确认` 记来源（`source:panel` / `source:session <id>`，回边留痕 R2） |
| **交付阶段卡** | **交付** | 人 | 起交付任务，由 Agent push / 开 PR 并记录交付事实 |

> 阶段卡上**没有**「创建任务」「启动」——创建与启动都收口在**事项主卡**。阶段卡只负责「确认 / 退回（+ 交付）」。

### 2.1 同一动作在「会话中」的触发入口（skill `workstream-panel`）

面板上的每个动作都能在会话里用自然语言（或 `/workstream-panel …`）触发，不必切回面板：

| 面板动作 | 会话中怎么说 | 路由 | 约束 |
|---|---|---|---|
| 拆分任务 | 「把 WS-x 的<阶段>拆成任务」 | `POST /api/workstreams/task/create` | 只建**等待态**，建完停下等人确认 |
| 创建任务 | 「给 WS-x 的<阶段>加任务：<标题/内容>」 | `task/create`（显式 `stage`） | 同上 |
| 启动事项 | 「启动 WS-x / 把队列跑起来」 | `POST /api/workstreams/queue/start`（不带 `stage`） | 人已确认拆分 / 用户明说 |
| 启动阶段（对话专属） | 「启动<阶段> WS-x」 | `queue/start` + `stage` | 只跑该阶段、跑完自动暂停 |
| 确认 | 「确认<阶段> WS-x」 | `POST /api/workstreams/stage/confirm` | **仅用户明确授权**；先复述证据再确认 |
| 退回 | 「退回<阶段>，原因…」 | `POST /api/workstreams/stage/reject` | **仅用户明确授权**；原因由人给 |
| 交付 | 「交付 WS-x」 | `POST /api/workstreams/deliver` | 与面板「交付」按钮同一条路径 |
| 聚焦 / 查看 | 「看看 WS-x / 把面板打开到 WS-x」 | `bound` + `focus` / `list` / `task/list` | `focus` 仅用户要求时 |

## 3. 逐阶段：用户 / Agent 分工

| 阶段 | 用户做什么 | Agent 做什么 | 人工门 |
|---|---|---|---|
| **规划** | 点「拆分任务」→ 看生成的任务 → 点「启动事项」 | 主场会话收到拆分提示词 → 调 `task/create` 建**规划任务**；任务会话执行 → 用 `/api/workstreams/plan` 补齐四件套（目标 / 边界 / 验收标准 / 阶段裁剪声明）→ 汇报 + 完成 marker | 四件套齐 → 阶段卡「**确认**」 |
| **设计** | 同上 | 出设计任务：在 `docs/design/**` 写设计文档 + 待确认问题（Q 表）；**只写设计、不写实现** | 设计完成 → 「**确认**」 |
| **执行** | 「拆分任务」→ **看任务清单确认拆分合理** → 「启动事项」 | 按任务实现：切分支 / 改码 / 跑测试 / conventional commit；范围外的新发现**回池**（不就地吸收） | 证据齐 → 「**确认**」 |
| **验收** | 点「拆分任务」（可选，建证据收集任务）→「启动事项」→ **人 sign-off** | 跑回归门与机检证据、记录 `covered`（paths + base/head 锚变更）；**不自签** | **人 sign-off** → 「**确认**」 |
| **交付** | 点交付阶段卡的「**交付**」，或对话说「交付 WS-x」（`POST /api/workstreams/deliver`，与按钮共用同一条路径）→ 在 GitHub 合并 | 交付任务：push 分支 + 开/复用 PR，用 `/api/workstreams/delivery` 记录 `delivery.pr` / `url` 事实 | 人 merge；`closed` 由 `derive-status` **派生** |

**回边**：任一阶段不满意 → 阶段卡「退回」+ 填原因 → `stage` 退回返工（必须留痕，R2）。

## 4. 会话与面板怎么配合（双向顺滑切换）

- **拆分 / 确认续接 → 主场会话**（一事项一条，`.dsh/workstreams/local.json` 的 `workstreamSessions`）；没有绑定才新建并绑定。
- **任务执行 → 每任务一条会话**（不是主场会话），完成后汇报 + marker 回写任务卡。
- **面板 → 对话**：主卡「拆分任务」把提示词发进主场会话。
- **对话 → 面板**：Agent 反查当前会话对应的事项并 `focus`，把面板高亮给用户。
- **阶段推进**：阶段确认成功后（面板点按或会话授权皆可），主场会话**自动收到下一阶段提示词**——对话自然从「规划」接到「设计」。

## 5. 用户最小操作清单（每阶段循环）

1. 打开事项面板（`⌥⌘K` 或从需求池进来）；
2. 在首个未处理事项上点「**拆分任务**」（或「**创建任务**」自己加）；
3. 看生成的任务，**确认拆分合理**；
4. 点「**启动事项**」；
5. 等任务跑完（看三级任务卡的状态 / 会话 / 汇报）；
6. 阶段卡点「**确认**」（或「退回」+ 原因）；也可在会话里明确授权 Agent 代发 `stage/confirm` / `stage/reject`；
7. 重复到「交付」；交付阶段点「交付」，在 GitHub 合并，然后跑 `derive-status` 派生终态。

## 6. Agent 的职责边界

**Do**：读卡与事实；出第一版（规划四件套 / 设计文档 / 实现 / 证据）；用 `task/create` 建**等待态**任务；执行任务会话；汇报 + 完成 marker；按语义选路由。

**Don't**：
- 不在用户未明确授权时调 `stage/confirm` / `stage/reject`（人工门）——授权时代发也要**复述证据 / 请求确认、拿人的原因**，记 `source:session <id>`；低层 `stage` 一律不调；
- 人未确认拆分前不 `queue/start`；
- 不直接改 `.dsh` 文件（`workstreams/*.md`、`queues.json`）；
- 不手写派生字段（`closed` / `outcome` / `split`）；
- 不把范围外工作并进当前事项（只拆不胀）。

## 7. 与需求池 / 任务面板的衔接

- **需求池 → 事项**：确认拆解建 `WS-*.md`（`stage: planning`）→ 继承需求会话 → 聚焦事项面板；需求确认后**冻结**，改需求另起。
- **事项执行 ≠ 任务面板**：事项的阶段任务走**事项面板自有** API / `workstream-panel` 技能；**不用** `/task-todo`，两套存储互不相通（`.dsh/workstreams/queues.json` vs `.dsh/tasks/*`）。

## 8. 常见坑

| 坑 | 正确做法 |
|---|---|
| 以为阶段队列 `.done` 就是阶段完成 | `.done` 只是任务跑完；还要过**机检 + 人工确认门** |
| 拆分完直接启动 | **拆分后先停**，人确认拆分合理才启动 |
| Agent 把 `stage` 传成 `task` | 阶段枚举 `task` 的中文是「**执行**」；传值用原始枚举（`planning` / `design` / `task` / `acceptance` / `delivery`），按提示词括号里的原始值为准 |
| 让 Agent 自签验收 | 机检绿 ≠ 完成；**人 sign-off** 是 Own 点 |
| 手写 `closed` / `outcome` | 派生；跑 `node .dsh/tools/derive-status.mjs` |