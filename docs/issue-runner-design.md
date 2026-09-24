# 任务面板设计（IssueRunner / Tasks）

> 状态：**v1 已实现**（v1.8.0+，方案 E：branch-based 串行队列）；**v2 方案已定稿，待实现**（2026-09-24：多队列泳道 + 手动任务 + 卡片式 UI + token 仅文件；决策记录见 §V2-13）
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
  ├── GitHub REST：拉 issues（过滤 PR）/ 创建 PR（token 走 Keychain）
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
| 公开仓库 | 匿名读 issues（60 req/h 限流）；私有需 token（Keychain） |
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
- **token 管理**：多仓库多 token、Keychain 按仓库作用域。

---

## V2 方案（2026-09-24 定稿，待实现）

> 本章是本次迭代（分支 `feature/tasks-manual-queue`）的落地依据。上文 v1 章节保留作历史决策记录。
> **模型决策已定稿**（详见 §V2-13 决策记录）：多队列模型先行；队列分支用户可填（默认由队列名生成 slug）；队内失败暂停队列；PR 是**可选能力**；issue 任务保持 v1 逻辑、自动生成**单任务队列**。

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

**修掉的既有缺陷**：v1 `gitCheckoutBranch` 里 `checkout main` 与 `pull --ff-only` 的失败被 `_ =` 吞掉，导致新分支可能从**上一个任务的分支**或陈旧提交切出（静默继承 / 静默偏离）。V2 改为显式三步（`checkout <base>` → `pull --ff-only` → `checkout -b <branch>` 或复用已存在分支），**任一步失败即判该任务 failed 并暂停队列**，绝不静默继续。

### V2-6 分支与 PR 规则

**分支归属**：

| 任务 | 分支 | 说明 |
|---|---|---|
| issue 任务（自动单任务队列） | `feature/issue-N` 或 `fix/issue-N` | 沿用 `branchForIssue` 的 label 判定与 `docs/git-workflow.md` 规范，行为与 v1 完全一致 |
| 手动任务（用户队列） | 队列的 `branch` | 队列分支默认由队列名生成 slug（小写、非字母数字换 `-`、去首尾、截断 40 字符），**用户可改**；留空 = 不切分支，在当前分支上执行 |

**PR 是可选能力，不是硬依赖**（决策 4）：

- GitHub issue 任务天然只在 GitHub 仓库出现（issue 来自 GitHub API），因此对它 PR 恒可用，行为同 v1；
- **公司内部仓库 / 无 PR 能力的远端**（自建 GitLab、纯本地 git、无远端）下，手动任务与队列照常可用：只切分支、commit、push，**不创建 PR**。开关 `autoPR` 在工作区不是 GitHub 仓库时自动置 `false` 并在表单里置灰说明；
- 队列级 PR：同一 head 分支在 GitHub 只能有一个 open PR，因此**队内任务完成时只 push**，队列跑完才创建一次 PR；创建前先 `GET /pulls?head=<owner>:<branch>` **复用已有 PR**，避免第二个任务吃 422；
- PR 创建失败（无权限、远端不支持、网络）**不判队列失败**：队列照常 `done`，卡片标注「分支已推送，PR 未创建」，并展示分支名 + 远端名供用户手动处理。

**推送校验**：沿用 v1 的 `pushRemoteName`（github > origin > 首个 remote）与 `gitBranchPushed`；无远端时不校验推送，直接判完成并标注「无远端，未推送」。

### V2-7 手动创建任务

**入口**：工具栏「+」→ 新建任务表单（NSAlert + accessoryView，体例与「配置 GitHub Token」一致）：

1. **标题**（必填）：卡片主行、会话名；
2. **描述 / 指令**（必填，多行 NSTextView）：发给代理的提示词正文；
3. **队列**（下拉：已有队列 / **新建队列…** / 暂不入队）：选择「新建队列」时展开 队列名 + 分支 + 基于分支 三个字段；
4. **完成后创建 PR**（开关，默认：工作区是 GitHub 仓库时开、否则置灰关）：属于**队列**属性，同一队列的任务共享；
5. **立即加入队列**（开关，默认开）。

**执行流水线**（与 issue 任务复用同一套，差异如下）：

| 步骤 | issue 任务（自动队列） | 手动任务（用户队列） |
|---|---|---|
| 切分支 | 每任务一次：`checkout main → pull → checkout -b feature/issue-N 或 fix/issue-N` | 队列首个任务：`checkout <baseBranch> → pull → checkout -b <queue.branch>`；队内后续任务：**不切分支** |
| 建会话 | `session.create(workspaceId)` + `session.rename(fix(#N): …)` | 同左，会话名 = 任务标题 |
| 提示词 | issue-resolve skill + issue 正文 | **通用提示词**：工作目录 / 分支 / 队列内位置、任务描述、要求（改代码 → 跑测试 → commit → push）、token 文件位置（需要 GitHub 写操作时）；不复用 issue-resolve skill |
| 收尾 | 校验分支已推送 → 开 PR → done(PR url) | 队列跑完才收尾（见 §V2-6）；单个任务完成只 push |
| 评论并关闭 | 有（done 且有 PR 时） | **无**（没有 issue 可关） |

**队列操作**（UI 上都在队列头）：新建 / 重命名 / 改分支 / 开始 / 暂停 / 开 PR / 归档。删除队列时，队内未执行任务回到「未入队」区，已完成任务的记录保留。

**非 GitHub 工作区**：手动任务与队列**仍然可用**（不依赖 issue 拉取），PR 相关全部隐藏或置灰；issue 区维持原有空态「当前工作区不是 GitHub 仓库」（文案改为只针对 issue 区）。前提是工作区必须是一个 **git 目录**（否则没有分支可切、也没有会话 cwd）：非 git 目录时「+」置灰并在状态条说明。

### V2-8 卡片式任务清单

列表改为 `NSScrollView + NSStackView`，体例照 `ProjectsPanel.swift`：`render()` 重建 `arrangedSubviews`，卡片 `widthAnchor == list.widthAnchor - 20`，卡片自身 `draw(_:)` 画圆角 + 描边、`hitTest` 把非按钮区域的点击交回卡片、`resetCursorRects` 设 `pointingHand`。

**组织维度：队列分区**（取代原先设想的按状态分区）：

```
┌ 队列：深色模式改造 ────────────────────────────┐
│ feature/dark-mode → main   ▸3/5   [开始][暂停][开 PR] │  ← 队列头（名称 + 分支 + 进度 + 操作）
└────────────────────────────────────────────────┘
  ┌────────────────────────────────────────────┐
  │ [手动]  [队列中 #1]              ⟳   ⊖      │  ← 来源徽标 + 状态徽标 + hover 图标操作
  │ 重构终端面板标题栏的配色逻辑                  │  ← 标题（semibold，2 行截断）
  │ feature/dark-mode · 会话 session-… · 无 PR   │  ← 元信息（分支 / PR / 会话，可点）
  │ [移出队列] [取消]                            │  ← 主操作行（展开后显示）
  │ ┌ 详情：正文 / 错误 / 时间线 ────────────────┐ │  ← 点卡片 = 展开 / 收起（保留 v1 手感）
  │ └──────────────────────────────────────────┘ │
  └────────────────────────────────────────────┘

┌ 未入队 ────────────────────────────────────────┐
  [Issue #12] 修复暗色模式下…            [处理]     ← issue 任务（自动单任务队列，折叠为普通卡片）
  [手动] 整理 README 的安装章节   [加入队列 ▾]      ← 手动任务
```

- **队列头**：名称、分支、进度 `n/m`、状态（活跃 / 暂停 / 完成）、操作按钮（开始 / 暂停 / 开 PR）；`autoCreated` 的自动单任务队列**不显示队列头**，直接渲染为普通卡片（否则 50 个 issue 会变成 50 个队列头）；
- **来源徽标**：`Issue #N` 与 `手动` —— 需求「创建的任务和 github issue 任务分开标记」的落点之一；工具栏另有来源筛选段控件（全部 / Issue / 手动）；
- **状态徽标**：待处理 / 队列中 #n / 运行中（配小 spinner）/ 已完成 / 失败 / 已取消 / 已关闭；失败 `systemRed`、完成 `systemGreen`（沿用现有语义色）；
- **交互**：点卡片非按钮区域 = 展开 / 收起详情（正文可滚动，长正文不挤走按钮，保留 v1 的 NSTextView 方案）；hover 时卡片底色提亮（`PanelControl.fill(dark:highlighted:)`）并显示行内图标按钮；**移出队列 / 取消 / 重试都不弹模态**，结果回底部状态条（成功 5s 自动清空、失败留到下次操作）；只有「评论并关闭 Issue」保留确认框（会改 GitHub 远端状态）；
- **底部状态条保留**（加载中 / 队列 n/m / 错误回显），compositing trap 的 `wantsLayer + masksToBounds` 写法不变。

**配色纪律**（`docs/ui-color-scheme.md`）：面板根 / header / toolbar / 状态条用 `DynamicFillView()`（`.panel`），卡片底与图标按钮用 `PanelControl.fill(dark:highlighted:)`，**不新写** `calibratedWhite` 灰阶；卡片在 `viewDidChangeEffectiveAppearance` 重绘取色。

### V2-9 L10n（中英成对，`main.swift` 的 `L10n.table`）

修改：`tasks.configInfo`（去掉钥匙串措辞，改为文件口径）。

新增（示意，实现时以 `L10n.table` 为准，`tests/l10n/run.sh` 兜住漏配）：

- 来源与筛选：`tasks.source.github`、`tasks.source.manual`、`tasks.filter.all` / `.github` / `.manual`；
- 队列：`tasks.queue.add`、`tasks.queue.addPick`、`tasks.queue.remove`、`tasks.queue.new`、`tasks.queue.name`、`tasks.queue.branch`、`tasks.queue.base`、`tasks.queue.start`、`tasks.queue.pause`、`tasks.queue.openPR`、`tasks.queue.progress`、`tasks.queue.idle`、`tasks.queue.pendingCount`、`tasks.queue.unnamed`；
- 状态：`tasks.state.queued`、`tasks.state.interrupted`、`tasks.sec.dirtyTree`（工作区有未提交改动）、`tasks.sec.noRemote`、`tasks.sec.prUnavailable`、`tasks.sec.branchPushedNoPR`；
- 手动任务：`tasks.new.title`、`tasks.new.name`、`tasks.new.body`、`tasks.new.queue`、`tasks.new.createPR`、`tasks.new.enqueue`、`tasks.new.create`、`tasks.errName`、`tasks.errBody`、`tasks.prompt.*`（通用提示词模板）；
- 详情与错误：`tasks.detailSession`、`tasks.detailSource`、`tasks.detailQueue`、`tasks.errInterrupted`、`tasks.errNotGit`、`tasks.errCheckout`。

### V2-10 测试与 CI

新增 `tests/tasks-panel/`（无头，体例照 `tests/projects-panel/`：`stubs.swift` + `run.sh` + 若干 `*-tests.swift`）：

1. **队列模型（本次重点，模型先行）**：入队顺序与 `order` 编号、重复入队幂等、移出后回 `pending`、队首推进、队列内失败 → 队列暂停（后续任务仍 queued）、跳过并继续、切队列的干净检查（脏工作区拒绝启动）、队列完成态与 `autoPR` 能力降级、自动单任务队列的创建与重试复用；
2. **模型与持久化**：TaskItem / Queue 编解码往返；`index.json` 旧格式兼容（无 `source` 视为 github、无 id 用 `issue-N`）；`manual.json` 增删改查；`queues.json` 读写；**`local.json` sessions 换键兼容**（数字键 ↔ `issue-N`）；坏文件不崩溃且不删除；
3. **token 解析**：临时 `DSH_HOME` 下「专属文件 → 通用文件 → nil」三级；保存写文件且权限 `0600`；空值删文件；断言实现里不再有钥匙串路径；
4. **卡片视图模型**：给定 TaskItem / Queue → 断言标题、来源徽标、状态徽标、队列头文案与进度、主操作标题与可用性（把 `primaryActionTitle` 一类纯函数抽出来覆盖 queued / interrupted / manual / 队列暂停等新分支）。

同步：扩展 `core/tests/tasks.test.js`（manual / queue / sessions 换键）；把 `tests/tasks-panel/run.sh` **同时**登记进 `scripts/local-ci.sh` 的 `stage_swift` 与 `.github/workflows/ci.yml`（两处清单必须一致）。

QA 钩子：`DSH_TASKS_TEST=1` 启动即开面板；`DSH_PANEL_TEST=` 全量核对串已含 `tasks`；`--ui-debug` 下 `setRightPanel` 落 `panel-tasks-debug.png`。

### V2-11 实施拆分（模型先行）

1. `refactor(tasks): GitHub token 只从文件读取（移除 Keychain 读写）` —— 独立、低风险，先落；含 L10n 文案与 README；
2. `feat(tasks-core): 队列模型与四文件持久化` —— `TaskItem` / `Queue` / `QueueStore` / `TaskStore` + `core/lib/tasks.js` 同步 + 无头单测（**模型先行，跑通后再接执行器**）；
3. `feat(tasks): 队列运行器` —— 全局串行、活动队列、失败暂停队列、切队列干净检查、显式 checkout 三步、重启恢复；
4. `feat(tasks): 手动创建任务` —— 表单（含队列选择 / 新建队列）+ 通用提示词；
5. `refactor(tasks): issue 任务改走自动单任务队列` —— 行为与 v1 逐条对齐（分支名、PR、评论关闭不变）；
6. `refactor(tasks): 任务清单改卡片式 UI` —— 队列分区 + 未入队区 + 自动队列折叠 + hover / 展开；
7. `test(tasks): tests/tasks-panel 无头套件 + CI 登记`，`docs: 本文档、README、.dsh/wiki` 同步。

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

**阶段 2 迭代预留**：

- **队列级并行**：worktree + 每队列一个工作树（依赖 dsh web 原生支持 worktree 后评估）；
- **issue 任务进共享队列**：放开「一 issue 一分支」约束，让多个 issue 在同一分支上串行修（需同步改 `docs/git-workflow.md`）；
- **PR 复用增强**：复用已有 PR 时把本次任务摘要作为评论追加；
- **队列模板 / 归档**：预置常用队列（如 `feature/refactor`）与已完成队列的归档视图；
- **跨驱动复用**：`core/lib/jobqueue.js` 与队列模型对齐，供「远程驱动」（钉钉 / 微信）适配器复用；
- **手动任务 / 队列共享**：搬进 `index.json`（`version: 2`）随仓库提交，展示层无需改动。
