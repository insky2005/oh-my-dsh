---
title: 模块：项目面板（Projects Panel）
tags: [module, projects, workspace, workspace-create, session-create, projects-root, panel]
updated: 2026-09-23T12:13:33Z
sources: [platforms/macos/src/ProjectsPanel.swift, platforms/macos/src/ProjectsCore.swift, platforms/macos/src/DshWebRPC.swift, platforms/macos/src/main.swift, platforms/macos/src/PanelSurface.swift, platforms/macos/src/ShellConfig.swift, tests/projects-panel/, tests/dsh-rpc/run.sh, docs/projects-panel-design.md, docs/dsh-version-impact.md, scripts/local-ci.sh, .github/workflows/ci.yml, README.md]
manual: false
---

# 模块：项目面板（Projects Panel）

把「工作区 = projects 根目录下的一个子目录」变成壳层一等公民：**在面板里建目录 + 幂等注册成 dsh 工作区，再用六个入口就地打开它**，不离开 App、不改 dsh 源码。分支 `feature/projects-panel`（设计文档 `docs/projects-panel-design.md`，PR #56）——**已实现、未发布**（CHANGELOG `[Unreleased]`，版本线 fallback `1.17.0`/BUILD 73）。实现提交：`b59ac97` 模型 → `f541f4d` RPC → `232d38c` 面板 + 控制器测试 → `6d8c327` main.swift 接线 → `206b577`（卡片命中测试修复）→ `0f1b7b2`（README/CONTRIBUTING/CHANGELOG/影响清单）。

- 入口：活动栏**首位**「项目」图标（SF Symbol `folder`）/ 视图菜单**首项** / **⌥⌘P**；右栏插槽第 9 个成员 `RightPanel.projects`，`rightPanelKind` 持久化 `"projects"`；`ProjectsPanelController.minWidth = 320`；
- **⌥⌘P 是让位来的**：该键原属「预览面板」，PR #57（`0253b35`，`feature/menu-files-panel`）把视图菜单正名为「文件面板」并改用 **⌥⌘F**，空出的 ⌥⌘P 交给本项目面板（L10n 键 `menu.togglePreview` 同步改名 `menu.toggleFiles`）。

## 组成

| 文件 | 规模 | 职责 |
|---|---|---|
| `platforms/macos/src/ProjectsCore.swift` | 217 行 | 纯 Foundation 模型：`ProjectWorkspace`、`resolvedRoot(configValue:dshHome:envOverride:)`（+ `RootSource`）、`absolutePath`、`validateName`、`workspacePath`、`listDirectories`、`merge(entries:registry:canonical:)` |
| `platforms/macos/src/ProjectsPanel.swift` | 699 行 | `ProjectsPanelController` + `ProjectCardView`（三行卡片）+ `ProjectsRootView`（`PanelSurface` 底色）+ `ProjectTargetPanel`（六个入口枚举，rawValue 即 `DSH_PANEL_TEST` 的面板名） |
| `platforms/macos/src/DshWebRPC.swift` | 431 行（`DshWorkspaceOps` 约 70 行） | `register` / `createSession` / `newestSessionId` + 端点 `DshWebRPC.workspaceCreate = Endpoint("workspace/create", "workspace.create")` |
| `platforms/macos/src/main.swift` | 6083 行 | 接线：活动栏首位 / 视图菜单 ⌥⌘P / `adoptProjectDirectory` 重根原语 / `openWorkspace` / `openWorkspaceInDsh` / `createSessionInWorkspace` / 设置窗口「项目」区块 / QA 钩子 |
| `tests/projects-panel/` | 4 文件 | 无头测试：模型 45 项 + 控制器 39 项，`run.sh` 一次跑完（本机实测 **84 项 ok / EXIT=0**） |

## projects 根目录（唯一可配置项）

| 优先级 | 来源 | 说明 |
|---|---|---|
| 1 | `DSH_PROJECTS_TEST_ROOT` | 仅 QA（`ProjectsCore.envRootKey`），必须是绝对路径才生效 |
| 2 | `projectsRoot`（`$DSH_HOME/shell/config.json`） | 键缺失 / 空串 = 用默认值；**相对路径拒绝**（`RootSource.invalidConfig` → 回默认值 + `app.log` 记一行） |
| 3 | `$DSH_HOME/oh-my-dsh/projects` | 正式版 `~/.dsh/oh-my-dsh/projects`；开发版 `~/.dsh-dev/…`（`applyDevIsolation` 天然隔离） |

- `projectsRoot` 是**新键**，故意不进 `ShellConfig.legacyUserDefaultsKeys`（没有 1.14 前的 UserDefaults 值可搬）；core `settings.js` 对键名无白名单，新增键无需改 core；
- **打开面板不写盘**：只读列举；`mkdir -p` 只在「新建工作区」时发生（连带建根），根不存在时面板给空态 `projects.rootMissing`；
- 改根两条路：面板头部「更改…」（`NSOpenPanel`，`canChooseDirectories` + `canCreateDirectories` → `ShellConfig.set` → `reload()`）与设置窗口「项目」区块（选择… / 保存 / 恢复默认；`~` 会展开，非绝对路径内联报错不写盘）；设置窗口保存后 `AppDelegate.projectsRootDidChange()` → `projectsPanel.workRootChanged()`，两处写的是**同一个键**。

## 卡片与三条流程

卡片三行：① 目录名（semibold 13pt）+ 徽标（`已注册 · N 个会话` / `未注册`）；② 绝对路径（次要色、中间截断、tooltip = 全路径）；③ 操作行 = **文件 / 终端 / 知识库 / 任务 / 通道 / 审查** 六个 `CustomIconButton`（SF Symbol 与活动栏同源：`doc.on.doc`/`terminal`/`book.closed`/`checkmark.circle`/`dot.radiowaves.left.and.right`/`doc.text`）+ **新会话**（带文字的强调色按钮）+ 在 Finder 中显示 + 复制路径。**整卡可点 = 在 dsh 中打开**（`mouseDown` → `onOpen`）。`206b577` 修掉「点名称没反应」：名称/徽标/路径都是 `NSTextField` 标签，标签自己会命中测试、把点击吃掉，于是 `ProjectCardView.hitTest(_:)` 覆写——命中的不是操作行控件（`NSButton` / `CustomIconButton`）就归位到卡片本身，操作行按钮仍按最深子视图优先正常工作。

| 流程 | 实测行为 |
|---|---|
| 新建 `abc` | `validateName` → `createDirectory`（**同步**，单个目录创建）→ `registerInBackground`（`workspace/create`，幂等）→ `reload()`。同名**目录**不是错误：状态行「该工作区已存在」并**继续注册**；同名**文件** → `projects.createFailed`；**不自动切换当前工作区**（避免没点入口右栏就跳走） |
| 六个快捷入口 | 卡片回调 `onOpenPanel(path, target)` → `main.swift openWorkspace`：先 `adoptProjectDirectory(path)`（不是存在的目录即中止，**不切面板**），再 `setRightPanel(...)`；日志 `projects: opened the <target> panel for <path>` |
| 新会话 | 后台 `DshWorkspaceOps.register`（8s）→ `createSession(workspaceId 优先，被拒退回 cwd，15s)` → 主线程 `adoptProjectDirectory` + `nudgeDSHWebCaches()` + **0.5s 后** `openDSHSession(sid)`；失败只进状态行（`projects.newSessionFailed`），**不弹模态** |
| 在 dsh 中打开 | 后台 `newestSessionId(port:inPath:)`（`session/list` 中 cwd canonical 相等者，**running 优先**，其次 `updatedAt` 最大）→ 有则 `adoptProjectDirectory` + `openDSHSession`，无则走「新会话」 |

- `DshWorkspaceOps.register` 把 nil 一律当「未注册」（旧 dsh / 服务未起 / store 漂移），**永不阻塞目录创建**、**不回收已建目录**；下次「新会话 / 在 dsh 中打开」会再注册一次（幂等）；
- 状态行是唯一结果通道：`setStatus` 每次都写 `app.log` 的 `projects: <文本>`，**成功类 5s 后自动清空、失败保留到下次操作**；名字非法的提示走 sheet 内联 + 状态行（`presentError` 有窗口时才补一个 sheet）。

## 当前工作区（单一真相，无第二个选中状态）

- 壳层的「当前工作区」只有 `ProjectDirectory.current` 一个真相（既有 `dshSession` 处理器在 web 切会话时写它）；面板**没有**面板内选中项——卡片高亮是每次渲染时算出来的：`canonical(ProjectDirectory.current) == canonical(ws.path)`（`DshWorkspaceStore.canonical` 走 `realpath(3)`，因此 `/var` 与 `/private/var`、符号链接路径与真实路径都能对上）；
- 六个入口与「新会话」都经 `main.swift` 的 **`adoptProjectDirectory(_:)`** 重根原语：`standardizingPath` → **必须是已存在的目录**（否则拒绝并记 `project directory refused (not an existing directory)`）→ 路径真的变了才依次 `previewPanel.setProjectDirectory` / `terminalPanel.setWorkspaceDirectory`（终端页签按工作区收起/恢复） / `wikiPanel.reloadRoot` / `tasks`·`channel`·`review` 的 `workspaceChanged` / `projectsPanel.workspaceChanged`（只重渲染 + 重列徽标）；
- **有意的小行为修正**：旧 `dshSession` 处理器不检查目录是否存在，会把各面板重根到已删除的目录；抽出的原语带 `fileExists + isDirectory` 守卫，这种情况直接返回 `false`；
- 用户在 dsh web 里切到别的工作区 → 同一个原语被调用 → 面板高亮随之移动，**面板高亮 / 终端页签归属 / 任务·通道·审查的工作区不可能互相打架**（设计 D5）。

## dsh 侧契约（新增耦合面 C10a/b/c、B10）

| # | 依赖 | 形状 | 壳层位置 | 失效表现 / 防御 |
|---|---|---|---|---|
| C10a | `workspace/create` | `{request:{path}}` → `{workspace:{workspaceId,…},created}`；**幂等**（已注册回 `created:false`）、目录必须已存在、**无 capability 门控** | `DshWorkspaceOps.register` | 新建的工作区不出现在侧栏 / 会话落 Ungrouped → 只降级为「未注册」，不阻塞目录创建，下次幂等重试 |
| C10b | `session/create` | `{workspaceId}` 优先（会话归属该工作区），被拒退 `{cwd}`（落 Ungrouped，功能可用） | `DshWorkspaceOps.createSession` | 「新会话」没反应 → 退 cwd + 状态行报错 |
| C10c | `session/list` | `items[].{sessionId,cwd,running,updatedAt}` | `DshWorkspaceOps.newestSessionId` | 字段缺失按「无会话」处理 → 退化为新建 |
| C4/R4 | 工作区列表 | 0.1.2 无 `workspace/list` → `DshWorkspaceStore.items`（活 RPC 试探 → `$DSH_HOME/storages/workspace.json`，domain `workspace` v2 校验 + 诊断） | `ProjectsPanelController.reload` | 徽标退化为「未注册」，列举与创建不受影响 |
| B10/R3 | 侧栏行点击 | `__dshOpenSession(id)`：`session/list` 取标题 → 点 `[role="treeitem"].sessionRow`（最多重试 8 次） | `sessionOpenerScript` + `openDSHSession` | 新会话建了但 web 不切过去 → nudge → 重试一次 → 重载页面 + `didFinish` 补打开 |

> `WikiPanel` 自带一份私有的 `WikiRPC.createSession` 孪生实现，**有意不重构**（约 15 行重复换来不动已上线面板）；`DshWorkspaceOps` 是新建的共享实现。

## 失败模式（都不阻塞创建）

| 场景 | 表现 | 观测点 |
|---|---|---|
| dsh web 未起 / 端口为 0 | 目录照建，徽标「未注册」+ 状态行「已创建目录，但尚未注册到 dsh（服务未就绪…）」 | `app.log` 的 `projects:` 行 |
| dsh ≤0.1.1 / 端点 404 | 同上；「新会话」可退化到只传 `cwd` | 同上 + `[dsh-opener]` |
| 侧栏还没有新工作区 / 新会话的行 | `nudgeDSHWebCaches()` → 0.5s 点行 → 失败**重试一次**（1.5s）→ 仍失败 `pendingOpenSessionId = sid` + `reloadPageReauthenticating(reason: "session-open")` → `webView(_:didFinish:)` 里**补打开一次**（用完清空） | `openDSHSession <id>: row-not-found` |
| `storages/workspace.json` 读不懂（上游改布局 / 升版本） | 注册状态与会话数退化为「未注册 / 0」，功能不受影响 | `[workspace-store] …`（既有 R4 护栏） |
| 根目录不存在 / 无子目录 | 空态 `projects.rootMissing` / `projects.empty` +「+ 新建工作区」；不自动写盘 | 面板 |
| 名字非法（空 / 含 `/` 或 `:` / 控制字符 / `.`·`..` / 以 `.` 开头 / > 64 字符） | 创建前拦截 + 规则提示，**不创建任何东西**、不发请求 | sheet 内联 + 状态行 |
| 根目录里的符号链接指向目录 | 视为工作区；canonical 归一后仍能与注册表匹配（链接进已有仓库是正常用法） | 面板徽标 |
| 慢卷 / 网络卷 | 列举 + 注册表读取全在后台队列（注册表最坏阻塞 6s），主线程只渲染；`loadToken` 保证慢的那次结果不会覆盖新的 | — |
| 「会话快照回退」之后 | 注册表就在快照数据集内（`storages`），回退后重开按新注册表重读即可，面板**无需特殊处理**（徽标在「已注册 ↔ 未注册」间变化） | `[workspace-store]` 诊断 + 徽标 |

## 测试与 QA

- `tests/projects-panel/run.sh`（两段，本机实测 EXIT=0，**84 项 ok** = 模型 45 + 控制器 39）：
  1. **模型层** `projects-tests.swift`（**45 项**）：默认根 / `resolvedRoot` 的四类来源（无配置、空白配置、绝对路径、`~` 展开、相对路径拒绝并标 `invalidConfig`、env 覆盖优先）/ `validateName` 十例（含 64 与 65 字符边界、trim）/ `workspacePath`（不产生双斜杠）/ `listDirectories`（普通目录入选、普通文件跳过、隐藏项跳过、**目录符号链接入选**、文件符号链接跳过、排序大小写不敏感、根不存在 → `[]`、mtime）/ `merge` 九例（canonical 匹配、尾斜杠、符号链接、空注册表、`sessionCount = sessionIds.count`）；
  2. **控制器无头冒烟** `controller-tests.swift`（**39 项**）：`NSApplication.shared` + 临时 `DSH_HOME` + 真实 `PanelSurface`/`ProjectsCore`/`ProjectsPanel`/`ShellConfig`/`DshWebRPC` + **假传输**（`DshWebRPC.perform`）——列表与徽标文案、非法名不建目录也不发请求、建目录真的落盘且请求体为 `workspace/create` 的 `payload.args.request.path`、无服务时目录保留 + 「尚未注册」、六个入口回调 `(path, target)`、新会话回调、点卡片 = 在 dsh 中打开、当前工作区标记落在哪张卡、配置换根后重列；
- `tests/dsh-rpc/run.sh`（整套 54 项）新增 `DshWorkspaceOps` **14 条断言**：`register` 5（解析 `workspaceId`、`args.request.path`、`created:false` 仍解析、端点缺失 → nil、返回体无 id → nil）、`createSession` 6（先带 `workspaceId`、被拒退回 `cwd`、**恰好两次**请求、无 `workspaceId` 时一次请求）、`newestSessionId` 3（running 优先于 updatedAt、无 running 取最新、无会话 → nil）；
- 已接入 `scripts/local-ci.sh`（swift 阶段）与 `.github/workflows/ci.yml` 的 swift job；`tests/l10n/run.sh` 自动覆盖新增的 `projects.*` / `menu.toggleProjects` 键；
- QA 钩子：`DSH_PROJECTS_TEST=1` 启动即开项目面板（**放在 `DSH_SKILLS_TEST` 之后**）；`DSH_PROJECTS_TEST_ROOT=<dir>` 覆盖根目录（仅 QA，不写 `shell/config.json`）；`DSH_UI_DEBUG=1` 落 `~/Library/Logs/oh-my-dsh/panel-projects-debug.png`（`setRightPanel` 通用路径）与渲染后的 `panel-projects-loaded-debug.png`（`onDidRender`）；`DSH_PANEL_TEST="projects,…"` 全量扫描钩子已认 `case "projects", "项目"`（九个面板，8s 起每个 5s 一切）。

## 明确不做（本次范围）

工作区重命名 / 删除 / 注销（清理交给 Finder 与 dsh web 侧边栏，面板不写破坏性路径，D3）；`git init` / `AGENTS.md` / `.dsh/wiki` 脚手架（D2）；列出并管理根目录之外的 dsh 工作区；工作区级「最近会话」列表（只提供「打开最近一条」）；与 Composer `@` 引用联动；模板 / 第二个当前工作区状态（D5）。
