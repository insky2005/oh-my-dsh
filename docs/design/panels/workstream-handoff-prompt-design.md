# 事项交接提示词（Workstream Handoff Prompt）设计

> 状态：已落地（`WorkstreamsPrompts.swift`；提示词由面板生成、注入任务 body）· 日期：2026-10-03（2026-10-06 落地）· 关联：`docs/research/ai-native-workflow-architecture.md`、`.dsh/requirements/README.md`、`docs/design/panels/requirements-workstream-store-design.md`、`docs/design/panels/workstream-panel-design.md`

## 1. 目的

把一个「事项」交给**新会话**处理时，需要一段提示词把 agent 领到正确的卡片、说清本步动作与模型规则。本文定义这段提示词的**模板与生成规则**，供面板（或人）复用。

## 2. 原则

1. **提示词是指针，不是状态副本**：状态（stage / 规划 / 覆盖）只活在 `.dsh` 卡片里，提示词不复述细节，避免漂移。
2. **动作 = (stage, action) 的函数**：面板按钮不是「一个提示词」，而是「当前 stage → 本步 action」，各 stage 一份 action 段，共用公共头。
3. **变量从卡片注入**：`<WS-ID>` / `<REQ-ID>` / `<stage>` / `<REG-ID>` / 目标，全部读卡片。
4. **卡片必须自足**：薄提示词成立的前提，是卡片的「规划」有目标 / 边界 / 验收标准 / 裁剪声明。
5. **人保留 Own**：规划确认与验收 sign-off 必须停下问，agent 不自签。

## 3. 公共头（所有 stage 共用）

工作区通用规则（模型 / `.dsh` 约定 / 人工确认门 / 只拆不胀 / 事项面板 API `/api/workstreams/*`）应由**工作区 `AGENTS.md` 承载、对话开始自动加载**（见 `docs/usage/ai-native-workflow-manual.md` §2.0）。提示词只带**本步事实**：

```text
你在 <repo> 处理一个事项。

本步事实：
- 事项：.dsh/workstreams/<WS-ID>.md
- 需求：.dsh/requirements/<REQ-ID>.md
- 存储约定：.dsh/requirements/README.md（通用规则见工作区 AGENTS.md）

当前 stage：<stage>      本步动作：<action>
目标：<卡片的规划.目标>
```

## 4. stage → action 段

| stage | action | 要点 |
|---|---|---|
| 规划 | 确认规划 | 补齐验收标准 + 裁剪声明后，**停下请人确认**，再进设计 |
| 设计 | 出设计 | 写 `docs/design/**`，不写实现；**写完停下请人确认** |
| 任务 | 拆分任务 | **`POST /api/workstreams/task/create`** 建**等待态阶段任务**（追加到该事项唯一队列；= 任务拆分本身，只建不启动）；**停下请人确认拆分合理**；`WS.queues` 由面板写回 |
| 任务 | 启动实施 | 确认后 **`POST /api/workstreams/queue/start`**（带 `stage` = 只跑该阶段）；切分支、边界内实施、conventional commits |
| 验收 | 校验 | 跑回归门 `<REG-ID>` + 机检证据；**人 sign-off**，agent 不自签 |
| 交付 | 交付 | push / PR；`covered` / `delivery` 经 `POST /api/workstreams/covered`、`/delivery` 回填（面板写卡，`outcome` 派生不手写） |

每个 action 段都附**模型规则**（强制）：

- 回边合法但留痕；跳过 / 裁剪必须在「规划」声明；
- **只拆不胀**：范围外 → 新需求卡片（R5），不就地吸收；
- 裁决是点记录；覆盖锚变更；终态是派生谓词（**不写** `closed` / `outcome`）；
- 回归门 `<REG-ID>`：若改动其覆盖路径，交付前运行；
- 任务阶段走**事项面板自有 API**（`task/create` 拆分、`queue/start` 启动、`delivery` 交付），**不用 `/task-todo`（任务面板）**；
- 不改其它会话的在途文件。

### 4.1 拆分提示词的定位与措辞

**拆分任务**是「推进一张事项卡」三件事之一（设计 `workstream-panel-design.md` §5.1：拆分 = 会话提示词 / 确认 = 阶段上的人工门 / 启动 = 事项卡「启动事项」（面板唯一入口，按阶段 canonical 顺序）或技能 `queue/start`）。它的提示词由 `WorkstreamHandoff.splitPrompt(card:stage:)` 生成，与其它动作**同形**（§3 公共头 + 动作段 + §4 规则段），只是 `stage` 由调用方**显式传入**。

- **定位**：
  - **触发** = 事项主卡「**拆分任务**」按钮；
  - **`stage` = 首个未处理阶段**（canonical 顺序里第一个运行态非「完成」的阶段，A13 派生态）——**不一定等于卡片当前 `stage`**：按钮问的是「下一件还没拆的事」，不是「卡停在哪」；
  - **送达** = 该事项的**主场会话**（`workstreamSessions`）；无绑定 / 坏会话按 `sessionTarget` 新建并绑定 / 回退当前会话；
  - 它是**指针不是状态副本**：提示词只点名事项与阶段，等待态任务的实际创建由会话里的 agent 调 `task/create` 完成。
- **措辞要求**（`actionSection(.splitTasks)`）：
  1. 用 `POST /api/workstreams/task/create` 建**等待态阶段任务**（= 任务拆分本身），**每条任务带本阶段 `stage`**，追加到该事项唯一队列；
  2. **只建不启动**；阶段 ↔ 队列映射由面板写回卡片 `queues`；
  3. **停下请人确认拆分合理**；
  4. **不自签**：拆分是人工确认门，agent 只建等待态任务，人在面板确认后才 `queue/start`；
  5. 本步动作是 `task/create`；`queue/start` 只作为「人确认后」的后续动作出现在规则段，不冒充本步动作。

### 4.2 创建任务抽屉与 `task/create`

事项主卡的「**创建任务**」按钮是「按阶段建等待态任务」的**面板侧入口**，与技能 / 会话调用的 `POST /api/workstreams/task/create` 是**同一条写入路径**（`WorkstreamsRunner.createStageQueue`）：

- **阶段选择器**：五阶段单选，默认该事项**首个未处理阶段**（`wsFirstUnprocessedStage`，A13 派生态）——与「拆分任务」同源；
- **一个输入框**：**首行 = 标题，其余行 = 内容**（`WSStageTaskComposerModel` 拆分）；⌘↩ 提交、Esc 取消、标题为空禁用提交；
- **提示词注入**：提交时用 `WorkstreamHandoff.stageTask(title:content:card:action:)` 生成该阶段的**交接提示词**（§3 公共头 + 动作段 + §4 规则段，与 `task/create` 完全同形），把用户输入的**内容附在提示词之后**；提示词仍在 body 开头，执行阶段的 `isHandoff` 判定与完成 marker 注入不受影响；
- **落点**：任务带该 `stage` 追加到该事项**唯一队列**、`WS.queues` 由面板写回；**只建等待态、不启动**。

与「拆分任务」的关系：**拆分**把 `splitPrompt` 发进主场会话，由会话里的 agent 调 `task/create`；**创建任务**是人在面板上直接走同一条 `task/create`（不经过会话）。两者产物相同（等待态、带 `stage` 的任务），都受「只建不启动 / 停下等人确认 / 不自签」约束。阶段卡**没有**创建任务入口。

## 5. 生成示例：WS-002

```text
你在 oh-my-dsh 仓库工作。处理事项 WS-002「需求 / 事项落盘 .dsh 落地」。

先读：.dsh/workstreams/WS-002.md、.dsh/requirements/REQ-002.md（通用规则见工作区 AGENTS.md）。

当前 stage：规划 → 确认规划后进设计。
目标：产出 docs/design/panels/requirements-workstream-store-design.md。
规则：……（同 §4）
结束前停下问：规划确认 / 设计确认 / 拆分确认 / 验收 sign-off。不要自签。
```

## 6. 变量来源

| 变量 | 来源 |
|---|---|
| `<repo>` | 工作区根 |
| `<WS-ID>` / `<REQ-ID>` | 面板选中的事项卡片 |
| `<stage>` | 卡片的 `stage` |
| `<action>` | 由 §4 按 `stage` 映射 |
| `<REG-ID>` | 卡片的 `regression`（无则省略该条） |
| 目标 | 卡片的「规划.目标」 |

## 7. 依赖与落地

- 可靠生成的前提是**存储 schema 定稿**（WS-002 / `requirements-workstream-store-design.md`）；
- `outcome` / `closed` 改为派生后，本模板不再出现「写 closed」这类动作；
- **已落地（2026-10-06 / 07）**：生成器为 `WorkstreamsPrompts.swift`（`WorkstreamHandoff`），阶段提示词由面板生成、原样注入任务 body 并按执行阶段追加完成 marker；阶段拆分 / 启动已改指事项面板自有 API（`task/create` / `queue/start`），交付事实经 `covered` / `delivery` 写路由回填，不再走任务面板 `/task-todo`；与 §4 表格一致。
- **拆分提示词（§4.1）已落地**：`WorkstreamHandoff.splitPrompt` 由主卡「拆分任务」按钮以**首个未处理阶段**调用，发进主场会话；措辞固定为「`task/create` 建等待态、带本阶段 `stage`、只建不启动、停下等人确认、不自签」。