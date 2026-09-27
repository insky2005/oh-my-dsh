# 任务面板设计（IssueRunner / Tasks）

> 状态：**v1 已实现**（v1.8.0+，方案 E：branch-based 串行队列）；**v2 已实现**（2026-09-24：多队列泳道 + 手动任务 + 卡片式 UI + token 仅文件；决策记录见 §V2-13）。v1 章节保留为历史决策记录，实现现状以 §V2-* 与 `.dsh/wiki/modules/issue-runner-panel.md` 为准
> 更新：2026-09-24
> 关联：`docs/git-workflow.md`（分支规范）、`docs/ui-color-scheme.md`（配色令牌）、`docs/projects-panel-design.md`（卡片面板体例）、`docs/dsh-version-impact.md`（会话 RPC 耦合面）、`.dsh/wiki/modules/issue-runner-panel.md`

## 目标

让 oh-my-dsh 从「查看/操作工具」进化为「**由 issue 驱动的工作执行器**」：面板拉取当前工作区 GitHub 仓库的 open issues，用户逐个（或「全部处理」串行）让 dsh 代理完成「切分支 → 修复 → 测试 → 提交推送 → 开 PR」的闭环，且全程可追溯、互不干扰。

## 核心决策（方案 E：branch，不用 worktree）

> 决策过程见会话记录：worktree 方案在 dsh 上存在分组错乱（未注册 workspace 的会话前端按 cwd 归组）与生命周期清理负担；且实测「主 workspaceId + worktree cwd」混传会被 dsh 拒绝。方案 E 用 **git branch + 串行队列**，绕开全部问题：

| 决策点 | 选择 | 依据（实测） |
|---|---|---|
| 隔离方式 | git branch（非 worktree） | 串行队列与分支切换天然匹配；worktree 留待 dsh web 原生支持后迭代 |
| 会话创建 | `session.create(workspaceId=主项目)` | 单独传 workspaceId 即 ok，cwd 自动 = 主项目目录，归主 workspace（无分组错乱） |
| 代理工作目录 | 会话 cwd = 主项目，当前分支 | 标记文件实测只在目标分支所在目录落盘 |
| 可追溯 | 会话/分支/PR 全保留，不自动删 | `session.export`/`archive` 等 API 不存在，删除即丢失追溯 |
| 串行 | 严格串行（同一时间一个任务） | 「全部处理」自动依次入队 |

## 架构

```
IssueRunnerPanelController (macOS, Swift)
  ├── 任务列表（NSTableView）：issue 编号/标题/标签/状态徽标
  ├── 仓库识别：git remote → owner/repo（自动，工作区切换时）
  ├── GitHub REST：拉 issues（过滤 PR）/ 创建 PR（token 走文件，见 §V2-1）
  ├── git 流水线（Process）：checkout main → pull → checkout -b fix/issue-N → 校验推送
  ├── dsh 会话：create(workspaceId) → rename("fix(#N): …") → prompt(issue-resolve) → 轮询 → cancel
  └── 串行队列：一次一个 running，完成自动启动下一个 pending

core/lib/jobqueue.js —— 跨平台串行队列状态机（Node，纯逻辑，可单测）
core/lib/issues.js  —— GitHub REST 封装（Node，可单测）
$DSH_HOME/skills/issue-resolve/SKILL.md —— 代理在任务会话中加载的执行指令（App 启动时安装到全局）
```

## 数据流（处理 issue #N）

1. 用户点「处理」（或「全部处理」）
2. `git checkout main` → `git pull --ff-only` → `git checkout -b fix/issue-N`
3. `session.create(workspaceId=主项目)` → `session.rename("fix(#N): 标题")`
4. `session.prompt`（queue 模式）注入 issue-resolve skill + issue 内容
5. 轮询 `session.list` 中该会话 `running` → 结束后
6. `git ls-remote` 校验分支已推送 → `POST /pulls` 创建 PR（base=main, head=fix/issue-N）
7. 状态 → done(PR url)；`git checkout main`；队列自动下一项

## 状态模型（Job）

```ts
{ id, title, source: "github" | "remote",     // source = 远程驱动预留
  state: "pending" | "running" | "done" | "failed" | "cancelled",
  prUrl?, branch?, sessionId?, error?, log? }
```

## 关联索引（issue ↔ branch ↔ session ↔ PR）

任务关联持久化在 `<repoRoot>/.dsh/tasks/`（随仓库提交，跨机器共享）：

- **`index.json`**（提交）：仓库级关联 `issue → branch → prUrl → state → startedAt/finishedAt/error`；
- **`local.json`**（gitignore）：本机级覆盖 `issue → sessionId`（dsh 会话 id 是本机实例特有的，不入共享索引）。

定位规则：
- **issue → branch**：`fix/issue-N`（或读 index.json）；
- **issue → session**：运行中读内存 `task.sessionId`；重启后读 `local.json`；
- **issue → PR**：读 index.json `prUrl`；
- **恢复**：App 重启后面板按 index.json + local.json 重建任务列表与关联（`restoreFromIndex`），再以 open issues 刷新标题；
- **实现**：`core/lib/tasks.js`（Node，可单测）+ `IssueRunnerPanel.swift` 的 `TaskIndex`（Swift，结构一致）。

## 远程驱动预留（钉钉/微信，本里程碑不实现）

- `source` 字段即任务来源标识；`core/lib/jobqueue.js` 是任务队列的统一后端；
- 未来「钉钉群/微信」驱动 = 一个 JobSource 适配器：接收消息 → 解析为 Job（含 issue 编号或自描述任务）→ `enqueue` → 同一队列串行执行；
- 接入点（计划）：App 内建消息接收（webhook/长连接）→ 构造 Job → 队列；面板 UI 无需改动（只订阅快照）；
- 详见「远程驱动」章节（待实现时补充）。

## 边界情况与失败处理

| 场景 | 行为 |
|---|---|
| 工作区非 GitHub 仓库 | 面板空态「当前工作区不是 GitHub 仓库」 |
| 公开仓库 | 匿名读 issues（60 req/h 限流）；私有需 token（文件，见 §V2-1） |
| 分支已存在 | `git checkout -b` 失败 → 提示「分支已存在」，可续跑 |
| 代理会话失败/超时（30min） | 标记失败，分支+会话保留（可追溯），可「继续新会话」 |
| 分支未推送 | 标记「分支未推送」（代理未 push），可重试 |
| PR 创建失败 | 标记失败 + 显示错误；分支已在远端，可手动开 PR |
| App 退出 | 分支/会话/PR 全保留；下次启动按 git 分支恢复队列状态 |
| 取消 | `session.cancel` + 标记 cancelled；分支保留由用户处理 |

## 测试与验收

- `node --test core/tests/issues.test.js core/tests/jobqueue.test.js` 全绿（CI 自动跑）；
- `swiftc` 编译检查（含新文件）；`build-app.sh` 构建通过；
- 手动 QA：见下节。

### 手动 QA 清单

- [ ] 打开任务面板（活动栏「任务」/ ⌥⌘J）→ 自动识别当前仓库 → 列出 open issues；
- [ ] 点某 issue「处理」→ 主项目出现 `fix/issue-N` 分支 → dsh web 左侧出现命名会话 → 代理执行 → 结束后 PR 出现在 GitHub；
- [ ] 同时点两个 issue → 第二个排队，第一个完成才启动；
- [ ] 处理中取消 → 会话被 cancel、状态 cancelled；
- [ ] 失败（如分支冲突）→ 状态 failed、有错误提示；
- [ ] 工作区切换 → 面板自动重识别仓库并刷新列表。

## 迭代预留

- **worktree**：等 dsh web 原生支持 worktree 后，把「切分支」步骤替换为「worktree + workspace.create + 任务结束清理」，队列与监控逻辑不变（`docs/` 本文件同步更新）；
- **远程驱动**：JobSource 适配器（钉钉/微信）；
- **token 管理**：多仓库多 token、按仓库作用域（v2 已改为只走文件，见 §V2-1）。

---

## V2 方案（2026-09-24 定稿，待实现）

> 本章是本次迭代（分支 `feature/tasks-manual-queue`）的落地依据。上文 v1 章节保留作历史决策记录。
> **模型决策已定稿**（详见 §V2-13 决策记录）：多队列模型先行；队列分支用户可填（默认由队列名生成 slug，中文名回退 `feature/queue-<id4>`）；队内失败暂停队列；PR 是**可选能力**；issue 任务保持 v1 逻辑、自动生成**单任务队列**；创建任务表单只有一个框（首行标题 / 其余行描述，一律先进「未入队」区）；队列计数含自动队列。

### V2-0 需求与改动面

| # | 需求 | 主要改动面 |
|---|---|---|
| 1 | 移除钥匙串读写 GitHub token，只从文件读取 | `IssueRunnerPanel.swift`（token 一节）、`main.swift` 的 L10n、README / wiki |
| 2 | 手动创建任务（本地 / 个人任务）+ 可加入队列、随时移出 | 任务模型、`.dsh/tasks/*` 持久化、新建任务表单 |
| 3 | **多队列（泳道）**：同一队列共享分支，任务按序执行 | 队列模型 `Queue`、队列运行器、队列分区 UI |
| 4 | 任务清单改卡片样式、优化交互 | `IssueRunnerPanel.swift` UI 层（NSTableView → NSScrollView + NSStackView） |

核心思路：**一切任务都在队列里执行**。用户显式创建的队列是「泳道」（可含多个任务、共享分支）；issue 任务的队列是系统自动创建的**单任务队列**（分支沿用 `fix/issue-N`），因此 v1 的「一 issue 一分支一 PR」行为完全不变。

### V2-1 GitHub token：只从文件读取

**删除**：`readKeychain(service:)`、`saveToken` 里的 `SecItemAdd` / `SecItemDelete`、`loadToken` 的第 ③④ 级 Keychain 回退，以及 `genericTokenService` / `tokenService(for:)` 两个 service 常量。改完 `platforms/macos/src/` 下不应再出现 `SecItem` / `kSecClass`。

**改后的解析顺序（只剩文件两级）**：

1. 文件专属：`$DSH_HOME/tokens/<owner>-<repo>`（默认 `~/.dsh/tokens/<owner>-<repo>`）；
2. 文件通用：`$DSH_HOME/gh-token`（App 与外部工具 / 代理共用同一份）。

**保存**：只写文件专属（原子写 + `chmod 600`）；输入留空 = 删除该文件。面板提示同步改为文件口径。

**兼容性**：自 `88f0255` 起面板保存 token 就是「文件 + 钥匙串双写」，凡是通过面板保存过的 token 早已在文件里，**绝大多数用户不会被要求重填**；只有更老构建（或手工 `security add-generic-password`）写进钥匙串的条目不再被读取 —— 面板文案与 README / wiki 明确写「钥匙串里的旧 token 不再使用，请重新填写一次」。

**验收**：全仓库 grep 无 `SecItem` / `kSecClass`；文件存在时私有 issue 拉取、开 PR、评论关闭均正常；删掉专属文件后回落到通用文件；输入留空时专属文件被删除；`tests/tasks-panel` 覆盖解析优先级。

### V2-2 统一任务模型（TaskItem）

```swift
struct TaskItem {
    enum Source: String { case github, manual }   // 来源标记 → 卡片徽标
    enum State: String {
        case pending, queued, running, done, failed, cancelled, closed
    }
    var id: String            // github: issue-<N>；manual: manual-<8 位随机>
    var source: Source
    var number: Int?          // 仅 github 任务有 issue 号
    var title: String
    var body: String?         // issue 正文 / 手动任务的描述（提示词正文）
    var labels: [String]
    var state: State
    var queueId: String?      // 所属队列（nil = 未入队）
    var branch: String?       // 由所属队列决定（见 §V2-6）
    var prUrl: String?
    var sessionId: String?
    var error: String?
    var startedAt: Date?
    var finishedAt: Date?
}
```

**状态语义**（与 v1 的差别：新增 `queued`，`pending` 不再被隐式自动执行）：

| 状态 | 含义 | 卡片主操作 |
|---|---|---|
| pending | 待处理，**未入队** | 加入队列 ▾ / 处理（issue 任务） |
| queued | 已入队，等待前一个任务结束 | 移出队列（随时可点） |
| running | 正在执行（全局同一时刻仅一个） | 取消 |
| done | 完成 | 打开 PR（若有）/ 评论并关闭（仅 github） |
| failed | 失败（分支与会话保留，可追溯） | 重试 / 跳过（队列因此暂停时） |
| cancelled | 已取消 | 重试 |
| closed | issue 已关闭（仅 github） | 打开 Issue |

**id 规则**：github 任务沿用 `issue-<N>`（旧索引零迁移）；手动任务 `manual-<uuid 前 8 位>`。

### V2-3 队列模型（Queue = 泳道）

```swift
struct Queue {
    var id: String            // q-<8 位随机>
    var name: String          // 队列名（用户输入，例：深色模式改造）
    var branch: String?       // 队列分支，队内所有任务共用；nil = 不切分支
    var baseBranch: String    // 从哪个分支切出，默认 main
    var taskIds: [String]     // FIFO 顺序
    var state: QueueState     // active | paused | done
    var autoCreated: Bool     // true = issue 任务的单任务队列（UI 折叠为普通卡片）
    var autoPR: Bool          // 队列跑完后是否创建 PR（能力不支持时自动置 false）
    var prUrl: String?        // 队列级 PR
    var createdAt: Date
}
```

**队列语义**：

- **同一队列共享一个分支**，任务按 `taskIds` 顺序执行，改动在同一分支上累积 —— 后一个任务**天然看到前一个任务的 commit**，这就是「有前后依赖的一组任务」的正确表达方式（替代 v1 里靠 `checkout` 失败碰运气）；
- **队列之间不并行**：一个工作树同一时刻只能 checkout 一个分支，因此全局仍然**只有一个 running 任务**。多队列买到的是「分组 + 顺序隔离」，不是并发（要并发只能上 worktree，v1 已否决）；
- **同一时刻只有一个「活动队列」**：它连续跑完队内任务；点另一个队列的「开始」= 在当前任务结束后切换为活动队列；
- **显式队列**由用户创建（可含多个手动任务）；**自动队列**由 issue 任务的「处理」自动创建（单任务、`autoCreated = true`），保留 v1 的分支与 PR 语义；重试时按 task id 复用同一个自动队列，不重复创建。

**issue 任务不进共享队列**：为保持 `docs/git-workflow.md` 的「一 issue 一分支一 PR」，issue 任务的卡片只有「处理」（= 自动单任务队列），没有「加入队列 ▾」。放开这条留给阶段 2 迭代。

### V2-4 持久化布局（`.dsh/tasks/`，各文件单一职责）

| 文件 | 作用域 | 唯一职责 |
|---|---|---|
| `index.json` | 提交（**结构不变**，`version: 1`） | github 任务：issue → branch / prUrl / state / title / body / labels / 时间戳；写入时补 `source: github`（读侧缺省按 github） |
| `manual.json` | **本机（新增，需加 `.gitignore`）** | 手动任务（本地 / 个人任务）的增删改查 |
| `queues.json` | **本机（新增，需加 `.gitignore`）** | 队列定义与顺序：name / branch / baseBranch / taskIds / state / autoPR / prUrl |
| `local.json` | 本机（已 gitignore） | **只有** task id → sessionId（`sessions`）；另存 `activeQueueId` 与退出时的 `runningTaskId`（用于识别中断） |

**`local.json` 换键（必须做）**：现在是 `sessions: { "6": { sessionId } }` —— 用 issue 号当键，手动任务没有 issue 号，结构直接失效。改为以 **task id** 为键：`sessions: { "issue-6": {...}, "manual-ab12cd34": {...} }`；读侧兼容纯数字键（自动视作 `issue-<N>`），**历史数据零迁移、不重写文件**。

**为什么手动任务与队列放本机**：手动任务是个人临时工作项（例：「把终端面板的滚动逻辑重构一下」），队列是本地工作流状态 —— 提交进仓库只会污染协作者的 diff。github 的 issue ↔ 分支 ↔ PR 关联索引**维持提交语义不变**（跨机器 / 跨同事可追溯），这是 v1 的既有价值。若将来要共享手动任务 / 队列，只需把它们搬进 `index.json`（`version: 2`），**展示层不受影响**（见 §V2-8：存储归属 ≠ 展示归属）。

`core/lib/tasks.js` 同步扩展（manual 与 queue 的读写 + sessions 换键兼容），保持 Node 与 Swift 双实现结构一致（沿用既有体例），并补 `core/tests/tasks.test.js` 用例。

### V2-5 执行模型：全局串行 + 活动队列 + 失败暂停

**运行器（QueueRunner）**只有一个入口 `pump()`：`runningTaskId == nil` 时取活动队列的队首任务 → 标 running → 执行流水线 → 任务结束时再 `pump()`。同一时刻只有一条轮询定时器（沿用 `pollTimer`）。

| 场景 | 行为 |
|---|---|
| 队内任务成功 | 队列继续下一个任务（**不切分支**，改动累积） |
| 队内任务失败 / 取消 | **暂停该队列**（`state = paused`），后续任务留在 queued；卡片给出「重试 / 跳过并继续」两个显式选择。共享分支上有依赖，继续跑等于基于半成品开工 |
| 队列全部完成 | `state = done`；若 `autoPR` 且分支已推送 → 创建 / 复用队列级 PR（见 §V2-6） |
| 切到另一个队列 | 切换前必须 `git status --porcelain` **干净**；不干净则暂停该队列并在卡片提示「工作区有未提交改动」，不切分支、不启动 |
| 任务结束时工作区不干净 | 卡片标注「有未提交改动」但队列**继续**（同一分支上累积是预期行为）；只在**切队列**时才强制干净 |
| 队列为空 | 状态条显示「队列空闲」 |

**重启恢复**：启动时读 `queues.json` 复原队列与顺序、`manual.json` + `index.json` 复原任务本身。上次退出时状态为 `running` 的任务 → 标记**已中断**（`failed` + 「上次运行被中断」，会话与分支保留），因为那个 dsh 会话已随进程结束 —— 这同时修掉了 v1 恢复后长期显示「运行中」的观感问题。**恢复后不自动开跑**：状态条提示「队列中有 N 个任务」，用户点队列头「开始」才继续，避免启动即消耗额度 / 擅自改仓库。

**实现备注（2026-09-24，`TasksRunner.swift`）**：

- 运行器是唯一的 board 变更入口（入队 / 启动 / 完成 / 取消 / 重试 / 重启恢复），面板只渲染与调用；阻塞工作（git / HTTP / RPC）交给注入的 `perform` 离开主线程执行，**board 的修改始终在同一个回调里完成**，`step()` 是唯一的定时入口；
- **入队即激活**：空闲时把任务加进队列会把该队列设为活动队列（这就是「加入队列 = 开始」）；重启后恢复的队列是 paused，那条路径不走 `enqueue`，所以不会自动开跑；
- **启动失败也记录 sessionId**：会话已建、只是重命名/提示词失败时，卡片仍能看到该会话（可追溯）；
- **issue 任务重试复用同一个自动队列**（不重复创建），失败的 issue 任务走 `retryAndResume` 回到 queued 再启动；
- 失败原因以 **L10n 键**存进 `error` 字段（`TaskFailure` 的 rawValue，如 `tasks.errDirtyTree`），面板显示时 `L10n.tr(error)`；
- **面板接线（第 5 步）**：`setupRunner(repoRoot:)` 读四文件 → `reconcileAfterRestart`（上次 running 记为「已中断」、active 队列暂停）→ 建 `TasksRunner` 并起 3s 定时器（`step()`）；issue 拉取经 `runner.updateBoard` 合并进 board（新增 issue → pending，已存在的刷新 title/labels/body，不再 open 的标 closed，**不碰 running/queued**），索引写入仍逐条 `mergeIssueTask`；表格用**指纹比对**（任务状态 + PR + 队列状态）只在真正变化时重建，避免每 3s 刷新打断滚动。

**修掉的既有缺陷**：v1 `gitCheckoutBranch` 里 `checkout main` 与 `pull --ff-only` 的失败被 `_ =` 吞掉，导致新分支可能从**上一个任务的分支**或陈旧提交切出（静默继承 / 静默偏离）。V2 改为显式三步（`checkout <base>` → `pull --ff-only` → `checkout -b <branch>` 或复用已存在分支），**任一步失败即判该任务 failed 并暂停队列**，绝不静默继续。

### V2-6 分支与 PR 规则

**分支归属**：

| 任务 | 分支 | 说明 |
|---|---|---|
| issue 任务（自动单任务队列） | `feature/issue-N` 或 `fix/issue-N` | 沿用 `branchForIssue` 的 label 判定与 `docs/git-workflow.md` 规范，行为与 v1 完全一致 |
| 手动任务（用户队列） | 队列的 `branch` | 队列分支默认 = `feature/` + 队列名 slug（小写、非字母数字换 `-`、去首尾、截断 40）；**slug 为空（纯中文 / emoji 名）时回退为 `feature/queue-<id 前 4 位>`**（例 `feature/queue-7f3a`）；**用户可改**；留空 = 不切分支，在当前分支上执行 |

**PR 是可选能力，不是硬依赖**（决策 4）：

- GitHub issue 任务天然只在 GitHub 仓库出现（issue 来自 GitHub API），因此对它 PR 恒可用，行为同 v1；
- **公司内部仓库 / 无 PR 能力的远端**（自建 GitLab、纯本地 git、无远端）下，手动任务与队列照常可用：只切分支、commit、push，**不创建 PR**。开关 `autoPR` 在工作区不是 GitHub 仓库时自动置 `false` 并在表单里置灰说明；
- 队列级 PR：同一 head 分支在 GitHub 只能有一个 open PR，因此**队内任务完成时只 push**，队列跑完才创建一次 PR；创建前先 `GET /pulls?head=<owner>:<branch>` **复用已有 PR**，避免第二个任务吃 422；
- PR 创建失败（无权限、远端不支持、网络）**不判队列失败**：队列照常 `done`，卡片标注「分支已推送，PR 未创建」，并展示分支名 + 远端名供用户手动处理。

> ⚠️ **2026-09-27 第三轮：PR 改由一个专门的「开 PR 会话」做，任务只 commit（上面「队内任务完成时只 push」「推送校验」两段描述的是旧行为）**。用户的原话：**「所有的具体任务会话中，只须完成本地 git commit 即可；若队列中所有任务完成了、且队列开启了 PR，则进行 push 及 PR，这个操作可以发起一个新会话，由其总结变动后再发起 PR。」** 于是：
>
> - **任务会话只 commit**：提示词里不再出现 push、PR、「远端必须有这些提交」，也不再有「不要 push」这种话（说了就是让代理操心不属于它的事）；`finish()` 里那条 `ls-remote` 推送校验、`BranchPushState` 三态、`tasks.errNoPush` 的产生路径、`env.createPR` / `env.prText` 与面板的 REST `createPR` **一并删除**（`tasks.errNoPush` 的 L10n 键保留：老任务记录里还存着这个错误码）。
> - **PR 会话**：队列最后一项完成 + `queue.autoPR` + 工作区有 GitHub 远端时，`TasksRunner.startQueuePR(queueID)` 在仓库目录里**新建一个 dsh 会话**（名字 `开 PR：<队列名>`，可像别的会话一样打开），把 `TaskPrompts.pullRequest(...)` 交给它：先读真实改动（`git log/diff`）、**自己写** PR 标题与正文（要的是总结，不是模板）、推送分支、开或复用 PR、最后一行必须给出 PR 链接、**不许改代码**。运行器的相位机多出 `.startingPR`（建会话中）与 `.openingPR`（会话在跑 / 结果在查），它们同样占用那个串行槽位（`isBusy` 为真、`runningTaskID` 为 nil、`openingPRQueueID` 指向队列），所以一次只有一个 PR 会话在飞。
> - **结果回收**：会话结束后在后台步骤里取它的汇报 → 用 `TasksRunner.prURL(in:)` 搜出 `github.com/.../pull/N`；搜不到就用 `findExistingPR(branch)` 兜底（会话开了 PR 却没引用链接的情况）。都没有 → 队列记 `prError`（`tasks.errPR`）并写日志，**队列保持 done**。失败原因显示在队列头「开 PR」按钮的 tooltip 上（`tasks.errPR` / 无分支 / 无远端 / 会话起不来），按钮仍在，点一下就是再来一次。队列头的「开 PR」按钮走的也是 `startQueuePR`（不再是直接调 GitHub API）。
> - **汇报回写**：任务结束（成功**或失败**）时在同一个后台步骤里取会话的最后一段文字，`markDone(report:)` / `markFailed(report:)` 写到 `TaskItem.report` + `local.json` 的 `reports`（**不进**随仓库走的 `manual.json`/`index.json`：汇报是这台机器的会话产物）；卡片详情多一行「汇报」；队列里下一棒的交接简报**优先用它**（会话被删也还在，读不到才回落到读会话日志）；`retryAndResume` 清掉上一轮的汇报（它不是这一轮的结局）。
> - **提示词按需出条目**：`TaskPrompts.manual` 不再写死 1–6 条，而是按 `TaskRepoShape` 生成条目并连续编号 —— 非 git 目录**没有分支条**（第 4 条改为「不要求 commit；任务自己 `git init` 建了仓库就 commit」）；有仓库才有分支条（有分支 → 「本任务须在分支 X 上处理（若该分支不存在，须基于 base 分支新建）」；不切分支 → 「本队列不切分支：直接在主分支 base 上处理（不要新建分支）」；两条都点名分支，`manual` 因此收了个 `base`）与「完成前 commit」；**token 条只在 GitHub 仓库出现**；「改完自查」同时照顾代码与文档（没有可跑测试的就说明）；「汇报」一条每个任务都要（`**必须**`，并说明它会被写回卡片）；「独立执行」不再说「与其他任务共享」；**前置任务的汇报整段移到所有要求之后**（用户的第 1 条：补充在整个要求的后面）。`pushes` 参数随之从 `TaskPrompts.manual` 消失。
> - **卡片与按钮的三处收尾（2026-09-27）**：① 队列名与任务名前各加一枚行标（`rectangle.stack` / `checklist`，第三档灰，取不到符号时 0 宽退化）；② 「打开会话」点击立刻在状态行说「正在打开会话…」，**失败改说给请求它的面板**（此前一律写进项目面板的状态行，任务面板里就是「点了没反应」），带「正在打开」守卫的超时与两个短 tooltip（打开会话 / 审查改动）；③ `TaskState.isEditable` 把「已完成的任务不可编辑 / 删除」与 README 对齐，`QueueHeaderModel.canEdit/canDelete` 让已完成的队列不再显示 设置 / 删除。
> - **回归**：`tests/tasks-panel` 运行器 **337 项**（原 314 → 新增 PR 会话的完整链路：任务只 commit 的提示词断言、PR 会话被创建/命名/收到分支与 base、PR 链接从汇报回收、未自报的 PR 由分支查回、无分支/无远端时拒绝并记录原因、批次里「任务 + PR 会话」两段推进），模型 **176 项**（汇报落在任务与 local.json、不写进 manual/index、失败也留汇报、重试清空、空白不算汇报、往返与 `attachSessions`），视图模型 **296 项**（详情里的「汇报」一行、队列头 PR 失败原因的 tooltip）。`tests/l10n` 删掉 4 条随 REST createPR 一起失效的文案（`tasks.prTitle` / `tasks.prBody` / `tasks.queue.prTitle` / `tasks.queue.prBody`）。

**推送校验（2026-09-27 改）**：推送**只在「这个队列会开 PR」时发生** —— `queueWantsPR = queue.autoPR && env.canOpenPR()`（`canOpenPR` = 工作区有 GitHub 远端）；提示词里的 push 要求与收尾的校验共用这一个判据，所以没开自动 PR 的队列**只做本地 commit、不 push、也不校验**（`finish` 里 `!queueWantsPR` 时只记一行「keeps its work local」）。要开 PR 的队列仍沿用 v1 的 `pushRemoteName`（github > origin > 首个 remote），但校验是**三态**的（`BranchPushState`：pushed / notPushed / unknown）——`ls-remote` 自己失败（私有远端没凭据、网络抖）算 `unknown`，只记日志并继续尝试开 PR，**不再把「问不到」当成「代理没推送」**（那会把已经干完的活判成失败）；无远端时跳过校验并记日志。真正「远端上没有这条分支」才判 `tasks.errNoPush`。

### V2-7 手动创建任务

**入口**：页签行右侧的「＋」图标按钮（或空态里的「新建任务」按钮）→ **从内容区顶部下拉一张表单抽屉**（§V2-8 的实现备注 2026-09-25c）。

**只有一个输入框**（2026-09-26 起，取代原来的「标题 + 描述」两个字段）：

1. **首行 = 任务标题**：卡片主行、会话名；
2. **其余行 = 任务描述**（发给代理的指令）；
3. **只有一行时，这一行同时是标题和描述** —— 描述回落到标题，代理收到的就是这一行。

创建后任务**一律进入「未入队」区**（决策 6），队列归属完全由卡片上的操作决定 ——

> 逻辑：`TaskDraft.composed(from:)` 负责拆行（首行去首尾空白作标题；其余行去掉首尾空白后作描述；若为空则回落到标题），`TaskDraft.combined(title:body:)` 是它的逆运算（编辑回填时把两部分合成一个框；描述就是标题时回到单行，不会出现同一句话写两遍）。校验**只看标题**（空框 → L10n 键 `tasks.errName`；`tasks.errBody` 随之删除：描述不再是必填项），`effectiveBody` 保证存储层永远拿到一段可发给代理的正文；运行器 `createManualTask` / `updateManualTask`（运行中的任务与 github 任务都拒绝编辑）/ `deleteManualTask`（运行中拒绝删除；删除即退出所有队列并清掉本机 session 记录）；「加入队列 ▾」的候选来自 `TaskBoard.queueChoices()`——**只列用户队列**，issue 任务的自动单任务队列不是目的地。

1. 点卡片 **「加入队列 ▾」** → 选**已有队列**，或**新建队列…**（**同一张抽屉**，创建后顺手把这一个任务入队：**队列名** / **分支**（默认见 §V2-6，可改、可留空；字段下方实时显示「将使用分支：feature/<slug>」，无 ASCII slug 的纯中文名回退通用文案）/ **基于分支**（默认 `main`）/ **完成后创建 PR**（开关，属于队列属性，队内任务共享；工作区不是 GitHub 仓库时置灰关））；队列也可**脱离任务单独创建**（队列分区头右侧的「新建队列」）；
2. 入队后：全局空闲 → 立刻启动队首；否则排队（见 §V2-5）；
3. 改主意：卡片「移出队列」→ 回到未入队区，或再点「加入队列 ▾」换到别的队列。

**执行流水线**（与 issue 任务复用同一套，差异如下）：

| 步骤 | issue 任务（自动队列） | 手动任务（用户队列） |
|---|---|---|
| 切分支 | 每任务一次：`checkout main → pull → checkout -b feature/issue-N 或 fix/issue-N` | 队列首个任务：`checkout <baseBranch> → pull → checkout -b <queue.branch>`；队内后续任务：**不切分支** |
| 建会话 | `session.create(workspaceId)` + `session.rename(fix(#N): …)` | 同左，会话名 = 任务标题 |
| 提示词 | issue-resolve skill + issue 正文 | **通用提示词**：工作目录 / 分支 / 队列内位置、任务描述、要求（改代码 → 跑测试 → commit → push）、token 文件位置（需要 GitHub 写操作时）；**按工作区「现在的形状」写**（非 git / git 无 GitHub 远端 / GitHub 三态，见本节末两条修正），不复用 issue-resolve skill |
| 收尾 | 校验分支已推送 → 开 PR → done(PR url) | 队列跑完才收尾（见 §V2-6）；单个任务完成只 push |
| 评论并关闭 | 有（done 且有 PR 时） | **无**（没有 issue 可关） |

**队列操作**（UI 上都在队列头）：新建 / 重命名 / 改分支 / 开始 / 暂停 / 开 PR / 归档。删除队列时，队内未执行任务回到「未入队」区，已完成任务的记录保留。

**非 GitHub 工作区**：手动任务与队列**仍然可用**（不依赖 issue 拉取），PR 相关全部隐藏或置灰；issue 区维持原有空态「当前工作区不是 GitHub 仓库」（文案改为只针对 issue 区）。

> **实现（2026-09-24 修正）**：board 只绑定**工作区目录**，不绑定 GitHub —— `adoptWorkspace(_:)` 对任意已解析的工作区都建立 runner（`<dir>/.dsh/tasks/` 即该工作区的 board），GitHub 远程只是额外点亮 issue 功能；工作区解析为空时才 `clearBoard()`（并在 `app.log` 写 `tasks: no workspace adopted …`）。工具栏右侧显示 `目录名 · 非 GitHub 仓库`，空态文案在非 GitHub 工作区改为「还没有任务：点右上角 + 新建一个…」。**目录不是 git 仓库也能建任务**：队列只要不设分支（留空）就不碰 git；设了分支则在启动时报 `tasks.errNotGit`（原设计里「非 git 目录置灰 +」改为「按钮始终可见，点了给明确说明」）。
>
> **实现（2026-09-27 修正 · 非 git 工作区其实跑不了任务）**：上面那句「队列只要不设分支（留空）就不碰 git」在 UI 上**做不到** —— 新建队列表单里「留空」的语义是**按名字派生 `feature/<slug>`**（`QueueComposerModel.effectiveBranchHint`，见 §V2-6），只有**编辑**队列表单里留空才是「不切分支」。于是在非 git 目录里：新建任务 → 加入队列 ▾ → 新建队列…（默认折叠的高级设置里分支字段是空的）→ 队列拿到 `feature/<slug>` → 入队即启动 → 第一个任务以 `tasks.errNotGit` 失败；而卡片上只有「重试」，重试必然同样失败，唯一的出路是用户自己发现「队列设置 → 清空分支 → 重试」这条三步绕路。运行器与 board 从头到尾都支持非 git（`TaskGit.enter` 无分支时返回 `.noBranch`、失败判定里 `.noBranch` 不算失败、无 remote 跳过 push 校验），**卡住的是表单表达不了「不切分支」**。修正三处：
>
> 1. **面板记住工作区是不是 git**：`IssueRunnerPanel.workspaceIsGit`（此前 `isGitRepo` 算完只拼进日志）；
> 2. **表单显式化**：`QueueComposerModel` 新增 `skipsBranch`（不切分支）与 `gitAvailable`，`forWorkspace(git:pr:)` 把新建表单收窄到工作区真能做的事 —— 非 git 目录里**默认就是 不切分支**、`branchValue` 提交显式空串、分支/基于分支字段退出使用、提示写「当前目录不是 git 仓库：队列不会切分支（任务照常运行）」；git 仓库里老行为一字不改（留空 = 派生），但多了一个**创建时就能勾的「不切分支」开关**（此前只有编辑模式能表达，这就是 §V2-6 那个二义性的根）。开关放在「将使用分支：… / 高级设置」那一行上，不新增行高（展开后的队列表单必须仍在 290pt 内）；
> 3. **失败可救**：`TaskCardModel.clearsBranchOnRetry`（failed + `tasks.errNotGit` + 队列确实有分支）让卡片的「重试」变成**「不切分支并重试」**——点一下先把该队列的分支清掉（`updateQueue(branch: .some(nil))`）再 retry，并把 `tasks.errNotGit` 文案改成说清出路（原文案「无法切分支 / 建会话」是错的：会话一直建得出来）。
>
> 回归（`tests/tasks-panel`）：运行器新增「非 git 工作区：无分支队列照常跑完 + 有分支队列报 errNotGit 且不浪费会话」（假 git 全部命令失败）；视图模型新增「非 git 默认不切分支 / git 里派生不变 / 开关压过已填分支 / 编辑不静默丢分支」与「errNotGit 的卡片给一键修好、别的失败不给」；表单视图新增「非 git：开关开着且不可点、字段停用、提示说原因、提交显式空分支」「git：开关可点、勾上后提示改口」。

> **实现（2026-09-27 补充 · 头部的工作区行）**：这条 28pt 工具栏行只放一句短文案（审查面板同一条行放的是控件），于是它并进了标题行 —— 头部变成两行（40pt → 46pt：`任务` + 工作区行，净省 22pt 给列表），三种状态分开说：GitHub 仓库 `owner/repo`、git 仓库但没有 GitHub 远端 `目录名 · 非 GitHub 仓库`、**目录根本不是 git 仓库** `目录名 · 非 Git 仓库`（后者的队列连分支都切不了，见 §V2-7，两种说法混成一句正是用户看不懂的地方）。文案与按钮可用性都由纯模型 `TaskWorkspaceModel.build(owner:repo:workspacePath:isGitRepo:)` 决定：非 GitHub 工作区里 **配置 GitHub Token / 刷新 Issues / 全部处理** 三个按钮置灰（它们本来就 `guard repo != nil`，点了不会有任何反应），tooltip 说明原因。
>
> 头部的工作区行还要解决一个渲染陷阱：`HeaderLabel` 用 `NSString.draw(at:)` 画字，**既不清除也不省略**（实测 165pt 的文案塞进 90pt 的 frame 会向右多画 1004 个像素点，正落在旁边的按钮底下）。新的 `FittingHeaderLabel`（与 `HeaderLabel` 同处 `PreviewPanel.swift`）在每次布局时把文字按自身 frame 截成「…」，tooltip 保留全文；`tests/skills-panel/render-tests.swift` 用离屏渲染钉住「框内有墨 + 框外 0 像素」，并**同时钉住前提**（朴素 `HeaderLabel` 确实会越界 —— 若哪天 AppKit 开始裁剪，这条断言会提醒重新评估而不是静默失效）。
>
> **实现（2026-09-27 补充 · 队列被删之后的失败卡片）**：卡片的**主操作不再只看任务状态**。删掉队列后，失败任务回到「未入队」区但**状态仍是 failed**，旧规则于是继续给它「重试」——可 `TaskBoard.retryAndResume` 在没有队列时只能把状态改回 `pending`，也就是说这个「重试」什么也没重试，只是把卡片 reset 了一次、让用户再点一次「加入队列」。现在主操作由**队列成员关系 + 状态**共同决定：有队列 → 「重试」（含分支进不去时的「不切分支并重试」）；**没有队列** → 手动任务直接给「加入队列」（下拉，选一个队列即入队开跑），issue 任务给「处理」（`startIssueTask` 重建它的自动单任务队列）。
>
> 同一次改动把界面侧的执行方式也改了：面板**按卡片模型给出的 `TaskCardModel.PrimaryAction` 执行**（`.joinQueue` / `.processIssue` / `.dequeue` / `.cancel` / `.openPR` / `.openIssue` / `.retry(clearsBranch:)`），不再自己按 `task.state` 猜——状态区分不了「在队列里失败」和「队列被删后失败」这两种情形，模型可以。新增的界面动作若要再加一个入口，先看这张枚举。

> **实现（2026-09-27 补充 · 派活之后的四次「说真话」）**：审计（三个独立探针 + 全量读码）发现了几处**界面在骗人**的地方，都收在这一次：
>
> 1. **自动队列把自己的任务装了两次**：`TaskQueue.auto` 预置了 `taskIds: [task.id]`，`startIssueTask` 又 `enqueue` 一次（enqueue 只防「已经在这个队列里」，而此刻任务的 `queueId` 还是 nil）→ `taskIds = ["issue-7","issue-7"]`。泳道从 `taskIds` 渲染，于是**同一张卡片出现两次**、进度 `0/2`、删除确认框说「2 个任务」。现在自动队列从空开始（**成员关系只有 `enqueue` 一个写者**），`enqueue` 自带去重防线，`reindexQueueMembership` 在加载时清掉历史重复项（旧 queues.json 自动修正，无需迁移）。回归：模型 8 项 + 运行器 2 项（含 `tasks(inQueue:).count == 1`）。
> 2. **两处假成功**：任务在表单打开期间被拉起 → `updateManualTask` 拒绝 `.running`，面板却丢弃返回值、报「已更新任务」并关表单（用户输入静默丢失）。现在按返回值说话：失败报「任务已经开始运行，改动没有保存」且**表单保持打开**；队列设置表单同理（队列没了 → 「队列已经不存在，改动没有保存」）；删除任务 / 删除队列被拒也各有明确文案。
> 3. **「取消任务」在两个窗口是死按钮**：任务的 `.running` 早于 `phase = .active`（`.starting` 要跑 git + 建会话 + 发提示词；`.finishing` 要推送 + 开 PR）。`cancelRunning()` 现在返回 `CancelOutcome`：`.starting` 期间**记住**取消请求、会话一建好立刻取消（`cancelRequested` → 在 `applyStart` 里生效）；`.finishing` 回答「已经在收尾，没有可取消的东西了」；两者都在状态行说出来。回归：运行器 +8（含用「异步 perform」新开的 `starting` 窗口与 `finishing` 窗口两个用例——同步 perform 观察不到这两个窗口）。
> 4. **「跳过并继续」接上了界面**：`TasksRunner.skip` 此前是死代码（README / 设计文档却一直承诺它）。失败 / 取消任务的卡片现在带「跳过并继续」，且只在队伍里**还有排队任务**时出现；队列头的 ▶ 在「暂停 + 有失败 + 还有排队」时 tooltip 改为「继续：跳过失败的任务，跑下一个」。顺带：已完成但**没有 PR** 的 issue 任务不再丢掉「评论并关闭」（`canCommentClose` 不该要求 `prUrl != nil`），灰掉的主按钮也带上了原因 tooltip；「评论并关闭」的 OK 按钮在评论为空时禁用（此前是弹窗消失、什么都不做）。
>
> 一条贯穿的规矩：**面板里每一个 `_ = runner?.xxx(...)` 都要么不可能失败，要么把失败说出来**——放弃返回值就是放弃解释，而这四次全是「用户按了、界面当没发生」。

> **实现（2026-09-27 补充 · 批次 2：跑起来之后看得见）**：批次 1 修的是「界面别骗人」，这一批修的是「跑起来之后你根本不知道」。
>
> 1. **活动栏 + Dock**：`ActivityBarButton.showsActivityDot`（角落 6pt 强调色小点，独立于 `setActive` 的「当前面板」高亮）由 `IssueRunnerPanelController.onRunStateChanged` 驱动 —— 面板关着也知道有任务在跑；任务**在后台结束**时 `NSApp.requestUserAttention(.informationalRequest)` 弹一下 Dock 并留角标（`✓` / `!`，聚焦即清），用户主动取消的不打扰。用系统通知要过一道授权，这个不需要。
> 2. **卡片的两条出口**：展开卡片上的「会话：xxx」此前是死文本。现在它旁边是两个图标按钮 —— **打开会话**（`onOpenSession` → `AppDelegate.openDSHSession`，与通道面板同一个桥）与**审查改动**（`onReviewSession` → `setRightPanel(.review)` + `reviewPanel.setActiveSession`）。两者的机器壳层早就有，缺的只是这两个回调；也因此「派活 → 看它干 → 审查改动」这条主循环第一次闭环。
> 3. **运行时钟**：`TaskCardModel` 新增 `runningFor`（`startedAt` 已在持久化里，重载不丢），meta 行第一项显示「已运行 1:05」（超一小时 `h:mm:ss`）。**3 秒定时器的重绘指纹里带上当前这一分钟** —— 否则 `0:59` 会永远停在那里（board 本身没有任何变化，指纹不变就不重绘）。
> 4. **等待中的队列**：同时可以有多个队列是 `.active`（对第二个点「开始」只是把 runner 指过去），界面此前让它们全都显示「活跃」、同时藏起「开始」按钮 —— 一个永远不动的活跃队列。现在 `QueueHeaderModel.isCurrent`（取自 `board.activeQueue()`）决定：真正在跑的那个显示「活跃」，其余显示「等待中」。
> 5. **统计卡跟着筛选走**：`TaskBoard.summary(source:)` / `TasksSummaryModel.build(_:source:)` 与页签用同一个筛选（队列数也只算「含有被显示任务」的队列）。
> 6. **重启之后的说明**：`reconcileAfterRestart` 的结果此前只进 `app.log`，现在面板用状态行说一句「上次运行被中断：N 个任务已标为失败、M 个队列已暂停（不会自动重跑）」。
>
> 仍未做：设计文档 §V2-8 提到的「隐藏已完成队列」筛选（只做了「已完成队列默认折叠成一行」）。

> **实现（2026-09-27 补充 · 批次 2.5：推送策略与会话状态）**：两条「界面在骗人」级别的问题。
>
> 1. **推送策略**：`TaskQueue.auto`/手动队列一律 `push` 的旧行为（以及配套的推送校验）换成**只给会开 PR 的队列推送**：`queueWantsPR = queue.autoPR && env.canOpenPR()`，提示词与 `finish` 共用该判据（代理被明确告知「不要 push」或「要 push」），没开自动 PR 的队列**只本地 commit**、不做任何校验 —— 于是「私有远端没凭据 → 明明干完的活被判成未推送」这类误判在非 PR 队列里**结构上不可能**再发生；PR 队列的校验本身也改成三态（`BranchPushState`），`unknown` 只记日志。
> 2. **会话状态三态**：`TaskBoard` 那边一个 Bool（`sessionRunning`）把「RPC 问不到」和「会话不在列表里」都表达成 false，而 `step()` 把 false 当「任务结束」→ **一次瞬时 RPC 失败就能把正在跑的任务判成已完成**（随后还可能踩上面那条推送误判）。现在 `SessionState { running, idle, unknown, missing }`：`unknown` **什么都不假设**（继续等，日志节流提示）；`missing` 要**连续 `TasksRunner.missingSessionPolls`（10 次 ≈ 30 秒）**才判失败，并且用新的 `tasks.errSessionGone`（「会话已经不在 dsh 里了（被删掉，或 dsh 重启过）——没人知道它做到哪一步」），而不是假装完成。

> **实现（2026-09-27 补充 · 批次 3 / F1-B：跨工作区作业台）**：面板原本只有一个 runner（当前工作区），而每次换工作区都会重建它并跑 `reconcileAfterRestart` —— 于是「在 A 派了任务 → 切到 B → 回 A」看到的是一张「失败 · 上次运行被中断」的卡片，可那个 dsh 会话还在后台跑完、跑完也没人更新它。**「切到别的项目去等」正是任务台存在的意义**，所以这一条按「真的做成作业台」来改。
>
> 1. **`TaskWorkspaceRegistry`（`platforms/macos/src/TasksWorkspaces.swift`，无 AppKit）**：册子上同时有几个工作区 —— **当前的**（UI 显示它的板子）与**任何仍有任务在跑的**（非当前且忙的一直被 tick：会话结束后照常收尾、照常开 PR；空转的非当前工作区被放下，板子在 `.dsh/tasks/` 里，切回去重建）。`step()` 一次 tick 所有在册工作区，并返回「刚刚结束的任务」+ 它属于哪个工作区（供提醒使用）。git 只在工作树内串行，所以**不同工作区并行**是自然语义。
> 2. **对账只做一次**：`makeRunner(path:reconcile:)` 里的 `reconcile` 由注册表给 —— 一个路径在**本次 App 运行里第一次**被加载时为真（此时「盘上写着 running 的任务不可能还在跑」成立），之后重建一律为假。这正是旧行为里「切走再回来 = 任务被判中断 + 队列被平白暂停」的根因。
> 3. **可见性三件套**（跟踪看不见的活只是换一种方式把它藏起来）：活动栏小点 = **任意**工作区在跑（`onRunStateChanged` 用的是注册表的整体忙闲）；面板头部多一个只在「别的工作区有任务在跑」时出现的图标（`tasks.otherWorkspaces`），悬停列「工作区 — 任务标题」，点开是菜单，选中经 `onSelectWorkspace` → `AppDelegate.adoptProjectDirectory`（与项目面板快捷入口同一个重根原语）；任务结束提醒（Dock 弹跳 + 日志）带上工作区名（`onTaskFinished(path:title:ok:)`）。
> 4. **每个工作区自己的一套 env**：`makeEnv(repoRoot:repo:)` 现在按路径探测自己的 GitHub 远端、token 与 `canOpenPR`（推送策略见批次 2.5），因此两个并行 runner 不会互相串味。
>
> 测试（无头，`tests/tasks-panel/runner-tests.swift` 的 `WorkspaceHarness`：按路径分发的假 repo / 假 dsh / 假磁盘）：切走的工作区 runner **原样保留**且任务仍是 running；在另一个工作区这一侧 tick 时它照常结束、`step()` 回报 `(path, title, ok)`；空转后放下，切回去从磁盘重建读到的是**完成态而不是「已中断」**；同一路径本次运行内 `reconcile` 恰好一次（`[true, false]`）；两个工作区并行（各自工作树各有自己的 checkout 与会话）。

> **实现（2026-09-27 补充 · F4：一任务一会话 + 交接简报）**：队列里**每个任务各自一条 dsh 会话**是有意的 —— 上下文小、审查面板按会话审的改动正好对应一张卡片、取消/会话名/「打开会话」都是任务级的。代价是下一棒没有记忆（它只看得到分支上的 commit，看不到上一棒的对话），而把整条队列塞进一个会话会同时失掉上面那几样（审查跨任务、取消变整队、失败会话被下一棒继承）、并让上下文变成不可控变量。于是补的是**交接**，不是共享上下文：
>
> - **`TaskPrompts.QueueBrief`**（`TasksRunner.swift`）：队列名、位次（第 k/n）、前面每一棒的标题与结局（`.done` / `.failed`+失败原因 / `.cancelled`）、**它们在各自会话里的最后一段汇报**、分支上相对基线的提交列表；渲染成提示词里的 `## 队列信息` 段（2026-09-27 起：抬头与**开 PR 会话**的那一段统一，字段顺序也统一 —— 队列 → 分支/基线 → 分支上已有的提交 → 前面任务的汇报；按用户的要求整段放在**所有要求之后**），以「不要重做已完成的部分，只做本任务」收尾。
> - **汇报不截断**：短摘要恰好会丢掉下一棒最需要的东西（决策理由、没做完的事、坑）。代价是简报长度随汇报线性增长 —— 因此 runner 把简报字符数写进 `app.log`（`tasks: brief for <task> is N chars`），长了看得见。
> - **失败 / 被取消的一棒同样进简报**：否则「重试」就是从零重新探索一遍。没有会话记录时写明「它没有留下汇报」，而不是假装无事发生。
> - **数据来源**：core 新增 `sessionReport()`（`core/lib/review-log.js`，取 `assistant/message` 事件里最后一条有文本的消息）+ CLI `ohmy-core brief report <sessionId> [--workspace <dir>] [--dsh-home <dir>]`；壳层通过既有的 `CoreBridge` 调它（与审查面板同一套会话日志解码，含 .zstd）。**简报在后台步骤里构建**（读日志 + 问 git 都是阻塞操作），不进主线程。
> - **第一个任务**：没有「前面已经做过的」；但分支上已有的提交照旧告诉它（队列复用同一分支重跑时，那就是上一轮留下的状态）。issue 任务的自动队列是单任务队列，天然没有简报。
> - 回归：core `core/tests/session-report.test.js`（5 例：取最后一条 / 忽略流式分片 / 没有汇报 / 会话不存在 / 不截断）；运行器新增 5 节用例（第一个任务无前情、第二位带上队列名位次标题汇报提交与「不要重做」、失败的一棒写清原因、超长汇报原样带上、无会话时写明没有汇报）。

> **实现（2026-09-27 补充 · F5 + 超时）**：
>
> 1. **默认基线分支不再假设 `main`**：`TaskQueue.auto` 的 `baseBranch` 一直是 `"main"`（`TasksCore`），而流水线第一步就是 `git checkout <base>`（`TasksRunner.enter`）—— 默认分支是 `master` / `develop` 的仓库，**第一个 issue 任务必然以「切换分支失败」告终**。现在采纳工作区时探测一次（`IssueRunnerPanel.detectDefaultBaseBranch`，git 侧只负责取事实）：推送远端（`github` > `origin` > 首个，复用 `pushRemoteName` 的偏好）的 `HEAD` → 本地 `main` → 本地 `master` → 当前分支 → 兜底 `main`；决策链在 `TaskBranch.defaultBaseBranch(symbolicRef:current:hasMain:hasMaster:)`，**无头可测**（含「`origin/HEAD` 是未解析的悬挂 symref 时不算数」这种坑）。结果同时喂给 runner 的 `env.defaultBaseBranch`（自动队列）与队列表单的 `QueueComposerModel.defaultBaseBranch`（预填「基于分支」、留空回落、占位文案）。
> 2. **超时 30 分钟 → 60 分钟，并且不再隐形**：`TasksRunner` 的默认超时改为 `defaultTimeout = 60 * 60`，面板用 `taskTimeout()` 读壳层设置 `tasksTimeoutMinutes`（5–1440 的整数）覆盖；运行中的卡片把上限写进那一行：「已运行 1:05（上限 60 分钟，到点会取消会话）」—— 到点被取消这件事，不该只能从一张失败卡片上事后得知。

> **实现（2026-09-27 补充 · 「全部处理」不再只管 issue）**：工具栏三个按钮里，「刷新」「配置 GitHub Token」确实是 GitHub 操作，它们在任何非 GitHub 工作区禁用是对的；**「处理」不是** —— 它的语义是「把所有还在等的任务跑起来」，只认 issue 纯属历史原因。现在：
>
> - **每个待处理任务各自一个单任务队列**（`TaskQueue.auto(forManual:)`，与 issue 任务同形：一条分支、一个 PR、`autoCreated`、默认折叠、不进「加入队列」候选）。理由：与 issue 语义对齐（决策 5），**批量不会把互不相干的任务捆到一条分支上**。分支按标题派生（`feature/<slug>`，纯中文标题退回 `feature/manual-<id4>` —— slug 算法只留 ASCII，中文标题因此拿不到拼音），基线用工作区默认分支（见 F5）。
> - **顺序**：按板面顺序（issue 索引先读、手动任务随后）串行推进。每个队列创建时都会 `resumeQueue（→ activeQueueID = 它）`，所以新增 `TasksRunner.focus(onQueue:)` 在批量结束后把 runner 指回第一个 —— 否则「最后创建的那个」会先跑。
> - **不可用当空转**：`nextStartable` 现在会先看 activeQueueID 指向的队列，没有可启动的任务时**落到下一个有活的活跃队列**。此前它会返回 nil 并卡住 —— 一批单任务队列里，除当前那条以外都会显示「活跃」却永远不动（审计里的 N4/U5）。面板侧新增 `TasksRunner.runningQueueID`，`isCurrent` 用它判断，因此真正在跑的那条才标「活跃」。
> - **批量边界**：只收 `.pending`（未入队、从没跑过或回退过）。失败 / 已取消的任务留在原处由卡片的「重试 / 加入队列」处理 —— 把失败历史一起自动重跑，风险大于收益。>1 时先确认（每项都是一条真实会话，各自受队列超时约束），结果写进状态行与 `app.log`。
> - **提示词**：自动队列（issue 的、以及批量给手动任务建的）不再说「与其他任务共享同一分支与改动」—— 它永远不会再收第二个任务；用户自建的队列照旧报自己的名字。判据是 `queue.autoCreated`，不是任务数。
> - **按钮**：`TasksRunAllModel`（纯模型，可无头断言）给出计数、启用条件与 tooltip（含非 GitHub 工作区「只切分支不开 PR」那句）；「处理」移到工具栏**第一位**，并在没有待办时禁用（顺带修掉死点击）。
>   ⚠️ **2026-09-27 修正（按钮不点亮）**：「没有待办时禁用」这句只在 `updateLabels()` 里算过一次 —— 而 `updateLabels()` 是**工作区**事实（adopt / 语言切换）的入口。可用状态是 **board** 的事实，新建任务（正是让「有待办」成立的那件事）走 `syncFromBoard() → render()`，那里只重画列表，于是按钮一直灰着，**直到用户切走再切回来**；`runAllTapped` 自己会重新算 model，所以动作从来没坏，坏的是按钮不肯说自己能用了。现在收成一处 `updateRunAllButton(githubAvailable:)`，由 `updateLabels()`（工作区：git / GitHub 可用性）与 `syncFromBoard()`（board：新建 / 入队 / 开始 / 完成 / 删除）**两个**入口调用 —— 按钮亮灭与列表内容从此由同一张 board 推出。`tests/tasks-panel/run.sh` 增加源码守卫：`syncFromBoard()` 内必须重新推导该按钮。

> **实现（2026-09-27 修正 · 非 git 目录里的「全部处理」）**：`TaskQueue.auto(forManual:)` 一开始无条件从标题派生分支，于是在 `git=no` 的工作区里，批量建的每个队列都带着 `feature/<slug>`，任务全部以 `tasks.errNotGit` 结束 —— 批次 1 定下的 §V2-7 规矩（非 git 目录的队列**不设分支**）被这条新路径绕过了。修正：
>
> - `TaskRunnerEnv.canSwitchBranches`（面板按 `isGitRepo(path)` 给），`TaskQueue.auto(forManual:baseBranch:switchesBranch:opensPR:)` 在不能切分支的目录里给出 `branch: nil`；`autoPR` 同样由 `canOpenPR()` 决定。
> - **就地修复**：`startManualTask` 在非 git 目录里发现「自动队列带着分支」（旧版本建的、或从 git 工作区带过来的）时，先把那条分支去掉并记日志 —— 否则重试与第一次一样失败。
> - **提示词**：非 git 目录里不再要求 commit / push（那是把代理往 `git init` 上引），改为「直接在当前目录修改、不要 git init、不要 commit / push」。
>   ⚠️ **2026-09-27 再次修正**：那句「不要 git init」**管过了界** —— 用户派了一个任务叫「初始化 git 仓库」，提示词却让代理不要做这件事。这条 rail 的本意是**壳层那一半**（管线不切分支、不提交、不推送），不是禁止任务本身；措辞改成「壳层不会切分支、不会提交、不会推送。默认直接在当前目录修改文件即可；**任务本身要求初始化仓库或提交时，照任务做**」，第 4 条同理（「默认不要 commit、不要 push……任务要求建立仓库／提交时才做」）。
> - **任务改了工作区形状之后要重新识别**：面板在 adopt 时定下「这个目录是不是 git 仓库 / 有没有 GitHub 远端」，并把同两个事实交给 runner 的 env；一个 `git init` 任务会让它们全部过期 —— 头部继续说「非 Git 仓库」、队列表单继续不给分支字段、`全部处理` 继续说「不切分支」。现在**任务结束（或该工作区转入空闲）时重新探测**：纯模型 `TaskWorkspaceShape.change(wasGit:hadRemote:isGitNow:hasRemoteNow:)` 判断「变成 git 仓库 / 多了 GitHub 远端」，面板据此 `workspaces.invalidate(path)` + `adoptWorkspace(path)` 重建 runner（**必须重建**：env 里的 `canSwitchBranches` 是建的时候抄下来的），并在状态行说一句。两条纪律：① `invalidate` **不动 `reconciled`** —— 板子还是这次运行的板子，重新对账会把在跑的任务判成「上次运行被中断」；② 只在**该工作区没有任务在跑**时重建，否则两个 runner 会各自 step 同一张板子。回归：视图模型 8 项（四种变化 + 两种不变 + 远端消失不重识别）、注册表 5 项（invalidate 后重建且 `reconcile` 仍为 false）。
> - **空仓库（刚 `git init`）也要能进队列分支**：重新识别一旦生效，紧接着的那个任务就会走**正常**的分支进入序列 —— 而它在空仓库里**必然失败**：`git checkout main` 在 HEAD 未出生时报 `pathspec 'main' did not match`（`errCheckout`），而且 `git init` 之后留下的文件全是未跟踪的，「工作区脏」那条也会先拦住它。`TaskGit.enter` 现在先问一次 `hasCommits()`（`rev-parse --verify --quiet HEAD`）：**空仓库跳过「切基线 / pull / 干净检查」三步，直接用 `checkout -b` 从尚未出生的 HEAD 开分支** —— 空仓库里没有任何提交可以丢，任务的工作自然成为第一个提交。有提交的仓库**完全不变**（回归 6 项：空仓库只做一次 `checkout -b`、既不查 status 也不 pull；普通仓库照旧先查脏、先切基线、再 pull；脏仓库仍然被拦住）。
> - **确认框**：`TasksRunAllModel` 现在收 `gitAvailable`，三种情形分开说 —— git + GitHub「队列跑完开 PR」／git 无 GitHub「只切分支，不开 PR」／非 git 目录「不切分支也不开 PR」。
> - 回归：模型（`switchesBranch: false` → 无分支）、运行器（非 git 目录里批量启动：**一条 git 命令都不跑**、任务照常跑起来；已存在的带分支自动队列在重试时被修好；提示词断言「不要 git init / commit」）、视图模型（非 git 的确认框文案）。

> **实现（2026-09-27 修正 · 提示词按工作区的形状写，并说清两条转换路径）**：`gitAvailable: Bool` 这种二态表达不了用户实际面对的三态 —— **非 git 目录 / git 仓库但没有 GitHub 远端 / GitHub 仓库** —— 而三种状态下同一句 rail 意思完全不同。两个真实症状：① 提示词里的形状是 `makeEnv` 时抄下的，于是一个队列里第一个任务跑了 `git init`（或 `git remote add origin …`）之后，**第二个任务的提示词还在说「这不是 git 仓库」**（队列在自己两项任务之间从不转入空闲，`recheckWorkspaceShape` 的重建被 `isBusy` 挡在门外）；② 「有仓库但没有 GitHub 远端」这一档，rail 4 把「不开 PR」的原因写成「**这个队列没有开自动 PR**」—— 那是队列设置，真因是没有远端，而这时代理唯一有用的那一步（`git remote add origin <url>`）一个字都没提。修正：
>
> - **纯模型 `TaskRepoShape`**（`TasksRunner.swift`，紧邻 `TaskPrompts`）：`.plain` / `.git` / `.github`，`detect(isGit:hasGitHubRemote:)` —— 「不是仓库」压过一切（没有工作树就无从谈远端）。
> - **面板每次写提示词都重新探测**：`IssueRunnerPanel.repoShape(path:)`（一次 `rev-parse --is-inside-work-tree`，是仓库才再问一次 `git remote -v`）在 `promptText` 闭包里调用 —— 那个闭包跑在 runner 的后台队列上，代价不落在 UI 线程，也正是**唯一**能在同一队列的两项任务之间说真话的地方。`pushes` 也跟着改成 `queue.autoPR && shape == .github`（队列的 PR 承诺与工作区事实同时成立才要求 push）。
> - **rail 2** 按 `shape`：`.plain` 只说壳层那一半（不切分支/不提交/不推送，任务要求就照做）；有仓库时照旧点名队列分支。**rail 4** 四种说法：`.plain`「默认不要 commit、不要 push（这里还没有仓库）……要把它变成 GitHub 仓库就是三步：`git init`（若还没建）→ `git remote add origin <GitHub 地址>` → `push`；壳层随后会重新识别这个工作区，后面的任务就能用分支了」；`.git`「commit，但**不要 push**：这个仓库还没有 GitHub 远端，壳层不会开 PR，改动留在本地分支上即可；任务本身要求发布到 GitHub 时，先 `git remote add origin <地址>` 再 push」；`.github && pushes` 与 `.github && !pushes` 两句一字不改（原样）。
> - **回归**：运行器 **323 项**（+9）—— 新增一节「git 仓库但没有 GitHub 远端：说「没有远端」，不说「这个队列没开自动 PR」」（分支照旧点名、真因写成「还没有 GitHub 远端」、不再拿队列设置当理由、给出 `git remote add origin`、远端出现前仍不 push），并反向断言 GitHub 工作区不会念叨「还没有远端」、也不会给出已经不需要的转换步骤；既有「非 git 的提示词」一节补一条「给出转换路径：init → remote add → push」。`tests/tasks-panel/run.sh` 增加**源码守卫**：提示词必须在 `promptText` 闭包里以 `Self.repoShape(path: repoRoot)` 现场探测（禁止再退回 `makeEnv` 抄一份），并保留那个唯一的探测函数。

> **实现（2026-09-27 修正 · 批量收哪些任务）**：`.pending` 起先被当成全部的「待处理」，于是**删除队列之后的失败 / 已取消任务**（它们回到未入队，卡片上只剩「加入队列」）落在批量之外 —— 用户的原话是「失败的还是失败状态，然后就不能通过全部处理来处理了」。现在判据是**归不归队列管**：
>
> - ✓ `.pending`；
> - ✓ 队列已不存在的 `.failed` / `.cancelled`（`queueId` 指向的队列不在册也算：陈旧 id 不会把任务藏起来）—— 批量给它们各建一个新的单任务队列重新跑（`markRunning` 会清掉旧错误）；
> - ✗ 仍在队列里的失败 / 取消任务：泳道自己的「重试 / 跳过并继续」管它们，全局批量不该悄悄复活一个被暂停的队列。
>
> 选择逻辑收在 `TasksRunAllModel.startable(in:)`：面板按它取任务，确认框的计数也来自它 —— 两者不会各说各话。回归：视图模型（队列里 0 个 / 删掉后 2 个、`isStartable` 对陈旧 `queueId` 的判定）+ 运行器（删队列→批量→两条任务各建一个新队列并依次跑完，旧错误被清掉）。

> **实现（2026-09-27 修正 · 建会话与会话归属）**：两处都是「面板自己造了一套」。
>
> 1. **建会话必须走共享实现**：面板曾私有实现 `createSession`，只发 `{workspaceId}`（没有 cwd 回退）。而 `workspaceId` 来自 `DshWorkspaceStore`（持久化文件），**陈旧是常态**（工作区被移除/归档、store 由另一份 DSH_HOME 写过）→ dsh 回 `workspace/not-found` → 该工作区**每个任务**都以 `tasks.errSession` 失败，日志里除了 errSession 什么都没有。现在调用 `DshWorkspaceOps.createSession`（两步：先 workspaceId 让 dsh web 正确分组，被拒则退 cwd —— 与 §4.3 的记录一致，`tests/dsh-rpc` 有用例），并在失败/成功时各记一行 `app.log`。`tests/tasks-panel/run.sh` 加了源码守卫，禁止面板再直接拼 `DshWebRPC.sessionCreate`。
>    实测证据（内置 dsh 0.1.2-rc.1 起在 3099 + `DshWebRPC.swift` 真件）：`{workspaceId:"ws-does-not-exist"}` → `workspace/not-found`；共享实现带同一个陈旧 id → 回退 cwd 成功；老的「只发 workspaceId」写法 → nil。
> 2. **分支归队列所有**：`task.branch` 是开跑时从队列抄下来的记录；`dequeue` / `removeQueue` / `detach` 都不清它，于是「移出队列」后卡片继续显示 `feature/x`。现在离开队列即清（分支是队列的属性），卡片显示顺序改为 `queue?.branch ?? task.branch`（将要用的分支优先），issue 任务的提示词不再用 `task.branch` 兜底。
> 3. **原生 RPC 失败必须留下原因**（`DshWebRPC.lastFailure`）：上面两条修完，用户重跑**仍然**每个任务 `tasks.errSession`，而日志只有一行「建会话失败」——因为 `DshWebRPC.call` 把**四种完全不同的失败**都压成 `nil`：401（没换到 cookie）、端点不存在、业务错误（`workspace/not-found`）、传输层没拿到 HTTP 响应。排查时用同一台 dsh web（同端口、同 token）以 `curl` 与真 Swift 代码请求 `session/create` **全部成功**，说明端口 / token / 载荷 / 服务端都没问题，问题在壳层这一次请求内部——但没有任何东西能说出它是什么。现在每次失败都记一行：`<method> HTTP <status> <error.code> <error.message>`，401 且手里没有 token 时补一句 `no launch token`；成功则清空（失败不会继承上一次的故事）。另外**启动时自检**：装上 launch token 之后在后台跑一次 `session/list`，把结果写进 `app.log`（`native RPC self-test: ok` / `FAILED — <原因>`）——一个被 token 围栏挡住的原生 RPC 从此在**第一秒**就可见，而不是等某个面板「点了没反应」。回归：`tests/dsh-rpc` 固定四种形状（401 无 token / 业务错误带 code+message / 传输失败 `HTTP -1` / 成功清空）。
> 4. **根因：端口被冻结在服务器启动之前**。有了原因，`app.log` 的时间戳立刻说话：**00:51:37.129** `tasks: workspace adopted`（`adoptWorkspace → makeRunner → makeEnv` 在这里读了 `server.port`）→ **00:51:38.563** `using node=… port=64679`（服务器**这时**才选定端口）→ **00:51:43.176** `dsh web is up on http://127.0.0.1:64679/`。建运行器的那一刻 `server.port` 还是默认的 **3080**，而这个值被捕获进 `TaskRunnerEnv` 的五个会话闭包；3080 上跑的恰好是**另一台** dsh web（本仓库的 harness GUI），拿本实例的 token 去换 cookie 只会 401（实测 `GET /?token=<外来 token> → 401`、`POST /api/session/create → 401 unauthorized`）—— 于是 `session/create` 永远 nil。运行器只在**工作区路径变化**时重建，本次启动内它一直打向 3080；同一时刻 `curl` 打真正的 64679 一切正常，这就是「curl 能通、App 不能通」的全部原因。现在端口改成**调用时求值**（`let portOf: () -> Int = serverPortProvider ?? { 3080 }`，`serverPortProvider` 由 main.swift 以 `[weak self] self?.server.port ?? 3080` 注入，不构成保留环），`workspaceId` 也改为建会话时才解析。守卫：`tests/tasks-panel/run.sh` 拒绝 `Self.<session>(` 里再出现冻结端口的形状。教训：**运行器环境里任何"外部世界此刻的值"都必须留成闭包**——面板在服务器就绪前就已经在工作了。

### V2-8 卡片式任务清单

列表改为 `NSScrollView + NSStackView`，体例照 `ProjectsPanel.swift`：`render()` 重建 `arrangedSubviews`，卡片 `widthAnchor == list.widthAnchor - 20`，卡片自身 `draw(_:)` 画圆角 + 描边、`hitTest` 把非按钮区域的点击交回卡片、`resetCursorRects` 设 `pointingHand`。

**组织维度：队列分区**（取代原先设想的按状态分区）：

```
┌ 队列：深色模式改造 ────────────────────────────┐
│ ▾ 深色模式改造   ▸3/5   ● 活跃    ▶  ⋯        │  ← 队列头第一行（名称 + 进度 + 状态 + 操作）
│ feature/dark-mode → main        ▬▬▬▭▭  1 个失败 │  ← 队列头第二行（仅展开时：分支 → 基线 + 进度条）
└────────────────────────────────────────────────┘
  ┌────────────────────────────────────────────┐
  │ [手动] 重构终端面板标题栏的配色逻辑  [队列中 #1] │  ← 标题与状态同一行（来源徽标在左、状态徽标在右）
  │ feature/dark-mode · 会话 session-… · 无 PR   │  ← 元信息（分支 / PR / 会话，可点）
  │ [移出队列] [取消]                            │  ← 主操作行（展开后显示）
  │ ┌ 详情：正文 / 错误 / 时间线 ────────────────┐ │  ← 点卡片 = 展开 / 收起（保留 v1 手感）
  │ └──────────────────────────────────────────┘ │
  └────────────────────────────────────────────┘

┌ 未入队 ────────────────────────────────────────┐
  [Issue #12] 修复暗色模式下…            [处理]     ← issue 任务（自动单任务队列：紧凑一行，与用户队列同一套组件与计数口径）
  [手动] 整理 README 的安装章节   [加入队列 ▾]      ← 手动任务
```

- **队列头**：**第一行**名称 + 进度 `n/m` + 状态徽标（活跃 / 暂停 / 完成）+ 图标操作（开始 / 暂停 / 开 PR / ⋯），**第二行**（仅展开时）分支 → 基线 + 进度条 + 失败数；**所有队列（含 `autoCreated` 的自动单任务队列）都渲染队列头**，与计数口径一致 —— 自动队列因只含一个任务，默认以**紧凑形态**（队列头与卡片合一的一行）呈现，点开即展开为标准形态；
- **来源徽标**：`Issue #N` 与 `手动` —— 需求「创建的任务和 github issue 任务分开标记」的落点之一；工具栏另有来源筛选段控件（全部 / Issue / 手动）；
- **状态徽标**：待处理 / 队列中 #n / 运行中（配小 spinner）/ 已完成 / 失败 / 已取消 / 已关闭；失败 `systemRed`、完成 `systemGreen`（沿用现有语义色）；
- **交互**：点卡片非按钮区域 = 展开 / 收起详情（正文可滚动，长正文不挤走按钮，保留 v1 的 NSTextView 方案）；hover 时卡片底色提亮（`PanelControl.fill(dark:highlighted:)`）并显示行内图标按钮；**移出队列 / 取消 / 重试都不弹模态**，结果回底部状态条（成功 5s 自动清空、失败留到下次操作）；只有「评论并关闭 Issue」保留确认框（会改 GitHub 远端状态）；
- **底部状态条保留**（加载中 / 队列 n/m / 错误回显），compositing trap 的 `wantsLayer + masksToBounds` 写法不变。

**配色纪律**（`docs/ui-color-scheme.md`）：面板根 / header / toolbar / 状态条用 `DynamicFillView()`（`.panel`），卡片底与图标按钮用 `PanelControl.fill(dark:highlighted:)`，**不新写** `calibratedWhite` 灰阶；卡片在 `viewDidChangeEffectiveAppearance` 重绘取色。

**实现备注（2026-09-24，第 6 步）**：

- 分层：`TasksUI.swift` 只放**视图模型**（`TaskCardModel` / `QueueHeaderModel` / `TasksSummaryModel`，纯 Foundation，`tests/tasks-panel` 里 67 项断言钉住「徽标写什么、给哪个按钮、按钮是否可用」），`TaskCardView.swift` 只做渲染与转发点击，面板只做装配 —— UI 规则因此能在没有窗口的环境里回归；
- 交互沿用 v1 手感：**点卡片（非按钮处）= 展开 / 收起**，展开区显示队列 / 会话 / 错误 / 正文与操作行；展开状态记在控制器（`expandedTaskID`），卡片每次重建都不丢；
- **队列头**：`▸/▾` 折叠（用户队列默认展开，issue 自动队列默认折成一行）、名称、`分支 → 基线`、`n/m` 进度、状态徽标（活跃 / 暂停 / 已完成）、失败计数、`开始`/`暂停`/`打开 PR`、`⋯`（重命名 / 改分支 / 完成后自动开 PR 开关 / 删除）；
- **来源筛选**（全部 / Issue / 手动）只影响渲染，不改任务；
- 列表重建用**指纹比对**（任务状态 + PR + 队列状态），3 秒的步进定时器不会打断滚动或关掉已弹出的菜单；
- 视图模型测试当场抓出两处真问题：`shortPR` 原先只认 REST 形式的 URL（web 形式 `github.com/o/r/pull/42` 会原样显示），以及队列**活跃时「开始」按钮仍置真**（视图靠 `canPause` 优先而侥幸掩盖）。

**实现备注（2026-09-25c：抽屉从内容区顶部下拉、图标按钮、更大的输入框）**：

- **抽屉挂在内容区顶部、从上往下滑出**：此前挂在底部会遮住表单自己的按钮（面板一矮就没有余量）；现在宿主仍是透明 + 点击穿透 + `masksToBounds` 的图层（覆盖工具条以下到面板底部），抽屉顶部距内容区顶 8pt，从宿主上边界之外滑入，高度由内容决定并**硬上限 = 内容区高度 − 16**（超出时先压缩描述框：`TaskFormKit.textView` 的高度约束是 .defaultHigh，最小 56pt，再小就滚动——按钮因此永远留在可见区，测试 `form-tests` 用 420/300/260pt 三种面板高度钉住）；
- **两个创建入口是图标按钮**：页签行右侧「＋」= 新建任务、「▣＋」= 新建队列（`CustomIconButton`，24pt，含 hover 与 tooltip），文字标签移到 tooltip；
- **表单不缩小自己，矮面板靠滚动**（2026-09-25e）：抽屉（`TaskFormSheetView`）内嵌滚动视图，抽屉高度 = `idealHeight()` 测得的表单自然高度（宿主每次 `layout()` 重算），上限 = 内容区高度 − 16；超出即滚动，**描述框始终 120pt（最小 88pt）**，因为"表单压缩自己"就是上一版把描述框压到 54pt、无法换行的原因。**不要**用"抽屉高度 == 文档视图高度"的约束：AppKit 会让文档视图不低于 clip 高度，这条链会让上限静默失效（实测 240pt 内容区里塞进 304pt 表单）；
- **抽屉高度 = 纯约束跟随**（2026-09-25k，最终做法）：`TaskFormSheetView.setContent` 内建 `sheet.height == form.height`（@999），面板只负责加"不高于内容区"的上限（required）——没有测量、没有回调、没有常量，表单内部长高在同一个布局回合就撑开抽屉；表单过高时上限生效、表单保持自身高度并内部滚动。前两版（`idealHeight()` 量 frame / `preferredHeight()` + `onHeightChanged` 回调）都因为"frame 只反映上一次布局"而滞后一整拍，已删除；
- **测量按内容而非 frame**（2026-09-25j，已被 25k 取代）：`TaskFormCardView.preferredHeight()` = 内部列栈 `fittingSize.height` + 上内边距 + 下内边距。读 `frame` 会滞后一拍（frame 反映上一次布局，点击后立刻测量得到旧高度 → 抽屉"展开不动、收起才长高"）；上下内边距都要加，否则抽屉比表单矮十几点又会冒滚动条；
- **抽屉必须跟着表单长高**（2026-09-25i）：抽屉高度有两个来源 —— 面板改尺寸（宿主 `layout()` 重测）与**表单内部长高**（高级设置展开、描述框变高）。后者不触发面板布局，因此表单通过 `TaskFormCardView.onHeightChanged` 主动上报，面板重测并**带动画**（0.16s ease-out）撑开抽屉；`presentForm` 与测试都要补一次 `layoutSubtreeIfNeeded()`（测量发生在布局回调里，尺寸下一帧才生效，否则滑入动画会拿旧高度）；
- **高级设置展开后不滚动**（2026-09-25h）：`TaskFormKit.inlineRow` 把分支 / 基于分支改成"标签在左、字段在右"（三行 caption 在上的排法让展开态高达 314pt，超过常见内容区就得滚动），高级设置内部间距 8 → 6，抽屉高度 `ceil` 取整；展开态 **274pt**，实测内容区 600/400/340/300pt 都整表单显示无滚动条，≤260pt 才回落到滚动；
- **抽屉打开时不吃穿透**（2026-09-25g）：宿主（`TaskFormSheetHostView`）的点击策略随状态切换 —— 无表单时点击穿透（否则覆盖内容区的宿主会挡住整个列表），表单打开时整块吞掉（`blocksClicksBelow`，宿主自身收到 `mouseDown` 什么都不做），抽屉背后被点开的任务卡片因此不会再出现；
- **输入框统一自绘框**（2026-09-25f）：`TaskFieldBox`（圆角 6 / 下沉底色 / 发丝边框）同时装单行 `NSTextField`（无 bezel）与描述用的 **`NSTextView`**，样式由构造保证一致。**可编辑 `NSTextField` 不能当多行用**：它的 cell 对任何高度都只报一行（实测 `cellSize(forBounds:)` 恒 30pt），"多行框"实际是加高的单行框 —— 这是用户第二次反馈的直接原因。描述默认 120pt、随输入长高（上限 260pt）后由文本视图内部滚动；文档视图宽度 == clip 宽度、高度 ≥ clip 高度（否则只有第一行可点）；
- **描述框是同款多行框**（2026-09-25d，已被 25f 取代）：`TaskFormKit.textArea` 用 `NSTextField`（`usesSingleLineMode = false` + `cell.wraps`），与单行框同 bezel / controlSize / 字号；默认 120pt，**随输入长高**（`TaskFormKit.textHeight` 按文本与宽度算出；高度约束优先级 999 —— 用 .defaultHigh 会被栈视图的 fitting 约束拉回最小高度，实测只有 56pt、只有第一行可点），面板矮时由抽屉的高度上限压到最小 56pt。**不要**换回 NSTextView；
- **队列表单只问一件事**（2026-09-25d）：`QueueComposerModel.showsAdvanced` 决定「高级设置」（分支 / 基于分支 / PR 开关）是否展开 —— **新建默认折叠**（分支由队列名派生，折叠时用一行「将使用分支：…」说明），**队列设置默认展开**；PR 开关在工作区非 GitHub 仓库时**隐藏**并换成一行说明（`tasks.queue.prUnavailable`），不再给出灰掉点不动的勾选框；
- **输入框放大 + 撑满表单**：单行框 `controlSize = .large` + `roundedBezel`、高度 30pt、字号 13pt；描述框默认 120pt（`textContainerInset` 6/8）、字号 13pt、**按可见宽度换行**；表单内边距 16、说明行最多两行（避免表单高度随文案膨胀）。**每一行都必须钉到表单宽度**（`TaskFormKit.stretch`，按钮行除外）：垂直栈 .leading 对齐下每行本来贴合自己的内容宽度，而**空文本框的固有宽度几乎为 0**，于是输入框塌到标题的宽度 —— 实测只有约 25pt、placeholder 被截成一个字。回归断言："输入框宽度 > 300pt（360pt 面板）"、"描述框与其同宽（±12pt）"、"面板变宽输入框跟着变宽"。

**实现备注（2026-09-25b：抽屉 + 页签行按钮 + 队列容器）**：

- **表单是抽屉，不再占据列表**（决策 9 修订）：两张表单（新建·编辑任务 / 新建·设置队列）由 `TaskInlineForms.swift` 提供内容，面板用 `TaskFormSheetView` + `TaskFormSheetHostView` 把它作为**内容区顶部的下拉抽屉**呈现（2026-09-25c 由底部改为顶部，见上）；`完成` / Esc / 取消收起并卸载内容，提交（连续录入）只是替换内容、不重播动画，焦点等抽屉到位后再给；
- **两个创建入口在页签行右侧**：「＋」（新建任务）与「▣＋」（新建队列）图标按钮，与来源筛选同处一行、右对齐；面板头的 `+` 与队列分区头的「新建队列」随之删除（同一动作只留一个入口，空态仍给「新建任务」按钮）；页签条对小宽度让位（`SkillTabStrip.setCompressible`），按钮自身不压缩 —— 窄面板下先截断页签，不把行撑出面板；
- **队列是一块容器**（决策 11）：`TaskQueueBlockView` 按审计面板的树体例画泳道 —— 泳道用**下沉档**底色（`PanelControl.fill(highlighted: true)`）、边框随队列状态着色，队列头贴泳道内边距（10），队内卡片**再向内缩进一层**（18 / 12）并保持**抬起档**底色（`highlighted: false`）。两层底色 + 两层缩进让"队列包含任务"成为几何事实，而不是两块相邻卡片；
- **创建/编辑一律不走对话框**（决策 9）：字段值、提示与可提交状态仍来自 `TaskComposerModel` / `QueueComposerModel`（`TasksUI.swift`，纯 Foundation），视图只摆放控件、转发输入；新建任务**提交后抽屉保持打开并清空**（连续录入），编辑保存后关闭；问题提示只在**按过提交**（按钮禁用时按 Enter）后出现，不边打字边报错；**只保留破坏性操作的确认框**（删除任务/队列、评论并关闭 issue）；
- **列表宽度**：卡片/队列头此前**没有宽度约束**（垂直栈 leading 对齐 → 每个视图各自贴合自身固有宽度），`+` 之后才暴露；现在统一由 `addCard(_:)` 打上 `widthAnchor == listStack.widthAnchor - 20`（ProjectsPanel 体例），并保证**卡片内部不得反向撑宽列表**：动作行只在主操作上留文字按钮、编辑/删除改 22pt 图标按钮（`pencil` / `trash`），队列头的开始/暂停/开 PR/更多 同样改图标按钮，文本与徽标压缩阻力降档 —— 窄面板下截断而不是把列表撑宽（`tests/tasks-panel/form-tests.swift` 断言 320pt 宽下卡片与队列头都恰好等于该宽度）；
- **样式**：卡片圆角 7→8、描边对齐 `SkillCardView`（深 0.38@0.7 / 浅 0.82）、展开态与运行态各一档强调边框、hover 提亮（tracking area）；标题 12→13 semibold、元信息 10→11；队列头改成 `SessionTitleBar` 体例（**不透明** highlighted 填充，去掉旧的「highlighted + alpha 0.55」半透明卡）、补 `viewDidChangeEffectiveAppearance`、两行结构（名称 + 状态徽标 + 图标按钮 / 分支 → 基线 + 进度条 + `n/m` + 失败数）；分区头 12pt bold + 右侧发丝线（队列分区头右侧带「新建队列」）；工具栏拆两行（28pt 工作区 + 计数胶囊 / 30pt 扁平页签筛选，复用技能面板的 `SkillTabStrip`）；空态改成图标 + 文案 + **「新建任务」按钮**（三态：无任务 / 筛选为空 / 非 GitHub 工作区）；`listDocument` 补齐 leading/top 钉接（此前只钉了宽度）。

### V2-7b 「加入队列 ▾」下拉对齐文件面板（2026-09-26）

卡片上的 加入队列 此前是一个**普通 NSButton**（点了就执行），菜单还用 `popUp(at: NSPoint(x: 0, y: view.bounds.height), in: card)` 锚在**卡片左上角** —— 列表弹出来正好盖住卡片自己，按钮上也看不出这里有个下拉。

- **控件换成壳层的 `PanelMenuButton`**（`PreviewPanel.swift`，正是文件面板「打开项目 ▾」用的那一个）：图标 + 文案 + chevron，hover 与菜单打开时整块高亮，宽度不够时自动退化成「图标 + chevron」小片 —— 两个面板因此是**同一个下拉控件**，不是"看起来像"；
- **菜单落在按钮正下方**：`popUp(positioning: nil, at: NSPoint(x: 0, y: -6), in: button)`（与 `FilePanel.popBelow` 同一写法），锚点是按钮而不是卡片；按钮在卡片底部、空间不够时由 AppKit 自行上翻；
- **新建队列排第一**：下拉项由新的纯模型 `QueuePickerItem.build(choices)` 生成 —— 第一项固定是 `tasks.queue.new`（新建队列…），随后才是按创建顺序排的已有队列（行里带该队列的分支）；空 board 时下拉里就只有这一项。面板只负责把行变成 `NSMenuItem`（第一项后面补一条分隔线）。顺序规则因此在无头测试里钉住；
- 顺带：卡片 `hitTest` 放行 `PanelMenuButton`（它不是 NSButton，否则点击会被卡片吞掉去展开/收起）；`primaryTapped` 不再需要 `canQueue` 分支。

回归：`tests/tasks-panel` 视图阶段断言「手动未入队卡片只有一个下拉控件、文案是 加入队列、onShowMenu 把按钮自己交给面板」与「已入队卡片的主操作是普通 NSButton、没有下拉」；视图模型阶段断言下拉顺序（新建队列第一 / 已有队列按创建顺序 / 空 board 只有一项）。

### V2-7c 队列头：三个操作从 ⋯ 里放出来（2026-09-26）

队列头此前把 **队列设置 / 完成后自动开 PR / 删除队列** 藏在一个 `⋯` 里，而且那个菜单在**非 GitHub 工作区**照样给出「完成后自动创建 PR」并可点 —— 建了也开不出 PR（队列表单里的 PR 开关本来就是「不是 GitHub 仓库就整块隐藏」，两处规则不一致）。

- **三个操作各自成为行上的图标按钮**（顺序：开始/暂停 · 打开 PR · 自动开 PR · 设置 · 删除）：`gearshape` = 队列设置（内联表单）、`trash` = 删除队列（仍走确认框）、自动开 PR 是 `checkmark.circle.fill`（开，强调色）/ `circle`（关）。`⋯` 与其菜单整体删除，`tasks.queue.more` 文案键一并删掉 —— 审计面板的方块也没有溢出菜单，操作一律摆在行上；
- **自动开 PR 的可用性跟着工作区走**：`QueueHeaderModel.prAvailable`（= 面板的 `repo != nil`，与队列表单同一个判据）。不可用时：**还没开**的队列整块不显示开关（死按钮比没有更糟）；**已经开着**的队列（在别的 GitHub 工作区建的）仍然显示，但**不可点**，tooltip 指向 `tasks.queue.prUnavailable` 说明原因 —— 状态不会被藏起来。`canOpenPR` 同样要求 `prAvailable`，非 GitHub 工作区不会再出现「打开 PR」；
- 开关的"开着"用**常驻图标色**表达：`CustomIconButton` 新增 `tintColor: NSColor?`（nil = 原行为），开着时给 `controlAccentColor`；
- tooltip 文案随之改成状态式：`tasks.queue.autoPROn`（已开启，点一下关闭）/ `tasks.queue.autoPROff`（已关闭，点一下开启）；`tasks.queue.settings` / `tasks.queue.delete` 从菜单标题改成 tooltip 措辞（去掉省略号）。

回归：视图模型断言 `prAvailable` 三态（可点 / 不显示 / 显示但不可点）与 `canOpenPR` 的门槛；视图断言行上有 `gearshape` + `trash`、没有 `ellipsis`、开关图标随状态切换、非 GitHub 时开关不出现（已开则禁用），以及**面板最小宽度 300pt 下所有按钮仍在行内、队列名仍可用**。

### V2-7d 抽屉背后加一层虚化（2026-09-26）

抽屉（表单）和内容区用的是**同一套面板底色**（`PanelControl` 的抬起档 + 发丝描边），所以表单打开时看起来只是"列表里多了一张卡"，层次分不出来。现在 `TaskFormSheetHostView` 里加了一层**虚化背景**：

- `NSVisualEffectView`，`material = .hudWindow` + `blendingMode = .withinWindow` + `state = .active`：`.withinWindow` 模糊的是**同一窗口里它背后的内容**（不需要窗口透明），`.hudWindow` 再叠一层**半透明暗色** —— 即使某个环境下模糊不生效，列表也照样被压到后面（不会退化成"什么都看不见"）；
- **铺满整个内容区**（钉住宿主的四边），**加在抽屉之下、列表之上**（构造时先 add，面板后挂的表单自然在它上面）；
- **与抽屉同时进出**：`presentForm` 里 `showScrim()` 后与抽屉同一个 `NSAnimationContext` 组内把 alpha 淡入到 1（`easeOut 0.22s`），`dismissForm` 里跟着淡出、动画结束再 `hideScrim()`；连续创建（表单已开）时直接把 alpha 置 1，不重播；
- **静止时不占位、不挡点击**：没有表单时 `isHidden = true`，宿主本来就点击穿透（`blocksClicksBelow == false` → `hitTest` 交回列表）；表单打开时宿主吞掉点击，虚化层也在宿主之内，所以点它不会落到背后的卡片上。

回归：视图断言「静止时虚化层不出现」「材质/混合方式就是 `.hudWindow` + `.withinWindow`」「打开后铺满内容区」「虚化层在抽屉之下、抽屉在它之上」「关闭后收起并回到全透明」。

注：虚化本身由窗口合成器绘制，**离屏 `cacheDisplay` 渲染不出来**（截图里这一层是透明的），所以视觉上以真机 App 为准；上面这些断言钉的是接线与层级。

### V2-8a 队列总览与计数

「有几个队列、每个队列什么状态、队列下哪些任务什么状态」由三层一起回答：

| 层 | 内容 |
|---|---|
| **统计信息卡**（内容区第一行） | 一整行圆角卡片里的四个计数（队列 12 · 排队 5 · 运行 1 · 失败 1），**失败 > 0 时那一段才变红**（审查面板摘要卡的体例，见 V2-8m）；工具栏第一行只留工作区名，第二行是来源筛选**扁平页签**（全部 / Issue / 手动） |
| **队列区块**（每个队列一块） | **队列头**：名称 + 分支（`feature/dark-mode → main`）+ 进度 `1/3` + 状态（活跃 / 暂停 / 已完成）+ 操作（开始 / 暂停 / 开 PR / ⋯ 改名·改分支·归档·删除）；**队内任务卡片**按 FIFO 排列，带队内序号 `#2` 与状态徽标 |
| **未入队区** | 列表末尾，标题带计数 `未入队 (7)` |

```
┌ 任务 ────────────────────────────── ⟳  +  ⚙  ✕ ┐
│ honghe/order-service   队列 12 · 排队 5 · 运行 1 · 失败 1   [全部|Issue|手动] │
├──────────────────────────────────────────────────┤
│ ▾ 深色模式改造   feature/dark-mode → main   ▶1/3   [开始][暂停][⋯] │
│     ● [手动] 重构终端标题栏配色            运行中                │
│     ○ [手动] 补齐深色下的图标资源          队列中 #2             │
│ ▸ 支付重构       feature/pay-refactor → main  ▶2/4  [开始][暂停][⋯] │
│ ▸ 文档整理       docs/cleanup → main       ⏸ 暂停 · 1 个失败  [开始][跳过] │
│ ▸ Issue #12      fix/issue-12 → main       ✓ 已完成              │
├──────────────────────────────────────────────────┤
│ 未入队 (7)                                        │
│   [Issue #34] 修复暗色模式下…             [处理]     │
│   [手动] 整理 README 安装章节         [加入队列 ▾]   │
└──────────────────────────────────────────────────┘
```

- **计数口径（决策 8）**：摘要条统计**所有**队列，含 issue 任务的自动单任务队列（行为一致）；自动队列不额外占用版面 —— 以「队列头与卡片合一的一行」呈现，点开即展开为标准形态（队列头 + 卡片）；
- **折叠**：点队列头整体折叠 / 展开（记住状态）；「已完成」的队列默认折叠为一行；工具栏另给「隐藏已完成队列」筛选；
- **失败两级可见**：队列头汇总 `1 个失败`，队内失败卡片自身标 `失败`；暂停的队列头给「开始 / 跳过」；
- **空态**：一个队列都没有时显示引导「在任务卡片上点『加入队列 ▾ → 新建队列…』创建第一个队列」。

### V2-7a 任务创建改成单框输入（2026-09-26）

表单从「标题 + 描述」两个字段收成一个内容框，切分规则在**模型层**（`TaskDraft`，纯 Foundation，可无头回归）：

| 输入 | 结果 |
|---|---|
| `Polish README` | 标题 = 描述 = `Polish README` |
| `Polish README\ntidy it up\nrerun tests` | 标题 = `Polish README`；描述 = `tidy it up\nrerun tests` |
| `Polish README\n\n  ` | 标题 = 描述 = `Polish README`（非首行全是空白 = 单行） |
| `   ` | 报 `tasks.errName`（**只有标题是必填的**：描述总能回落到标题） |

- `TaskDraft.composed(from:)` 拆框、`TaskDraft.combined(title:body:)` 是它的逆运算（编辑回填成同一个框；**描述 == 标题时回到单行**，不会出现同一句话写两遍）；`effectiveBody` 让「留空的描述」在存储层自动变成标题，于是 `createManualTask` / `updateManualTask` 写进 board 的任务永远带着一段可发给代理的正文；
- **不重复**：单行任务的描述就是标题，通用提示词（`TaskRunnerEnv.manual`）与卡片详情都不再把同一句话打印两遍；
- 视图：`TaskComposerView` 只剩一个多行编辑器（`TaskFormKit.textArea`，默认 160pt、随输入长高、上限 260pt 后内部滚动），占位文案即规则（`tasks.new.contentHint`），信息行给一句话摘要 + 快捷键；
- **Enter 不再提交**（首行/其余行都靠它换行）——**⌘↩ 提交**、Esc 关闭；提交按钮的禁用/可用状态与提示行逻辑不变；
- 删除的文案键：`tasks.new.name` / `tasks.new.nameHint` / `tasks.new.body` / `tasks.new.bodyHint` / `tasks.errBody`（描述不再是必填的独立字段）；
- 回归：`tests/tasks-panel` 四阶段 **562 项**（新增 composed/combined/effectiveBody 的拆行与往返、单行任务的存储与提示词不重复、编辑回填单行、空框报错、`type()` 单框输入助手），视图阶段改成对同一个编辑器的尺寸/长高断言。

### V2-8m 布局对齐审查面板（2026-09-25）

任务面板的骨架**逐层照审查面板（`ReviewPanel.swift`）**重排，两处偏离被显式否掉：工具栏仍是**两行**（只把计数胶囊移出），统计信息是**纯文字卡**而不是彩色胶囊。

| 位置 | 审查面板 | 任务面板（改后） |
|---|---|---|
| 顶 1 | `HeaderLabel` 标题 + 右侧图标按钮（刷新 / 关闭） | 不变：任务 + 刷新 / 全部运行 / 配置 / 关闭 |
| 顶 2 | **单行**工具栏（28pt，控件靠左、筛选靠右，底部发丝线） | **两行**：28pt 工作区名（`honghe/order-service`）/ 32pt 来源页签 + 新建任务·新建队列图标按钮；底线保留 |
| 内容 1 | `makeSummaryCard()`：整宽圆角卡 + 一行文字统计 | `TaskSummaryCardView`：同一体例（`PanelControl.fill` 抬起档 + 发丝描边 + 11pt 文字 + 12/9 内边距），一行 `队列 12 · 排队 5 · 运行 1 · 失败 1` |
| 内容 2 | 树：块（标题 + 状态在**同一行**）→ 子块缩进 | 队列（泳道块）→ 任务卡（缩进）**标题与状态同一行** |

- **计数从工具栏搬进内容区**：四枚胶囊不再占工具栏第一行，改由 `TaskSummaryCardView` 渲染，位置是 `listStack` 的**第一行**（`render()` 里第 0 步，先于「队列 (n)」分区头）——与审查面板的摘要卡一样随列表滚动。卡片**只要有 board 就显示**（全 0 也显示：它是"这个工作区有几条队列/几个任务"的答案），没有 runner（工作区解析为空）时整块不出现；
- **失败徽标才变色**：文字按 `TaskSummaryPart.tone` 分段着色（中性 = `secondaryLabelColor`，失败 > 0 = `systemRed`），分隔符 `·` 用 `tertiaryLabelColor`；模型仍是纯 Foundation（`TasksSummaryModel.parts`），着色规则在视图层；
- **标题与状态同一行**（`TaskCardView.build`）：`[来源徽标] 标题 [spacer] 状态徽标` 一行，栈对齐用 `.top` 而**不是** `.centerY` —— 标题允许折到 2 行（展开态不限），`.top` 让徽标贴在**首行**；`.centerY` 会把两枚徽标浮在两行文字中间（实测 2 行标题下徽标顶比标题顶低 8pt）。徽标压缩阻力置 `required`、标题降档，窄面板下先截断标题（tooltip 给全文）；
- **队列头**：名称 + 进度 + 状态徽标本就在同一行（`.centerY`，名称单行截断），保持不动；只有分支 / 进度条 / 失败数在第二行且**仅展开时**出现——折叠态仍是一行；
- **语言切换重建列表**：卡片与摘要卡的文案在构建时取 `L10n`，`refreshTooltips()` 现在除了刷新工具栏 tooltip，还会在**有 board 时重跑 `render()`**（此前只重建工具栏胶囊，卡片文案会停在旧语言）；
- **徽标固有宽度修正**：`TaskBadgeView.intrinsicContentSize` 此前返回的是**裸标签**尺寸（少算 6pt × 2 内边距），任何按固有宽度排布的徽标都会被裁字 —— 实测「队列中 #2」渲染成「队列中 #」、`手动` 渲染成「手」。同一行排布下这尤其扎眼，因此一并修正（固有宽度 = 标签 + 12 / 4）；
- 顺带清掉不再被引用的 `tasks.summary` 文案键（计数由 `tasks.stat.*` 逐段拼出），并把卡片/泳道/摘要卡共用的两条发丝灰度收进 `TaskInk`；
- 回归断言（`tests/tasks-panel`，视图阶段 117 项、视图模型阶段 130 项）：摘要卡"撑满宽度 / 一行 / 每个计数都在 / 零失败中性、有失败变红"；任务卡"来源徽标在标题左、状态徽标在标题右、两枚徽标都落在标题首行的高度带里"（`descendants(_:of:)` 走查 + 坐标换算，`.centerY` 会被这条抓住）；徽标"固有宽度 = 标签 + 12pt 内边距"（截断回归）。

### V2-8n 卡片样式对齐审计面板（2026-09-25）

V2-8m 对齐的是**布局**，这一版把**样式**也对齐到同一套方块语法（`ReviewPanel.makeBlock`）：

| 元素 | 审计面板 | 任务面板（改后） |
|---|---|---|
| 圆角 | 8 | 8（不变） |
| 描边 | 一条发丝线（`ReviewInk.hairline`：浅 0.80 / 深 0.38@0.7），**不随状态变色** | 同一条（`TaskInk.hairline`）—— 泳道不再按队列状态染边（活跃/失败/完成只体现在徽标里），卡片不再有展开态强调边 |
| 底色 | **按嵌套层级**：会话/对话 = 抬起档（`PanelControl normal`），文件（最内层）= 下沉档（highlight） | 同规则：**队列泳道 = 抬起档**、**队内任务卡 = 下沉档**、未入队卡片（直接站在面板上，没有容器）= 抬起档（`TaskCardModel.isNested`） |
| 唯一的强调色 | dsh web 当前会话：accent 淡填充（浅 0.20 / 深 0.40）+ accent 边框（0.45/0.55）+ accent 标题 | 运行中的任务卡：同一套 accent 淡填充 + accent 边框（这张卡的标题保持常规色，运行语义另有实心徽标） |
| 展开指示 | chevron 符号（`chevron.right` / `chevron.down`，11pt semibold，tertiary），14pt 槽位 | 卡片与队列头都用同一个符号（此前队列头是文本 `▸/▾` 字符、卡片没有 chevron） |
| 头部行内边距 | 8 左右 / 7 上下；子级缩进 12 / 10，间距 6 | 卡片与队列头统一 8/7；泳道子卡片缩进 12/10、上 6 下 8 |
| 标题下的次要行 | 10pt `tertiaryLabelColor`（会话的 id/时间/体积、对话的 prompt） | 任务卡的元信息行（标签 · 分支 · PR）同为 10pt tertiary |
| hover | 没有 | **去掉**（卡片不再随鼠标改底色），只保留手型光标与点击展开 —— 底色档位现在只表达层级，不表达交互状态 |

**刻意保留的差异**（这些是任务面板自己的语义，硬套会丢信息）：

- 标题行里保留**来源/状态徽标**（审计面板在同一槽位放的是等宽 10pt 的 trailing 摘要）；
- 队内卡片保留**展开后的详情区与操作按钮行**（审计的文件块下面是 diff 正文）；
- 队内失败 / 暂停等状态仍然只由徽标表达，不再染卡片或泳道的边框。

**验证**：离屏渲染浅色 + 深色两版，把审计面板的方块（`ReviewPanel.makeBlock` 参数复刻）与队列泳道/任务卡并排比对（`/tmp/card-style-light.png`、`/tmp/card-style-dark.png`）；`tests/tasks-panel` 四阶段 529 项（新增 `isNested` 两问、泳道高度断言改成相对断言）。

### V2-9 L10n（中英成对，`main.swift` 的 `L10n.table`）

修改：`tasks.configInfo`（去掉钥匙串措辞，改为文件口径）。

新增（示意，实现时以 `L10n.table` 为准，`tests/l10n/run.sh` 兜住漏配）：

- 来源与筛选：`tasks.source.github`、`tasks.source.manual`、`tasks.filter.all` / `.github` / `.manual`；
- 队列：`tasks.queue.add`（**加入队列** —— 手动未入队卡片的主按钮，`TaskCardModel.primaryKey` 里**当数据**传给视图；2026-09-26 才补进表，漏配期间一直以原始 key 显示）、`tasks.queue.remove`、`tasks.queue.new` / `.newTitle` / `.newInfo` / `.newButton` / `.create` / `.createOnly`、`tasks.queue.name` / `.nameHint`、`tasks.queue.branch` / `.base` / `.baseHint` / `.branchAuto` / `.branchWillUse` / `.branchPlaceholderCreate` / `.branchPlaceholderEdit` / `.noBranch`、`tasks.queue.start` / `.pause` / `.openPR` / `.more` / `.settings` / `.autoPR` / `.advanced` / `.delete`、`tasks.queue.failedCount`、`tasks.queue.editTitle` / `.editInfo` / `.updated`、`tasks.queue.prUnavailable` / `.prTitle` / `.prBody` / `.createPR` / `.creatingPR`；
- 队列总览：`tasks.queue.state.active` / `.paused` / `.finished`、`tasks.section.queues`（队列 (%d)）、`tasks.section.unqueued`（未入队 (%d)）；
- 状态：`tasks.state.queued`、`tasks.state.interrupted`、`tasks.sec.dirtyTree`（工作区有未提交改动）、`tasks.sec.noRemote`、`tasks.sec.prUnavailable`、`tasks.sec.branchPushedNoPR`；
- 手动任务：`tasks.new.title`、`tasks.new.content`（**任务内容**，唯一输入框的标题）、`tasks.new.contentHint`（占位文案说明「首行是标题、其余行是描述」）、`tasks.new.create`、`tasks.new.save`、`tasks.new.done`、`tasks.new.editTitle`、`tasks.new.editInfo`、`tasks.errName`（空框时唯一的报错）、`tasks.prompt.*`（通用提示词模板）；队列内联表单：`tasks.queue.settings`、`tasks.queue.editTitle`、`tasks.queue.editInfo`、`tasks.queue.nameHint`、`tasks.queue.baseHint`、`tasks.queue.branchWillUse`、`tasks.queue.prUnavailable`、`tasks.queue.createOnly`、`tasks.queue.created`、`tasks.queue.updated`；统计卡逐段计数：`tasks.stat.queues` / `.queued` / `.running` / `.failed`（V2-8m 之前的合并键 `tasks.summary` 已删除）。v1 遗留的 `tasks.queue.rename` / `.renameInfo` / `.changeBranch` / `.branchInfo` 被「队列设置」内联表单取代，已删除；
- 详情与错误：`tasks.detailSession`、`tasks.detailSource`、`tasks.detailQueue`、`tasks.errInterrupted`、`tasks.errNotGit`、`tasks.errCheckout`。

### V2-10 测试与 CI

新增 `tests/tasks-panel/`（无头，体例照 `tests/projects-panel/`：`stubs.swift` + `stubs-ui.swift` + `run.sh` + 若干 `*-tests.swift`）。**四个阶段全绿（2026-09-25：模型 126 + 运行器 154 + 视图模型 128 + 视图 95 = 503 项）**，已登记进 `scripts/local-ci.sh` 的 `stage_swift` 与 `.github/workflows/ci.yml`：

1. **队列模型（本次重点，模型先行）**：入队顺序与 `order` 编号、重复入队幂等、移出后回 `pending`、队首推进、队列内失败 → 队列暂停（后续任务仍 queued）、跳过并继续、切队列的干净检查（脏工作区拒绝启动）、队列完成态与 `autoPR` 能力降级、自动单任务队列的创建与重试复用；
2. **模型与持久化**：TaskItem / Queue 编解码往返；`index.json` 旧格式兼容（无 `source` 视为 github、无 id 用 `issue-N`）；`manual.json` 增删改查；`queues.json` 读写；**`local.json` sessions 换键兼容**（数字键 ↔ `issue-N`）；坏文件不崩溃且不删除；
3. **token 解析**：临时 `DSH_HOME` 下「专属文件 → 通用文件 → nil」三级；保存写文件且权限 `0600`；空值删文件；断言实现里不再有钥匙串路径；
4. **卡片视图模型**：给定 TaskItem / Queue → 断言标题、来源徽标、状态徽标、队列头文案与进度、主操作标题与可用性（把 `primaryActionTitle` 一类纯函数抽出来覆盖 queued / interrupted / manual / 队列暂停等新分支）；
5. **队列运行器**（已落地，`runner-tests.swift` 108 项）：假 git + 假 dsh 驱动全流水线 —— 分支进入（clean 检查 → checkout base → pull → checkout[-b]）、入队即激活队列、全局串行（第二个队列不许并发）、队内第二项不切分支、**队列级 PR 只在最后一项收尾且复用已有 PR**、失败各档（脏工作区 / checkout / pull / 建会话 / 提示词 / 未推送 / 超时）都暂停队列、取消 / 重试 / 跳过并继续、重启恢复不自动开跑、issue 任务自动单任务队列与重试复用。

同步：扩展 `core/tests/tasks.test.js`（manual / queue / sessions 换键）；把 `tests/tasks-panel/run.sh` **同时**登记进 `scripts/local-ci.sh` 的 `stage_swift` 与 `.github/workflows/ci.yml`（两处清单必须一致）。

QA 钩子：`DSH_TASKS_TEST=1` 启动即开面板；`DSH_PANEL_TEST=` 全量核对串已含 `tasks`；`--ui-debug` 下 `setRightPanel` 落 `panel-tasks-debug.png`。

### V2-11 实施拆分（模型先行）

> **进度**：第 1 步（token 只从文件读取）已完成 —— commit `0a8f535`；第 6 步（卡片式任务清单）已完成 —— `TasksUI.swift`（视图模型：徽标 / 元信息 / 主操作 / 队列头 / 摘要，**无头可断言**）+ `TaskCardView.swift`（卡片 + 队列头 + 徽标渲染）+ 面板列表（`NSScrollView + NSStackView`，队列分区、未入队区、来源筛选、新建/编辑任务表单、新建队列表单、「加入队列 ▾」菜单、队列 ⋯ 菜单）；第 5 步（issue 任务改走自动单任务队列 / 面板接运行器）已完成 —— 面板删除 `startTask`/`pollSession`/`openPR`/`finishCurrentTask`/`gitCheckoutBranch`/`gitBranchPushed`/`issueFixPrompt` 与 Swift 版 `TaskIndex`，行模型换成 `TaskItem`，执行全部经 `TasksRunner`（3s 定时 `step()`、`updateBoard` 合并 issues、`syncFromBoard` 渲染、`findExistingPR` 复用）；第 4 步（手动创建任务）已完成 —— `TaskDraft`（校验，L10n 键 `tasks.errName`；**2026-09-26 起表单收成一个框**，见 §V2-7a）/ `QueueChoice`（**只列用户队列**，issue 自动队列不是目的地）/ 运行器 `createManualTask` · `updateManualTask` · `deleteManualTask`（运行中拒绝删除，删除即退出所有队列并清掉本机 session），UI 表单留到第 6 步；第 2 步（队列模型 + 四文件持久化）已完成 —— `TasksCore.swift` / `TasksStore.swift` + `core/lib/tasks.js` 同步 + `tests/tasks-panel/`（126 项）；第 3 步（队列运行器）已完成 —— `TasksRunner.swift`（含 git 三步显式检查 / 全局串行 / 失败暂停 / 队列级 PR 复用 / 取消·重试·跳过 / 重启恢复）+ `runner-tests.swift`（108 项）。

1. `refactor(tasks): GitHub token 只从文件读取（移除 Keychain 读写）` —— 独立、低风险，先落；含 L10n 文案与 README；
2. `feat(tasks-core): 队列模型与四文件持久化` —— `TaskItem` / `Queue` / `QueueStore` / `TaskStore` + `core/lib/tasks.js` 同步 + 无头单测（**模型先行，跑通后再接执行器**）；
3. `feat(tasks): 队列运行器` —— 全局串行、活动队列、失败暂停队列、切队列干净检查、显式 checkout 三步、重启恢复；
4. `feat(tasks): 手动创建任务` —— 表单（含队列选择 / 新建队列）+ 通用提示词；
5. `refactor(tasks): issue 任务改走自动单任务队列` —— 行为与 v1 逐条对齐（分支名、PR、评论关闭不变）；
6. `refactor(tasks): 任务清单改卡片式 UI` —— 队列分区 + 未入队区 + 自动队列折叠 + hover / 展开；
7. `test(tasks): tests/tasks-panel 无头套件 + CI 登记`，`docs: 本文档、README、.dsh/wiki` 同步 —— 已完成（三阶段 347 项；本文件、README、CONTRIBUTING、`.dsh/wiki/tasks.md` 与 `modules/issue-runner-panel.md` 同步；另补 `.gitignore` 的 `manual.json` / `queues.json`、清掉 9 个 v1 遗留 L10n 键）。

分支：`feature/tasks-manual-queue`（本仓库规范：不在 main 上开发，合并走 PR）。

### V2-12 风险与边界

| 风险 / 场景 | 处置 |
|---|---|
| 旧钥匙串里的 token 失效 | 面板文案 + README / wiki 写明「请重新填写一次」；面板保存一直是双写，绝大多数用户不受影响 |
| `local.json` 换键 | 读侧兼容纯数字键（视作 `issue-<N>`），历史文件零迁移 |
| 工作区不是 git 目录 | 「+」置灰 + 状态条说明（没有分支可切、没有会话 cwd） |
| 工作区不是 GitHub 仓库 / 公司内部仓库 | 手动任务与队列照常可用；PR 能力自动关闭、相关操作隐藏；issue 区显示原有空态 |
| 队列共享分支 + 失败 | 暂停队列，绝不基于半成品继续；卡片给「重试 / 跳过并继续」 |
| 同一分支重复开 PR | 先 `GET /pulls?head=` 复用已有 PR，避免 422 |
| 队列与手动任务存本机，换机器 / 换 clone 会丢 | 设计取舍（个人工作项）；github 关联索引仍提交；将来搬进 `index.json` 不影响展示层 |
| 50+ issue 时卡片列表性能 | 自动单任务队列折叠为普通卡片，不会出现 50 个队列头；NSStackView 全量重建与项目面板一致，若变慢再引入可见区懒加载 |
| 多队列被误期待为并行 | 文档 / UI 明说全局串行；并行留给未来 worktree 迭代 |
| 恢复队列后误改仓库 | 恢复后不自动开跑，必须显式点队列「开始」 |

### V2-13 决策记录与迭代预留

**本次已定（2026-09-24）**：

1. **多队列，模型先行** —— 先把队列数据模型与持久化跑通（含无头单测），再接执行器与 UI；
2. **队列分支用户手填** —— 默认由队列名生成 slug，用户可改；留空 = 不切分支；
3. **队内失败暂停队列** —— 共享分支上有依赖，失败后必须停下来等用户决定，不自动跳过；
4. **PR 是可选能力** —— GitHub issue 任务可用；公司内部仓库 / 无 PR 能力的远端下，手动任务与队列只做「分支 + commit + push」，PR 相关自动关闭，失败也不判队列失败；
5. **issue 任务保持 v1 逻辑** —— 「处理」自动创建单任务队列，分支与 PR 语义不变。
6. **创建表单不带队列字段** —— 新建任务只有一个内容框（首行标题、其余行描述、单行则两者），创建后一律进入「未入队」区；队列归属只由卡片上的「加入队列 ▾」决定（选已有队列 / 新建队列…）。队列表单才含 队列名 / 分支 / 基于分支 / 完成后创建 PR；
7. **队列分支默认值** —— `feature/` + 队列名 slug；slug 为空（纯中文 / emoji 名）时回退 `feature/queue-<id 前 4 位>`；
8. **队列计数包含自动队列** —— 摘要条与列表按同一口径统计所有队列（含 issue 任务的自动单任务队列）；自动队列默认以紧凑形态（队列头与卡片合一的一行）渲染，可展开。

**本次已定（2026-09-25）**：

9. **创建/编辑不走对话框** —— 新建任务、编辑任务、新建队列、队列设置全部在**面板内的底部抽屉**里完成（无 NSAlert）：覆盖列表、无法移动、关闭即丢值，而且卡片的宽度限制了输入框；抽屉横跨整个面板、输入框因此够宽，从底部上滑也不会让列表在指针下重排。入口只有页签行右侧的两个按钮（空态另给「新建任务」）。**只保留破坏性确认框**（删除任务 / 删除队列 / 评论并关闭 issue，都会改本机记录或 GitHub 远端状态）。
    > 2026-09-25b 修订：最初实现是"表单卡片插进列表"（锚定在被编辑的卡片下方），用户实测两点不满意——输入框太窄、列表被表单顶走；改成底部抽屉后两者都解决，代价是"表单与它作用的对象同屏相邻"这一点让位给"表单够大够稳"。
10. **卡片宽度由列决定，内部内容让位** —— 卡片/队列头一律撑满列表宽度；内部不许出现"至少要这么宽"的控件（多文字按钮 → 主操作文本 + 其余图标按钮，文本/徽标可截断）。这条是加 `+` 按钮后暴露的真实缺陷（卡片比列表宽），用无窗口布局断言钉住（320pt 宽下必须恰好 320pt）。
11. **队列画成容器，任务画在容器里** —— 队列不是"又一张卡片"，而是一条**泳道**：下沉档底色 + 状态色边框 + 队内卡片再缩进一层、保持抬起档底色（审计面板的树体例）。判据是几何的（有无包含、缩进是否成立），无窗口测试直接断言"卡片底边不越出泳道、左缩进大于泳道头"。

**阶段 2 迭代预留**：

- **队列级并行**：worktree + 每队列一个工作树（依赖 dsh web 原生支持 worktree 后评估）；
- **issue 任务进共享队列**：放开「一 issue 一分支」约束，让多个 issue 在同一分支上串行修（需同步改 `docs/git-workflow.md`）；
- **PR 复用增强**：复用已有 PR 时把本次任务摘要作为评论追加；
- **队列模板 / 归档**：预置常用队列（如 `feature/refactor`）与已完成队列的归档视图；
- **跨驱动复用**：`core/lib/jobqueue.js` 与队列模型对齐，供「远程驱动」（钉钉 / 微信）适配器复用；
- **手动任务 / 队列共享**：搬进 `index.json`（`version: 2`）随仓库提交，展示层无需改动。
