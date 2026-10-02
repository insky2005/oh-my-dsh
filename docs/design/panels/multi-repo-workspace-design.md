# 多仓库工作区设计（Multi-repo Workspace）

> 状态：已评审（设计定稿，未实现）· 日期：2026-10-02 · 关联：docs/design/panels/issue-runner-design.md、docs/design/panels/tasks-queue-session-loop-design.md、docs/process/git-workflow.md、.dsh/wiki/modules/issue-runner-panel.md
> 决策来源：2026-10-02 会话讨论（用户场景：多个 git 仓库平铺在一个根目录下，根目录本身不是仓库）

## 1. 背景与问题

用户把多个独立 git 仓库的目录放在同一个根目录下，再用 dsh 注册一个 workspace 指向这个根目录。根目录本身**不是** git 仓库，只有它的子目录是。

任务面板（Tasks / IssueRunner）当前按「工作区 = 一个仓库」设计：

- 「这个工作区是不是 git 仓库」由对根目录跑 `git -C <root> rev-parse --is-inside-work-tree` 决定（`platforms/macos/src/IssueRunnerPanel.swift` 的 `isGitRepo`），根目录不满足 → 判成 `非 Git 仓库`；
- 于是队列只能走「不切分支」，`QueueIntegration.available` 里 `.merge / .push / .pr` 全部不可用（`platforms/macos/src/TasksCore.swift`），提示词也只按单仓库形状生成（`platforms/macos/src/TasksRunner.swift` 的 `TaskPrompts.requirements`）。

用户不希望被迫 `git init` 根目录（会改变仓库结构、且根提交覆盖不到子仓库改动），希望产品能原生支持「工作区下多个仓库」的 git 工作流。

## 2. 目标与非目标

**目标**

1. 根目录不是 git 仓库时，任务面板仍能识别工作区里的**一组** git 仓库，并展示正确的能力状态；
2. 队列的「切分支 → 任务执行 → 交接简报 → 提交」工作流能覆盖这组仓库；
3. 队列交付（push / 本地合并 / 开 PR）能按仓库执行并汇报每个仓库的结果；
4. 向后兼容边界干净：只有「根是仓库且无参与子仓库」与今天逐字一致；有子仓库的工作区一律多仓库（§4.3）。

**非目标（本设计不做）**

- 不自动对根目录 `git init`，也不隐式创建/删除子仓库；
- 不修改 dsh 上游，不引入 git worktree；
- 不追求「跨仓库原子提交」（git 本身不支持）；各仓库各自提交、各自上线；
- 不讨论嵌套超过一层的工作区（见 §14 待确认 Q1）。

## 3. 现状：单仓库假设集中在哪

| 层 | 现状 | 代码位置 |
|---|---|---|
| 探测 | `isGitRepo(root)` 单值 | `platforms/macos/src/IssueRunnerPanel.swift`（`isGitRepo`） |
| 形状 | `TaskRepoShape`（plain / git / github）单值 | `platforms/macos/src/TasksRunner.swift`（`TaskRepoShape`） |
| env | `TaskRunnerEnv.git: TaskGit` 单例 + `repoRoot` | `platforms/macos/src/TasksRunner.swift`（`TaskRunnerEnv`） |
| 流水线 | `pump` 对一个 `git.enter(branch, base)` | `platforms/macos/src/TasksRunner.swift`（`pump`） |
| 简报 | `git.commits(base)` 单仓库 | `platforms/macos/src/TasksRunner.swift`（`brief`） |
| 交付 | 队列级 `prUrl`，finalize 对一个分支 | `platforms/macos/src/TasksRunner.swift`（`startQueueIntegration` / `makeFinalizeRun`） |
| 模型 | `TaskQueue.branch/baseBranch/prUrl` 单仓库 | `platforms/macos/src/TasksCore.swift`（`TaskQueue`） |
| UI | 头部三态 `TaskWorkspaceModel`、表单 `gitAvailable` 布尔 | `platforms/macos/src/TasksUI.swift`（`TaskWorkspaceModel`） |

改造思路一句话：**把这些「单值」逐层替换成「一个仓库集合」，并为集合提供聚合后的可用性判断。**

## 4. 核心模型：WorkspaceRepoSet

新增纯模型（放 `platforms/macos/src/TasksCore.swift`，可无头单测，不碰 I/O）：

```swift
struct GitHubRepo: Equatable {
    var owner: String
    var name: String          // 仓库名，不含 owner
}

/// 工作区里一个可当作 git 目标的仓库。
struct WorkspaceRepo: Equatable {
    /// 工作区内的相对路径；"." 表示根目录自己。稳定 id，用于队列持久化。
    var id: String
    var absolutePath: String
    var isGit: Bool
    /// 该仓库自己的默认分支（main / master 可能不同）。
    var defaultBase: String = "main"
    var remoteName: String?   // 推送首选远端（github > origin > 第一个）
    var github: GitHubRepo?   // 有 github.com 远端时才有
    /// 展示名："." → 根目录末级名；否则相对路径。
    var displayName: String
}

struct WorkspaceRepoSet: Equatable {
    var repos: [WorkspaceRepo]
    /// 根仓库（若参与）为主；否则第一个有 GitHub 远端的；否则第一个 git 仓库；都不满足为 nil。
    var primary: WorkspaceRepo?

    var gitRepos: [WorkspaceRepo] { repos.filter(\.isGit) }
    var gitAvailable: Bool { !gitRepos.isEmpty }
    /// 是否有「任意一个」仓库可开 PR（issue 区可用性用）。
    var prAvailable: Bool { repos.contains { $0.github != nil } }
    /// 是否「所有目标仓库」都可开 PR（PR 交付模式用，见 §7.2）。
    func allCanOpenPR(_ targets: [WorkspaceRepo]) -> Bool {
        !targets.isEmpty && targets.allSatisfy { $0.github != nil }
    }
}
```

### 4.1 探测规则（`WorkspaceRepoSet.detect(root:)`）

工作区的仓库集合 = **根目录（如果它自己是仓库）+ 直接子目录里的独立仓库**（用户 2026-10-02 决定：根 + 子都参与，根为主）：

1. 根目录是 git 仓库（`rev-parse --is-inside-work-tree == true` 且 `--show-toplevel == root`）→ 把根加入集合，`id = "."`；
2. 扫描**直接子目录**中带 `.git`（目录或文件）的项，逐个组装 `WorkspaceRepo`（各自探测 `defaultBase` / `remoteName` / `github`）；
3. 两者都没有 → `repos = []`，面板维持现有「非 Git 仓库」完整可用性。

**主仓库（primary）**：优先取面板设置里用户指定的主仓库（§8.1）；未指定、或指定的仓库已不存在时，回退自动规则 —— 根参与时为根，否则第一个有 GitHub 远端的，再否则第一个 git 仓库。主仓库决定队列默认目标（Q2）、issue 默认归属（§9）与 `env.git` 的落点。

**submodule 排除**：根是仓库时，子目录里的 git **子模块**（列在根 `.gitmodules` 内）由父仓库管理，默认**不**作为独立目标加入集合（见 §14 Q10）；普通独立子仓库照常加入。

扫描纪律（Q1 已定）：**只扫直接子目录**；排除隐藏目录（`.` 开头）、`node_modules / .build / .cache / dist` 等重目录，以及 `.gitmodules` 里列出的 submodule 路径；探测函数可注入（测试用假目录树，不落盘）。所有 git 探测都发生在**后台线程**（沿用现有 `env.perform` 的纪律）。

### 4.2 兼容矩阵

| 场景 | 探测到的 `repos` | 模式 | 行为 |
|---|---|---|---|
| 根是仓库，**且无**参与子仓库 | `[root]` | 单仓库（legacy） | 与今天逐字一致 |
| 根是仓库，**且**有参与子仓库 | `[root, child…]` | 多仓库（N≥2，根为主） | 根作为 primary；子仓库一并参与流水线（Q6 已定） |
| 根非 git，有子仓库（1 个或 N 个） | `[child…]` | 多仓库（N≥1） | 新增多仓库路径；N==1 也按多仓库模式 |
| 根非 git，无子仓库 | `[]` | plain | 与今天「非 Git 目录」一致 |

### 4.3 模式判定：只有「根是仓库且无参与子仓库」才是 legacy 单仓库

**单仓库模式（legacy）是唯一的向后兼容形态**：工作区与今天完全同构 —— 根目录是仓库、且没有参与的子仓库。其余只要工作区里存在子仓库（或根不是仓库但有子仓库），都进入**多仓库模式**（用户 2026-10-02 评审：不按数量切换，避免加/减仓库时交互范式来回翻）：

| 判定 | 模式 | 说明 |
|---|---|---|
| 根是仓库 **且** 无参与子仓库 | **单仓库（legacy）** | 与今天逐字一致 |
| 根是仓库 **且** 有参与子仓库 | **多仓库** | 根 + 子都参与，根为 primary（Q6 已定） |
| 根不是仓库 **且** 有子仓库 | **多仓库** | N≥1；**N==1 也是多仓库** |
| 没有任何仓库 | **plain** | 与今天「非 Git 目录」一致 |

**为什么这样切**：单仓库模式只在「与今天完全同构」时出现，向后兼容边界干净；其余有仓库的情况一律多仓库，用户加一个子仓库只是列表多一行，不会换范式。

**模式与措辞解耦**：提示词写什么，由**本次目标仓库集合** `targets` 决定，与模式无关：

- `targets.count == 1` → 用今天逐字节相同的单仓库文本（按该仓库的 `TaskRepoShape` 生成）；目标不是工作区根时额外加一行工作目录说明（见下）。
- `targets.count ≥ 2` → 用多仓库清单文本（§6）。

| 维度 | 单仓库模式（根 = 仓库，无子仓库） | 多仓库模式 |
|---|---|---|
| 头部 | 仓库能力（`owner/repo` / `目录名 · 非 GitHub 仓库`） | `目录名 · N 个仓库`（N≥1，tooltip 列仓库名，根标注为主仓库） |
| 队列表单 | 无仓库选择区（与今天一致） | 有仓库选择区；**默认只选 primary（根）**，N==1 只读锁定 |
| issue 区 | 今天的形态 | 有仓库归属；N==1 只读，N≥2 可切换 |
| 分支 / base | 用仓库自己的 `defaultBase` | 用各目标仓库自己的 `defaultBase` |
| git 操作 | `gitFor(repo)` | `gitFor(repo)`（根 `-C .`，子 `-C <child>/`） |

**子仓库工作目录说明（单目标时唯一新增的文本）**：目标仓库不是工作区根时，提示词头部补一行：

> 本工作区的 git 仓库位于子目录 `<child>/`；所有 git 命令请加 `-C <child>/`（或先 `cd` 进去），不要在工作区根执行 git。

**边界：根目录后来变成仓库**。因为 Q6 定为「根 + 子都参与」，在容器型工作区里对根 `git init` 只是把根**加入**目标集合并成为 primary —— **不会**切回单仓库模式，子仓库继续参与。状态行可提示「根目录现在也是仓库，已作为主仓库加入」。真正的模式回退只有两种：多仓库 → plain（仓库都被移除）、多仓库 → legacy 单仓库（根是仓库且参与的子仓库被移除）。二者都是用户显式动作。

## 5. Runner：按仓库预检与切分支

### 5.1 env 改造

`repoRoot` 继续是**会话 cwd**（会话仍在工作区根启动，agent 自行 `cd` 进子仓库），git 能力改为按仓库取：

```swift
struct TaskRunnerEnv {
    var repoRoot: String                    // 会话 cwd，不变
    var repos: [WorkspaceRepo]              // 新增
    var gitFor: (WorkspaceRepo) -> TaskGit  // 新增
    var canOpenPR: (WorkspaceRepo) -> Bool  // 由 () -> Bool 升级
    var git: TaskGit                        // 保留 = gitFor(primary)，兼容现有调用点
    // …其余字段不变
}
```

`makeEnv`（`platforms/macos/src/IssueRunnerPanel.swift`）在 adopt 时构建 `repos`；同时新增 `reposProvider: () -> [WorkspaceRepo]` 供运行期重新探测（与现有「提示词现场探测 repoShape」同一哲学）。

### 5.2 `pump` 两段式

1. **预检（pre-flight）**：解析本队列的目标仓库（`queue.repos`，空 = 默认 primary），逐个检查 `isGit / 工作区干净 / base 可解析`。**任一不过即失败并指名仓库**（新增 `TaskFailure` 文案，如 `tasks.errRepoDirty`、`tasks.errRepoNoBase`），此时尚未改动任何仓库。（注意：**执行阶段仍是 fail-fast**，与 §7.2 交付的「各仓库独立处理」不同——避免一半仓库已经开工；若希望执行阶段也独立，另议。）
2. **进入分支**：预检全过，再逐个 `gitFor(repo).enter(branch, base: repo.defaultBase)`。同一分支名在所有目标仓库上创建（各自独立，重名无冲突）。中途某个失败时，前面的仓库已切走——这是**非破坏性**的，不强行回滚，错误里说明「哪些仓库已切到分支、哪个失败」。

```swift
// 伪代码
let targets = resolveTargets(queue, repos)          // 运行期重探测
guard let failed = preflight(targets, branch, base) else { ... }
for repo in targets {
    let entered = env.gitFor(repo).enter(branch: branch, base: repo.defaultBase)
    if let failure = TasksRunner.failure(for: entered) { ... }
}
```

### 5.3 交接简报

`brief` 从「一个仓库的 commits」升级为「每个仓库的 commits」，按仓库分组展示：

```swift
struct RepoCommits: Equatable { var repoID: String; var commits: [String] }
// QueueBrief.commits 由 [String] 改为 [RepoCommits]
```

单仓库时渲染结果与今天一致（只有一组，见 §6 的零变化要求）。

## 6. 提示词

`TaskPrompts.requirements`（`platforms/macos/src/TasksRunner.swift`）由「一个 shape」改为「目标仓库列表」：

- **单目标时（`targets.count == 1`，无论目标是根仓库还是子仓库），生成的文本必须与今天逐字节相同**——这是零回归的关键，也是 454 项 runner 测试不被打散的保证；目标不是工作区根时只额外加一行工作目录说明（§4.3）。
- 多仓库时新增/改写条目：
  - 头部：「本队列涉及仓库：`repo-a/`、`repo-b/`（相对工作区根）」；
  - 分支条：「**每个**仓库都须在其分支 `X` 上处理（各自基于自己的默认分支：`repo-a` 基于 `main`，`repo-b` 基于 `master`）」；
  - commit 条：「在有改动的仓库里**分别** `git -C <repo> add/commit`（建议 feat/fix: 简述）；没有改动的仓库不用提交」；
  - token 条：只要任一目标仓库是 GitHub 就出现（token 文件按 `owner-repo` 组织，agent 自行选）；
  - 反误解条：「不要用一把 `git status` 概括全部，逐仓库 `git -C <repo> status` 确认」。

`TaskRepoShape` 保留（它是单仓库的纯函数，被多处复用），多仓库路径用仓库列表派生等价信息。

## 7. 队列模型与交付

### 7.1 模型字段

`TaskQueue`（`platforms/macos/src/TasksCore.swift`）新增：

```swift
struct QueueRepoRun: Equatable {
    var repoID: String          // WorkspaceRepo.id（相对路径）
    var branch: String
    var base: String
    var intent: QueueIntegration     // 队列对该仓库的意图（= 队列级交付模式）
    var effective: QueueIntegration  // 按该仓库能力降级后的实际动作
    var status: RepoRunStatus        // pending / running / done / failed / skipped
    var prUrl: String?
    var note: String?                // 失败原因或成功摘要（L10n 键或纯文本）
}

struct TaskQueue {
    // …现有字段
    /// 本队列的目标仓库（WorkspaceRepo.id 列表）；nil/空 = 默认主仓库（primary，Q2）。
    var repos: [String]?
    /// 每个仓库的交付结果（各仓库独立处理）。
    var repoRuns: [QueueRepoRun]
    /// 保留：第一个成功的 PR URL（旧 UI / 兼容）。
    var prUrl: String?
}
```

`initialize` / `from(dictionary:)` 都按可选字段处理，旧 `queues.json` 无这两个键时 `repos = nil`、`repoRuns = []`，即旧行为。

### 7.2 可用性与降级（各仓库独立处理）

交付模式是**队列级 intent**（队列自己的覆盖；未覆盖时各仓库按 §8.1 的按仓库默认值：`intent(repo) = queue.integration ?? perRepoDefault(repo)`），且**每个仓库按自己的能力独立处理**（用户 2026-10-02 决定：各仓库独立处理），不因最弱的仓库而整体拒绝：

```swift
/// 该仓库对某个 intent 能否原生做到。
static func supports(_ mode: QueueIntegration, repo: WorkspaceRepo, hasRemote: Bool) -> Bool {
    switch mode {
    case .none:  return true
    case .pr:    return repo.github != nil
    case .merge: return repo.isGit
    case .push:  return repo.isGit && hasRemote
    }
}

/// 按能力降级：PR → 推送 → 本地合并 → 不做。
static func effective(_ intent: QueueIntegration, repo: WorkspaceRepo, hasRemote: Bool) -> QueueIntegration {
    if supports(intent, repo: repo, hasRemote: hasRemote) { return intent }
    switch intent {
    case .pr:    return hasRemote ? .push : (repo.isGit ? .merge : .none)
    case .push:  return repo.isGit ? .merge : .none
    case .merge: return .none
    case .none:  return .none
    }
}

/// 选项可用性：只要「有一个」目标能原生做到就可选（单仓库时即今天的可用性）。
static func available(_ intent: QueueIntegration, targets: [WorkspaceRepo],
                      hasRemote: (WorkspaceRepo) -> Bool) -> Bool {
    guard !targets.isEmpty else { return intent == .none }
    return intent == .none || targets.contains { supports(intent, repo: $0, hasRemote: hasRemote($0)) }
}
```

- 单仓库时与现有 `available(_:isGit:hasGitHubRemote:hasRemote:)`（`platforms/macos/src/TasksCore.swift`）结果一致。
- 混合能力时**不再整体灰置**：在表单 / 队列头 tooltip 里逐仓库列出实际动作（如「`repo-a`：PR · `repo-b`：本地合并（无远端）」），交付结果也按仓库分别落到卡片。

### 7.3 finalize 会话

**一个队列一个交付会话**（Q4 已定）：提示词（`TaskPrompts.integration`，`platforms/macos/src/TasksRunner.swift`）对每个目标仓库给出它的 **effective 动作**，要求分别执行，并在最后**逐行**输出可解析结果：

```
repo-a: pr https://github.com/o/a/pull/12
repo-b: merge 已合并到 main（无远端，未推送）abc1234
```

`startQueueIntegration`（`platforms/macos/src/TasksRunner.swift`）的守卫改为：intent 为 `.none` → 不做；否则只要有**任意一个**目标 `effective != .none` 就继续（不因某个仓库缺远端而整体拒绝）。`PRRun` 增加 `targets: [WorkspaceRepo]` 与每个仓库的 effective。

失败处理：各仓库独立——某个失败不丢弃已成功的仓库，`QueueRepoRun.status` 分别记录，队列仍进入 `done`，卡片展示「N 个成功 / M 个失败 + 原因」，失败仓库可单独重试（v1 先只展示，重试列入 P4）。

### 7.4 结果解析

`prURL(in:)`（`platforms/macos/src/TasksRunner.swift`）升级为 `repoResults(in:)`：解析每行 `<repoID>: <action> <结果>`，PR 行取 URL；解析不到时，对每个目标仓库用 `findExistingPR(repo:branch:)` 兜底（现有 `findExistingPR` 已按 owner/repo 查询，改造量小）。

## 8. UI

| 位置 | 改动 |
|---|---|
| 头部 `TaskWorkspaceModel`（`platforms/macos/src/TasksUI.swift`） | 单仓库模式：仓库能力（`owner/repo` 或 `目录名 · 非 GitHub 仓库`）；多仓库模式：`目录名 · N 个仓库`（N≥1，tooltip 列出仓库名）。`githubAvailable` = 任一仓库有 GitHub 远端 |
| 工作区形状重检 `TaskWorkspaceShape`（`platforms/macos/src/TasksUI.swift`） | 从「变成 git / 多了远端」扩展为「仓库集合变化（新增 / 删除仓库）」，复用已有 `workspaces.invalidate + adoptWorkspace` 机制 |
| 队列表单 `QueueComposerModel`（`platforms/macos/src/TaskInlineForms.swift`） | 单仓库模式：无仓库选择区（与今天一致）；多仓库模式：`availableRepos` 仓库选择区，**默认只选 primary（根）**，N==1 只读锁定。分支仍只有一个，跨仓库统一 |
| 队列卡片 / 队列头 | 增加仓库徽标；完成后展示 N 个 PR 链接（`repoRuns`） |
| 空态 / 状态行 | 多仓库模式给出「本工作区有 N 个 git 仓库」的说明 |

### 8.1 面板设置：按仓库独立配置

现有设置项都是「按工作区」存的，多仓库下必须能**逐仓库**配置（用户 2026-10-02 要求）：

| 设置项 | 现在 | 多仓库模式 |
|---|---|---|
| GitHub token | 已按 `owner/repo` 存文件 | 不变（本来就是仓库级） |
| 工作流默认（交付方式） | 按工作区 | **按仓库**（默认跟随主仓库） |
| 交付成功后自动关闭队列 | 按工作区 | **按仓库**（默认跟随主仓库） |
| issue 仓库归属 | 新增，工作区级选择 | 不变（它就是在选一个仓库） |
| 主仓库（primary） | 自动（根 → 第一个 GitHub → 第一个 git） | **可由用户指定**（工作区级，选中集合里的一个仓库） |
| 任务超时 | 全局 | 不变（壳层级限制，不随仓库变） |

**仓库级配置的继承（跟随主仓库）**（用户 2026-10-02）：

- 主仓库的仓库级配置是**唯一来源**；其他仓库**默认跟随主仓库配置**；
- 每个非主仓库有一个「跟随主仓库配置」开关（默认开）：开着则字段禁用并显示继承值；关掉则用主仓库当前值预填该仓库字段，从此独立存储；
- **token 不参与跟随**：它是 `owner/repo` 级凭据，每个 GitHub 仓库各自填写。

**解析链**（工作流默认 / 交付后自动关闭各自独立）：

1. 该仓库有显式按仓库值 → 用它；
2. 该仓库非主仓库且未显式设置（默认跟随）→ 用主仓库的解析结果；
3. 主仓库未显式设置 → 旧的工作区值（兼容既有数据）→ `recommended(primary)`。

**存储**（`platforms/macos/src/IssueRunnerPanel.swift`，沿用 `workspaceSettingsKey`）：

- 新增 `tasksIntegrationByRepo` / `tasksAutoCloseOnPublishByRepo`，键由工作区路径与 `repoID` 拼接（分隔符取不会出现在路径里的字符）；**只存显式值，缺失 = 跟随主仓库**；
- 新增 `tasksPrimaryRepoByWorkspace`（工作区级，值 = `repoID`）：指定值若仍存在于当前仓库集合就用它，否则回退 §4.1 的自动规则；
- 不迁移旧值：旧的工作区值作为主仓库的兜底（解析链第 3 步）。

**UI（设置抽屉 `TaskSettingsView`，`platforms/macos/src/TaskInlineForms.swift`）**：

- 单仓库模式：与今天完全一致（一个 token 框 + 一组工作流 radio + 一个自动关闭勾选）；
- 多仓库模式：抽屉顶部一排**仓库选择**（分段控件 / 列表），**主仓库固定排第一**，其余仓库在后；选中哪个编辑哪个仓库；
- 选中非主仓库时，顶部显示「跟随主仓库配置」开关（默认开）：开着则工作流 / 自动关闭字段禁用并显示继承值，只有 token 可编辑；关掉则字段可用并用主仓库当前值预填；
- 主仓库没有「跟随」开关（它就是来源）；单仓库模式隐藏主仓库设置（唯一仓库即主仓库）；
- 每个仓库的选项按其能力收窄（无远端不给 push/PR，非 GitHub 不给 token 框）；
- 抽屉顶部给出「本工作区有 N 个仓库」总述；切换仓库、或改主仓库导致重排时，表单内草稿按仓库缓存，不丢未提交输入。

**与队列 intent 的关系（关键）**：

- 队列的 `integration` 仍是可选覆盖；**未覆盖时，每个目标仓库用它自己的按仓库默认值**作为 intent，再叠加 §7.2 的能力降级：
  `intent(repo) = queue.integration ?? perRepoDefault(repo)`；
- 单仓库模式下退化为今天的行为（队列未覆盖 → 该工作区/该仓库的默认值）；
- 多仓库模式的队列表单默认「**跟随各仓库设置**」，也可选一个统一模式覆盖全部（复用今天的 radio，多一项「跟随各仓库设置」）。

## 9. issue 区

issue 天然属于**一个** `owner/repo`，多仓库下必须收敛：

- 新增按工作区存的设置 `issueRepoID`（`WorkspaceRepo.id`），默认 **跟随主仓库**（用户 2026-10-02）；用户可在 issue 区切换，切换后即显式指定，不再跟随；
- issue 列表 / 刷新 / token / 「全部处理」都针对该仓库；
- issue 任务的 auto queue 的 `repos` 固定为 `[issueRepoID]`；
- 多仓库模式下始终有仓库归属：N≥2 可切换，N==1 只读锁定（见 §4.3）；单仓库模式维持今天的形态；
- **主仓库不是 GitHub 仓库时**：issue 区显式提示「主仓库不是 GitHub 仓库，请选择仓库」，不静默回退到别的仓库（Q12）。

## 10. 持久化与迁移

- `queues.json` 新增可选 `repos` / `repoRuns`；`platforms/macos/src/TasksStore.swift` 读写无需版本升级。
- `issueRepoID` 进本地设置（不进 `queues.json`）。
- 面板设置新增按仓库的 `tasksIntegrationByRepo` / `tasksAutoCloseOnPublishByRepo`（`ShellConfig`），读取回退到旧的工作区值，无需迁移（§8.1）。
- 无需数据迁移脚本：缺省字段即旧语义。

## 11. 分阶段实施

| 阶段 | 内容 | 交付价值 | 风险 |
|---|---|---|---|
| **P1** | `WorkspaceRepoSet` 探测 + 模式判定（§4.3）+ 头部 + 队列表单仓库区 + 按 targets 的提示词分派 + **按仓库设置与主仓库设置**（§8.1） | 面板能识别多仓库、逐仓库配置与指定主仓库；加子仓库不换交互范式 | 低 |
| **P2** | 按仓库预检 + `gitFor` 切分支 + 简报聚合 | 队列「切分支/交接」真正覆盖多仓库 | 中 |
| **P3** | 按仓库交付 / PR（各仓库独立降级）+ `repoRuns` + 卡片 N 个结果 | 交付闭环 | 中高 |
| **P4** | issue 仓库选择 + 失败仓库单独重试 | 收尾 | 中 |

每阶段都保持两条老路径（根仓库 / plain）零变化，并各自补无头测试。

## 12. 测试计划

沿用 `tests/tasks-panel/` 五段结构与「假 git 全部脚本化」的做法：

- **模型段**（`model-tests.swift`）：`WorkspaceRepoSet.detect` 用临时目录树（含 `git init` 的子仓库、含 submodule 排除）断言各场景，重点是**根非 git + 恰好一个子仓库 → 仍是多仓库模式**；`QueueIntegration.available`（至少一个能原生做到）与 `effective` 的逐仓库降级链；`TaskQueue` 新旧 JSON 往返。
- **运行器段**（`runner-tests.swift`）：`gitFor` 按路径分派脚本化的 fake git——多仓库全部切分支成功；一个仓库脏 → 预检失败且**不切任何仓库**；简报按仓库分组；finalize 提示词给出每仓库 effective；`repoResults` 解析与兜底；**单目标（无论根仓库还是子仓库）的提示词与今天单仓库文本逐字节相同（子仓库只多一行工作目录说明）**；混合能力下每仓库的 effective 降级（PR → push → 本地合并 → 不做）与 per-repo 结果解析。
- **视图模型段**（`ui-tests.swift`）：头部各模式；多仓库表单默认只选 primary、可改选；混合能力的逐仓库动作提示。
- **设置段**（`form-tests.swift` / 模型段）：按仓库设置的写入与读取回退链（按仓库 → 旧工作区值 → `recommended`）；多仓库抽屉的仓库切换与能力收窄；`intent(repo) = queue.integration ?? perRepoDefault(repo)`；**主仓库指定的解析与失效回退**（指定仓库被移除 → 自动规则）；**非主仓库「跟随主仓库」的继承与关闭后独立存储**；**issue 默认跟随主仓库、用户切换后不再跟随**。
- **视图段**：多仓库头部/卡片仓库徽标存在性。
- **源码守卫**：与现有「提示词必须现场探测 repoShape」同源的守卫，加一条「目标仓库集合必须运行期重探测，禁止从 env 抄一份」。

## 13. 风险与取舍

| 风险 | 处理 |
|---|---|
| 预检通过后中途 enter 失败，仓库状态不齐 | 不回滚（非破坏性），错误里说清哪些已切；重试从当前状态继续 |
| 各仓库默认分支不同 | 按仓库各自探测，不共用 `main` |
| 根是仓库且其子目录是 submodule | 默认按根 `.gitmodules` 排除，避免父仓库/子模块被当两个目标重复处理（Q10） |
| 根仓库把独立子仓库当嵌入式仓库（gitlink） | 不要求根仓库跟踪子仓库内容：提示词逐仓库独立提交；根仓库如何对待子目录（`.gitignore` / submodule）由用户决定 |
| PR 结果解析脆弱 | 保留 `findExistingPR` 按仓库兜底，不把解析成功当唯一判据 |
| 探测误报 / 性能 | 只扫一层、跳过重目录、后台线程、函数可注入 |
| 破坏现有测试 | 根仓库单仓库（legacy）行为逐字节不变；单目标提示词与今天单仓库文本逐字节相同（§4.3），清单文本只走 `targets.count ≥ 2` |
| agent 在 N 个仓库间出错 | 提示词显式列仓库、逐仓库操作；v1 一个会话，后续可拆每仓库一个 finalize |

## 14. 待确认问题（评审）

| # | 问题 | 我的建议 |
|---|---|---|
| Q1 | 仓库发现范围：只扫直接子目录 / 递归多层 / 用户手动配置 | **已定：只扫直接子目录**，排除隐藏目录与 `.gitmodules` 里的 submodule（用户 2026-10-02） |
| Q2 | 队列目标仓库：默认全部 / 必选 | **已定：默认主仓库（primary），可改选其它**（用户 2026-10-02） |
| Q3 | 混合能力交付：整体聚合 / 每仓库独立处理 | **已定：各仓库独立处理**，按能力降级（PR → push → 本地合并 → 不做），结果按仓库分记（用户 2026-10-02） |
| Q4 | finalize：一个队列一个会话 / 每仓库一个 | **已定：一个队列一个会话**；失败仓库单独重试留 P4 |
| Q5 | issue 仓库：默认 primary / 每次询问 | **已定：默认跟随主仓库**，可切换（用户 2026-10-02）；切换后成为显式指定 |
| Q6 | 根目录本身是仓库且子目录也是仓库 | **已定：根 + 子都参与，根为 primary（用户 2026-10-02）** |
| Q7 | 分支名：跨仓库统一 / 每仓库可不同 | **已定：跨仓库统一** |
| Q8 | 模式判定：按仓库数量 / 按结构 | **已定：按结构**（§4.3）——只有「根是仓库且无参与子仓库」才是 legacy 单仓库；提示词措辞另按 `targets.count` 决定 |
| Q9 | 根目录后来 `git init` | **Q6 定为根 + 子都参与后此问题消解**：根只是加入集合并成为 primary，不切换模式；状态行提示即可 |
| Q10 | 根是仓库时，子目录里的 submodule 是否作为独立目标 | **已定：排除**（由父仓库管理）；普通独立子仓库加入 |
| Q11 | 面板设置按仓库的范围 | **已定**（用户 2026-10-02）：工作流默认、交付后自动关闭按仓库，**非主仓库默认跟随主仓库**；token 已按仓库（不跟随）；issue 归属是工作区级选择；超时保持全局；主仓库为工作区级设置 |
| Q12 | 主仓库不是 GitHub 仓库时，issue 区怎么办 | **已定：显式提示 + 提供切换**（不静默回退到别的仓库），例如「主仓库不是 GitHub 仓库，请在 issue 区选择仓库」 |

## 15. 参考

- `docs/design/panels/issue-runner-design.md` — 任务面板主设计（工作区形状、队列、提示词现状）
- `docs/design/panels/tasks-queue-session-loop-design.md` — 队列 × 会话回传、队列状态机
- `docs/process/git-workflow.md` — 分支与提交规范
- 关键源码：`platforms/macos/src/IssueRunnerPanel.swift`、`platforms/macos/src/TasksRunner.swift`、`platforms/macos/src/TasksCore.swift`、`platforms/macos/src/TasksUI.swift`、`platforms/macos/src/TaskInlineForms.swift`、`platforms/macos/src/TasksStore.swift`
