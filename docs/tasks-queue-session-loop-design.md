# 任务队列 × 会话回传 设计（task-queue-session-loop）

> 状态：已实现（P0/P1 2026-09-30；P2 活泳道 + 手动发布 2026-10-01）
> 关联面板：任务（Tasks / IssueRunner）
> 关联文档：docs/task-todo-skill-design.md、docs/issue-runner-design.md、docs/builtin-skills-design.md、docs/git-workflow.md
> 决策来源：2026-09-30 会话讨论定稿

## 1. 背景与目标

`task-todo` 技能能把沟通结论批量写进任务面板，但落成任务之后的流程仍然有堵点：

1. 用户要**手动建队列、再一条一条把任务加进队列**；
2. 队列跑完后，完成情况只留在每张任务卡上，**发起任务的会话没有上下文**——验收时不知道该回哪个会话，回去了也没有前因后果。

本设计把这条链路接成一个闭环：

1. 在会话 X 里一次性创建「队列（等待态）+ 队内任务」；
2. 在会话 X 里说「启动队列」即可开跑（面板手动点开始同样支持）；
3. 队列**进入 `.done`** 时，把完成情况回传会话 X；
4. 用户在 X 里直接验收、要求调整。

## 2. 现状与可复用能力

| 能力 | 位置 | 结论 |
|---|---|---|
| 批量建任务 API | `TasksAPI.swift` / `IssueRunnerPanel.apiTaskCreate` | 复用解析与 delegate 形状 |
| 队列模型 | `TasksCore.swift` `TaskQueue` / `QueueState` | 复用，新增 `.draft` |
| 队列生命周期 | `TaskBoard.createQueue/enqueue/resumeQueue/pauseQueue/refreshQueueCompletion` | 复用 |
| runner 串行执行 | `TasksRunner`（`step` / `pump` / `applyFinish`） | 复用 |
| 会话 RPC | `IssueRunnerPanel.promptSession` → `session.prompt(mode: queue)` | 回传复用 |
| 会话 id 发现 | dsh shell-env 注入 `$DSH_SESSION_ID` | 技能可拿到 |

**关键约束**：`session.prompt` 只有 `queue | steer` 两种模式，没有「只追加历史、不触发一轮」的模式。
因此回传会让会话 X 真实跑一轮 agent；本设计接受这一点，并用受控文案把这一轮限制为「简短确认」。

## 3. 会话识别

- 技能调 API 时带上 `"session": "$DSH_SESSION_ID"`（dsh 的 shell-env 会为每次 bash 工具调用注入它）。
- 壳层不从 HTTP 推断会话（HTTP 没有会话上下文）；`session` 缺省时退化为旧行为（不回传）。
- 会话 id 是机器私有：只进 `local.json`，不进 `queues.json` / `index.json`。

## 4. 队列状态机：新增 `.draft`

```swift
enum QueueState: String { case draft, active, paused, done }
```

| 状态 | 含义 | 面板起始提示 |
|---|---|---|
| `.draft` | 建好但**从未启动** | 开始处理队列 |
| `.active` | 已启动，runner 可取任务 | 活跃 / 等待中 |
| `.paused` | **启动过但停了**（失败 / 取消 / 重启） | 继续处理队列 |
| `.done` | 当前一批任务都结束了；**活泳道**，可继续追加 / 发布 / 关闭 | — |
| `.closed` | **用户手动关闭**的终态：保留记录，不再接收任务 / 启动 / 发布 | — |

迁移：

| 事件 | draft | active | paused | done | closed |
|---|---|---|---|---|---|
| `createQueue`（面板 / API） | 新队列 | — | — | — | — |
| `queue/start` / 面板开始 | → active | — | → active | — | 拒绝 |
| 任务全部 done | — | → done | — | — | — |
| 任务 failed / cancelled | — | → paused | — | — | — |
| **追加任务** | 保持 | 保持 | **保持 paused** | **→ draft（并重臂回传）** | 拒绝 |
| 手动关闭 | → closed | → closed | → closed | → closed | — |
| App 重启 | 保持 draft | → paused | 保持 | 保持 | 保持 |

影响点：

- `TasksCore.swift`：枚举 + `createQueue` / `TaskQueue.auto(for:)` / `auto(forManual:)` 初值改 `.draft`；
  `TaskQueue.from` 仍以 `.paused` 兜底（旧文件语义不变）。
- `nextStartable()` / `activeQueue()` 只看 `.active` → `.draft` 不会自动开跑。
- `reconcileAfterRestart` 只处理 `.active` → `.draft` 重启后保持 draft。
- `TasksUI.swift` 的 `switch queue.state` 是穷举的，编译器强制补 `.draft` 分支与提示文案。
- L10n：新增 `tasks.queue.state.draft`（待启动 / Draft）。
- `TasksAPI.queueDictionary` 的 `state` 自然输出 `"draft"`。
- 测试：`model-tests.swift` / `ui-tests.swift` 中「新队列 = paused」的断言改为 draft。

## 5. 队列 ↔ 会话 关联

存 `local.json` 的机器私有 overlay：

```
queueSessions: { "q-xxxx": "session-..." }    // 队列 → 创建它的会话
queueNotified: { "q-xxxx": "2026-09-30T..." } // 已回传标记（幂等 / 重启补发）
```

- 关联在**创建时**建立，与「谁启动」解耦：会话启动、面板启动都不改写它。
- 面板手建队列没有 origin → 不回传（**不做**「回传会话」选择器，用户 2026-10-01 决定）。
- 追加任务到 `.done` 队列会**重臂** `queueNotified`：下一轮完成照常回传。
- 默认回传到创建会话；`queue/start` 不接受改写 origin（将来如需重绑再单独设计）。

## 6. API

新增两个纯模型路由（`TasksAPI.swift` + `TasksAPIDelegate` + `IssueRunnerPanel` 实现）。

### POST /api/tasks/queue/create

```jsonc
{
  "workspace": "/abs/path",
  "session": "session-...",        // 可选：来源会话
  "focus": true,
  "name": "外观切换",
  "branch": "feature/appearance",  // 可选；"" = 不切分支；缺省按名字派生
  "baseBranch": "main",            // 可选
  "autoPR": true,                  // 可选；缺省按工作区能力
  "tasks": [ {"title": "...", "body": "..."}, "标题" ]
}
```

响应：`{ ok, workspace, queue: {id,name,state:"draft",branch}, created:[{id,title}], rejected:[...] }`

### POST /api/tasks/queue/start

```jsonc
{ "workspace": "/abs/path", "session": "session-...", "queueId": "q-xxxx" }
```

- 有 `queueId`：启动该队列（draft 或 paused → active）。
- 无 `queueId`：找 `session` 创建且仍是 `.draft` 的队列；恰好一个 → 启动；0 个 → 404 `no-queue`；
  多个 → 409 + `queues` 候选列表，让 agent 消歧。
- 响应：`{ ok, workspace, started: ["q-xxxx"] }`。

### POST /api/tasks/queue/append

```jsonc
{ "workspace": "/abs/path", "session": "session-...",
  "queueId": "q-xxxx",            // 或 "name": "队列名"
  "tasks": [ {"title": "…", "body": "…"} ] }
```

- 目标队列按 `queueId` → `name` → `session`（本会话创建的非关闭队列）解析；多个候选 → 409 `ambiguous-queue`。
- 只入队、不启动。追加到 `.done` 队列会**回到 `.draft` 并重臂回传**；`.paused` 保持 `.paused`；
  `.closed` 拒绝（`queue-closed`）。响应同 queue/create：`{ok, queue, created, rejected}`。

`GET /api/tasks/list` 的 queue 项可选增加 `"reportsToSession": true`（不暴露 session id）。

## 7. Runner

- `createQueueWithTasks(name:branch:baseBranch:autoPR:originSession:drafts:) -> (queue, created)`：
  1. `board.createQueue(...)` → `.draft`；
  2. 每条 draft → `TaskItem.manual` + `board.enqueue`（**直接调 board，不走 `runner.enqueue`**，
     避免 `activateQueueIfIdle` 把等待队列激活）；
  3. `board.local.queueSessions[queue.id] = originSession`；
  4. 一次 `persist()`。不启动任何东西。
- 启动：复用 `startQueue(queueID:)`；按 `session` 消歧在 API 层做，runner 只收 queueId。
- 任务会话的标题带前缀 **`TASK: `**（`TasksRunner.taskSessionTitlePrefix + task.title`），
  在 dsh web 侧栏一眼可辨；PR 会话保持自己的「开 PR：<队列>」前缀。
- 回传触发：`QueueState` 进入 `.done` 的唯一路径是 `TaskBoard.markDone` → `refreshQueueCompletion()`。
  在 `TasksRunner.applyFinish` 的 `.done` 分支后调用 `notifyFinishedQueues()`：
  - 遍历 `state == .done`、`local.queueSessions[id] != nil`、`local.queueNotified[id] == nil` 的队列；
  - 组装摘要，`env.perform` 后台调 `env.notifySession(sessionId, text)`（复用 `promptSession`）；
  - 成功后写 `queueNotified[id]`；**失败也写**（记日志），避免死循环。
- 重启补发：`step()` 的空闲分支扫一次上述条件（app 在 done 与回传之间退出时补发）。

## 8. 回传内容

- 触发：**仅队列进入 `.done`**。失败/取消会让队列停在 `.paused`，不触发；
  若用户在面板重试/跳过后队列最终 done，则此时回传一次（摘要如实标出失败/取消项）。
- 文案（给 X 的 agent，要求简短确认）：

```
【任务面板】队列「<name>」已全部完成（<done>/<total>）
分支：<branch> → <base>　耗时：HH:mm → HH:mm（N 分钟）

1. ✓ <标题>
   汇报：
     <完整汇报，单条上限 1500 字，超出标注「已截断」>
   PR：<prUrl>
2. ✗ <标题>
   失败：<error>
   汇报：
     <失败前的最后一段话>

队列 PR：<url> / 未开 PR（<prError>）
分支上相对 <base> 的提交：
  <oneline 列表>          ← 仅 git 仓库且有分支时

这是任务面板的完成通知。请用一两句话确认收到并等待用户验收，不要主动改代码或新建任务。
```

- 报告取 `TaskItem.report` 的**完整文本**（runner 在任务结束时写回），不再只取首行；
  失败项同时给错误键与失败前的汇报。**不回传会话标识**（用户 2026-09-30）。
- 提交列表由 `git log --oneline <base>..HEAD` 得到，在 `env.perform` 后台执行；
  **非 git 仓库 / 不切分支的队列不显示**。
- PR 信息取 `queue.prUrl` / `prError`，**不等 PR 会话结束**。

## 9. 技能改造（task-todo）

`SkillInstaller.swift` 内嵌 + `.dsh/skills/task-todo/SKILL.md` 仓库副本**字节一致**（tests/skills 校验）。
新增：

- 建队列 + 批量入队：`POST /api/tasks/queue/create`，带 `session: $DSH_SESSION_ID`；
  队列名可由沟通主题派生；仍遵守「用户没要求就不建」。
- 启动：用户说「启动队列 / 开始处理队列」时，`GET /api/tasks/list` 找到该队列（或按 session 定位）
  → `POST /api/tasks/queue/start`。
- 边界更新：不再是「绝不建队列/入队」——改为「只有用户明确要求，且走队列 API；不绕过 API、
  不直接改盘上文件」。
- **默认沿用已有泳道**：用户要求把需求落成任务时，默认 `POST /api/tasks/queue/append`（带 `session`）——
  本会话已有队列就追加进去；`404 no-queue` 才 `queue/create`（等待态 + 批量入队）。
  只有用户明确说「只建任务 / 先别入队 / 不要队列」才用 `/api/tasks/create`；明确说
  「新建队列 / 另起一个」才直接 create——这是「验收 → 再补几条 → 再跑」循环的入口，
  **不需要用户每次都说「追加」**。

## 10. 面板

- 队列头 `.draft` 文案「待启动」+ tone；`canStart` 对 draft 生效；
  `startHintKey` 区分 draft（开始）/ paused（继续）。
- 可选（P1）：队列头显示「结果回传会话」标记。

## 11. 边界与失败模式

| 场景 | 处理 |
|---|---|
| App 未运行 / 端口不通 | 技能报错，不直接改盘上文件（沿用 task-todo 规则） |
| `$DSH_SESSION_ID` 为空 | 照常建队列，但不回传（无 origin） |
| 会话被删 / 归档 | `promptSession` 失败 → 记日志、标记已通知、不重试；完成情况仍在任务卡上 |
| 会话正忙 | `session.prompt` 的 `queue` 模式天然排队，安全 |
| 重复回传 | `queueNotified` 幂等；重启补发只针对未通知的 done 队列 |
| 一个会话建多个 draft 队列 | `queue/start` 无 queueId 时返回 409 + 候选，agent 消歧 |
| 队列停在 paused | 不回传（按定稿） |

## 12. 测试

- `tests/tasks-panel/model-tests.swift`：新队列 = `.draft`；draft 不自动起跑；draft → active；重启后 draft 保持。
- `tests/tasks-panel/runner-tests.swift`：`createQueueWithTasks` 落成 draft + queued 且不启动；
  done 触发一次回传且文案含各任务状态；paused（失败/取消）不触发；失败跳过并跑完后 done 触发；
  重启补发；`queueNotified` 幂等。
- `tests/tasks-panel/api-tests.swift`：两个新路由的解析/响应；`session` 可选；start 消歧 409 / 404。
- `tests/skills/run.sh`：内嵌与仓库副本字节一致。
- `tests/l10n/run.sh`：新键成对。

## 13. 分期

- **P0**：`.draft` 状态；`queue/create` + `queue/start`；`queueSessions` / `queueNotified`；
  done 回传；技能改造。
- **P1**：面板「回传会话」标记；start 按队列名消歧；重启补发（可与 P0 同批）。
- **P2（2026-10-01 实现）**：队列改为**可追加的活泳道**——`.done` 只是「当前一批任务都结束」，
  追加任务回到 `.draft` 并**重臂回传**（`.paused` 追加保持 paused）；PR/push 改为**手动发布**
  （`autoPR` 是队列配置、默认关）；新增手动终态 **`.closed`**（保留记录，之后不再接收任务/启动/发布）。
  「面板手建队列选择回传会话」**不做**（用户 2026-10-01 决定）。merge 属于流程，壳层不做：
  发布只 push + 开/更新 PR，评审与合并都在壳层之外。

## 14. 已定决策

1. 回传方式：`session.prompt`（mode=queue），文案要求 agent 仅简短确认。
2. 回传触发：**仅队列进入 `.done`**；失败/取消（`.paused`）不回传。
3. 手动取消：不回传。
4. 新建队列状态独立为 `.draft`，不复用 `.paused`。
5. 启动入口：会话说「启动队列」或面板点开始；两者都不改变创建时建立的队列↔会话关联。
6. PR：不等待 PR 会话；队列 done 即回传。
7. 技能默认：落成任务默认建「等待态队列 + 入队」；task-only 仅在用户明确要求时。
8. PR/push/merge：全部手动。`autoPR` 为队列配置、**默认关**；「发布」= push + 开/更新 PR；
   merge 由用户在本地/评审后处理，壳层不碰。
9. `.done` 是活泳道：追加任务 → `.draft` 并重臂回传；`.paused` 追加保持 `.paused`；追加不自动启动。
10. `.closed` 是**手动**终态（保留记录，不再接收任务/启动/发布）。
