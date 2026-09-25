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
> **模型决策已定稿**（详见 §V2-13 决策记录）：多队列模型先行；队列分支用户可填（默认由队列名生成 slug，中文名回退 `feature/queue-<id4>`）；队内失败暂停队列；PR 是**可选能力**；issue 任务保持 v1 逻辑、自动生成**单任务队列**；创建任务表单只填标题 + 描述（一律先进「未入队」区）；队列计数含自动队列。

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

**推送校验**：沿用 v1 的 `pushRemoteName`（github > origin > 首个 remote）与 `gitBranchPushed`；无远端时不校验推送，直接判完成并标注「无远端，未推送」。

### V2-7 手动创建任务

**入口**：页签行右侧的「＋」图标按钮（或空态里的「新建任务」按钮）→ **从内容区顶部下拉一张表单抽屉**（§V2-8 的实现备注 2026-09-25c）。

1. **标题**（必填）：卡片主行、会话名；
2. **描述 / 指令**（必填，多行 NSTextView）：发给代理的提示词正文。

表单**只有这两个字段**（决策 6）：创建后任务**一律进入「未入队」区**，队列归属完全由卡片上的操作决定 ——

> 逻辑已落地（第 4 步）：`TaskDraft` 校验两个字段都非空，空值返回 L10n 键 `tasks.errName` / `tasks.errBody`，`normalizedTitle/Body` 统一去首尾空白；运行器 `createManualTask` / `updateManualTask`（运行中的任务与 github 任务都拒绝编辑）/ `deleteManualTask`（运行中拒绝删除；删除即退出所有队列并清掉本机 session 记录）；「加入队列 ▾」的候选来自 `TaskBoard.queueChoices()`——**只列用户队列**，issue 任务的自动单任务队列不是目的地。UI 表单在第 6 步接。

1. 点卡片 **「加入队列 ▾」** → 选**已有队列**，或**新建队列…**（**同一张抽屉**，创建后顺手把这一个任务入队：**队列名** / **分支**（默认见 §V2-6，可改、可留空；字段下方实时显示「将使用分支：feature/<slug>」，无 ASCII slug 的纯中文名回退通用文案）/ **基于分支**（默认 `main`）/ **完成后创建 PR**（开关，属于队列属性，队内任务共享；工作区不是 GitHub 仓库时置灰关））；队列也可**脱离任务单独创建**（队列分区头右侧的「新建队列」）；
2. 入队后：全局空闲 → 立刻启动队首；否则排队（见 §V2-5）；
3. 改主意：卡片「移出队列」→ 回到未入队区，或再点「加入队列 ▾」换到别的队列。

**执行流水线**（与 issue 任务复用同一套，差异如下）：

| 步骤 | issue 任务（自动队列） | 手动任务（用户队列） |
|---|---|---|
| 切分支 | 每任务一次：`checkout main → pull → checkout -b feature/issue-N 或 fix/issue-N` | 队列首个任务：`checkout <baseBranch> → pull → checkout -b <queue.branch>`；队内后续任务：**不切分支** |
| 建会话 | `session.create(workspaceId)` + `session.rename(fix(#N): …)` | 同左，会话名 = 任务标题 |
| 提示词 | issue-resolve skill + issue 正文 | **通用提示词**：工作目录 / 分支 / 队列内位置、任务描述、要求（改代码 → 跑测试 → commit → push）、token 文件位置（需要 GitHub 写操作时）；不复用 issue-resolve skill |
| 收尾 | 校验分支已推送 → 开 PR → done(PR url) | 队列跑完才收尾（见 §V2-6）；单个任务完成只 push |
| 评论并关闭 | 有（done 且有 PR 时） | **无**（没有 issue 可关） |

**队列操作**（UI 上都在队列头）：新建 / 重命名 / 改分支 / 开始 / 暂停 / 开 PR / 归档。删除队列时，队内未执行任务回到「未入队」区，已完成任务的记录保留。

**非 GitHub 工作区**：手动任务与队列**仍然可用**（不依赖 issue 拉取），PR 相关全部隐藏或置灰；issue 区维持原有空态「当前工作区不是 GitHub 仓库」（文案改为只针对 issue 区）。

> **实现（2026-09-24 修正）**：board 只绑定**工作区目录**，不绑定 GitHub —— `adoptWorkspace(_:)` 对任意已解析的工作区都建立 runner（`<dir>/.dsh/tasks/` 即该工作区的 board），GitHub 远程只是额外点亮 issue 功能；工作区解析为空时才 `clearBoard()`（并在 `app.log` 写 `tasks: no workspace adopted …`）。工具栏右侧显示 `目录名 · 非 GitHub 仓库`，空态文案在非 GitHub 工作区改为「还没有任务：点右上角 + 新建一个…」。**目录不是 git 仓库也能建任务**：队列只要不设分支（留空）就不碰 git；设了分支则在启动时报 `tasks.errNotGit`（原设计里「非 git 目录置灰 +」改为「按钮始终可见，点了给明确说明」）。

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

### V2-9 L10n（中英成对，`main.swift` 的 `L10n.table`）

修改：`tasks.configInfo`（去掉钥匙串措辞，改为文件口径）。

新增（示意，实现时以 `L10n.table` 为准，`tests/l10n/run.sh` 兜住漏配）：

- 来源与筛选：`tasks.source.github`、`tasks.source.manual`、`tasks.filter.all` / `.github` / `.manual`；
- 队列：`tasks.queue.add`、`tasks.queue.addPick`、`tasks.queue.remove`、`tasks.queue.new`、`tasks.queue.name`、`tasks.queue.branch`、`tasks.queue.base`、`tasks.queue.start`、`tasks.queue.pause`、`tasks.queue.openPR`、`tasks.queue.progress`、`tasks.queue.idle`、`tasks.queue.pendingCount`、`tasks.queue.unnamed`；
- 队列总览：`tasks.queue.compact`、`tasks.queue.expand`、`tasks.queue.hideDone`、`tasks.queue.failedCount`、`tasks.queue.empty`、`tasks.queue.state.active` / `.paused` / `.finished`、`tasks.section.unqueued`（未入队 (%d)）；
- 状态：`tasks.state.queued`、`tasks.state.interrupted`、`tasks.sec.dirtyTree`（工作区有未提交改动）、`tasks.sec.noRemote`、`tasks.sec.prUnavailable`、`tasks.sec.branchPushedNoPR`；
- 手动任务：`tasks.new.title`、`tasks.new.name`、`tasks.new.nameHint`、`tasks.new.body`、`tasks.new.create`、`tasks.new.save`、`tasks.new.done`、`tasks.new.editTitle`、`tasks.new.editInfo`、`tasks.errName`、`tasks.errBody`、`tasks.prompt.*`（通用提示词模板）；队列内联表单：`tasks.queue.settings`、`tasks.queue.editTitle`、`tasks.queue.editInfo`、`tasks.queue.nameHint`、`tasks.queue.baseHint`、`tasks.queue.branchWillUse`、`tasks.queue.prUnavailable`、`tasks.queue.createOnly`、`tasks.queue.created`、`tasks.queue.updated`；统计卡逐段计数：`tasks.stat.queues` / `.queued` / `.running` / `.failed`（V2-8m 之前的合并键 `tasks.summary` 已删除）。v1 遗留的 `tasks.queue.rename` / `.renameInfo` / `.changeBranch` / `.branchInfo` 被「队列设置」内联表单取代，已删除；
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

> **进度**：第 1 步（token 只从文件读取）已完成 —— commit `0a8f535`；第 6 步（卡片式任务清单）已完成 —— `TasksUI.swift`（视图模型：徽标 / 元信息 / 主操作 / 队列头 / 摘要，**无头可断言**）+ `TaskCardView.swift`（卡片 + 队列头 + 徽标渲染）+ 面板列表（`NSScrollView + NSStackView`，队列分区、未入队区、来源筛选、新建/编辑任务表单、新建队列表单、「加入队列 ▾」菜单、队列 ⋯ 菜单）；第 5 步（issue 任务改走自动单任务队列 / 面板接运行器）已完成 —— 面板删除 `startTask`/`pollSession`/`openPR`/`finishCurrentTask`/`gitCheckoutBranch`/`gitBranchPushed`/`issueFixPrompt` 与 Swift 版 `TaskIndex`，行模型换成 `TaskItem`，执行全部经 `TasksRunner`（3s 定时 `step()`、`updateBoard` 合并 issues、`syncFromBoard` 渲染、`findExistingPR` 复用）；第 4 步（手动创建任务）已完成 —— `TaskDraft`（两个字段 + 校验，L10n 键 `tasks.errName` / `tasks.errBody`）/ `QueueChoice`（**只列用户队列**，issue 自动队列不是目的地）/ 运行器 `createManualTask` · `updateManualTask` · `deleteManualTask`（运行中拒绝删除，删除即退出所有队列并清掉本机 session），UI 表单留到第 6 步；第 2 步（队列模型 + 四文件持久化）已完成 —— `TasksCore.swift` / `TasksStore.swift` + `core/lib/tasks.js` 同步 + `tests/tasks-panel/`（126 项）；第 3 步（队列运行器）已完成 —— `TasksRunner.swift`（含 git 三步显式检查 / 全局串行 / 失败暂停 / 队列级 PR 复用 / 取消·重试·跳过 / 重启恢复）+ `runner-tests.swift`（108 项）。

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
6. **创建表单不带队列字段** —— 新建任务只有标题 + 描述，创建后一律进入「未入队」区；队列归属只由卡片上的「加入队列 ▾」决定（选已有队列 / 新建队列…）。队列表单才含 队列名 / 分支 / 基于分支 / 完成后创建 PR；
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
