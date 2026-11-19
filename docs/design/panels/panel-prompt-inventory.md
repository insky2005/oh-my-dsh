# 面板提示词清单（需求池 / 事项 / 任务）

> 状态：已落地 · 日期：2026-11-17（事项四阶段 + 交付操作；2026-11-19 事项提示词统一为三段式，WS-1..WS-5 逐字快照同步）
> 关联：`docs/design/panels/requirements-pool-panel-design.md`（§5.7 需求提示词）、`docs/design/panels/workstream-handoff-prompt-design.md`（§3 / §4 事项阶段提示词）、`docs/design/panels/workstream-panel-design.md`（§5.1 四件事：拆分 / 确认 / 启动 / 交付）、`docs/design/panels/tasks-queue-session-loop-design.md`
> **单一事实来源是代码**。本文件是索引与快照；改提示词必须同步本文件与对应设计文档，否则会漂移。

## 0. 说明

「面板发出的提示词」在本清单里分**两类**：

1. **直接发给会话**：用户点面板按钮 → 壳层调 `session.prompt` 发一段文本；
2. **写进任务 body、由 runner 发出**：面板生成文本 → 存成三级任务的 body → 任务启动时作为该任务会话的提示词。

**目标会话选择规则**（当前实现）：

| 来源 | 选择规则 | 落点 |
|---|---|---|
| 需求池 | 该需求**绑定会话**（`.dsh/requirements/local.json`）→ 来源会话 → 当前会话 → 都没有则**复制提示词** | `main.swift` `startRequirementRefinementSession` / `sendBreakdownPrompt` / `notifyBreakdownResolved` |
| 事项面板（聊天侧） | 该事项**主场会话**（`.dsh/workstreams/local.json` 的 `workstreamSessions`）；没有则新建并绑定；失败回退当前会话 | `main.swift` `startWorkstreamSession` / `continueWorkstreamInSession` |
| 事项任务（执行侧） | **每个三级任务一条新会话**（不是主场会话） | `WorkstreamsRunner` |

编号：`RQ-*` 需求池 · `WS-*` 事项面板 · `TK-*` 任务面板（存量，参考）。

## 1. 需求池面板

| 编号 | 触发 | 目标会话 | 来源 | 一句话 |
|---|---|---|---|---|
| RQ-1 | 「创建并细化」/ 卡片「细化」 | 需求绑定会话 / 新建「细化 REQ-xxx」 | `RequirementsCore.refinementPrompt` | 请 agent 一起细化，只讨论不改码 |
| RQ-2 | 卡片「拆解」 | 需求来源会话 / 当前会话 / 复制 | `RequirementsCore.breakdownPrompt` | 请 agent 出 1..N 事项提案 |
| RQ-3 | 面板「确认拆解」 | 需求绑定会话 | L10n `requirements.notify.confirmed`（+ `confirmedFocus`） | 回写「已生成 WS-…，去事项面板」 |
| RQ-4 | 面板「驳回拆解」 | 需求绑定会话 | `RequirementsCore.rejectPrompt` | 带原因请 agent 改方案再提案 |

### RQ-1 细化（`refinementPrompt`）

```text
<REQ-id>「<标题>」@.dsh/requirements/<REQ-id>.md
请和我一起细化这条需求：澄清目标、边界、验收标准；

注意：
- 只讨论、只澄清，不要修改代码或其它文件。
- 须修改需求时，用 POST /api/requirements/update（带上 session，保持同一会话）。
- 细化后，等待用户进行「需求拆解」。
```

### RQ-2 拆解（`breakdownPrompt`）

```text
<REQ-id>「<标题>」@.dsh/requirements/<REQ-id>.md，需求已确认。
根据需求，将需求拆解为可依次落地的事项。
请给出拆解方案：每个事项的标题、边界、依赖顺序。

注意：
- 只拆不胀，范围外的新发现回池。
- 提交待确认提案（不要建卡、不要自签）。调用 拆解器 API `POST /api/requirements/breakdown/propose  {"id":"<REQ-id>","items":[{"title":"...","boundary":"...","dependsOn":["..."]}]}` 提交。
- 提交后，等待用户确认『待确认提案』。
```

### RQ-3 确认拆解回写（L10n `requirements.notify.confirmed`）

```text
<REQ-id>「<标题>」@.dsh/requirements/<REQ-id>.md，需求拆解已确认。
已生成 <WS-…、WS-…>，请到事项面板继续处理。
（可用 ⌥⌘K 打开事项面板）

注意：
- 回复『收到』。
- 列出事项清单。
```

> 第 5 个格式参数是 focus 提示行（`requirements.notify.confirmedFocus`）。确认后右栏也会真的 `setRightPanel(.workstreams)`。

### RQ-4 驳回拆解（`rejectPrompt`）

```text
<REQ-id>「<标题>」@.dsh/requirements/<REQ-id>.md，需求拆解已驳回。
驳回原因：<原因>            ← 原因为空时省略这一行
请修改拆解方案。

注意：
- 只拆不胀，范围外的新发现回池。
- 重新提交待确认提案（不要建卡、不要自签）。调用 拆解器 API `POST /api/requirements/breakdown/propose  {...}` 提交。
- 提交后，等待用户确认『待确认提案』。
```

## 2. 事项面板

### 2.1 直接发给会话的

| 编号 | 触发 | 目标会话 | 来源 |
|---|---|---|---|
| WS-1 | 主卡「拆分任务」 | 事项主场会话（复用/新建并绑定） | `WorkstreamHandoff.splitPrompt(card:stage:)`，`stage` = **首个未处理阶段** |
| WS-2 | 阶段卡「确认」成功后 stage 前移 | 事项主场会话（有绑定才发） | `WorkstreamHandoff.nextStagePrompt(card:)` |

> WS-2 的前置是**人工门**（R10）：阶段卡「确认 / 退回」由面板点按则卡片留痕记 `source:panel`；用户在会话里**明确授权**后由 agent 调 `POST /api/workstreams/stage/confirm` / `stage/reject` 则记 `source:session <id>`（都写进卡片 `## 阶段确认`，`stage` 前移 / 回边）。**签字仍是人，agent 不自签**。

两条提示词同用**公共头**（与需求池三段式同构：身份行 → 阶段 / 本步 → 一句话 → 注意）：

```text
<WS-id>「<标题>」@.dsh/workstreams/<WS-id>.md
阶段：<中文>（<raw>）· 本步：<动作>
目标：<卡片「## 规划」里的目标>          ← 有则出现

<一句话：本步要做什么 + 停在哪儿>

注意：
- <1..3 条：API 细节 / 门禁 / 技能指针>
```

`isHandoff` 判据 = 文本含身份行里的事项卡指针 `@.dsh/workstreams/`；旧格式的 `本步事实：` / `当前 stage：` 不再算交接（runner 改用 WS-5 兜底）。

**WS-1 逐字快照**（`splitPrompt(card:stage:)`，`stage = 规划`）：

```text
WS-000007「阶段提示词」@.dsh/workstreams/WS-000007.md
阶段：规划（planning）· 本步：拆分任务
目标：产出面板生成的各阶段提示词

把「规划」阶段要做的事拆成等待态阶段任务，建完停下请人确认拆分合理。

注意：
- 用 `POST /api/workstreams/task/create` 建**等待态阶段任务**：`stage` 必须传上面括号里的原始值 `planning`（`planning` / `design` / `task` / `acceptance`），**不要传 `task`**；调用示例 body `{"id":"WS-000007","stage":"planning","titles":["…"],"session":"$DSH_SESSION_ID"}`。
- 阶段任务带 `stage`，追加到该事项唯一队列；**只建不启动**，拆分是人工确认门、**不自签**，人在面板确认后才 `queue/start`。
- 改事项卡片一律走 `/api/workstreams/*`（`workstream-panel` 技能），**不直接改 `.dsh` 文件**；阶段任务走 `POST /api/workstreams/task/create`（任务带 `stage`）、`POST /api/workstreams/queue/start` 启动；回边合法但必须留痕，跳过 / 裁剪在「规划」声明；只拆不胀，范围外的新发现回需求池；终态是派生谓词（不写 `closed` / `outcome`）；不改其它会话的在途文件。
```

> 执行阶段（`stage = task`）的拆分只把阶段行换成 `阶段：执行（task）`、示例换成 `"stage":"task"`，并把「不要传 `task`」改成「**不要传其它阶段的原始值**」（避免自相矛盾）；其余逐字相同。

**WS-2 逐字快照**（`nextStagePrompt(card:)`，规划确认后 → 设计）：

```text
WS-000007「阶段提示词」@.dsh/workstreams/WS-000007.md
阶段：设计（design）· 本步：出设计
目标：产出面板生成的各阶段提示词

在 `docs/design/**` 写本事项的设计文档，把待确认问题列成 Q 表；只写设计、不写实现，写完停下请人确认设计。

注意：
- 设计文档写在 `docs/design/**`，Q 表逐条列出待确认问题。
- 只写设计，不写实现（实现属执行阶段）。
- 改事项卡片一律走 `/api/workstreams/*`（`workstream-panel` 技能），**不直接改 `.dsh` 文件**；阶段任务走 `POST /api/workstreams/task/create`（任务带 `stage`）、`POST /api/workstreams/queue/start` 启动；回边合法但必须留痕，跳过 / 裁剪在「规划」声明；只拆不胀，范围外的新发现回需求池；终态是派生谓词（不写 `closed` / `outcome`）；不改其它会话的在途文件。
```

> WS-2 只在 `stage` 真的前移且存在下一阶段时发送；验收是最后阶段 → `nil`，不续发。

### 2.2 写进任务 body、由 runner 发出的

| 编号 | 触发 | body 来源 | 动作段 |
|---|---|---|---|
| WS-3 | 阶段任务（agent 调 `task/create` / 创建任务抽屉 / 面板生成阶段队列） | `WorkstreamHandoff.stageTask` / `prompt(card:action:)` | 见下（按阶段默认动作） |
| WS-7 | **事项主卡「交付」**（操作，不是阶段；前置 `accepted`，发进**主场会话**）/ 会话说「交付 WS-x」（`POST /api/workstreams/deliver`） | `WorkstreamsDelivery.prompt(plan:)` | 交付长模板（见代码）：不新建会话 / 任务、不改 `stage`，完成信号 = `POST /api/workstreams/delivery` |

创建任务抽屉会在提示词末尾追加用户输入：`任务内容：` + 内容（首行是标题、其余行是内容）。

**WS-3 逐字快照**（`stageTask`，规划阶段默认动作；抽屉内容附在最后）：

```text
WS-000007「阶段提示词」@.dsh/workstreams/WS-000007.md
阶段：规划（planning）· 任务：补规划四件套 · 本步：确认规划
目标：产出面板生成的各阶段提示词

补齐本事项「## 规划」的四件套（目标（WHAT）/ 边界 / 验收标准（AC<n>）/ 阶段裁剪声明），写完停下请人确认规划。

注意：
- 用 `POST /api/workstreams/plan` 写「## 规划」；不直接改 `.dsh` 文件。
- 人确认前不得进入设计。
- 改事项卡片一律走 `/api/workstreams/*`（`workstream-panel` 技能），**不直接改 `.dsh` 文件**；阶段任务走 `POST /api/workstreams/task/create`（任务带 `stage`）、`POST /api/workstreams/queue/start` 启动；回边合法但必须留痕，跳过 / 裁剪在「规划」声明；只拆不胀，范围外的新发现回需求池；终态是派生谓词（不写 `closed` / `outcome`）；不改其它会话的在途文件。

任务内容：
第一行说明
第二行细节
```

> 第二行只在 `stageTask` 时多出 `· 任务：<标题> ·` 一段；`prompt(card:action:)` 生成的是 `阶段：<中文>（<raw>）· 本步：<动作>`。共用规则（WS-1 第三条）逐字附在每个提示词末尾。

**WS-3 各动作的一句话 + 动作特有注意**（逐字；`<raw>` 用阶段原始值）：

```text
# 确认规划（planning）
补齐本事项「## 规划」的四件套（目标（WHAT）/ 边界 / 验收标准（AC<n>）/ 阶段裁剪声明），写完停下请人确认规划。
注意：
- 用 `POST /api/workstreams/plan` 写「## 规划」；不直接改 `.dsh` 文件。
- 人确认前不得进入设计。

# 出设计（design）
在 `docs/design/**` 写本事项的设计文档，把待确认问题列成 Q 表；只写设计、不写实现，写完停下请人确认设计。
注意：
- 设计文档写在 `docs/design/**`，Q 表逐条列出待确认问题。
- 只写设计，不写实现（实现属执行阶段）。

# 拆分任务（任意阶段，`<raw>` = 该阶段原始值）
把「<阶段>」阶段要做的事拆成等待态阶段任务，建完停下请人确认拆分合理。
注意：
- 用 `POST /api/workstreams/task/create` 建**等待态阶段任务**：`stage` 必须传上面括号里的原始值 `<raw>`（`planning` / `design` / `task` / `acceptance`），非 task 阶段写「**不要传 `task`**」、task 阶段写「**不要传其它阶段的原始值**」；调用示例 body `{"id":"<WS-ID>","stage":"<raw>","titles":["…"],"session":"$DSH_SESSION_ID"}`。
- 阶段任务带 `stage`，追加到该事项唯一队列；**只建不启动**，拆分是人工确认门、**不自签**，人在面板确认后才 `queue/start`。

# 启动实施（task）
在已确认的边界内启动本阶段实施：改代码、跑测试、commit，做完停下请人验收。
注意：
- 用 `POST /api/workstreams/queue/start`（带 `stage`）只跑本阶段任务；提交用 conventional commits。
- 只在已确认的边界内改代码，不碰其它会话的在途文件。

# 校验（acceptance）
跑回归门与机检证据、记录覆盖点，然后停下请人 sign-off。
注意：
- 用 `POST /api/workstreams/covered` 记录覆盖点（paths + base / head 锚变更）；不直接改 `.dsh` 文件。
- 必须由人 sign-off，agent 不自签。
```

> **交付不是阶段的动作段**：四阶段到此为止。验收确认（`accepted`）后，`WorkstreamsDelivery.prompt(plan:)`
> 由事项主卡「交付」按钮发进**主场会话**执行 push / PR，用 `POST /api/workstreams/delivery` 记
> `pr` / `url` 事实（`outcome` 派生、不手写）——不新建会话 / 任务，也不改变 `stage`。交付提示词同样是三段式
>（身份行 → `阶段：验收（acceptance）· 操作：交付` → 分支 / 仓库 / 覆盖 / 已有 PR / 提交 → 一句话 → 注意）。

### 2.3 运行时包装

| 编号 | 场景 | 来源 | 说明 |
|---|---|---|---|
| WS-4 | 每个执行任务 | `WorkstreamHandoff.completionMarkerInstruction(marker)` | 追加在末尾，要求会话最后一行原样回显 marker（完成证据） |
| WS-5 | 任务 body 不是面板交接提示词时的兜底（`isHandoff == false`） | `WSPrompts.task(task:queue:)` | 「你在推进事项 … 的『<阶段>』阶段」+ 任务 + 要求（只做这一条 / 不碰运行态文件 / 汇报） |
| WS-6 | 待确认任务重试 | `WSPrompts.retryContinuation(title:marker:)` | 「上一轮因中断或未拿到完成证据而停止，请从未完成处继续本任务：<标题>。」+ marker |

**WS-4 逐字快照**（marker 非空时追加在提示词末尾）：

```text
完成前，请在最后一行原样输出以下标记（供面板识别本次任务已结束）：
<marker>
```

**WS-5 逐字快照**（兜底模板；任务没有 `workstreamId` 时第一行改为「你正在推进一个事项的…」）：

```text
你正在推进事项 <WS-id> 的「<中文阶段>」阶段。

任务：<标题>

<任务说明正文>

要求：
- 只做这一条任务；完成后把改动留在仓库（需要时 commit）。
- 不要直接改动事项面板的运行态文件（.dsh/workstreams/ 下的 queues.json / local.json）。
- 结束时用一两句话汇报结果。
```

**WS-6 逐字快照**（`marker` 非空时再接一段 WS-4）：

```text
上一轮因中断或未拿到完成证据而停止，请从未完成处继续本任务：<标题>。
（不要重做已经完成的部分。）
```

## 3. 任务面板（存量，参考）

任务面板有自己的提示词单一来源 `TaskPrompts`（`TasksRunner.swift`），本清单只列**功能入口**，不复制全文：

| 编号 | 场景 | 来源函数 |
|---|---|---|
| TK-1 | issue 任务 | `TaskPrompts.issue` |
| TK-2 | 手动任务 | `TaskPrompts.manual` |
| TK-3 | 通用要求（分支/队列） | `TaskPrompts.requirements` / `multiRepoRequirements` / `childWorkdirRequirement` |
| TK-4 | 完成 marker | `TaskPrompts.completionMarkerInstruction` |
| TK-5 | 重试续跑 | `TaskPrompts.retryContinuation` |
| TK-6 | 交接简报 | `TaskPrompts.briefSection` / `brief` |
| TK-7 | 收尾 / 开 PR / 合并 / 推送 | `TaskPrompts.pullRequest` / `integration` / `mergeAndPush` / `pushOnly` |
| TK-8 | 队列完成通知 | `TaskPrompts.queueFinishedSummary` |

## 4. 梳理结论

1. **三套提示词各有单一来源，但此前没有统一清单**——本文件补上；三处来源分别落在 `RequirementsCore`、`WorkstreamsPrompts`（+ `WorkstreamsDelivery` / `WSPrompts`）、`TaskPrompts`。
2. **阶段命名歧义（已修）**：事项阶段枚举是 `task`、中文叫「执行」，而路由叫 `task/create`、动作叫「拆分任务」——agent 极易把 `stage` 传成 `task`。提示词现在阶段行里直接给原始值（`阶段：规划（planning）· 本步：…`），非 task 阶段明说「不要传 `task`」（task 阶段改成「不要传其它阶段的原始值」避免自相矛盾），`splitPrompt` 生成带 `"stage":"<raw>"` 的调用示例；`api-tests` / `runner-tests` 固化四个原始值的映射（交付不是阶段，没有 `delivery`）。
3. **提示词双重身份**：事项「阶段提示词」既是**聊天提示词**（WS-1/WS-2）又是**任务 body**（WS-3）。改一处会同时影响两侧，需一起验。
4. **目标会话规则不统一**：需求池四级回退（绑定→来源→当前→复制）、事项面板两级（绑定→新建）、任务面板「每任务一条 + 回传来源会话」。长期建议收敛为「**实体 → 主场会话**」一种模型。
5. **两处同名不同物**：需求池有「拆解」、事项面板有「拆分任务」；前者是 REQ→WS，后者是 WS 阶段→任务，别混。

## 5. 维护约定

- **新增**任何面板动作发提示词 → 在本文件登记编号，并写清目标会话与来源函数；
- **改动**提示词 → 同步四处：① 代码；② 本文件；③ 对应设计文档（需求池 §5.7 / `workstream-handoff-prompt-design` §3·§4 / `workstream-panel-design` §5.1）；④ 若涉及 API 措辞，`requirement-pool` / `workstream-panel` 技能；
- 本文件**不复制**长模板全文（交付 / 任务面板），以「来源函数」为准，避免双份漂移；短提示词（RQ-1..4、WS-1..6）保留逐字快照。