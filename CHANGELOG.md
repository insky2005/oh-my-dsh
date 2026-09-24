# Changelog

All notable changes to this project are documented in this file. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). Versions below
`v1.8.0` are summarized from the git history (conventional commits).

## [Unreleased]

### Added

- **项目面板（Projects，`⌥⌘P`，活动栏首位「项目」图标）：把「工作区 = 一个目录」变成壳层里的一等公民**。面板以可配置的**项目根目录**（默认 `$DSH_HOME/oh-my-dsh/projects`，可改成任意绝对路径，存 `shell/config.json` 的 `projectsRoot`）为范围，每个直属子目录就是一张工作区卡片：
  - **新建工作区**只需输入目录名：面板 `mkdir -p <root>/<name>` 后调 dsh 的 `workspace/create`（**幂等**、路径须已存在）注册；注册失败（dsh 未起来 / 旧版本）只标「未注册」并在下次操作重试，**目录保留**；名字规则在创建前拦截（空 / 含 `/` 或 `:` / 以 `.` 开头 / 超 64 字符）；同名目录已存在按「采用」处理，不报错；
  - **六个快捷入口**：文件 / 终端 / 知识库 / 任务 / 通道 / 审查——点一下即把壳层当前工作区切到它并打开对应面板（终端 cwd、文件树根、wiki 根、任务·通道·审查的工作区一起跟随）；
  - **新会话**：点 dsh web 侧栏**该工作区行自带的 `+`**（注入桥 `window.__dshNewSession(工作区名)`）——由 dsh 自己决定**复用该工作区已有的空会话**还是新建，然后打开它，壳层只是"替用户点了那一下"；**在 dsh 中打开**（点卡片名称）复用该工作区最近一条**可打开**的会话（`blank` 空会话在侧栏不可见，故跳过；运行中优先），没有则走「新会话」；另有在 Finder 中显示 / 复制路径；
  - **新建即选中（壳层 + dsh web 两侧）**：创建（或采用）工作区成功后 ① 面板立刻经 `onSelectWorkspace` → `adoptProjectDirectory` 把它变成**当前工作区**——卡片**高亮**、各面板重根到它，并把该卡片**自动滚进视野**（列表按名字排序，新卡片常在很下面；日志 `projects: selected the new workspace …`）；② 注册成功后 `onWorkspaceRegistered(path)` → **dsh web 也切到该工作区**（点它侧栏行的 `+`：dsh 复用该工作区的空会话或新建，然后打开，侧栏行还会滚进视野）——这也正是 dsh 自己「添加工作区」的行为（`WorkspacePickFlow.onPick` → `startSession`）：**一行工作区行不等于"当前工作区"**，没有会话的 workspace 在 web 里没有可选中项，不这么做页面会一直停在上一条会话上。被名字规则拒绝的名称不建目录、也不改变当前工作区；
  - **单一真相**：当前工作区始终是壳层的 `ProjectDirectory`，重根收口到新抽出的 `AppDelegate.adoptProjectDirectory(_:)`（`dshSession` 跟随、面板快捷入口与新建工作区共用同一个原语，面板只做高亮——**不引入第二个"面板内选中项"**）；该原语带 `fileExists` 守卫，拒绝把面板重根到已消失的目录（旧代码会照常重根）；
  - **侧边栏延迟**：刚注册的工作区由 dsh 自己的**工作区流**送达客户端侧栏（实测 **~0.17 秒**出现在侧栏 DOM，**不需要刷新、更不需要重连**）；「新会话」的桥内部重试 12×150ms 等工作区行出现，「在 dsh 中打开」失败后 1.5s 再试一次，仍失败就**放弃**并写面板状态行——**永不自动重载页面**（旧版的失败重载 + `didFinish` 重放会形成每 ~10s 一轮的死循环刷新，已在 `ed989ac` 删除）；
  - **未注册的目录不联动**：项目根目录下某个目录若不在 dsh web 的 workspace 里，卡片就不提供 dsh 动作（「新会话」禁用、点卡片只在状态行提示），六个**本地**面板入口（文件/终端/知识库/任务/通道/审查）照常可用，并在徽标后面多出一个 **folder+ 图标按钮「添加工作区 / Add workspace」**（与 dsh web 同词；幂等注册 → 徽标翻「已注册」、dsh 动作解锁）；**已注册**的卡片则在徽标后面显示 **`+` 图标「新会话 / New Session」**（两个按钮互斥，都在标题行）；
  - 实现：`platforms/macos/src/ProjectsCore.swift`（纯模型：根目录解析 / 命名规则 / 目录列举 / 与 dsh 注册表按 canonical 路径合并）、`ProjectsPanel.swift`（面板：卡片三行 + 头部 + 根目录行 + 空态 + 结果行 + 取名 sheet）、`DshWebRPC.swift` 新增 `workspaceCreate` 端点与 `DshWorkspaceOps`（注册 / 建会话 / 按工作区挑会话）、`main.swift` 接线与设置窗口「项目」区块（路径字段 + 选择…/保存/恢复默认）；测试 `tests/projects-panel/`（模型 45 项 + 控制器无头 49 项 = **94 项**）与 `tests/dsh-rpc/` 新增 14 项（整套 54 项），均已接入 CI 与 `scripts/local-ci.sh`；设计见 `docs/projects-panel-design.md`。
  - 顺带修正 `DshWorkspaceStore.canonical`：改用 `realpath(3)`，让 macOS 目录列举给出的 `/private/var/...` 与用户/dsh 存写的 `/var/...` 归一到同一条工作区（此前两种写法互不相等，面板会把已注册工作区标成「未注册」）。

- **Files 面板：目录树右键「添加到对话」把文件/文件夹作为 `@` 引用插进 dsh web 的输入框**：在文件或文件夹上右键 → **添加到对话** → 输入框末尾出现该条目（文件夹带尾斜杠，含空格的路径走 dsh 的 `@"…"` 引号语法）的引用 chip —— 与用户自己敲 `@` 从候选里选出来的是**同一种节点**，提交时序列化成同一段 `@相对路径` 文本。项目根与空白处不提供（没有「相对的自己」）；未打开会话时条目禁用并提示。**不改 dsh 源码**：壳层把 chip 节点直接写进 dsh web 的 Lexical 编辑器（`window.__dshInsertFileReference`），不伪造按键也不依赖焦点。新增纯模型 `platforms/macos/src/ComposerReference.swift`（引用语法 + 相对路径，无头单测 `tests/file-panel/composer-reference-tests.swift`）与目录树菜单规则/用例更新；真 WKWebView 实测与 dsh 升级核对项见 `docs/dsh-version-impact.md` B9 与 `docs/file-panel-composer-reference.md`；QA 钩子 `DSH_COMPOSER_TEST_PATH` / `DSH_COMPOSER_TEST_SESSION`。

### Changed

- **视图菜单「显示/隐藏 预览面板」正名为「显示/隐藏 文件面板」，快捷键由 `⌥⌘P` 改为 `⌥⌘F`**：该面板的实现从 v1.7 起已由 `FilePanel.swift` 承担，活动栏（`bar.preview` = 文件 / Files）、面板头部与 README 里也一直叫「文件」，只有视图菜单还留着旧名「预览」。同时把 **`⌥⌘P` 空出来给即将落地的「项目」面板**（本提交只做让位，面板本身单独评审）。L10n 键同步改名 `menu.togglePreview` → `menu.toggleFiles`（避免留一个名不符实的死键），设置窗口的快捷键清单同步更新为 ⌥⌘F。

### Fixed

- **项目面板「新会话」每次都要 dsh web 重连，而且新会话根本不出现（实际已经建了）**。根因有两层，都在"壳层替 dsh web 建会话"这个做法上：① dsh web 侧栏对会话有一条**可见性规则**——*Ordinary sessions are visible; among blank sessions, only the current one is visible*（`dsh-client-ui-workspace/lib/client.js` 的 `sessionVisible`；`blank` = 从未发过消息的会话）。壳层用 `session/create` 建的正是 blank 会话，而它不是页面的当前会话，于是**侧栏里连这一行都没有**；壳层切页面的唯一手段是点行，于是「新会话」永远切不过去，还每点一次就多留一条谁也打不开的空会话（`app.log` 里 `workspaceRow=yes` + `sessionRows` 不增长、`session/list` 里空会话越积越多）。② 为了掩盖①，旧代码每次先 `nudgeDSHWebCaches()`——派发合成的浏览器 `offline`→`online` 让客户端重连，这就是用户看到的**每次点都重连**。现在「新会话」改走 dsh 自己的入口：注入桥新增 `window.__dshNewSession(工作区名)`（`sessionOpenerScript`），在侧栏找到该工作区行并点它行内自带的 `+`（`dsh-client-ui-workspace` 的 `ProjectRowItem`；行内按钮固定 [工作区菜单, 新建会话]，取最后一枚；hover 才显示但 `click()` 有效，实测可用），于是 dsh 自己执行 `connectWorkspace` 的语义——**复用该工作区已有的 blank 会话，没有才建，然后 open**（会话成为当前会话，blank 行随之以本地化的「新会话 / New Session」出现在侧栏）。结果：不重连、不堆空会话、完全复用 dsh 的语义；壳层经 `dshSession` 追踪器跟随页面切过去的会话。侧栏 DOM 变样时（B10）保留兜底：走 RPC 建会话 + 状态行 `projects.newSessionFallback` 提示去侧栏该工作区行点「+」（那一步会复用这条空会话），**不再 nudge、也不再点行**。配套：`DshWorkspaceOps.newestSessionId` 跳过 `blank == true` 的会话（「在 dsh 中打开」不会再选中一条打不开的空会话，只剩空会话时改为走「新会话」由 dsh 复用）；`onWorkspaceRegistered` 不再 nudge（实测新工作区经 dsh 的工作区流 1–2 秒内自己出现在侧栏）。新增无头套件 `tests/injected-scripts/`（注入 dsh web 的所有 JS 必须可解析、每个 `window.__dshX` 桥名都必须有脚本安装它、不许出现会被 Swift 吃掉的转义——历史上这类错误的表现就是"按钮点了没反应"），`tests/dsh-rpc/` 补 3 例守 blank 跳过；两套均已接入 `scripts/local-ci.sh` 与 CI。
- **项目面板新建工作区后没有任何「选中」反馈（要自己在列表里找那张新卡片）**。以前创建**不**切换当前工作区（当时的顾虑是"用户没点任何入口，右栏内容就跳走"），代价是反直觉：刚在这里建完项目，卡片却不亮、也不一定在视野里。现在**创建即选中**：`createWorkspace` 成功后立刻经新回调 `onSelectWorkspace` → `adoptProjectDirectory` 把它变成当前工作区（卡片高亮 = `ProjectDirectory.current`，面板**不引入**第二个选中态），并记 `pendingScrollPath`，下一次渲染把该卡片 `scrollToVisible` 滚进视野；同名目录按「采用」处理时同样选中，被名字规则拒绝的名称则**既不建目录也不改变当前工作区**。控制器无头测试补 3 例（非法名不选中 / 新建选中 / 采纳选中）。
- **项目面板建完工作区后，dsh web 还停在原来那条会话上（没切到新工作区）**。新工作区的**侧栏行**确实自己出现了（dsh 的工作区流推送，实测 ~0.17s），但**"有行"不等于"是当前工作区"**：dsh web 的"当前工作区"是由**当前会话**决定的，而一个刚建的空目录还没有任何会话，于是没有任何东西可被选中，页面继续显示旧会话——壳层卡片亮了，web 那边没动。dsh 自己的「添加工作区」正是为此在选完文件夹后立刻 `startSession(workspaceId)`（`WorkspacePickFlow.onPick`）。现在壳层照做：注册成功后 `onWorkspaceRegistered(path)` → `dshWebFollowNewWorkspace` → **点该工作区侧栏行自带的 `+`**（复用「新会话」那条桥，dsh 复用空会话或新建并打开），并把该行 `scrollIntoView` 滚进视野。卡片 folder+（采纳一个已存在但未注册的目录）走同一条回调，行为一致。控制器无头测试补 2 例（新建注册后回传路径 / folder+ 注册后回传路径）。

## [1.16.2] - 2026-09-23

### Added

- **会话快照与回退（Session Snapshots，设置菜单 →「会话快照…」）**：dsh 升级会把会话日志换成新世代（0.1.5 起新建会话写 `session.v3.jsonl.zstd`，被迁移的老会话把原文件留成冻结归档），而**上游只有升级链、没有降级通道**——这是一次不可逆的数据迁移。壳层现在在**任何 App / 内置 dsh 版本组合变化之前**自动留一份可回退的快照：
  - **数据快照**：`$DSH_HOME/sessions/ + storages/`，APFS clonefile（实测 306 MB / 246 会话 = **0.124 s**、几乎不占额外空间），最多保留 3 份；裁剪时保护「当前数据所属组合 / 最近一次回退目标 / `forCombo` 等于当前组合」三份；
  - **树池**：`runtime/dsh` 整树**按 dsh 版本去重**存一份（实测 256 MB / 24,872 文件 = 5–6 s、约 14 MB），每次启动自查补齐——**这一步是必需的**：装新 pkg 会把旧 bundle 连同旧 `runtime/dsh` 一起替换掉，事后再抓来不及；
  - **触发时机**：① 功能首次启用（`bootstrap` 基线）② App/dsh 组合变化 ③ **App 内升级 dsh 之前（强制，`performApply` 里接线）** ④ 用户点回退时的现场快照（`pre-rollback`，使回退可撤销）。顺序铁律是**先快照、再起 dsh**——dsh 一打开会话就会补写 `session/end-seed`，晚一步就抓不到干净状态；组合未变时启动只读一次状态文件（实测 **0.059 s**）；
  - **回退并退出**：预览「将恢复 N 条（并移除其新世代日志）/ 将隔离 M 条 / 内置 dsh 换回 X」→ 二次确认 → 停自拉起的 dsh web → 现场整体停放到 pre-rollback 快照 → 恢复目标数据 → 快照之后新建的会话**移入隔离区而不是删除**（带清单） → 换回旧 dsh 树（池内 rename，**离线瞬时**；缺则提示联网补装或改重装旧 App） → 写回 `dataCombo` 并**钉住自动升级** → 退出 App（活着的 dsh 会立刻把会话再迁移回去，所以必须退出）。事务带 `rollback-journal.json`：中途崩溃或「数据与树版本不一致」会在下次启动给出提示，可**续做/撤销**；
  - **边界**：这是数据回退，不是 App 回退（pkg 装不了旧版本）——「问题出在 App 本身」时走「只回退数据 + 提示安装旧版 App」，快照 meta 记着当时的 App 版本供提示使用；凭据（`credentials*`）、壳层自身状态与 token（`shell/`，含 `dsh-web.json` 里那把 launch token）、通道绑定（`channels/`）、CEF profile（`browser*/`）**一律不进快照、不回退**；
  - 实现：`core/lib/snapshot.js`（纯决策：触发判定 / 回退计划 / 裁剪保护 / 事务状态机）、`core/lib/snapshot-io.js`（落盘：clonefile、树池、隔离、裁剪）、`ohmy-core snapshot …` CLI、`platforms/macos/src/SnapshotModel.swift` + `SnapshotWindow.swift` 与启动前钩子；测试 `core/tests/snapshot*.test.js`（21 例）、`tests/snapshot-rollback/run.sh`（端到端，含升级路径与崩溃拒绝）、`tests/snapshot-panel/run.sh`（窗口模型），均已接入 CI。设计与九类场景演绎：`docs/session-snapshot-rollback-design.md`。
- **升级核对专用 QA 钩子（仅开发/QA）**：`DSH_PANEL_TEST="files,terminal,wiki,tasks,browser,channel,review,skills"` 在启动后按序切到每个面板（配 `DSH_UI_DEBUG=1` 每个面板各落一张 `panel-<name>-debug.png`）——此前只有六个单面板钩子，且缺的恰是**没有菜单快捷键、脚本点不到**的 tasks 与 channel；`DSH_PREVIEW_DEBUG=1` 的文件打开探针同时演练**新旧两种请求形状**（`host.openPath` 与 `session/openWorkspacePath` + `payload.args.request.path`），拦截器只认老形状时会当场失败，而不是在 UI 里静默。

### Fixed

- **修复：快照的树池会收下「从没启动成功过」的树，回退时把坏树换回来**（用户实测踩到：升级到 0.1.5 正常 → 回退到升级前快照后启动即报同一个 HMR 错）。原因：启动钩子在 **spawn dsh web 之前**就抓树，于是"构建坏了但 App 起来了"的状态下，池里存下的是漂移闭包（`cordis-plugin-hmr 1.0.19`）；回退把这份坏树换回 bundle → 再次启动失败。三处修复：① **抓树改到页面加载完成之后**（`captureRuntimeTree()` 挂在 `didFinish`，一次/启动）——只有**已经证明能启动**的树才进池；`snapshot launch` 增加 `--no-tree`（启动前的数据快照不变）；② **闭包校验**：新增 `snapshot tree` 子命令与 `captureTree` 的 `--expected-lock` 守卫——与提交的 lock 指纹不一致的树**拒绝入池**，池里已有的不一致副本会被替换；回退换树前同样校验，不一致则**拒绝换入**并回报 `needsTreeInstall`（让壳层用 lock 重新 `npm ci`）；③ **补装走 lock**：`DSHUpdater.installVersion` 在 App 带着该版本的提交 lock 时改用 `npm ci`，`runtime-locks/` 随 App 一起分发。
- **修复：新构建的 App 因运行时依赖漂移而无法启动（`dsh: user patch-layer watching requires the Cordis HMR service`）**。只钉 `DSH_PACKAGE_SPEC` **不够**——dsh 用 caret 范围声明它的 cordis 工具链（`^1.0.17` 等），所以 `npm install @deepseek-ai/dsh@0.1.2-rc.1` 会装上**当天最新的 1.x**：实测重建得到 `cordis-plugin-hmr 1.0.19`（已安装的生产包是 1.0.17），而新版 HMR 插件在 0.1.2-rc.1 的 loader 下无法实例化 → profile 的 `patchReload: "live"` 走到 `watchUserPatches` 直接抛错、`dsh web` 打印入口 URL 后立刻退出（App 表现为启动失败/白屏）。单独把 `hmr` 钉回 1.0.17 仍报错——漂移是整组的。现在：① 仓库为每个受支持的 spec 提交一份**已知可启动**的闭包锁 `platforms/macos/runtime-locks/<spec>/{package.json,package-lock.json}`（0.1.2-rc.1 那份从真能启动的生产运行树导出，583 个包），构建改用 **`npm ci`** 复现闭包；② 没有 lock 的 spec 走老路并打印警告；③ 装完做**启动冒烟**（`smoke_runtime`：起一次 `dsh web`，40 秒内必须打出入口 URL 且进程存活，否则**构建失败**并打印日志；跨架构 stage 自动跳过；可用 `DSH_SKIP_RUNTIME_SMOKE=1` 临时跳过）；④ runtime 缓存键加入 lock 指纹，改锁即重建。排查与结论记入 `docs/dsh-version-impact.md` E7 / R8 详解。
- **审查面板预先适配 dsh 的「会话日志世代命名」（为后续 dsh 升级铺路；当前内置 dsh 仍是 0.1.2-rc.1，日常行为不变）**：dsh 按 **Session 格式世代**给会话日志命名——世代 0 是 `session.jsonl`，之后每代带 `.vN`（`session.v3.jsonl`），压缩存储再加 `.zstd`。**dsh 0.1.5 起新建会话直接写 `session.v3.jsonl.zstd`**；被迁移过的老会话则把原来的 `session.jsonl.zstd` 留作冻结归档、活日志换成新世代名（实测同一会话：归档 19 条事件、活日志 22 条，之后的新事件只进活日志）。壳层读取器原先只认世代 0 的两个文件名，一旦内置 dsh 升级就会**新会话一条都列不出来、老会话永远停在迁移前的旧内容**——面板不报错，只是空或旧（`app.log` 里表现为 `review: listed 0/N sessions` + `review: audit FAILED`）。现在 `core/lib/review-log.js` 按**规范文件名**枚举（`^session(\.v[1-9][0-9]*)?\.jsonl(\.zstd)?$`，`.v0`/大写/前导零/临时后缀等非规范名一律拒绝），**取世代号最大的那一份**（迁移会话因此读活日志而不是归档），同代压缩优先；新增 `sessionLogCandidates()` 暴露完整候选顺序。`core/tests/review-log.test.js` 增 6 条用例（新世代会话可被发现并审计、迁移会话读活日志、非规范名忽略、世代 0 向后兼容、压缩与非压缩两种新世代文件）。
  - 内置 dsh 的版本推进（0.1.2-rc.1 → 0.1.5-rc.2）**兼容审计已完成、暂缓执行**：五个耦合面的逐项实测记录见 `docs/plans/dsh-015rc2-compat-audit.md`（端点只增不减、参数包裹字段与鉴权 cookie 未变，唯一断裂点就是上面这条），通用清单 `docs/dsh-version-impact.md` 已补 D6/D8/D9、R7 详解与两条 SOP 核对项。**待「会话快照 + 回退」功能上线后再推进**——那次升级会让会话日志换代且无法回退到旧版 dsh，必须先有安全网。

## [1.16.0] - 2026-09-21

### Added

- **技能面板（Skills / `⌥⌘S`，活动栏「技能」）：在壳层里查找 / 安装 / 移除 agent 技能，并管理调用开关**。面板分「已安装」与「可安装」两个页签：**已安装**扫描 dsh 的四个技能根（`<工作区>/.dsh/skills`、`<工作区>/.agents/skills`、`$DSH_HOME/skills`、`~/.agents/skills`），按 dsh 的 rank 去重并逐行标出**级别** —— `内置` / `用户级` / `共享级` / `项目级`（同名被压住的标「被遮蔽」）；**可安装**按当前 registry 渲染清单或按关键字搜索，支持清单勾选安装、从地址安装与手动导入本地目录。**内置技能只读**（开关禁用、无移除入口、不可被安装覆盖——App 启动时按内嵌内容同步，字节一致性不变，故 `SkillInstaller.swift` 零改动）；**共享级**（外部 skills CLI 管理的 `~/.agents/skills`）可看可改开关、但不在面板里移除；**用户级 / 项目级**可改开关、可移除。
  - **调用开关写回 SKILL.md frontmatter**：`用户可调用` → `user-invocable`、`模型可调用` → `disable-model-invocation`（关闭即写 `true`）；**切回默认值会删掉该键**，从而字节还原原文件；只增删改这两行，键序/注释/引号/CRLF/正文全部原样保留（不是 YAML 往返）。**只写规范键**——dsh 对旧的驼峰键（`userInvocable` 等）会直接忽略整个技能。改完 dsh 自动发现，无需重启；重启后开关仍在（记录在壳层 `$DSH_HOME/shell/skills.json`，面板重装同一技能时按记录重放）。
  - **安装目标**：默认 **用户级** `$DSH_HOME/skills/<name>/`（所有工作区通用），可选 **项目级** `<工作区>/.dsh/skills/<name>/`（rank 100、优先级最高，写用户仓库前会提示 git diff）；同名已存在先确认，目标是内置同名技能则拒绝；技能目录**整目录复制**（SKILL.md + 附件），拒绝路径穿越、仅接受 https、失败不留半成品。
  - **registry 是可配置项**（`shell/skills.json` 的 `registries`，默认预置 skills.sh）：`owner/repo` 或 GitHub 地址 → **列出该仓库的技能清单**（浅克隆后本地扫描，避开 GitHub API 限流）；well-known 地址 → 读 `/.well-known/skills/index.json` 清单；其他 URL → 视为 skills.sh 兼容的搜索接口（模板 `{q}`/`{limit}`）。**skills.sh 只提供关键字搜索、没有全量清单接口**（实测 `/api/leaderboard`、`/api/skills` 均 404，站点榜单是 HTML）——因此该 registry 未配清单来源时，列表区明确提示「按关键字搜索」，不做 HTML 抓取。
  - 新增 `platforms/macos/src/SkillsPanel.swift`（右栏面板）、`SkillsCore.swift`（纯 Foundation 模型：frontmatter 读写、四根扫描与级别判定、壳层技能记录 `shell/skills.json`）、`SkillSources.swift`（地址解析、registry 清单与搜索、拉取/安装/移除，传输可注入）与 `tests/skills-panel/`（无头模型单测，已接入 `scripts/local-ci.sh` 与 CI swift job）；`tests/skills/` 的内置技能字节断言保持不变。
  - 设计、四档级别判定与 registry 模型：`docs/skills-manager-design.md`；dsh 升级核对项见 `docs/dsh-version-impact.md` D2/D2b/D2c/D2d。
- **技能面板的「可安装」列表：整张卡片可点看详情 + 悬停才出现安装按钮**：点击卡片用**系统默认浏览器**打开该技能的页面（只接受 http(s)，不用内置浏览器面板）——skills.sh 型 registry 打开 `https://www.skills.sh/<source>/<skill>`，GitHub 清单打开仓库内技能目录，well-known 打开该技能的 `SKILL.md`，裸 git 打开远端，本地路径改为在 Finder 中显示；**「安装」按钮改为鼠标移入卡片时才出现**，移出即隐藏，平时列表保持干净；「可安装」页签进入即默认显示**热门列表（按安装量降序，前 30）**，输入关键字切换为搜索结果。
- **文件面板：目录树右键菜单与头部菜单按钮（#1 #2 UI 返工）**：目录树右键菜单按对象给项 —— 目录上「新建文件夹 → 新建文件 ｜ 重命名 → 删除 → 在 Finder 中显示」，**文件上不提供新建项**，「在 Finder 中显示」单独分组；新建在当前目录下创建并进入命名，重命名 / 删除（移到**废纸篓**，可恢复）后页签跟随改名或关闭。面板头部改为「**打开项目 ▾ / 当前文件 ▾**」两个菜单按钮（点击总是打开菜单，不再出现「点了没反应」），「打开文件」按钮**仅在选中文件时可用**；项目目录可用外部应用打开。
- **文件面板：图片预览自适应窗口 + 手动缩放（#8）**：打开图片时按比例**适应窗口**（等比、以较紧的一边为准、不放大超过 100%），支持触控板**捏合**、`⌘+` / `⌘−` / `⌘0`、`⌘`+滚轮、**双击**（适应窗口 ↔ 100%）与放大后拖拽平移，缩放范围 5%–1600%、单步 ×1.25，右下角浮动百分比角标；新增 `ImagePreviewView.swift` 与纯模型 `ImageZoom.swift`（缩放数学可无头测试）。
- **终端面板：滚动方向 / 选中即复制 / 页签按 workspace 隔离（#3 #4 #5）**：滚动方向对齐其余面板的语义；**双击选词**、**选中文本即复制**（新增设置项「终端：选中文本即复制」可关）；终端页签**按 workspace 隔离并记忆**，在 dsh web 切换工作区时同步联动、切到没有终端的工作区自动开启；并恢复触控板滚动惯性。
- **壳层：页面刷新自愈 + 「视图 → 重新加载页面」`⌘R`（#6）**：长时运行后 WebView 手里那份 cookie 可能不再被接受（页面只显示纯文本 `dsh web authentication required…`，而面板照常可用），此前的右键「重新载入」走的是 WebKit 默认菜单、等价于裸 `reload()`，救不回来。现在：① 视图菜单新增**「重新加载页面 `⌘R`」**，刷新改走 `server.entryURL`（带启动 token 的入口地址，303 重新落一份 cookie）而不是裸 reload；② **主框架 401 / 加载失败自动自愈一次**——自己拉起的 dsh web 若已死则重拉；③ `ServerManager.stop()` 清空 `entryURL`/`process` 并新增 `isRunning`，补刷新与 cookie 诊断日志（此前的刷新不留任何日志，复现过也查不到）。成因收敛过程见 `docs/ux-feedback.md` #6。

### Changed

- **面板配色统一为单一灰阶令牌**：面板顶部/内容区底色统一为 `#1B1B1C`（浅色 `#F9FAFB`），卡片 / 按钮 / 页签底色统一为控件两档 `#43454A` / `#353638`（浅色 `#FFFFFF` / `#F1F3F5`）——六色全部取自 dsh web 的 `neutral bluish` 设计令牌，壳层与 web 界面天然同调，取代「每个面板各写一档灰」的历史局面。**单一事实来源 `platforms/macos/src/PanelSurface.swift`，改色只改这一个文件**；方案见 `docs/ui-color-scheme.md`（含两套取色 API、CALayer 不吃动态色的注意事项、语义色与系统绘制控件的边界）。
- **文件面板：大文件保留语法高亮（分块着色）**：不再按行数 / 大小关闭高亮，改为**分块着色**，3000+ 行的文件打开后依然有高亮且不卡 UI。
- README 面板数量文案与目录树同步为八个面板。

### Fixed

- **面板顶部条/标签被同色不透明兄弟视图覆盖（技能面板的标题与按钮不可见）**：`DynamicFillView` 是不透明视图，原实现按 `dirtyRect` 填充，而 AppKit 可能给不透明视图传入**大于其自身 bounds** 的脏矩形——于是内容容器（先添加、层级更低的兄弟）会把它上方的头部条、标签条整条刷成自己的底色，看起来就是"顶部空白/被遮住"。改为 `bounds.intersection(dirtyRect).fill()` 只填自己拥有的区域；技能面板同时把内容容器放到最底层、头部最后添加（双重保险）。新增无头绘制回归测试（`tests/skills-panel/render-tests.swift`：真实 `DynamicFillView`/`HeaderLabel` 离屏渲染后断言头部条有内容、且不透明兄弟不会越界覆盖），已验证**去掉该修复后测试会失败**。
- **Tasks 面板内容区未吃到面板底色**：`NSTableView` 自身背景盖住了面板底色，改为跟随配色令牌。

- **技能面板的改动现在会被 dsh web 立即看到（对话输入框 `/` 的技能菜单不再需要手动刷新）**：dsh 客户端按会话缓存技能目录，且只在 `connection/reset`（连接重连）或切换 agent preset 时失效；技能文件变化不是会话事件、服务端不会推送，所以此前改完 `user-invocable` / 安装 / 移除都必须手动刷新页面。现在面板在**改开关 / 安装 / 移除**后通知壳层，由壳层向 web 页注入 JS 派发**浏览器 offline → online 事件**，触发客户端自身重连并发出 `connection/reset`，各客户端插件缓存（含技能目录）随之清空并重取——与手动刷新等效但不重载文档。1.5s 节流；`DSH_SKILLS_NO_NUDGE=1` 可关闭。

- **可用列表滚动后"划过的技能全部保持高亮"**：AppKit 的 tracking area 只在指针移动时触发 enter/exit，内容从静止指针下滚过时不会触发 `mouseExited`，于是划过的卡片一直亮着、也不还原。现在面板监听 clip view 的滚动通知，每次滚动按**当前指针位置**重算唯一 hover 的卡片（`SkillHoverResolver`，纯函数 + 4 条单测：命中/落在卡片间隙/已被滚出可视区/指针在列表外）。

- **修复「新建的会话在审查面板里只有一行会话、看不到里面改的文件」**：面板的审计结果**按 sessionId 缓存后永不失效**——而新建会话一诞生（成为 dsh web 当前会话）就会被审一次，那会儿日志里只有会话头，于是「0 文件 / 本会话没有记录到文件变更」被**永久钉住**：后面改了多少文件都不会再读一次（点刷新也只重列会话，不动审计缓存）。会话日志是**活文档**（dsh 每落盘一批追加一个独立可解压的 Zstandard 帧，只增不减），因此缓存必须按**日志身份**而不是 id 认账：
  - `ReviewLogModel.ReviewLogStamp`（size + mtime，纯 Foundation）+ `ReviewLogModel.auditNeedsRefresh(cached:onDisk:)`：只有日志与审计时所读的**仍是同一份**才复用缓存；日志路径未知（尚未出现在列表里）时判为「无法判断」，保留缓存而不是反复重读；
  - 审计前先打戳、读完落盘该戳：审计**进行中**追加的帧仍然比戳新，因此下个 tick 会再读一次，不会漏掉最后一批；失败（含解码失败）同样记录戳，坏会话不会每 5 s 重试一次；
  - **打开面板即重列**（`ensureLoaded()` 不再只列一次）：打开面板本就是在问「自上次看看它改了什么」；重列期间**不擦内容**（先把现有树画出来，数据到了再替换）——沿用「刷新不清屏」的既有约定；
  - **可见时轮询**：面板在屏上时每 5 s 给已展开会话的日志做一次 `stat`，只有**真的变了**才跑一次 `review audit`（未变化时零 CLI 调用）；面板收起/切走即停（隐藏只把分隔线宽度收成 0、视图仍挂在树上，所以可见性判定不能只看 `superview`）；
  - 回归测试 `tests/review-panel/controller-tests.swift`（无头驱动真控制器 + 假 core CLI）：新建会话第一次读 → 如实显示「0 文件 / 无变更」→ 日志增长后**不需要任何操作**自动重读并列出文件，且日志不再变化时**不会**重复审计；对修复前的代码实测 6 例 FAIL（`tests/review-panel/run.sh` 已接入 `scripts/local-ci.sh`）。

- **文件面板：关闭再打开后目录树宽度变成上限 420（#9，第三版才修好）**：关闭面板时壳层把右侧窗格宽度收成 0，`contentSplit` 随之被压扁，再次打开时 NSSplitView 从 0 重新分配、把目录树推到允许的最大值 420。前两版用「0 → N 宽度转变」+ 事件监视器恢复**从未执行过**（拿真实 `app.log` 对照确认：既没有恢复记录，也从未记住过宽度）——根因是 `NSSplitView` 拖分隔条时跑的是**它自己的 event-tracking loop**，这类事件不经过 `NSEvent.addLocalMonitorForEvents`。第三版改为：新增 `TreeDividerSplitView: NSSplitView` 子类 override `mouseDown(with:)`（`super` 返回即「拖拽结束」），据此**准确**区分「用户拖拽」与「程序重排」——拖拽结束记录宽度、非拖拽的宽度变化一律纠正回记住的宽度，另有「关闭面板」「面板切走」两个兜底记录点，所以从未拖过也能正确回到默认 160。`tests/file-panel/` 用**真实 NSWindow + 真实 split view** 跑完整序列（拖到 300 → 收成 0 → 恢复 900 → 断言仍是 300），并断言「框架自己重排到 420 必须被纠正且不会被记成用户选择」。
- **文件面板：打开图片即崩溃**：百分比角标原会按文本测量并 `invalidateIntrinsicContentSize()`，而缩放是在 `layout()` 里应用的，于是 magnify 的 KVO 回调可能在**一次布局过程中**触发角标改尺寸、崩在 `-[NSView _invalidateIntrinsicContentSizeDirtyingConstraints:]`。三处一起改：角标改为**固定尺寸**（54×18，文本变化只 `needsDisplay`）、KVO 回调**推迟到下一个 runloop**、`applyFit()` 数值未变时不再重复设置 magnification。
- **文件面板：图片预览不居中 + 拖动面板宽度时缩放反复跳变**：新增 `CenteringClipView`（`constrainBoundsRect` 里把小于视口的文档居中，NSScrollView 默认把文档钉在左下角 → 图片贴在左下角）+ `ImageZoom.padding`(16pt) 内边距，fit 按「视口 − 2×边距」计算；缩放跳动则是因为 fit 误用 `contentView.bounds`（开启动量缩放后它是**文档坐标**）作视口，形成「设 magnification → 视口值变 → 重新 fit」的振荡，改用 clip view 的 **frame**（屏幕点）后二者互不影响，并在视口退化（live resize 中间帧）时跳过、设置 magnification 时用 `CATransaction` 关闭隐式动画。
- **文件面板：大文件（3000+ 行）磁盘变更后重新加载把应用卡住（#7）**：改为**异步读取 + 单次高亮 + 稳定性窗口**，代理改写大文件后不再卡 UI。
- **终端面板（#3 #4 #5 后续）**：恢复滚动惯性、双击后**按词扩选**、在 dsh web 切换 workspace 且目标工作区没有终端时自动开启一个。

### Docs

- 新增 `docs/ui-color-scheme.md`（面板配色方案：六色令牌表、两套取色 API、CALayer 与动态色的坑、语义色边界）。
- `docs/ux-feedback.md`：记录 9 条使用问题（Files 新建/外部打开、目录树宽度、大文件重载、图片缩放；Terminal 滚动/选词/页签；WebView 刷新 401），逐条补实现位置与验证结论；#6 收敛到「面板正常 → 仅 WebView 那份 cookie 被拒」并给出 ⌘R 与右键 Reload 一致化方案。
- `.dsh/wiki/` 同步：技能面板（Skills Manager）、审查面板日志新鲜度、面板配色统一、UX 反馈修复。

### Tests

- 新增 `tests/file-panel/`（模型 28 例 + 真面板 38 例，含真窗口复现「关闭/重开面板丢目录树宽度」、`image-zoom-tests.swift` 17 条缩放断言）、`tests/skills-panel/`（模型单测 + 控制器冒烟 + 离屏绘制回归）、`tests/terminal-panel/`、`tests/wiki-panel/panel-header-tests.swift`，全部接入 `scripts/local-ci.sh` 与 CI swift job。

## [1.15.0] - 2026-09-13

### Added

- **审查面板（Review / `⌥⌘R`，活动栏「审查」）：只读回答「这个会话里代理到底改了哪些文件、改成什么」**：直接读 dsh 自己落盘的会话日志（`$DSH_HOME/sessions/<workspace>/<session>/session.jsonl[.zstd]`），**不写任何文件、不发任何请求、不改 dsh**。面板按 **会话 → 对话（turn）→ 文件 → 变更内容** 的树展示，每层可展开/收起，对话用该轮的用户消息做摘要；会话只在**第一次展开**时才真正审计（列表只读日志头，展开才解码全量日志并缓存）。每个文件的**逐次改动都标出来源**：`已应用`（顶层 `write`/`edit` 工具结果里的 hunk，与 dsh web 的 diff 卡片同源）、`参数还原`（由调用参数还原——`run_code` 嵌套调用没有 hunk 元数据）、`全文写入`/`新建`（日志只记了写入内容），嵌套调用另标 `嵌套调用`；`bash` 直改（`sed -i`、`>`、`rm`、`git checkout` …）没有结构化的前后内容记录，单列为「shell 命令」并按「可能写文件」启发式打标（默认只显示可疑项，可关掉过滤看全部）；失败/被拒的调用单列「失败的调用（未改动）」，不计入变更统计；读取诊断（Zstandard 尾部未完成帧、无法解析的行）一律显式列出，**不静默丢数据**。**跟随 dsh web**：在 web 里切换会话时面板展开同一 sessionId（按 id 解析，跨工作区也能定位）并标为「当前会话」；工作区切换只重列会话、不清审计缓存。**只读边界**：日志里没有的东西不会显示——`bash` 直改与尚未落盘的部分只标注「需人工核对」。
  - 审计折叠逻辑放在 **core**（`core/lib/review-log.js`）：dsh 的 JSONL 后端把日志写成**多个独立可解压的 Zstandard 帧的拼接**（每次落盘一批一帧），一次性解压只能拿到第一帧；Apple 的 Compression 框架在这套 SDK 上**没有 zstd 算法**，Swift 侧无法自行解码。因此 core 自带 `scanZstdFrames()` 逐帧解码，壳层经 `CoreBridge.run(…, preferBundledNode: true)` 调用（**必须用内置 Node**，用户自装的 Node 18/20 没有 zstd），且**不依赖 dsh 的私有模块**——不新增升级耦合面；
  - 新增 `platforms/macos/src/ReviewPanel.swift`（右栏面板）、`ReviewLogModel.swift`（展示模型：JSON 解码 + 文件分组 / diff 折叠，纯 Foundation，可无头测试）、`core/bin/ohmy-core.js review sessions|audit|audit-file`（CLI 契约）与 `tests/review-panel/`（模型层单测），已接入 `scripts/local-ci.sh` 与 CI swift job；
  - 覆盖矩阵（哪些改动能被看到、哪些只能「需人工核对」、为什么不做回滚）见 `docs/review-panel-design.md`。
- **文件面板（Files）页签按工作区记忆与恢复**：切换工作区（在 dsh web 切到另一工作区的会话）时，先把原工作区的已打开页签（顺序 + 当前选中项）记入内存并**关闭全部页签**——释放编辑器 / 语法高亮 / 预览内容，不再把旧工作区的文件挂在新工作区上；切回原工作区时按原顺序重开并还原选中项，磁盘上已消失的文件自动跳过。**未保存修改先询问**：保存并切换 / 不保存——**面板始终跟随工作区**（dsh web 已经切过去了，不存在「留在原工作区」这个答案，否则两边显示不一致）；保存失败的页签**保留在页签栏**（既不静默丢弃改动、也不掉队），面板不可见（无人可问）时同样保留并照常跟随。点面板右上角「关闭」按钮 = 关闭全部页签**并清空全部工作区的记忆**（彻底回收）；切到其它面板不算关闭。**关闭时若还有未保存修改会先问**（页签 ✕ / ⌘W 与面板 ✕ 同一套提示：保存并关闭 / 不保存 / 取消，取消 = 不关；保存失败则中止关闭并保留缓冲）。记忆仅存在于本次进程，不落盘。新增 `platforms/macos/src/WorkspaceTabMemory.swift`（纯逻辑）与 `tests/file-panel/run.sh`（模型 28 例 + 真面板 38 例），已接入 `scripts/local-ci.sh` 与 CI swift job。

### Changed

- **面板头部改为固定标题（文件 / 终端 / 知识库）**：文件面板头部固定「文件 / Files」（不再跟随当前文件显示路径）、终端面板头部固定「终端 / Terminal」（不再跟随会话标题 / 已结束状态）、知识库面板头部固定「知识库 / Wiki」（不再跟随当前页面名）；三者都复用活动栏同名键（`bar.preview` / `bar.terminal` / `bar.wiki`），语言切换时随 `refreshTooltips()` 刷新。信息没有丢——文件面板的路径、终端面板的会话标题/已结束状态、知识库面板的页面名都改放进**头部标题的悬停 tooltip**（终端「会话已结束」仍在内容区叠加提示里；页面名在树与页头上本来就有），页签 tooltip 也一直带着。新增 `tests/terminal-panel/`（无头，不建 PTY）与 `tests/wiki-panel/panel-header-tests.swift`（无头，不扫目录）：标题固定 / 语言切换后仍固定 / 关会话后不被清空。

### Fixed

- **审查面板首轮体验问题成批修掉（空面板 / 宽度 / 跨工作区 / 会话名 / 主题）**：① **消除「刚打开时面板一片空」**（工作区兜底 + 预取 + 不擦内容）与**面板宽度不跟手**（根视图误入 Auto Layout，改回手动布局并把滚动条换成覆盖式）；② **跨工作区切换后只显示目标工作区的会话**（不再把上一个工作区的会话钉在首位）；③ 会话列表**点行展开后不再重列**、只展开当前会话、当前会话改用**高亮**标出（去掉 `current` 文字），Turn 标题不再被长内容挤掉；④ **会话名不再显示 sessionId hash**——标题改为**打开面板时**独立读取 + 失败重试（去掉启动期抓取与页面就绪钩子），无标题的会话显示为 dsh web 的「新会话 / New Session」；⑤ 内容区 / 圆角块**跟随浅色 / 深色主题**。

- **修复「core 单测整套挂死」**：个别用例泄漏的 runner / 打开句柄会让 `node --test` **永不退出**（本机表现为整套测试挂住、CI 超时才失败）。现在核心套件统一加 `--test-timeout=60000`（用例泄漏后 60s 判失败，而不是把整轮拖死；README / CONTRIBUTING / CI 同参数），并修掉泄漏 runner 的用例本身。

- **修复「dsh 认证 cookie 无限累积 → 启动后 WebView 报 Failed to load plugins」**：`dsh >= 0.1.2` 用 launch token 换浏览器 cookie 做鉴权，而 **cookie 名由 authority（`host:port`）派生**——`cookieName(authority) = "dsh-auth-" + base64url(sha256(authority))`；cookie 本身**不区分端口**（RFC 6265 按 domain+path 匹配），WKWebView 的 cookie 存储又按 bundle id 持久化。于是壳层**每次启动都自拉起一个新端口的 dsh web** = 每次多一只 ~226 B 的新 cookie（30 天 TTL，实测开发版已累积 **68 只**），且**永不复用、永不覆盖**、只增不减。链路唯一被压垮的是 **client-modules 的 application batch**：45 个插件拼成**同一条 ~2.1 KB 的 combo URL**，而 node http 默认 `maxHeaderSize` 是 16 KiB——累积 `Cookie:` 头一旦超过 ~14.1 KB（**第 63 只**），请求行 + cookie 头整体超限，服务端回 **431 Request Header Fields Too Large**（空 body）→ `<script src>` 触发 **element 的 error 事件**（不是 JS 异常）→ client-modules 抛 `bundle script … failed to load` → 界面显示 **Failed to load plugins**；而紧挨着的 bootstrap（路径仅 ~80 B）仍 200，所以外壳能渲染、只有插件全挂。逐项实测：68 只 cookie → 431、40 只 → 200（3,718,152 B）、1 只 → 200；阈值扫描 62 只(14,134 B) → 200、**63 只(14,362 B) → 431**；换一个全新 cookie 存储（同二进制、同服务器）立刻恢复正常。处置：
  - 新增 **`platforms/macos/src/DshWebCookieJanitor.swift`**：复刻 dsh 的 cookie 名派生（含 `authority(port:)`），**启动时在加载入口 URL 之前**清掉所有 `dsh-auth-*` 里**非本次 authority** 的（保留当前那只，中途重载无 token 的 `webView.url` 不会掉凭据），**退出时**清掉本次留下的
  - （`applicationWillTerminate`，异步 + 泵 run loop 有界等待，超时 1.5 s，best effort——真正的保证是启动清理）；
  - spawn dsh web 时给 `NODE_OPTIONS` 追加 `--max-http-header-size=65536` 作保险带（用户/环境已显式设置则原样保留，不覆盖不重复）；
  - 清理**只碰 `dsh-auth-*`**：UI 偏好在 localStorage、会话/工作区在 `$DSH_HOME`、壳层配置在 `$DSH_HOME/shell/config.json`、Browser 面板（CEF）另有自己的 cookie 存储，均不受影响；
  - 新增 `tests/dsh-auth-cookies/run.sh`（无头，纯逻辑 22 例：用**真实抓到的 cookie 名**做向量钉住派生规则、启动/退出清理选择、68 只堆积必须清空、NODE_OPTIONS 追加规则），已接入 `scripts/local-ci.sh` 与 CI swift job。详见 docs/dsh-version-impact.md §6.3（R6）。

- **修复「未保存提示点取消后，反复切换工作区 Files 面板再无反应」**：页签记忆首次落地时用一个「已拒绝的目标」标记（`declinedSwitchTarget`）避免同一目标重复询问，但该标记只在**另一个**工作区到来时才清除——取消后面板仍停在原工作区（树根没变），于是对同一工作区的后续每次切换请求都被**静默吞掉**，面板永久卡在不再跟随的工作区上（`app.log` 实测：`cancelled by user` 之后每次都是 `stays declined`）。现在取消/中止**只延迟、不拉黑**：不再记标记，下一次请求（= dsh web 里真实的会话切换）照常询问；同时把「已有询问在途」由「忽略新请求」改为**最新请求优先**（`supersedePendingSwitchPrompt` 结束旧 sheet，杜绝卡死）。回归测试见 `tests/file-panel/panel-switch-tests.swift`（`a later switch to the same workspace is attempted again`，对修复前的 `FilePanel.swift` 实测失败）。

- **修复「未保存提示取消后，Files 面板与 dsh web 显示不同工作区」**：提示原本给了「取消」——但工作区切换是在 dsh web 里先发生的，取消只会让面板永久停在旧工作区，与 web 不一致。现在提示只问**是否保存**（保存并切换 / 不保存），面板**无条件跟随**；改动无法落定时（保存失败、面板不可见、ESC 等未识别响应）把相关页签**留在页签栏**（不关、不记忆），既不丢改动也不掉队；并发请求改为**最新优先**（`switchRequestGeneration` + `supersedePendingSwitchPrompt`）。测试改为钉住不变量：`an unsaved tab stays open when there is nobody to ask` / `the panel follows the workspace anyway` / `the saved tab was handed over to the workspace it left`。

- **修复「切换工作区提示框按钮显示成 `preview.switchDiscard`」**：上一轮把两个 L10n 键改成动作中性名（`preview.switchUnsavedTitle`→`preview.unsavedTitle`、`preview.switchDiscard`→`preview.discard`）时，只改了新写的关闭提示调用点，工作区切换提示的两处**漏改**——而 `L10n.tr` 的兜底是 `table[key] ?? (key, key)`，于是标题与按钮直接把键名当文案显示。已修正两处调用点，并新增 **`tests/l10n/` 键名 lint**（`lint.py`，接入 `local-ci.sh` 与 CI swift job）：扫出所有 `L10n.tr("…")` 字面量键与 `L10n.table` 比对——**缺失键 / 重复键 / 中英缺一**一律 FAIL（对修复前的 `FilePanel.swift` 实测报出 `preview.switchDiscard, preview.switchUnsavedTitle`），表里无人引用的键只告警（有 `wizardL10n` 这类运行时拼键）。

- **修复「关闭页签 / 关闭面板会静默丢弃未保存修改」**：页签 ✕ 与 ⌘W 调用的 `close(_:)` 直接关页签、面板 ✕ 直接 `closeAllTabs()`，两者都不问一句——面板里完全可以停着未保存的编辑。现在两条路径统一走 `askAboutUnsaved` + `saveTabs`：**保存并关闭 / 不保存 / 取消**（取消 = 不关；保存失败 → 中止关闭、保留缓冲并报 `preview.saveFailed`；无窗口无人可问 → 一律不关，绝不静默丢弃）。工作区切换的提示与关闭提示共用 `pendingPromptAlert`，新的切换请求会让在途提示失效。L10n 更名两键为动作中性：`preview.switchUnsavedTitle`→`preview.unsavedTitle`、`preview.switchDiscard`→`preview.discard`，新增 `preview.closeUnsavedMessage` / `preview.closeSave`。

- **修复正式版点 Wiki 面板「生成/更新知识库」无反应、起不出 dsh 会话（复用别人的 dsh web 导致原生 RPC 全 401）**：正式版（非开发版）启动时若 3080 上已经有一个 dsh web，会走「复用」分支——而该分支写死 `entryURL = http://127.0.0.1:3080`（**不带 `?token=`**），于是 `server.webToken == nil` → `DshWebRPC.token = nil` → 独立 ephemeral session 换不到 cookie → `session/create`、`session/prompt` 一律 401 → `WikiRPC.createSession` 返回 nil，而旧的失败路径「还没有在途生成」时什么都不做，表现就是点了没反应。三层根因叠加：① 3080 上是**壳层自己上次异常退出留下的孤儿**（实测 `lsof`：`stdout/stderr = ~/Library/Logs/oh-my-dsh/server.log` + `cwd = HOME`，正是 `ServerManager` 拉 dsh web 的写法；同机另有 5 个同类残留），而 `applicationWillTerminate` 只停「本次自拉的」服务、复用过的实例永远收不掉；② 就绪探针 `isDSHServing()` 用 `URLSession.shared`，它共享 app 持久 cookie 存储里一张**未过期**的 `dsh-auth-*`（authority `127.0.0.1:3080`，30 天），使裸 GET 返回 200 + 含 `__DSH_BOOT__` 的真页面，被误判成「老版本、无需鉴权、可以复用」（磁盘缓存同理可骗）；③ 该 3080 实例其实是 dsh 0.1.2，`/api` 只认 token。处置：
  - `ServerManager.start()` **彻底删除复用分支**（连同 `DSH_NATIVE_FORCE_SPAWN` 开关）：永远自拉起自己的 dsh web（3080 被占自动换空闲端口），保证拿到 launch token；同 `DSH_HOME` 下数据本就共享，自拉起不丢任何东西；
  - 就绪探针改用**专用 session**（`httpCookieStorage = nil`、`httpShouldSetCookies = false`、`.reloadIgnoringLocalCacheData`、`urlCache = nil`），不再被持久 cookie / 磁盘缓存欺骗；
  - 新增 **`reapRecordedOrphan()`**：拉起时把 `{pid, port, token}` 记到 `$DSH_HOME/shell/dsh-web.json`，下次启动若该实例仍在（用 token 探活证明还是自己那台，绝不误杀别的进程）就先回收再拉起——「上次没关干净」不再累积；正常退出时清除记录；
  - `app.log` 在 `webToken == nil` 时明确告警「native RPC cannot authenticate (401)」，不再静默；
  - Wiki 面板：会话压根没起来时状态条显示「生成失败（详见日志）」并写 `app.log`（端口/仓库/workspaceId），不再是一次无效点击；
  - `DshWebRPC`：只有端点真的不存在（HTTP 404/405）才降级为点号方法——此前**任何**失败（超时/401/业务错误）都会把该端点永久钉成 legacy，一次抖动就让本次运行内所有后续调用打到 0.1.2 根本没有的端点；cookie 换成功才记为已认证；`WikiRPC.createSession` 在 workspaceId 被拒时回退 `cwd` 建会话（保证「能在对应 workspace 起出会话」），create/prompt 超时 6s→15s。详见 docs/dsh-version-impact.md §4.4（含完整证据链）。

- **修复「内置浏览器面板一片空白（页签/地址栏照常更新）+ 右键菜单弹错位」**：两处根因叠加，都落在 **OSR（离屏帧自绘）渲染路径**上。
  - **触发（1.14.0 设置搬家丢了用户取值）**：1.14.0 把壳层设置从 `UserDefaults` 搬进 `$DSH_HOME/shell/config.json`（`ShellConfig`）时**没有迁移已有取值**——用户显式设过的 `browserRenderMode = windowed`（窗口化渲染，见 docs/plans/BROWSER_PLAN-browser-panel.md §十一的既定默认）留在 plist 里再没人读，于是回落到代码里的 `osr` 分支，而 OSR 路径（下述）本身是坏的。现在 `ShellConfig` **首次加载时一次性把旧 UserDefaults 里壳层自有键搬进 config.json**（只搬本文件尚无取值的键，`legacyUserDefaultsMigratedAt` 标记保证只做一次、显式值永远优先；browserRenderMode / appTheme / previewPanelWidth / channel.global.list 等一并保住），并把**代码默认改回文档记载的 `windowed`**（要 OSR 需显式设 `osr`）。
  - **OSR 自绘帧画在被盖住的层上（空白的直接原因）**：帧原来写进 `BrowserOSRView`（容器，父层）的 `layer.contents`，而容器的子视图 `pageView`（页面区，铺满容器且垫着不透明黑/白背景）的 layer 画在父层 contents **之上**，整帧被盖住 → 内容区永远只剩背景色。CEF 本身没问题：标题、地址栏、console、CDP 截图全部正常，所以只靠 REST API 排查发现不了。现在帧**画在 `pageView` 自己的 layer 上**（同层：背景色在 contents 之下做兜底，窗口化模式不受影响）。详见 docs/browser-blank-panel-fix.md。
  - **右键菜单位置（“点右键，左边有反应”）**：OSR 下 CEF 给的菜单坐标与宿主视图坐标系不一致（视口按 `GetScreenInfo.device_scale_factor` 走设备像素：帧回调 1814×2174 对应 907×1087 点），按视图坐标换算得到的点落到窗口右下之外，AppKit 只能把它塞回屏幕边缘 → 表现为“点下面弹上面、点右边跑到左边”。现在**以当前鼠标的屏幕坐标为准**（右键必来自鼠标），CEF 参数只作键盘唤起菜单时的兜底，两者差异写 `app.log`。
  - **OSR 帧派发错配**：帧回调原来按 `tab.id` 找页签，而 CEF 给的是 shim 的 `browserId`（DevTools 子浏览器同吃同一计数器，开过 DevTools / 关过页签后必然错位）→ 改为按 `browserId` 认页签，DevTools 子浏览器的帧进 `devtoolsContent`（不再画进主页面区）。
  - 回归测试：`tests/browser-panel/` 新增帧落点（pageView 而非容器）、按 browserId 派发、DevTools 帧进 DevTools 区、菜单锚点（共 71 例，对修复前的代码实测 4 例 FAIL）；新增 `tests/shell-config/`（旧 UserDefaults 迁移 / 只做一次 / config.json 优先 / 不搬无关键，13 例）。两套均已接入 `scripts/local-ci.sh` 与 CI。

### Docs

- **审查面板**：新增 `docs/review-panel-design.md`（目标 / 非目标、数据来源的三类记录、覆盖矩阵、为什么审计逻辑在 core 而不在 Swift、CLI 契约），并在 `.dsh/wiki/modules/` 下新增模块页 `review-panel.md`。
- **浏览器面板空白事故**：新增 `docs/browser-blank-panel-fix.md`（OSR 帧落点、菜单锚点、帧派发的根因与排查手段、回归测试）；`docs/dsh-version-impact.md` 补写 **§6.3「R6 详解」**（dsh-auth cookie 累积：cookie 名派生规则、431 的 ~14 KB 阈值实测、启动/退出清理时机与升级时的验证命令）。
- **wiki 增量同步**：审查面板模块页、文件面板工作区页签记忆、工作区切换的取消语义、dsh 认证 cookie 清理与 ShellConfig 旧设置迁移、浏览器面板渲染默认（windowed）与 1.14.0 空白事故、v1.15.0 版本线与用例基线。
- **README / CONTRIBUTING 同步本次发布**：README 修正浏览器面板渲染**默认已改回 windowed**（原文写「默认 OSR」，与代码不符）、WebView 最小宽度（1050 → 1100pt）与「右侧六个面板」（→ 七个）的表述，并在「特性一览」补审查面板、在「目录」补 `ShellConfig.swift` / `DshWebRPC.swift` / `DshWebCookieJanitor.swift` / `WorkspaceTabMemory.swift`；CONTRIBUTING 补齐本次新增与既有但漏列的测试套件（`review-panel` / `file-panel` / `l10n` / `shell-config` / `dsh-auth-cookies` / `terminal-panel` / `terminal-emulator`）与 `tests/` 结构说明。

## [1.14.0] - 2026-09-11

### Added

- **钉钉原生适配器（`dingtalk-stream`）**：通道面板新增**钉钉自建应用机器人**接入，走官方 Stream 模式长连接（无需公网回调 / 内网穿透），与微信共享同一套面板模型（接入向导 / 连接状态 / 项目视图会话消息 / 每会话跨项目路由）。core 新增独立适配器模块（`core/lib/dingtalk.js`、`dingtalk-stream-transport.js`、`dingtalk-device.js`、`dingtalk-access.js`）与配套单测（`core/tests/dingtalk*.test.js`），面板侧完成向导接线与生命周期（启动拉起 runner、退出关闭）；设计与边界见 `docs/channel-dingtalk-stream.md`。
- **钉钉绑定向导（device-code 扫码）+ owner-binding 安全门**：向导内完成 device-code 绑定——`init/begin` 得二维码 → 面板内渲染 → 手机钉钉扫码**自动创建企业内部应用 + 机器人** → 本地 `poll` 拿 AppKey/AppSecret 写入 store（chmod 600）；不便于扫码时提供「在浏览器中打开」链接。绑定完成后**只有本机管理员能驱动 dsh**：未绑定前机器人**拒绝所有人**（防任何组织成员经机器人操作本机 bash/文件/token），用 `/bind <口令>` 绑定（口令本机生成、见面板与运行日志），且**串行化处理——只有第一个发送正确口令的人能绑定**（修掉并发 last-writer-wins）；绑定成功回两条消息（确认 + 完整 `/help`）。绑定状态落 `~/.dsh/channels/<channelId>.binding.json`（chmod 600）；已配置的钉钉通道重开向导**不再重复扫码**（否则会重复创建应用），并自动恢复 `/bind` 口令；向导任一步「返回」都会取消在途 login 子进程。
- **通道面板交互增强**：全局配置新增**解绑**（清空该通道配置并停掉 runner）；平台卡片状态点支持**悬浮提示**（不再只靠颜色传达状态，对色觉障碍友好）；微信绑定页展示「**已配置**」状态 + 显式「重新登录」（避免误替换已绑定 token）；钉钉无「正在输入」能力，以文字 ack 代替 sendTyping。
- **dsh 升级改为「分步 + 分阶段 + 二次确认」**：不再一步升到 dist-tags.latest，每次只升到**紧邻的下一个发布候选**（stable/rc，排除 alpha/beta/dev；从 registry versions 取号，选步逻辑入共享 core 的 nextStepTarget，Swift 与 core 同一规则）。手动「检查并升级」为三段式：① 检测并提示「当前 vA → 可升 vB」→ 用户确认；② 后台把 vB 预热进共享 npm 缓存（不改动线上 dsh 树、可取消）；③ 下载完成**再次确认**后才原地安装 + 重启。自动升级（启用时）**先起服务不再阻塞启动**，24h 节流到达后在后台检测并下载，下载完成后弹窗请用户确认才正式升级（prefetch / apply 拆分见 core/lib/upgrade.js 与 main.swift 的 DSHUpdater）。
- **dsh 升级备份与失败自动回滚**：正式升级前整树快照 runtime/dsh 到 ~/Library/Caches/oh-my-dsh/upgrade-backups/（只留最近一份）；安装失败或安装后版本校验不符自动回滚到备份并给出提示。新增调试钩子 `DSH_AUTO_UPGRADE_NOW=1`（忽略 24h 节流、每次启动都跑自动升级，便于验证该流程）。

### Changed

- **内置 dsh 版本推进到 `@deepseek-ai/dsh@0.1.2-rc.1`**（0.1.1 → 0.1.1-rc.2 → 0.1.2-rc.1，`build-app.sh` 的 `DSH_PACKAGE_SPEC` 默认值与打印行同步；构建期可用 `DSH_PACKAGE_SPEC` 覆盖）。壳层与内置 dsh **同步移动**：0.1.2 改了 `/api` 的鉴权（每实例 launch token → cookie）与 RPC 形状（斜杠端点 + `payload.args`），并移除了 `workspace.list` / `session.list` 的旧形态，本版全部兼容改动都围绕这些变化（见下方 Fixed）；升级影响清单、五个耦合面与执行 SOP 见 `docs/dsh-version-impact.md`，逐项兼容审计与验证记录见 `docs/plans/` 下的 0.1.2 文档。

### Fixed

- **dsh 私有 workspace 存储读取加护栏（R4）**：`workspace.list` 在 dsh 0.1.2 被移除后，壳层只能读 dsh 自己持久化的 `$DSH_HOME/storages/workspace.json` 来枚举工作区——那是 `defineDomain({ name: "workspace", version: 2 })`（`dsh-workspace/lib/invariant.js`）定义的**私有带 schema 存储**，还带 `pendingMutation` 这类中断恢复标记，上游随时可能改字段/搬文件/升版本，读不懂时会让 5 处功能（频道 `/wks`、门控、`/ses`、面板项目目录、wiki/issue-runner 的工作区归属）**静默变空**。本次不加新数据源（0.1.2 已无 `workspace.list`，`workspace/follow` 是流式），而是把这条兜底变得可观测、可收口：
  - core 与 Swift 两侧读取器都校验 `unit.name/unit.version`；版本对不上仍**尽力解析**但明确报出（`[workspace-store] … is domain workspace v3, this build understands v2 — read best-effort`），形状意外报 `unexpected shape`，**文件缺失保持安静**（0.1.1 本就正常没有它）；
  - 日志出口：core → 频道 runner 日志，Swift → `app.log`；
  - **单一实现收口**：原先有三份各自解析该私有格式的代码（core `workspace-store.js`、Swift `DshWorkspaceStore`、`main.swift` 的 `persistedWorkspacePath`），现在 `main.swift` 改为调用 `DshWorkspaceStore`，只剩 core 与 Swift 两处；
  - 只读不写；补 core 4 条 + Swift 4 条用例（版本不匹配/形状意外/缺失安静 + 解析顺序与字段）。
  - docs/dsh-version-impact.md 新增 §6.2「R4 详解」（依赖的具体结构、五个静默断裂点、三个次要坑、升级时的验证命令）。
- **修复「面板点会话行定位到 dsh web」在 dsh 0.1.2 下静默失效（R3 实测坏点）**：注入的 `sessionOpenerScript` 固定发 `POST /api/session/list`，但 body 里仍是点号 `method:"session.list"` 且 payload 未包 `args`，0.1.2 服务端直接拒绝（`gateway/bad-request: method "session.list" does not match endpoint "session/list"`）；0.1.1 上该斜杠路径又不存在，等于**写死单版本形状、两个世代各坏一次**。改为运行时双面：先按 0.1.2 形状（`session/list` + `payload.args._request`）请求，失败再回退点号（`/api/session.list` + `payload`），失败原因打 `[dsh-opener]` 日志。另外 `DSH_UI_DEBUG=1` 新增页面加载后的注入桥自检（`dsh injected bridges: {tracker, opener, preview, rows}`），让这类「成功时无感、失败时无声」的脚本至少有可观测信号；docs/dsh-version-impact.md 新增 §6.1 详解 R3 的三个脚本各自依赖什么、坏了什么症状、升级时怎么验。
- **外部已启动的 dsh 0.1.2 实例不再「悄悄」被忽略**：0.1.2 起的实例会用 401 + `authentication required` 回应裸请求，壳层因此判为不可复用而另起一个实例——这是**按设计**的：token 每进程随机且只存在于该进程 stdout，拿不到；而只要 `DSH_HOME` 相同，壳层自拉起的实例与外部实例就是同一份数据（workspaces / 会话 / settings / channels 全在 `$DSH_HOME` 下），复用只省一个进程。现在这个判断会写进 `app.log`（`existing dsh web on 3080 wants its launch token … not adopting`），不再出现「怎么又起了一个实例」无从解释的情况；唯一的注意点是同一个 `DSH_HOME` 不要长期并行跑两个 dsh web（两者持久化同一批文件）。见 docs/dsh-version-impact.md A3/R2。
- **修复内置 dsh 0.1.2 下壳层原生 RPC 全部失效（wiki 生成、issue-runner 流水线、会话目录跟随）**：`WikiRPC`（WikiPanel）、`IssueRunnerPanel` 的会话/工作区调用与 `DSHSessionRPC`（main.swift）此前只会讲 dsh ≤0.1.1 的老接口——点号方法名、payload 直接是参数、且**不带任何鉴权**；0.1.2 起 `/api` 只认 launch token 换来的 cookie、端点改斜杠、参数包进 `payload.args.<request|_request>`，于是这些原生调用全部 401/404（wiki 点「生成」拿不到 sessionId、issue-runner 建会话/发消息失败、workspace.list 扫描为空；只有 `DSHSessionRPC` 有磁盘兜底不至于完全失灵）。修复为新增共享的 `platforms/macos/src/DshWebRPC.swift`：
  - **双面调用**：先按 0.1.2 斜杠端点 + `payload.args.<request|_request>` 试，失败再回退点号方法，并**按端点**记忆所选接口面（同一服务有 `session/list` 却没有 `workspace/list`，按服务记忆会互相污染）；`modernExtras` 只在 0.1.2 面注入（如 session/prompt 必填的 requestId）；
  - **鉴权**：用一个独立 **ephemeral URLSession** 访问 dsh web 自报的 `/?token=…` 种下 `dsh-auth-*` cookie（WebView 的 cookie 在 WebKit 自己的数据存储里、与 URLSession 的 `HTTPCookieStorage` 互不共享，只能自行换取），每端口只换一次，401 时自动重换一次并重试；
  - **工作区列表**：0.1.2 已无 `workspace.list`，回退读 dsh 持久化的 `$DSH_HOME/storages/workspace.json`（`DshWorkspaceStore`，与 core 同一份契约，按 `global.workspaceIds` 保序）；
  - token 由 `ServerManager.webToken`（dsh web 自报的带 token 入口地址）在服务就绪时注入，**不落日志**；
  - 消费者全部改接：`WikiRPC`（createSession/prompt/sessionRunning/cancel/workspaceList/resolveWorkspaceId）、`IssueRunnerPanel`（会话 + 工作区）、`DSHSessionRPC`（会话 cwd 两条路径，保留磁盘兜底）。
  - **测试**：新增 `tests/dsh-rpc/run.sh`（headless，注入 HTTP 假传输：信封形状、斜杠/点号回退、按端点记忆、token 换取与 401 重换、workspace.json 解析），接入 `ci.yml` 与 `scripts/local-ci.sh`；wiki 面板测试的编译清单补上该文件。
- **修复开发版（内置 dsh 0.1.2-rc.1）下 Channel 指令全部失效 —— 微信发 /wks 回「没有可用的 workspace」，而面板里明明有已启用的 workspace（C1）**：channel runner（core）此前只讲 dsh ≤0.1.1 的老接口——点号方法名（/api/workspace.list、/api/session.list…）、payload 直接是参数、且不带任何鉴权。0.1.2 起 dsh 换了两处：① /api 被**每实例 launch token 换来的 cookie** 挡住（裸 POST 一律 401）；② 方法名改为**斜杠端点**、参数包在 payload.args 里，并且**彻底移除了 workspace.list**（工作区改由 workspace/follow 流式下发）。于是 runner 的每次调用都失败：列不出工作区（/wks「没有可用 workspace」）、列不出会话（/ses 空）、普通消息与 /new 也建不了会话。修复为：
  - core 新增 **dsh 版本无关的 RPC 传输层**（core/lib/dsh-rpc.js）：先按 0.1.2 的斜杠端点 + 信封尝试，端点不存在（404）再回退老的点号方法，且**按端点（而非按服务）记忆**所选接口形态，避免 workspace/list 的 404 连带把 session/list 也拖回老接口；
  - 新增 **launch token → browser cookie 交换**：GET `/?token=…` 取 dsh-auth-* Cookie 并缓存，之后带 cookie 调 /api（无 token 时静默退回旧版行为，不破坏 0.1.1）；
  - **工作区列表磁盘兜底**（core/lib/workspace-store.js）：0.1.2 没有 workspace.list，改读 dsh 自己持久化的 $DSH_HOME/storages/workspace.json（与壳层 B 方案同一个文件，按 global.workspaceIds 保序，取 workspaceId/path/title/sessionIds），因此 /wks 即便没拿到 token 也能列出工作区；
  - **会话读取/回推适配**：会话列表改走 session/list；最后一条回复改由 session/page 按 session/list 给出的 projection cursor（projections.asOfSeq）回放；prompt 补上 0.1.2 必填的 requestId；
  - **壳层把 token 传给 runner**：ServerManager 记住 dsh web 自报的带 token 入口地址（entryURL/webToken），启动 `channel run` 时以 `--dsh-token` 传入（不落日志）；CLI 同时支持环境变量 DSH_WEB_TOKEN；
  - **修正 channel runner 启动时机**：原先在 `startServer()`（异步）之后立即启动，runner 可能拿到默认端口 3080 且拿不到 token，现改为服务就绪（端口与 token 都已知）后再启动。
- **修复开发版读不到保存的面板宽度（ShellConfig 早期缓存错误 home）**：ShellConfig 在 applyDevIsolation 注入 DSH_HOME 之前被首次访问，按旧路径（~/.dsh/shell/config.json，不存在）载入并把"已加载"置真，之后一直返回空缓存 → 读不到保存宽度、回退默认 560。改为"按路径感知重载"（缓存记录载入路径，DSH_HOME 变化即重新加载）。
- **面板宽度逻辑修正**：560 现在是面板**最小宽度**（此前被当作"默认宽度"，导致点面板总缩回 560）；用户拖动的宽度会被记住，**程序化布局不再回写覆盖**（切面板替换 subviews[1] 时的等分宽度不再被保存）。切面板时**按目标宽度预置新面板视图 frame + 零时长无动画**，消除"先等分(WebView≈1000)再扩到 1100"的中间帧。冲突策略（WebView 优先）：窗口 < 约1709pt 放不下"面板≥560 + WebView≥1100"时自动隐藏面板，保 WebView ≥1100。
- **ShellConfig 写入防抖异步**：改为 0.3s 防抖、后台线程经 core CLI 持久化（失败回退直写），退出时 flushNow，避免高频（面板拖动）同步 spawn 子进程阻塞主线程。
- **壳层配置改为语言无关的文件存储（core 单一实现）**：新增共享 core 的 settings 模块（core/lib/settings.js + ohmy-core settings get/set/unset/list/path），把壳层自有配置存成 UTF-8 JSON：$DSH_HOME/shell/config.json（dev → ~/.dsh-dev/shell/config.json）。Swift 侧新增 ShellConfig 门面：读直接读该 JSON（快、无子进程），写委托 core CLI（写入/合并/原子化语义单一实现，失败时回退直写）。已迁移 ~12 个自有 key（appLanguage/appTheme/dshRegistry/autoUpgradeDsh/nextAutoUpgradeCheck/hasCompletedOnboarding/preview*/rightPanelKind/browserLastURL/browserRenderMode/channel.global.list/wiki*）。仍留在原生 UserDefaults 的仅系统/框架强制项：AppleLanguages、NSWindow Frame。dev 隔离注入（applyDevIsolation）提前到任何配置读取之前。
- **开发版使用独立 bundle id（com.ohmydsh.app.dev）→ 独立 UserDefaults 域**：此前 dev 与正式版共用 com.ohmydsh.app，导致 dev 的偏好/状态与正式版共享——例如 Channel 面板「全局配置」的通道列表 channel.global.list（含缓存状态/连接）会显示正式版那份。改为 dev 构建时 bundle id 加 .dev 后缀，dev 拥有自己的 UserDefaults 域（channel.global.list、auto-upgrade 节流、语言/registry/主题等全部独立），可与正式版并存。
- **所有家目录级 ~/.dsh 硬编码统一改走 DSH_HOME（开发版不再误读正式 ~/.dsh）**：
  - ChannelPanel 三处硬编码 ~/.dsh/channels（channel 运行状态、项目关联 workspaces.json、项目开关）→ 复用 env-aware 的 ChannelStoreReader.channelsDir()；
  - IssueRunnerPanel 的 GitHub token 路径（~/.dsh/gh-token、~/.dsh/tokens/<owner>-<repo>）→ 按 $DSH_HOME 解析；
  - core：channel-runner 的 channel-runtime 目录与 ohmy-core 的 --dsh-home 默认值 → 优先 process.env.DSH_HOME；
  - 内置技能文档（web-dev-tools 的 browser-api.port、issue-resolve 的 token 路径）→ 改为 ${DSH_HOME:-$HOME/.dsh}（dev/prod 通吃；内嵌文本与仓库副本保持字节一致，skills 测试通过）。
  - 保持不变的：项目内 <repo>/.dsh（tasks/channels.json/wiki）与有意保留常量（dev home、旧 browser-dev 迁移源）。
- **适配 dsh 0.1.2-rc.1 的预览打开文件（D3）**：0.1.2 把文件打开从 host.openPath 迁到会话控制器的 session/openWorkspacePath（端点 /api/session/openWorkspacePath，路径在 payload.args.request.path —— 实测抓包确认）。预览拦截脚本改为同时匹配新旧端点，并按 payload.args.request.path → args.path → payload.path 依次取路径，恢复「消息流里点文件 → 在预览面板打开」。
- **修复 dsh 0.1.2-rc.1 下切换会话不跟随切换项目目录（会话跟踪）**：0.1.2 客户端把 RPC method 从点号改为斜杠（如 subagents/list）并把 sessionId 放到 payload.args.*，壳层注入的 session 跟踪脚本按旧的点号 method 与 payload.sessionId 匹配会全部落空，导致 webView 切会话不通知壳层、项目目录不跟随。修复为同时识别新旧两种 method 名，并从 payload.args（parentSessionId/agentId/sessionId/request.sessionId）回退到旧的 payload.* 取 sessionId。配合 B（workspace.json 磁盘映射）即可在切换会话后更新终端/预览/wiki/tasks 的项目目录。
- **恢复 dsh 0.1.2-rc.1 下的会话 workspace / 项目目录读取（DSHSessionRPC）**：0.1.2-rc.1 移除并改了 /api/session.list（改为 token + 控制器 RPC），壳层读当前会话 cwd/workspace 会 401/404 而失败。修复为当 live API 取不到时，回退读取 dsh 持久化的 $DSH_HOME/storages/workspace.json（磁盘、无需鉴权）：按 sessionId 找到所属 workspace 的 path，否则取最近更新的 workspace path，用于终端/预览/wiki/tasks 的项目目录定位。
- **适配 dsh 0.1.2-rc.1 的 Web token 鉴权（升级到该版本后启动失败）**：dsh 0.1.2-rc.1 起给 Web 界面加了每实例 token + cookie 鉴权，裸 GET 根路径返回 401、无 __DSH_BOOT__，而 oh-my-dsh 原先用裸 GET 根路径判就绪、并直接加载根路径，导致升级到 0.1.2-rc.1 后 App 判定「dsh web 启动失败」。修复为：启动时读取 dsh web 自己打印的服务地址（含 token，来自其日志行 dsh web: http://127.0.0.1:<port>/?token=...），据此做就绪判定，webView 也直接加载该带 token 地址（WKWebView 跟随 303 种 cookie 后正常显示）；无 token 的旧版本回退到原 __DSH_BOOT__ 探测。见 ServerManager.start() / servedEntryURL()。
- **自动升级节流时间戳改为「本轮跑完才写」+「稍后提醒」**：不再在开始检测时就消耗 24h 窗口（秒退/中途退出不会吞掉窗口，下次启动会重试）；自动检测下载完成后若用户选「稍后」，则把下次自动检查推到约 2 小时后并定时提醒，用户仍可随时手动升级；离线/下载失败按 ~2h 重试，无需升级/已升级按 ~24h 节流。
- **开发版（DSH_DEV_BUILD=1）运行隔离**：开发版构建现在自拉起**独立 dsh 实例**（不复用已在 3080 运行的实例，3080 被占时自动取空闲端口），并使用**独立 DSH_HOME（默认 ~/.dsh-dev）**，使 dsh 会话/配置/skills/channel 与正式 ~/.dsh 完全隔离；同时错开 CEF CDP（9333→9433）与 Browser API（3081→4081）端口，可与正式版并存测试（均尊重用户显式 DSH_HOME / DSH_CDP_PORT / DSH_BROWSER_PORT 覆盖）。旧开发版 CEF profile ~/.dsh/browser-dev 会**自动迁移**到新隔离目录 ~/.dsh-dev/browser-dev（幂等，目标已存在则跳过）。shell 侧 channel token 读写路径统一改为按 $DSH_HOME 解析，开发版不再写入正式 ~/.dsh。
- **自动升级进行中「检查并升级 dsh」菜单置灰**：当自动升级开启且后台正在检测/下载/安装时，Settings 菜单里的「检查并升级 dsh…(⌘U)」自动置灰不可点，避免与自动流程并发；手动流程下载/安装期间同样置灰。Settings 窗口内按钮在忙碌时点按会提示「已有升级流程正在进行」。
- **升级流程不再用全窗口状态浮层盖住整个界面**：手动/自动「检查、下载、安装」阶段均在后台静默执行，不再调用会铺满主窗口（白底+转圈）的 showStatus 浮层，避免点 Settings 的 Check & Upgrade 时整个 App 闪屏；只在每步完成时弹确认/结果框（真正重启服务那一下仍走启动浮层）。
- **自动升级 dsh 失败（exit 127）**：App 内自动升级用打包 node 的绝对路径启动 npm，但 npm 执行依赖包 lifecycle 脚本（如 `@deepseek-ai/dsh-subprocess-local` 的 postinstall `node ensure-spawn-helper.mjs`）时通过 shell 按 `PATH` 找 `node`；GUI 启动的 App 继承 launchd 的精简 PATH 通常没有 `node`，报 `sh: node: command not found`、升级中断。修复为给升级子进程前置注入打包 node 所在目录到 `PATH`。
- **升级后未重启服务 / WebView 未重载**：自动/手动升级跑完后运行中的 dsh web 仍在内存里跑旧代码（只刷新版本事实、没重启服务），新版本要等下次启动才生效。修复为升级成功后停止 App 自己拉起的服务并重新拉起 + 重载 WebView（含首次启动失败的场景）。
- **钉钉 Stream 连接长期停在「连接中」**：连接就绪判定改用 SDK 语义的「socket 已打开（connected）」（不再等一个永远不会来的回调）、以原始 ticket 建连、并补上明确的连接超时——修掉绑定成功后卡片一直显示 connecting 的状态。
- **通道消息分桶修正**：命令 / 系统类消息（`/help`、`/status` 等，无项目上下文）固定进**通道级全局桶**，只有 dsh 会话消息才按 workspace 归属——此前这类消息会被记到某个工作区下，项目视图与路由错乱。
- **通道「启用」只由项目开关决定**：归档（archive）通道不再把它自动重新启用（迁移只播种一次）。
- **`/wks <N>` 按序号切换工作区**（对齐 `/ses <N>`），不再只支持带内容形式。
- **解绑按钮不再误打开绑定向导**：把该按钮从卡片点击手势中排除（改用 NSGestureRecognizer 委托，替换原先按点击坐标的脆弱判断）。
- **重开绑定向导的状态修正**：step 0/1 不再显示 `/bind` 口令行，恢复为「已绑定」后正确显示「已完成」。

### Docs

- **dsh 升级影响清单**：新增 `docs/dsh-version-impact.md`（五个耦合面 A–F + 每次升级的执行 SOP + 0.1.1 → 0.1.2-rc.1 实例复盘），并补写 §6 的 **R3 详解（注入脚本）** 与 **R4 详解（`workspace.json` 私有存储兜底）**，明确「当前唯一还在静默失效风险里」的面与升级时的验证命令。
- **钉钉**：新增 `docs/channel-dingtalk-stream.md`（原生适配器设计：独立于微信、device-code 绑定、owner-binding 门控、Stream 长连接语义），并更新 `docs/channel-status.md` / 通道面板文档（绑定 / 解绑 / 指令状态）；allowlist 与群聊拒绝配额等留作后续迭代。
- **README / CONTRIBUTING 同步本次发布**：README 更新「内置 dsh 版本 = 0.1.2-rc.1」、dsh 升级改为「分步 + 二次确认 + 备份回滚/自动升级后台化」、开发版隔离（独立实例 / 独立 `DSH_HOME` / 独立 bundle id / 端口错开）、壳层设置改存 `$DSH_HOME/shell/config.json` 与 `DSH_AUTO_UPGRADE_NOW`；CONTRIBUTING 补 `tests/dsh-rpc` 套件、core 模块说明与 `swift-sources.sh` 单一来源约定。
- **Wiki 同步**：dsh 0.1.2 兼容收尾（R4 存储护栏 / R3 注入脚本双面 / 外部 0.1.2 实例不复用）与钉钉原生适配器、通道绑定 / 解绑文档刷新，并记录 216 用例测试基线。

## [1.13.0] - 2026-08-24

### Added

- **Channel 面板 ↔ dsh web 会话双向联动**：点击面板项目视图会话行（单一手势）同时展开/收起其消息并定位到 dsh web 对应会话（经注入的 `sessionOpenerScript` 驱动）；反过来 dsh web 切换会话时面板自动展开对应会话、其余行收起（无对应则会话列表仍显示、仅行收起）。**以 sessionId 对应，不用 name**。设计见 `docs/channel-web-session-link.md`。
- **Channel 指令体系 v2**：`/workspaces`(`/wks`) 与 `/sessions`(`/ses`) 支持**带内容切换**（无内容只列出、有内容即切到对应项，等同 `#wN`/`#sN`）、`/new` **统一回复**（无内容建占位 `New Session` 等首条消息激活、有内容 prompt=内容并回推答案）、移除 `/switch`；`/new` 无内容不再固定 dsh 会话标题（交由 dsh web 自动命名）。
- **Channel 项目开关落地（门控路由）**：全局 workspace 关联存 `~/.dsh/channels/<channelId>.workspaces.json`（project=workspace），开关**真正门控**——普通消息/`/new` 路由到未启用该通道的 workspace 回「该项目未启用该通道」、不建会话；`/workspaces` 只列已启用项；`#wN`/`#sN` 按目标/当前 workspace 是否启用门控（导航放行、仅拦截实际路由）。
- **Channel 异步应答 + 官方 sendTyping**：先 ack「处理中」、后台生成、结果回推；在途时后续消息回「请等待」不入队；用官方 `sendTyping`（getConfig 拿 typing_ticket）替换「处理中」文字 ack，生成时回微信原生「正在输入…」。
- **Channel 项目视图对话回复后实时刷新**：轻量重读全局 store，仅当内容签名变化时全量重建（保留折叠/展开状态），不随轮询抖动。
- **Channel 项目视图读全局 store 展示会话消息**（E 里程碑）：落地 Channel-Message-Session 关联 A/B/C/D（会话复用/工作区归属/路由统一/全局存储）；store 保留会话历史、面板显示全部会话（`/new` 不再覆盖旧会话）；`/new` 后绑定会话到 conversation、下一条普通消息复用而非新建；优化项目视图布局（通道标题栏/会话区块/对话气泡与宽度比例）。
- **Channel runner 日志**：runner stdout/stderr 路由到 `~/Library/Logs/oh-my-dsh/channel-runner-<id>.log`，暴露 core 调试日志。
- **内置 Skill 全局化 + 重命名**：三个面板配套 Skill 改为 **App 启动时安装到全局 `$DSH_HOME/skills/`**（缺失即装、App 托管下内容不一致自动覆盖更新、用户改过不覆盖），并重命名为 `web-dev-tools`（浏览器面板）/ `repo-knowledge`（Repo Wiki 面板）/ `issue-resolve`（IssueRunner 面板）；启动时自动把旧名 `shell-browser`/`repo-wiki`/`issue-fix` 迁移到新名；移除面板「按仓库安装」逻辑；新增 `tests/skills/` 无头单测（含内嵌 SKILL.md 与仓库副本字节一致断言）。
  - **frontmatter 用合法键**：`modelInvocable`/`userInvocable`（驼峰）是 dsh 弃用键会导致 skill 被忽略，已改为省略（默认 model 可调用）+ `user-invocable: false`（kebab）表达「仅 model 可调用」；`web-dev-tools` 为 model+user 双可调用。
- **macOS 源码清单单一事实来源**：新增 `platforms/macos/swift-sources.sh`（glob 自动收录 `src/*.swift` + `vendor/Highlightr/*`，排除独立工具 `MakeIcon.swift`）；`build-app.sh` / `scripts/local-ci.sh` / `ci.yml` 三方共用，新增 Swift 文件不再需要逐个登记，彻底消除「新增文件遗漏 local-ci.sh」的问题。
- **开发版构建支持**：构建时 `DSH_DEV_BUILD=1` 打包开发版（Info.plist 写入 `DSHDevBuild=1`），或直接 `./scripts/local-ci.sh dev`（等价 full，但 build 用 `DSH_DEV_BUILD=1`）；开发版运行时自动使用独立 CEF profile（`~/.dsh/browser-dev`）并跳过单实例退出，可与已安装正式版并存测试；未来如需隔离端口/channel 等资源，在 `main.swift` 的 `isDevBuild` 覆盖处快速追加。

### Fixed

- **文件面板打开文件实时刷新**：已打开的页签在磁盘内容变化后自动刷新——代理（或其他进程）改写打开的文件时，可编辑页签经 CodeEditorView.reloadFromDisk() 保留滚动位置、且不覆盖未保存的本地编辑（dirty 页签跳过），只读文本/图片/PDF/元数据页签直接重渲染；与 Wiki 面板已有的 2s 轮询刷新保持一致，打开即所见最新内容。
- **单实例约束（修复双实例争抢 CEF profile）**：App 启动时按 bundle id 检测是否已有其他实例在跑，若有则聚焦已有实例并立即退出，避免两个副本共用 `~/.dsh/browser` 导致 Chromium 异常退出（`Chromium didn't shut down correctly.`）。
- **Channel 双向联动交互**：点击会话行单一手势展开/收起并定位 dsh web、统一「手动切换 vs web 跟随」展开状态（不再互斥冲突）、会话未匹配时保持会话列表可见（仅行收起）。
- **Channel 项目开关门控修正**：开关关闭后刷新不再被重新开启（迁移只播种一次）；门控改为「按目标 workspace」——`#wN`/`#sN` 导航放行，仅拦截实际路由。
- **release 发布幂等化**：`github-publish.sh` curl 路径幂等化（中断可重跑，release 已存在则复用并只补传缺失资产）+ 逐资产进度输出。

### Docs

- **README**：Channel 面板章节补充「项目开关门控语义 + sendTyping 异步应答」与「dsh web 会话双向联动」；文件面板补「打开文件实时刷新」；AGENTS.md 增补「README 更新直接在当前分支提交，不切分支/不开 PR」。
- **Wiki 同步**：Channel 项目开关 / Channel-Message-Session 关联模型 / v1.13.0 内置 Skill 全局化与 swift-sources 单一来源等页面刷新。
- **发布决策固化**：`docs/release-process.md` 增补「CI CEF prepare 暂不修复」「暂不使用 gh CLI（发布统一走 curl API）」与已知坑；`docs/channel-*` 设计/实施记录更新（E 里程碑完成、Channel-Message-Session 关联模型核查）。

## [1.12.0] - 2026-08-22

### Added

- **通道面板（微信远程驱动 dsh）**（活动栏通道图标 + 菜单）：绑定微信个人号（官方 iLink 协议），在微信里发消息/斜杠指令远程驱动 dsh 干活——消息路由到项目会话、结果回复回微信；已跑通「扫码登录 → 长轮询收消息 → 指令/路由 → dsh 会话 → 回复回微信」**全链路**（真实微信 + 真实 dsh web 端到端验证）。
  - **配置面板**：全局配置视图 + 项目引用开关（写 `.dsh/channels.json`）；内置平台卡片（微信 ClawBot / 钉钉 / 飞书，带**实时连接状态徽标**）；微信扫码登录**在面板内渲染二维码**（CIQRCodeGenerator，不弹浏览器），登录态落 `~/.dsh/channels/<id>.json`（文件优先，chmod 600）；统一 40pt HeaderLabel 样式，顶部「全局配置」随时重开；
  - **项目视图**：Channel 行默认展开 Sessions + 原生 NSSwitch（灰绿）开关 + 展开区显示真实会话；行占满整宽、从内容区顶部渲染；
  - **微信内斜杠指令**：`/help`（分组排序）、`/ping`、`/status`（新格式）、`/workspaces`(`/wks`，代号+标题+`~`路径)、`/new`（无内容只创建标记 pending 等待首条消息激活、有内容创建并立即 prompt，落 workspaceId）、`/sessions`(`/ses`，工作区头+最近 5 条)、`/switch`；快捷指令 `#w1`/`#s1...`（切项目/会话，未找到有明确提示）与 #tag 路由（如 `#w1 帮我看看`）；
  - **会话驱动**：conversationId → dsh 会话映射（多轮续接，`/new` 另起），经 `session.create` + `session.prompt`（queue）驱动，回复回传微信；通道级全局状态（lastWorkspace / 会话映射 / activeSession）持久化 `~/.dsh/channels/<id>.state.json`（重启可恢复，写失败尽力不抛错）；
  - **生命周期**：启动自动拉起已配置 channel runner、退出关闭；绑定成功后自动启动 listener；SIGTERM 立即退出不留僵尸进程；runner 去重（同 channelId 不重复启动）。
- **通道核心入 `core/`（跨平台复用）**：统一抽象层（ChannelEvent / ChannelReply / 状态机 / Router / 管理编排）+ 微信 ClawBot 适配器（transport **重写为纯官方 iLink 协议**，由 `@tencent-weixin/openclaw-weixin` 2.4.6 官方源码推导）+ CLI（`channel login` / `listen` / `reply` / `run`，vendor qrcode-terminal）+ 单测（指令 / 路由 / 会话 / 传输层，全绿）。
- **文件面板升级为预览 + 编辑器**（`⌥⌘P` / 活动栏「文件」图标）：UTF-8 且 ≤2MB 的代码/文本文件面板内直接编辑，**行号栏随滚动严格对齐**（gutter 逐行按实际字形基线绘制）、**语法高亮**（vendored Highlightr，180+ 语言，明暗自适应）；未保存页签显示 `*`；`File ▸ 保存`（⌘S）原子写回，`File ▸ 关闭页签`（⌘W / Ctrl+W）；保存图标 + File 菜单置于 Edit 前；设计文档 `docs/plans/PREVIEW_PLAN-file-panel.md`（rollback-first）。
- **CI / 测试补齐**：local-ci 与 GitHub swiftc 编译清单登记 FilePanel / CodeEditorView / Highlightr / ChannelPanel；channel 单测并入 `node --test core/tests/`；clawbot 测试 mock 只返回一次消息、移除依赖真实 dsh web 的 e2e（避免残留临时会话/目录）。

### Fixed

- **通道消息重复回复**：轮询改**严格串行 while 长轮询**（对齐官方 monitor）——setInterval 破坏 `get_updates_buf` 游标推进导致同一消息被反复处理/重复回复（根因与验证见 `docs/channel-issues.md`）。
- **通道路由/状态**：通道级状态写入加内存缓存，避免 onState 与 setActiveSession 并发写 state 文件互相覆盖；`/new` 创建后立即用 /new 文本 prompt（会话非 blank、dsh web 可见）；快捷指令未找到提示更新（`#wN` → 未找到工作区、`#sN` → 未找到会话）；`/wks` 显示 workspace title + `~` 缩短路径不泄露用户目录；加载全局通道过滤历史坏 id；`channel run` 默认 dshHome=~/.dsh 使 CLI 可用。
- **面板 v2 UI**：分隔线位置修正（去掉标题/工具条之间、保留工具条/内容区之间）；工具条清空（无文字无线）+ 引导标题/卡片改纯 Auto Layout 左对齐；项目视图从内容区顶部渲染（FlippedStackView）、行占满整宽、展开手势移回 Channel 名（不再吞开关点击）。
- **代码编辑器**：Highlightr() init 崩溃防护；行号栏滚动去同步/末行缺失/越界/首布局漂移——按每行实际字形基线绘制、布局稳定后重绘。
- **终端启动目录**：解析忽略系统临时目录会话（`chan-e2e-*` 测试残留），终端不再默认落在测试临时目录。
- **CI 编译清单**：补齐 ChannelPanel.swift（修复 ChannelPanelController 未定义）与 FilePanel/CodeEditorView/Highlightr。

### Docs

- **通道文档**：`docs/channel-design.md`（能力设计：统一抽象 + 微信/钉钉/飞书多平台扩展 + ClawBot 可行性）、`docs/channel-commands.md`（指令清单）、`docs/channel-status.md`（完成状态总览）、`docs/channel-storage.md`（存储全局化设计）、`docs/channel-issues.md`（重复回复根因排查）。
- **文件面板**：`docs/plans/PREVIEW_PLAN-file-panel.md` 设计文档（预览增强，rollback-first）；README「预览面板」小节改为「文件面板」（预览 + 编辑 + 高亮）。
- **发布流程固化**：`docs/release-process.md`（四步发布：CHANGELOG → tag → local-release → 版本推进）；AGENTS.md 增补发布指引与 GitHub token 位置；SECURITY.md Supported Versions 同步步骤。
- **README / CONTRIBUTING 覆盖本次发布内容**：新增 Channel 面板介绍（右栏面板 + 特性一览 + 截图）；项目结构/测试清单补 channel 模块与文件面板组件；wiki 同步（channel-panel / file-panel 模块页、架构/数据模型/任务/构建脚本刷新）；README 增加 app 截图。

## [1.11.0] - 2026-08-21

### Added

- **浏览器面板（Chromium/CEF 内核）**（活动栏 globe / `⌥⌘B`）：多标签浏览器，每标签一个 Chromium 渲染进程（五 helper app：base/Alerts/GPU/Plugin/Renderer，名字承重）；地址栏导航（无 scheme 自动补 `https://`）、后退/前进/刷新·停止；控制台抽屉（CDP 捕获 console/异常/全部网络请求 + JS 求值 + 清空）；DevTools 按钮在系统浏览器打开完整 Chromium DevTools；`use-mock-keychain` 不弹钥匙串密码框；profile 收在 `~/.dsh/browser/`。
- **浏览器 REST API**（`127.0.0.1:3081`，`DSH_BROWSER_PORT` 覆盖，端口文件 `~/.dsh/browser-api.port`）：`status`/`open`/`tabs`/`back`/`forward`/`reload`/`stop`/`eval`/`console`/`console/clear`/`screenshot`/`hide`，CORS 放行；Agent 驱动自动展开面板；配套技能 `.dsh/skills/shell-browser/SKILL.md`（modelInvocable）。
- **DevTools 工具条可拖动调高**（150–700pt，主窗口联动压缩）：拖动条悬停显示上下拖拽光标；拖动中主页面/DevTools 两 CEF 视图完全静止（frame/视口不动）、全程禁用 autoresizing、跳过 layout 钩子、抑制逐帧 notifyResize，松手统一对齐并恢复页面滚动位置（CDP 记录 scrollY、松手 scrollTo）；80ms resize 节流消除逐帧重排导致的页面抖动上移（详见 `docs/devtools-drag-fix.md`）。
- **视图菜单「外观」切换**（`feat(#6)`）：浅色/深色/系统三态，与设置窗口外观双向同步。
- **App 体积精简**（约减 ~138M）：slim app bundle（移除重复 node ~116M、node-pty win32 prebuilds），见 `docs/plans/APP_SLIM-app-size.md`。
- **活动栏图标顺序与文案调整**：Files(重叠文件图标)/Terminal/Browser/Wiki/Tasks，tooltip 固定英文。
- **CEF 构建管线**（`platforms/macos/build-cef.sh`）：版本固定 + sha1 校验 + `.cache` 缓存；wrapper/shim/helper 编译；五 helper 组装与由内向外签名；`build-app.sh`/CI 接入。
- **本地发布/CI 工具链**：`local-release.sh` 支持 `pack` 子命令（只打包不发布）；发布模式强制版本一致性（版本单一来源 git tag，不一致即阻断）；runtime 缓存按架构分目录、双架构 release 不再互相覆盖重建；CEF 缓存 key 改用稳定绝对路径。
- 测试：`tests/browser-panel/`（日志缓冲/URL 规范化/HTTP 解析/REST 路由，56 断言）；CI 编译清单与浏览器测试步骤登记。
- 设计文档：`docs/plans/BROWSER_PLAN-browser-panel.md`（含根因修正：CEF 148+ 需五 helper，缺 `(Renderer)` 导致 renderer 静默失败——曾误判为签名问题）。

### Fixed

- **DevTools 拖动条导致 CEF 视图上移/底部空白**：根治为 contentsScale 同步 + CEF 视图 frame 统一由 layout() 同步（去手动/AutoLayout 竞争）、frame origin 强制为零；拖动中禁用 pageView/devtoolsContent 的 autoresizesSubviews、完全跳过 layout 钩子、抑制 notifyResize（此前每帧 WasResized 致页面缓慢上移），松手统一刷新——消除页面顶部反复重排跳动与累积上移。
- **CEF 覆盖式启动卡死**：覆盖式约束改用 activate 数组激活（init 里 `isActive=true` 曾致启动卡 buildWindow/Starting）；回退覆盖式约束并修 `CEFShim.shutdown` 未初始化时泵循环空指针；覆盖式切换后把主 CEF 视图钉回顶部全高（Chromium 会把 CEF 底部对齐致顶部空白）+ 视口一次 resize。
- **DevTools WebSocket 连不上**：CEF 默认拒绝带 Origin 的连接，加 `--remote-allow-origins=*` 放行；ws 获取改实时 `/json` 按 URL 匹配当前页签（CDP targetId 陈旧/误配导致 WebSocket 连不上）。
- **浏览器面板**：浅色外观页签背景调浅；DevTools 关闭闪退（窗口关闭拦截缺失）。
- **i18n**：语言切换后刷新各面板头部操作按钮与活动栏 tooltip（此前只重建菜单，tooltip 停留旧语言）；补 `terminal.closePanel` 文案、浏览器面板标题跟随语言切换；活动栏 tooltip 恢复系统语言切换（bar.preview 文案改为 文件/Files）。
- **IssueRunner 面板**：issue 关闭后标记实际状态 closed 并适配操作按钮。
- **dsh web 自拉起**：加 `--no-open`，避免默认浏览器被自动打开。
- **发布/CI**：`$VER` 统一加花括号 `${VER}` 修复 UTF-8 locale 下 unbound variable；local-ci.sh swift 阶段补齐 browser 面板测试与 CEF 编译。

### Docs

- `docs/devtools-drag-fix.md`：DevTools 拖动条导致 CEF 视图上移问题分析与修复方案。
- `docs/plans/BROWSER_PLAN-browser-panel.md`：浏览器面板设计（含 CEF 五 helper 根因修正）。
- wiki 同步：浏览器面板 OSR/Chromium 演进、五面板结构、发布/CI 工具链、per-arch 缓存。
- 合并规范：PR 合并一律用 `--no-ff`（merge commit）。

## [1.10.0] - 2026-08-18

### Added

- **系统优先 node 选择策略**：`dsh web` 启动优先使用操作系统安装的 node（PATH → nvm current → nvm default → nvm 最新 → Homebrew），内置 node 仅作兜底；`DSH_NODE` 显式覆盖仍无条件优先（无回退）。
- **About 面板显示实际 node**：显示实际运行 dsh web 的 node 版本与路径，合并为一行。
- **dsh web 环境合并登录 shell PATH**：App 启动时经 `/bin/zsh -ilc` 读取一次登录 shell PATH（8s 超时兜底、失败保留继承值）赋给 dsh web，使其 bash 会话能使用用户全局工具（nvm bin、`~/.local/bin` 等，如 `agent-browser`）；不再向 PATH 注入内置目录。
- **GitHub token 按仓库作用域**：解析优先级 Keychain 专属（`<owner>/<repo>`）→ `~/.dsh/tokens/<owner>-<repo>` → Keychain 通用 → `~/.dsh/gh-token`；多工作区各用各的 token（App 与外部工具/代理共用同一份）。
- **GitHub token 双写保存**：面板保存时 Keychain + `~/.dsh/tokens/<owner>-<repo>` 文件（chmod 600）双写，清空时双清。
- **GitHub token 文件优先读取**：token 读取改为文件优先（免 Keychain 密码提示），Keychain 写入设 `kSecAttrAccessibleAfterFirstUnlock` 免每次弹密码。
- **issue 处理按统一分支规范**：feature 类 issue 切 `feature/issue-N`，bug/其他切 `fix/issue-N`（按 label 判定）；issue-fix skill 分支说明同步。
- **issue-fix skill 自动安装**：任务开始时 `ensureIssueFixSkillInstalled` 写入 `<repoRoot>/.dsh/skills/issue-fix/`（内嵌副本与仓库字节一致、幂等），全新工作区也能处理 issue。
- **`scripts/git-remote.sh`**：push 前检测 remote 名（github 优先，origin 兜底），`release-fix.sh` 不再硬编码 origin。
- **文档**：`docs/git-workflow.md`（统一分支与发布规范：main 只合并/只打主版本，feature/fix/release 分支模型，patch 版本同步回 main 走 PR）；AGENTS.md 补充分支提交强制规范与 GitHub token 位置；`.dsh/wiki` 知识库同步刷新。

### Changed

- **Node 选择策略反转（系统优先、内置兜底，含版本门槛）**：`dsh web` 启动优先使用操作系统安装的 node（PATH → nvm current → nvm default → nvm 最新 → Homebrew），但**低于版本门槛（默认 22.0.0，`DSH_NODE_MIN` 可覆盖）的系统 node 会被跳过**——dsh rc.6 实际需要 Node ≥ 22（`node:zlib` 的 zstd ESM 导出、`Promise.withResolvers`、`node:module.stripTypeScriptTypes`，Node 20 全部缺失，实测 v20 启动 dsh web 会崩在插件树加载）；仅当系统 node 缺失/过旧、或用它启动 dsh web 失败时才回退内置 node；`DSH_NODE` 显式覆盖仍无条件优先（无回退）；启动轮询增加 1s 沉降校验，避免"引导页含 `__DSH_BOOT__` 但随后崩溃"的假就绪。
- **dsh web 环境不做 PATH 注入，但合并登录 shell PATH**：移除启动与升级路径的内置目录 PATH 置顶；App 启动时经 `/bin/zsh -ilc` 读取一次登录 shell PATH（8s 超时兜底、失败保留继承值）赋给 dsh web，使其 bash 会话能使用用户全局工具（nvm bin、`~/.local/bin` 等，如 `agent-browser`）；About 面板的 Node 版本显示实际运行 dsh web 的 node。
- **CI action 升级**（dependabot）：`actions/upload-artifact` 4→7、`actions/setup-node` 4→7、`actions/cache` 4→6、`actions/download-artifact` 4→8。
- **版本 fallback 推进到 1.10.0**（v1.9.0 发布后的开发线版本）。

### Fixed

- **Tasks 面板跟随工作区切换**：dshSession 切换时无条件触发 `tasksPanel.workspaceChanged()`（不再依赖 ProjectDirectory 变化）；切换顺序修正为先 `ProjectDirectory.set` 再触发；`workspacePath` 非空时严格按当前会话判断（GitHub 仓库→显示 issues，非 GitHub→诚实显示 not a GitHub repo，不再 fallback 到其他 workspace），仅启动早期 ProjectDirectory 未解析时才用 `workspace.list` 兜底；Ungrouped 会话切回也能正确识别。
- **token 读取文件优先**（免 Keychain 密码提示）：顺序为文件专属 → 文件通用 → Keychain 专属 → Keychain 通用；配置框文案更正为按仓库双写（`~/.dsh/tokens/<owner>-<repo>`），配置按钮图标改齿轮。
- **壳层内嵌 repo-wiki skillMarkdown 同步**：补规则 8 提交指令（与仓库 SKILL.md 字节一致），修复 `ensureInstalled` 每次用旧内嵌版覆盖仓库文件导致提交规则丢失。
- **nvm 解析**：系统 node 解析 honor nvm default alias、prefer nvm current（最后一次 `nvm use`）。
- **git remote 名检测**：`git push` 前检测 remote 名（github 优先，origin 兜底），`release-fix.sh` 不再硬编码 origin。

## [1.9.0] - 2026-08-16

### Added

- **IssueRunner 任务面板**（活动栏「任务 / Tasks」、⌥⌘J）：GitHub issue 驱动的串行任务流水线——
  - 仓库自动识别（git remote）+ open issues 拉取（REST，过滤 PR；私有仓库 Keychain token）；
  - 处理流程：切分支 `fix/issue-N` → 新建 dsh 会话（归主工作区）→ 会话改名可追溯 → issue-fix skill 修复 → 推送 → 开 PR；
  - 串行队列、行内展开详情（状态/标签/分支/PR/正文，滚动区 + 底部按钮）、取消/重试/打开 PR；
  - 完成后的 issue 支持「评论并关闭」（用户触发，POST comment + PATCH close）；
  - 任务关联索引落地 `.dsh/tasks/`（index.json 随仓库提交，local.json 本机 session 映射），重启可恢复；
  - 共享核心：`core/lib/issues.js`（issues/PR/comment-close/remote 检测）、`core/lib/jobqueue.js`（串行队列）、`core/lib/tasks.js`（关联索引）；
  - skill：`.dsh/skills/issue-fix/SKILL.md`。
- **Wiki 自动提交**：更新完成后由代理（repo-wiki skill 规则 8）`git add .dsh/wiki` + commit（不 push，message 概括实际变更）；面板 `WikiAutoCommit` 兜底。

### Changed

- 版本单一来源：`scripts/version.sh` fallback 推进到 1.9.0（发布后立即推进开发线版本，避免与已发布版本混淆）。

### Fixed

- IssueRunner：仓库识别兜底（workspace.list 解析）、gitBranchPushed 按 remote 名解析、恢复任务标题/正文显示、行内详情滚动与按钮固定。

## [1.8.0] - 2026-08-15

### Added

- 里程碑 M1（产品化基础，P1）全部交付（详见本里程碑文档 `docs/milestones/M1-productization-foundation.md`）：
  - 开源就绪：MIT LICENSE、CONTRIBUTING.md、SECURITY.md、CHANGELOG.md、CODEOWNERS、AGENTS.md、Issue 模板（bug/feature）；
  - CI：`.github/workflows/ci.yml`（macOS arm64/x64/Universal 矩阵 + 单测 + swiftc 编译检查 + `.cache/` 缓存）、`nightly.yml`、dependabot；
  - 发布：`.github/workflows/release.yml`（tag 触发 → 构建 → `.dmg`/`.pkg` + SHA-256SUMS → GitHub Release）；
  - 版本单一来源：`build-app.sh` 的 VERSION/BUILD 由 git tag / CI 运行号驱动（`scripts/version.sh`）；
  - 共享核心 `core/`（Node 模块）：ANSI 模拟器（42 用例全绿）/ 端口与服务管理 / 升级 / 会话 RPC 从 Swift 抽出，`core/bin/ohmy-core.js` CLI；
  - 设置窗口（语言 / registry / 升级 / 主题 / 快捷键，⌘, 打开）与首次引导（onboarding）；
  - 平台骨架 `platforms/macos/` 迁移（src/ + build-app.sh + make-pkg.sh，git mv 保留历史）。

### Changed

- `build-app.sh` 支持 `DSH_ARCH=arm64|x86_64|universal` 交叉构建（swiftc `-target` + universal lipo）。

### Fixed

- 构建脚本 `TMPDIR` 在清理 `.build` 后未重建导致 swiftc 失败的隐患。

## [1.7.1] - 2026-08-15

### Added

- Repo Wiki 知识库面板：生成/维护/浏览 + 多工作区跟随（`feat(wiki)`）；
- `docs/productization.md` 产品化方案与里程碑目标文档；
- 知识库增量更新流程与 `.dsh/wiki/` 结构。

### Fixed

- 终端多字节输入乱码（`docs/terminal-input-fix.md`：`Darwin.write` 传数组缓冲区必须用
  `withUnsafeBytes`）；
- 终端/Wiki 面板 header 合成溢出（`docs/terminal-header-fix.md`：父容器 `wantsLayer` +
  `masksToBounds`）。

## [1.6.28] - 2026-08-14

### Added

- 原生 macOS 壳首个可分发版本（`b4bceba`）：自包含运行时（内置 Node + dsh）、
  端口探测/复用/自拉起、预览面板、集成终端面板（PTY + ANSI 模拟器）、中英双语、
  dsh 手动/自动升级、registry 配置、退出清理。

---

[Keep a Changelog]: https://keepachangelog.com/en/1.1.0/
[Semantic Versioning]: https://semver.org/spec/v2.0.0.html