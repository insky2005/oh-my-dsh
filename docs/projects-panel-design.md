# 项目（Projects）面板设计

> 状态：**设计定稿，待实现**（`feature/projects-panel` / PR #56）。评审意见已并入：① 面板快捷键定为 **⌥⌘P**；② 「文件面板」正名 + 快捷键改 ⌥⌘F 作为**独立改动**拆出，**已合并进 main**（PR #57，`0253b35`）；③ 实现顺序见 §15。本文件只描述设计，不含代码。
> 关联：`docs/dsh-version-impact.md`（本次新增耦合面：C10 工作区注册与建会话、B10 侧栏行点击桥；沿用 C4/R4 的 workspace.json 兜底）、`docs/skills-manager-design.md` / `docs/review-panel-design.md`（面板体例参照）、`docs/ui-color-scheme.md`（配色令牌）、`.dsh/wiki/tasks.md`（加面板清单）
> 实现（规划）：`platforms/macos/src/ProjectsCore.swift`（纯模型）、`ProjectsPanel.swift`（面板）、`DshWebRPC.swift`（新增 `DshWorkspaceOps`）、`main.swift`（接线）；测试 `tests/projects-panel/`、`tests/dsh-rpc/`

---

## 1. 目标与非目标

### 1.1 目标

在壳层里把「工作区 = 项目根目录下的一个子目录」变成一等公民，**不离开 App、不修改 dsh 源码**：

1. **可配置的 projects 根目录**：默认 `$DSH_HOME/oh-my-dsh/projects`，用户可改成任意绝对路径；
2. **面板内快速创建工作区**：只输入工作区名（即目录名），例：`abc` → 创建 `<root>/abc`；
3. **工作区列表 + 快速进入**：对每个工作区，一键进入**文件 / 终端 / 知识库 / 任务 / 通道 / 审查**面板，并让这些面板以**该工作区**为根；一键**新建 dsh web 会话**（会话属于该工作区）；一键**在 dsh 中打开**（复用该工作区最近一条会话，没有则新建）。

面板入口：**活动栏第一个图标**（`folder`）/ 视图菜单首项 / **⌥⌘P**；右栏面板槽第 9 个成员（`RightPanel.projects`）。

### 1.2 已定决策（本次设计前置确认）

| # | 决策 | 说明 |
|---|---|---|
| D1 | **列表范围 = 仅 projects 根目录下的直属子目录** | 不在面板里列 dsh 已注册、但位于根目录之外的工作区（那些仍归 dsh web 侧边栏管） |
| D2 | **新建 = 只建目录 + 注册为 dsh 工作区** | 不做 `git init`、不写 `AGENTS.md`、不建 `.dsh/wiki`；是否需要仓库/指引由用户在会话里自行决定 |
| D3 | **不提供任何删除/移除/重命名入口** | 清理走 Finder 与 dsh web 自己的侧边栏；面板对工作区只做「创建 / 进入」，不写删除路径 |
| D4 | **活动栏放第一位**；快捷键 **⌥⌘P** | 顺序：项目、文件、终端、浏览器、知识库、任务、通道、审查、技能；「视图」菜单首项同为「项目」，与活动栏一一对应。⌥⌘P 原先属于「文件面板」，本次**让位**给它（文件面板改 **⌥⌘F**，菜单文案「预览面板」改「文件面板」）——见 §13.E |

### 1.3 非目标

- 不做工作区模板/初始化脚手架；不做重命名、不做目录删除、不做 dsh 注销；
- 不接管 dsh web 的侧边栏工作区管理（添加/归档/排序仍由 dsh web 自己做）；
- 不引入「第二个当前工作区」状态（见 §7）；
- 不改 DeepSeek Harness 源码，也不改 `core/`（Node）代码——本特性是纯壳层能力。

---

## 2. 概念与默认值

- **工作区（Workspace）**：一个**目录**。壳层的「工作区」与 dsh 的 Workspace（`workspaceId` + `path`）是同一件事的两种视角：壳层关心路径，dsh 关心注册身份。本面板保证「目录存在」与「dsh 侧已注册」尽量一致（注册失败不阻塞创建，见 §8）。
- **projects 根目录**：所有工作区的父目录。默认 `<DSH_HOME>/oh-my-dsh/projects`：
  - 正式版 `DSH_HOME=~/.dsh` → `~/.dsh/oh-my-dsh/projects`；
  - 开发版 `DSH_HOME=~/.dsh-dev`（`applyDevIsolation()` 注入，见 `docs/dsh-version-impact.md` D7）→ `~/.dsh-dev/oh-my-dsh/projects`，与正式版天然隔离；
  - 该目录**不在启动时创建**：面板首次打开只读列举，只有「新建工作区」才 `mkdir -p`（连带建根）。
- **路径语义**：根目录只接受**绝对路径**（`~` 会展开）；相对路径视为无效配置（设置窗口内联拒绝，面板侧回退默认值并记日志）。

---

## 3. 数据模型

### 3.1 配置

| 项 | 值 |
|---|---|
| 存储位置 | `$DSH_HOME/shell/config.json`（`ShellConfig`，见影响清单 **D4**） |
| 键 | `projectsRoot` |
| 值 | 绝对路径字符串；**键缺失/空串 = 用默认值**（不改写文件） |
| 默认值 | `$DSH_HOME/oh-my-dsh/projects` |
| 读取方 | 面板（每次打开/刷新）、设置窗口「项目」区块 |
| 写入方 | 面板头部「更改…」、设置窗口「保存…」/「恢复默认」 |

配置走既有的 `ShellConfig`（写操作合并去抖后交给 core `settings.js`，失败回落直接原子写）。core 的 settings store **对键名没有白名单**（`core/lib/settings.js` 只做 read/modify/atomic-write），因此新增键无需改 core。`projectsRoot` 是**全新键**，**不要**加进 `ShellConfig.legacyUserDefaultsKeys`（那份清单只用于从旧 UserDefaults 一次性搬值，新键没有历史值可搬）。

**测试用覆盖**：`DSH_PROJECTS_TEST_ROOT=<dir>` 优先级高于 `projectsRoot`（仅 QA 钩子使用，见 §11.4）。

### 3.2 目录名规则（`ProjectsCore.validateName`）

| 情形 | 结果 | 说明 |
|---|---|---|
| 空 / 纯空白 | `.empty` | 先 trim |
| 含 `/`（路径分隔） | `.separator` | 只允许单段目录名 |
| 含 `:` | `.separator` | HFS/APFS 上 `:` 会被改写成 `/`，必须拒绝 |
| 含控制字符（`\u0000`–`\u001F`、`\u007F`） | `.illegalCharacter` | |
| `.` 或 `..` | `.dot` | |
| 以 `.` 开头 | `.hidden` | 面板不列隐藏目录，建了也看不见 |
| 字符数 > 64 | `.tooLong` | 常规项目名足够，避免撞路径长度上限 |
| 其他 | ✅ 通过（存 trim 后的值） | |

同名目录已存在**不是错误**：面板提示「已存在」、选中该卡片，并继续做（幂等的）注册。

### 3.3 `ProjectWorkspace`

```swift
struct ProjectWorkspace: Equatable {
    let name: String           // 目录名（卡片标题）
    let path: String           // 绝对路径（<root>/<name>）
    let modifiedAt: Date?      // 目录 mtime，用于排序/展示（可空）
    let registered: Bool       // dsh 侧是否存在同路径工作区
    let workspaceId: String?   // 已注册时的 dsh workspaceId（建会话用它分组）
    let sessionCount: Int      // 已注册时 = sessionIds.count；未注册 = 0
}
```

### 3.4 列举与注册匹配

- **列举**：`FileManager.contentsOfDirectory(atPath: root, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey])`，只保留**目录**（含**指向目录的符号链接**——用户常把已有仓库 link 进 projects 根），跳过名字以 `.` 开头的项，按名（大小写不敏感）排序。根目录不存在 → 返回空数组（**不**报错、**不**创建）。
- **注册表读取**：`DshWorkspaceStore.items(port:dshHome:log:)`（dsh ≤0.1.1 走活 RPC `workspace/list`；dsh ≥0.1.2 回退 `$DSH_HOME/storages/workspace.json`，域名 `workspace` / v2 校验 + 诊断日志，见影响清单 **C4 / R4**）。**必须在后台队列调用**（最坏阻塞 6s）。
- **匹配**：两侧都用 `DshWorkspaceStore.canonical(path)`（standardize + 解析符号链接）归一，因此 `/r/abc`、`/r/abc/`、`/link/abc → /r/abc` 都能对上。

---

## 4. dsh 侧契约（实测）

被测版本 = 内置 `@deepseek-ai/dsh@0.1.2-rc.1`（`platforms/macos/build-app.sh` 的 `DSH_PACKAGE_SPEC` 默认值），源码位置：

- `node_modules/@deepseek-ai/dsh-api-workspace-controller/lib/typert.remote-client.js`（`workspace/*` 与 `directoryPicker/*` 的线上方法名与参数名）
- `node_modules/@deepseek-ai/dsh-api-session-controller/lib/types/types.d.ts`（`SessionCreateRequest`）
- `node_modules/@deepseek-ai/dsh-api-session-controller/lib/typert.remote-client.d.ts`（`session/*` 方法名）

### 4.1 一元 RPC 两代形状（沿用现状，不新增机制）

| 世代 | 端点 | 信封 |
|---|---|---|
| ≥0.1.2 | `POST /api/<ns>/<verb>`，method 同名（如 `workspace/create`） | `{type:"client-request", rpcId, method, payload:{args:{<field>: args}}}`，**字段名按端点不同**（`request` / `_request`） |
| ≤0.1.1 | `POST /api/<ns>.<verb>`（点号） | `payload = args` |

壳层统一走 `DshWebRPC.call(endpoint:payload:port:)`：先斜杠端点，**仅 404/405** 才钉死点号回退；0.1.2 的 `/api` 需要 launch-token 换来的 `dsh-auth-*` cookie（`DshWebRPC.authenticate`）。本设计**只新增端点常量**，不动这套机制。

### 4.2 `workspace/create`

```ts
// dsh-api-workspace-controller
workspaceCreateRequest = { path: string }                       // wire 参数名 "request"
workspaceCreateResult  = { workspace: { workspaceId, path, title, sessionIds, createdAt, updatedAt },
                           created: boolean }
```

- 语义：**"Create or resolve one Workspace over an existing directory"** —— **幂等**：目录已注册则直接返回既有工作区（`created:false`），未注册则注册（`created:true`）；
- 前置：**目录必须已存在**（壳层先 `mkdir -p` 再调用）；
- 门控：该 verb 是 `invocation: { kind: 'direct' }`，**没有 capability 要求**（只有 `directoryPicker/*` 才走 `requireCapability`，见 `lib/index.js` 的 `DirectoryPickerController`）——也就是说浏览器/壳层直接可调；
- 参数名证据：`typert.remote-client.js` 中该条目为 `parameters: [{ name: 'request', wire: 'request', … }]`，与 `session/create` 同形，故 `DshWebRPC.Endpoint("workspace/create", "workspace.create")` 用默认 `field: "request"`。

### 4.3 `session/create`

```ts
SessionCreateRequest = { workspaceId?, cwd?, sessionId?, agentPreset? }
SessionCreateValue   = { sessionId, agentPreset? }
```

- 传 `workspaceId`：新会话**归属该工作区**（在 dsh web 侧边栏分组在工作区下），壳层优先用它；
- 传 `cwd`：会话工作目录直接指定（老 dsh 或 `workspaceId` 被拒时的回退；结果会落在「Ungrouped」分组，功能可用）；
- 与既有 `WikiRPC.createSession(port:cwd:workspaceId:)` 的策略**完全一致**（先 workspaceId、被拒退 cwd）。本设计把等价逻辑收进共享的 `DshWorkspaceOps`，**但不去重构 WikiPanel 的私有实现**（避免动已上线面板；两处 15 行重复是有意为之，后续如需统一另开一次专门重构）。

### 4.4 工作区读取：没有 `workspace/list`

0.1.2 移除了 `workspace.list`（改为 `workspace/follow` 长连接流），壳层照旧走 `DshWorkspaceStore`：活 RPC 试探 → 不成立则读 `$DSH_HOME/storages/workspace.json`（`unit.name == "workspace"`、`unit.version == 2`，读不懂记诊断日志）。面板用它拿「已注册 / N 个会话 / workspaceId」，**不新增任何 dsh 私有布局依赖**（详见影响清单 C4、R4）。

### 4.5 「在 dsh web 中打开某会话」只能靠注入桥

dsh web 不暴露会话 store 到全局，也没有"打开会话"的 URL —— 现有 `sessionOpenerScript` 注入 `window.__dshOpenSession(sessionId)`：先按会话 id 查 `session/list` 拿标题，再在侧栏 DOM 里找 `[role="treeitem"]` 且 `className` 含 `sessionRow`、行文本等于标题的那一行并 `click()`（最多重试 8 次，每次先展开 `aria-expanded=false` 的组）。这是影响清单 **B 面 / R3** 的既有弱点，本设计**不加重**它，只做两件事：

1. 调用前先 `nudgeDSHWebCaches()`（合成 `offline` → `online` 让 web 客户端重连、重拉列表）——否则壳层刚创建的会话/工作区可能还不在侧栏里；
2. `openDSHSession` 增加**一次** 1.5s 重试；仍失败则记 `pendingOpenSessionId` 并重载页面——复用既有的 `reloadPageReauthenticating(reason:)`（⌘R 同款：走 launch token 重新认证 + 主框架 401 自愈），在 `webView(_:didFinish:)` 里再打开一次（只打开一次，用完清空）。

### 4.6 契约速查

| # | 依赖 | 值 / 形状 | 壳层位置 | 验证方式 |
|---|---|---|---|---|
| C10a | `workspace/create` | `{request:{path}}` → `{workspace:{workspaceId,…},created}`，幂等，路径须存在 | `DshWebRPC.swift` `DshWorkspaceOps.register` | 单测（假传输）+ 手工：新建后 dsh web 侧栏出现该工作区 |
| C10b | `session/create` | `{workspaceId\|cwd}` → `{sessionId}` | `DshWorkspaceOps.createSession` | 单测 + 手工：面板「新会话」后 web 切到新会话 |
| C10c | `session/list` | `items[].{sessionId,cwd,running,updatedAt,blank}` | `DshWorkspaceOps.newestSessionId` | 单测 + 手工：工作区已有会话时「在 dsh 中打开」复用最近一条 |
| C4/R4 | 工作区列表 | 0.1.2 无 `workspace/list` → `storages/workspace.json`（domain workspace v2） | `DshWorkspaceStore.items` | `tests/dsh-rpc/run.sh` + `app.log` 的 `[workspace-store]` 诊断 |
| B10/R3 | 侧栏行点击 | `__dshOpenSession(id)`：`session/list` 取标题 → 点 `[role="treeitem"].sessionRow` | `sessionOpenerScript` + `openDSHSession` | `DSH_UI_DEBUG=1` 的 `dsh injected bridges` + console `[dsh-opener]` |

---

## 5. 面板结构与交互

活动栏首位（`ActivityBarButton(symbol: "folder")`；用 macOS 13 一定存在的符号——`NSImage(systemSymbolName:)` 对未知符号返回 nil，图标会空白），右栏槽第 9 个面板，快捷键 **⌥⌘P**（由「文件面板」让出并**已生效**：PR #57 已合并，见 §13.E）。

```
项目面板（右栏槽第 9 个，活动栏首位，⌥⌘P）
├─ 头部（DynamicFillView + HeaderLabel）         [＋ 新建] [⟳] [⚙] [✕]
├─ 根目录行（次要色路径 + tooltip 全路径）   根目录：~/.dsh/oh-my-dsh/projects  [更改…]
├─ 内容（NSScrollView + FlippedStackView）  工作区卡片 × N
│    └─ 卡片：abc
│         ├─ 名称（可点 = 在 dsh 中打开）        徽标：已注册 · 3 个会话 / 未注册
│         ├─ 路径（次要色、中间截断、tooltip）
│         └─ 操作行：文件 终端 知识库 任务 通道 审查 │ ＋新会话 │ 在 Finder │ 复制路径
└─ 状态行（成功 5s 后自动清空；失败保留到下次操作）
```

### 5.1 头部

| 控件 | 行为 |
|---|---|
| 标题「项目」 | `HeaderLabel`（面板头部**固定**显示面板名，不显示工作区名——遵循既有面板约定） |
| `+` 新建工作区 | 取名 sheet（§5.4） |
| `⟳` 刷新 | 重读根 + 列举 + 注册表（后台） |
| `⚙` 设置 | 打开壳层设置窗口（`openSettingsWindow`） |
| `✕` 关闭 | `onRequestHide` → 收起右栏（沿用既有语义） |
| 根目录行 | 次要色文本显示**有效**根路径（tooltip = 全路径）；「更改…」弹 `NSOpenPanel`（`canChooseDirectories`、`canCreateDirectories`），选中即写 `projectsRoot` 并刷新 |

### 5.2 卡片（三行）

1. **第一行**：目录名（semibold 13pt）+ 右侧徽标。名字区域**可点 = 「在 dsh 中打开」**（tooltip 说明：复用该工作区最近一条会话，没有则新建）；徽标二选一：`已注册 · N 个会话` / `未注册`。
2. **第二行**：绝对路径（次要色、中间截断、tooltip 全路径）。
3. **第三行**：操作行，全部 `CustomIconButton` + tooltip（图标与活动栏同源，用户一眼能对上）：

| 按钮 | 符号 | 动作 |
|---|---|---|
| 文件 | `doc.on.doc` | 进入文件面板（树根 = 该工作区） |
| 终端 | `terminal` | 进入终端面板（cwd = 该工作区） |
| 知识库 | `book.closed` | 进入 Wiki 面板（根 = 该工作区） |
| 任务 | `checkmark.circle` | 进入任务面板（工作区 = 该工作区） |
| 通道 | `dot.radiowaves.left.and.right` | 进入通道面板（工作区 = 该工作区） |
| 审查 | `doc.text` | 进入审查面板（工作区 = 该工作区） |
| **新会话** | `plus` + 文本 | 在该工作区建一条 dsh web 会话并切过去 |
| 在 Finder 中显示 | `.reveal` | `NSWorkspace.activateFileViewerSelecting` |
| 复制路径 | `link` | 路径写剪贴板（tooltip 用 `files.copyPath`；用 `link` 而非 `doc.on.doc` 以免与「文件」入口撞符号） |

**强调色出现在两处**：卡片左侧 accent 细边（或描边）= 这是**当前工作区**（`ProjectDirectory.current` 归一后相等）；「新会话」按钮。其余配色一律取自 `PanelSurface`（面板底色）与 `PanelControl`（卡片/按钮两档），**不新增颜色令牌**（见 `docs/ui-color-scheme.md`）。

### 5.3 空态与状态行

- 根目录存在但无子目录：居中提示「还没有工作区…」+ 一个明显的「+ 新建工作区」按钮；
- 根目录不存在：提示该根路径 + 同上按钮（点新建时 `mkdir -p` 连带建根）；
- 状态行（面板底部）显示最近一次操作结果：`已创建工作区 abc` / `该工作区已存在` / `已创建目录，尚未注册到 dsh（服务未就绪）` / `创建失败：<原因>` / `无法新建会话：<原因>`。成功类消息 5s 后自动清空，失败保留到下次操作。**不使用模态弹窗**报错（面板可能在窄窗口里，模态会打断阅读）。

### 5.4 新建工作区 sheet

照 `FilePanel.promptForNewItem` 的写法（`NSAlert` + `NSTextField` 作 `accessoryView`，`beginSheetModal`，无窗口时只记日志）：

- 标题「新建工作区」；`informativeText` = **将要创建的绝对路径**（`<root>/<name>`，随输入实时更新可选）；
- 输入框 placeholder「工作区名（作为目录名）」；按钮「创建 / 取消」，回车提交；
- 校验失败在信息行给出具体原因（空 / 含 `/` 或 `:` / 以 `.` 开头 / 过长），**不创建任何东西**。

---

## 6. 流程时序

### 6.1 新建工作区

```
面板(主线程)            ProjectsCore(后台)              dsh(HTTP)
  输入 abc
  validateName ─────────► ok("abc")
  createWorkspace:
     ├─ mkdir -p <root>/abc ─────► 磁盘
     ├─ workspace/create {path} ─► /api/workspace/create   (幂等)
     │                              ◄─ {workspace:{workspaceId},created}
     └─ 主线程：重列 + 状态行「已创建工作区 abc」/「已存在」
```

- `mkdir` 成功但注册失败（服务未起/老 dsh）→ 目录**保留**，状态行提示「尚未注册」，卡片徽标显示「未注册」；下次「新会话 / 在 dsh 中打开」会再注册一次（幂等）。
- 创建**不**自动切换当前工作区（避免用户没点任何入口，右栏内容就跳走）——用户点入口或新会话时才切（§6.2）。

### 6.2 快捷入口（文件/终端/知识库/任务/通道/审查）

```
点击 [终端] on abc
   └─ 主线程：adoptProjectDirectory("…/abc")     // 唯一重根原语，见 §7
              setRightPanel(.terminal)
                 └─ 终端面板 setWorkspaceDirectory → 该工作区的页签恢复/新建（cwd = …/abc）
```

任务 / 通道 / 审查三个面板的 `workspacePath` 闭包读 `activeWorkspacePath()`（其内部首选 `ProjectDirectory.current`），因此重根后它们天然以新工作区取数并重列；知识库走 `reloadRoot()`，文件面板走 `setProjectDirectory`（含按工作区记忆/交还页签的既有语义）。

### 6.3 新会话 / 在 dsh 中打开

```
[新会话] on abc（主线程）
  └─ 后台线程：
        wid = DshWorkspaceOps.register(port, "…/abc")          // 幂等；失败 → nil
        sid = DshWorkspaceOps.createSession(port, cwd:"…/abc", workspaceId: wid)
              // 先 workspaceId；被拒则只用 cwd（落 Ungrouped）
     成功 → 主线程：
        adoptProjectDirectory("…/abc")        // 面板先跟上
        nudgeDSHWebCaches()                   // 让 web 客户端重新拉会话/工作区列表
        0.5s 后 openDSHSession(sid, retry: 1) // 点侧栏行切过去
        失败 → pendingOpenSessionId = sid; reloadPage()
               → webView(_:didFinish:) 里再打开一次（只打开一次）
     失败 → 状态行「无法新建会话：<原因>」（不弹模态）

[在 dsh 中打开] on abc
  └─ 后台：register → newestSessionId(port, inPath: "…/abc")
             // session/list 里 canonical(cwd) 相等者，running 优先，其次 updatedAt 最大
     有 → 主线程 adoptProjectDirectory + openDSHSession(该 id)
     无 → 走上面的「新会话」
```

---

## 7. 状态与真相（重根原语）

**壳层的「当前工作区」始终只有 `ProjectDirectory.current` 一个真相**（既有的 `dshSession` 处理器在 web 切会话时写它）。本面板**不引入**第二个「面板内选中项」状态：

- 卡片高亮 = `canonical(ProjectDirectory.current) == canonical(ws.path)`，只读计算，刷新时重算；
- 六个入口与「新会话」都通过同一个重根原语写它，因此**面板高亮、终端页签归属、任务/通道/审查的工作区**不可能互相打架；
- 用户在 dsh web 里切到别的工作区 → 既有 `dshSession` 处理器照旧重根，面板下次刷新时高亮随之移动。

**重构点（行为不变）**：把 `dshSession` 处理器里那段重根代码抽成 `AppDelegate.adoptProjectDirectory(_:)`：

```swift
@discardableResult
private func adoptProjectDirectory(_ path: String) -> Bool {
    let std = (path as NSString).standardizingPath
    guard FileManager.default.fileExists(atPath: std) else { return false }
    let changed = ProjectDirectory.current != std
    ProjectDirectory.set(std)                 // 先写真相，后续消费者读到的一定是新值
    guard changed else { return true }        // 同一工作区不重复重根（避免闪动/丢页签）
    previewPanel?.setProjectDirectory(std)
    terminalPanel?.setWorkspaceDirectory(std)
    wikiPanel?.reloadRoot()
    tasksPanel?.workspaceChanged()
    channelPanel?.workspaceChanged()
    reviewPanel?.workspaceChanged()
    return true
}
```

原处理器保持既有语义：**路径变了才重根**，随后仍**无条件**调用三个 `workspaceChanged()` 与 `setActiveSession(_:)`（那是「同一工作区里换会话也要刷新列表/展开行」的既有行为）。

> **一处有意的小行为修正**：抽出的原语带 `fileExists` 守卫，而现行 `dshSession` 处理器**不检查目录是否存在**——即会话的 cwd 已被删除时，旧代码仍会 `ProjectDirectory.set()` 并把各面板重根到一个不存在的目录。新原语在这种情况直接返回 `false`（不重根、记一行日志），避免面板被指向已消失的目录。这是**有意**的差异，不是重构走样；实现时需在 PR 描述里点明。

---

## 8. 失败模式与边界

| 场景 | 行为 | 观测点 |
|---|---|---|
| dsh web 还没起来 / 端口未就绪 | 目录照建；状态行「已创建目录，尚未注册到 dsh」；「新会话」报错只进状态行，不崩、不弹模态 | `app.log` 的 `projects:` 行 |
| dsh ≤0.1.1 或旧端点不认 `workspace/create` | 记「未注册」；建会话退回只传 `cwd`（进 Ungrouped，功能可用） | 同上 + `[dsh-opener]` |
| 侧栏还没有新工作区/新会话的行 | nudge → 0.5s 点行 → 失败重试一次 → 仍失败则重载页面并在 `didFinish` 打开一次 | `openDSHSession …: row-not-found` 日志 |
| `$DSH_HOME/storages/workspace.json` 读不懂（上游改布局/升版本） | 注册状态与会话数退化为「未注册 / 0」，功能不受影响（只影响徽标）；诊断进日志 | `[workspace-store] …`（既有护栏，R4） |
| 根目录不存在 | 空态 + 根路径提示；不自动写盘；首次新建时 `mkdir -p` 连带建根 | — |
| 根目录在慢卷/网络卷 | 列举与注册表读取全在后台队列，主线程只渲染 | — |
| 名字与已有**目录**冲突 | 非错误：提示「已存在」，选中该卡片，仍做幂等注册 | 状态行 |
| 名字与已有**文件**冲突 | `createDirectory` 报 EEXIST → `创建失败：…` | 状态行 |
| 名字含 `/`、`:`、`.` 开头、过长、空 | 创建前拦截 + 提示规则；不创建任何东西 | sheet 内联提示 |
| 根目录里的符号链接指向目录 | 视为工作区；`canonical` 归一后与注册表匹配（因此「已注册」判定仍准确） | 面板徽标 |
| **会话快照回退**（main 已有特性）之后 | 工作区注册表就在快照数据集内（`SNAPSHOT_INCLUDES = ['sessions','storages']`，见 `core/lib/snapshot.js`），回退会把 `storages/workspace.json` 一起换回去——面板**无需任何特殊处理**：回退本身会退出 App，重开后按新注册表重读即可；表现为徽标在「已注册 ↔ 未注册」间变化、会话数按被隔离/恢复的会话重算 | `[workspace-store]` 诊断 + 面板徽标 |
| 终端/知识库重根时面板不可见 | 沿用既有语义：终端只为**屏上**的面板起 PTY，用户切过去时再起；wiki 只在可见时扫描 | `terminal workspace:` 日志 |
| 用户在设置里填相对路径 | 不保存 + 内联错误提示；面板侧若读到非法配置则回退默认值并记日志 | `app.log` |

---

## 9. 设置窗口「项目」区块

`SettingsWindowController` 新增一节（排在 Registry 之前），与面板头部「更改…」共享同一份配置：

| 元素 | 行为 |
|---|---|
| 区块标题 | `projects.settingsSection`（「项目」/「Projects」） |
| 路径字段 | 可编辑 `NSTextField`，显示当前 `projectsRoot`（键缺失则显示**默认路径**）；`~` 会展开 |
| 「选择…」 | `NSOpenPanel`（`canChooseDirectories` + `canCreateDirectories`）→ 回填字段（**不**立即保存） |
| 「保存」 | 绝对路径 → `ShellConfig.set(path, forKey: "projectsRoot")` + 通知面板 `workRootChanged()`；非绝对路径/空 → 内联错误提示、不写 |
| 「恢复默认」 | `ShellConfig.removeObject(forKey: "projectsRoot")` + 清空字段 + 通知面板 |
| 提示行 | `projects.settingsRootHint`：显示默认路径（`<DSH_HOME>/oh-my-dsh/projects`），说明「留空即默认」 |

保存**不**要求目录已存在（面板首次新建时会连带创建）；`show()` 每次同步字段值（既有区块的做法）。

---

## 10. L10n 文案表

新增（`L10n.table`，中英成对；`tests/l10n/run.sh` 会 lint 未定义键与重复键）：

| 键 | 中文 | English |
|---|---|---|
| `bar.projects` | 项目 | Projects |
| `menu.toggleProjects` | 显示/隐藏 项目面板 | Toggle Projects Panel |
| `projects.title` | 项目 | Projects |
| `projects.rootLabel` | 根目录：%@ | Root: %@ |
| `projects.changeRoot` | 更改… | Change… |
| `projects.changeRootTooltip` | 选择项目存放的根目录 | Choose the projects root folder |
| `projects.newWorkspace` | 新建工作区 | New Workspace |
| `projects.newWorkspaceLocation` | 将创建于 %@ | Will be created at %@ |
| `projects.namePlaceholder` | 工作区名（作为目录名） | Workspace name (used as the folder name) |
| `projects.invalidName` | 工作区名不能为空，不能含 “/” 或 “:”，不能以 “.” 开头，且不超过 64 个字符 | Invalid name: must not be empty, contain “/” or “:”, start with “.”, or exceed 64 characters |
| `projects.nameExists` | 该工作区已存在 | That workspace already exists |
| `projects.createFailed` | 创建失败：%@ | Could not create it: %@ |
| `projects.created` | 已创建工作区 %@ | Created workspace %@ |
| `projects.registerPending` | 已创建目录，但尚未注册到 dsh（服务未就绪，稍后会自动重试） | Folder created; not registered with dsh yet (server not ready — it will retry) |
| `projects.empty` | 还没有工作区。点「+」新建一个。 | No workspaces yet — create one with “+”. |
| `projects.rootMissing` | 根目录不存在：%@ | Root folder does not exist: %@ |
| `projects.sessions` | %d 个会话 | %d sessions |
| `projects.registered` | 已注册 | Registered |
| `projects.unregistered` | 未注册 | Not registered |
| `projects.openInDsh` | 在 dsh 中打开 | Open in dsh |
| `projects.newSession` | 新会话 | New Session |
| `projects.newSessionFailed` | 无法新建会话：%@ | Could not create a session: %@ |
| `projects.enterPanel` | 在「%@」面板中打开该工作区 | Open this workspace in the %@ panel |
| `projects.settingsSection` | 项目 | Projects |
| `projects.settingsRootHint` | 默认：%@（留空即用默认） | Default: %@ (leave empty to use it) |
| `projects.settingsPick` | 选择… | Choose… |
| `projects.settingsReset` | 恢复默认 | Reset to Default |
| `projects.settingsInvalidPath` | 请输入绝对路径（可用 “~”） | Enter an absolute path (a leading “~” is allowed) |

复用（语义完全一致，不复制新键）：`btn.cancel`、`files.create`、`files.revealInFinder`、`files.copyPath`、`snapshot.action.refresh`（刷新）、`preview.closePanel`（关闭）。

**变更（既有键）**：`menu.togglePreview` → **`menu.toggleFiles`**——值由「显示/隐藏 预览面板」/「Toggle Preview Panel」改为「显示/隐藏 文件面板」/「Toggle Files Panel」，快捷键由 **⌥⌘P** 改为 **⌥⌘F**。**该变更已落地**（PR #57，main `0253b35`）：实现阶段只需**新增** `menu.toggleProjects`（⌥⌘P），不要重复改动 `menu.toggleFiles`。理由与完整清单见 §13.E。

---

## 11. 测试计划

### 11.1 模型层（`tests/projects-panel/run.sh`，纯 Foundation）

`ProjectsCore.swift` + `projects-tests.swift`（作 `main.swift`）：

- 默认根：`defaultRoot("/x/.dsh")` = `/x/.dsh/oh-my-dsh/projects`；
- `resolvedRoot`：配置为空/空白 → 默认；`~/` → 展开；相对路径 → 回默认；`DSH_PROJECTS_TEST_ROOT` 覆盖优先；
- `validateName`：`abc` ✅；空串 / 纯空白 → empty；`a/b`、`a:b` → separator；`.`/`..` → dot；`.x` → hidden；65 字符 → tooLong；含 `\u0001` → illegalCharacter；两端空白被 trim；
- `workspacePath(root:name:)`：拼接正确、不产生双斜杠；
- `listDirectories`（临时 fixture）：普通子目录入选、普通文件跳过、隐藏目录跳过、指向目录的符号链接入选、指向文件的符号链接跳过、排序稳定、根不存在 → `[]`；
- `merge`：注册项按 `canonical` 归一对上（含符号链接路径与尾斜杠两种写法）→ `registered=true`/`workspaceId`/`sessionCount`；匹配不到 → `registered=false`。

### 11.2 控制器无头冒烟（同一 `run.sh` 第二段，AppKit 无窗口）

`stubs.swift`（照 `tests/review-panel/controller-stubs.swift` 配方：`L10n`/`AppLog`/`DynamicFillView`/`HeaderLabel`/`CustomIconButton`/`FlippedStackView`）+ **真实** `PanelSurface.swift`/`ProjectsCore.swift`/`ProjectsPanel.swift`/`ShellConfig.swift`/`DshWebRPC.swift` + `controller-tests.swift`（作 `main.swift`，`NSApplication.shared` + 临时 `DSH_HOME`）。通过 `DshWebRPC.perform` 注入假传输、记录请求：

- `createWorkspace(named: "abc")` → 目录真的出现；请求体为 `method == "workspace/create"` 且 `payload.args.request.path` 等于目标路径；
- `createWorkspace(named: "a/b")` → 不建目录、不请求；
- 建两个工作区后列表渲染出两张卡片，徽标文案来自 fixture 注册表（`已注册 · 2 个会话` / `未注册`）；
- 点六个入口 → 回调参数为 `(path, .terminal/.files/…)`；点「新会话」→ `onCreateSession(path)`；
- `DshWorkspaceOps.createSession`：第一次请求带 `workspaceId`，服务端拒绝（fake 返回 ok:false）后第二次只带 `cwd`；
- 配置根目录切换（写 `ShellConfig` 的 `projectsRoot`）→ `reload()` 后列表来自新根。

### 11.3 `tests/dsh-rpc/` 扩充

`workspaceCreate` 端点的 modern/legacy 两代回退（404/405 才降级）、`register` 解析 `{workspace:{workspaceId}}`、`newestSessionId` 的选取规则（running 优先 → updatedAt 最大；`cwd` 归一后不匹配的会话一律排除）。

### 11.4 QA 钩子与 CI

- `DSH_PROJECTS_TEST=1`：启动后直接打开项目面板（仿 `DSH_SKILLS_TEST`）；
- `DSH_PROJECTS_TEST_ROOT=<dir>`：覆盖根目录（仅 QA）；
- `DSH_UI_DEBUG=1`：面板渲染后落 `panel-projects-debug.png` + 视图层级 dump（沿用 `dumpPanelDebugInfo`）；
- `DSH_PANEL_TEST="projects,files,terminal,…"`：**main 现有的全量扫描钩子**（随 v1.16.2 sync 进入 main；`buildSplitView` 末尾 → `AppDelegate.panelNamed(_:)` → `runPanelSweep`）。接线三件事：① `panelNamed` 增加 `case "projects", "项目"`；② 同步该钩子注释里的面板清单（八 → 九）；③ `setRightPanel` 的 `uiDebug` 分支带 `label: "projects"` 落截图；
- 接线：`scripts/local-ci.sh` 的 `stage_swift` 与 `.github/workflows/ci.yml` 的 swift job 各加 `tests/projects-panel/run.sh`；`tests/l10n/run.sh` 自动覆盖新键。

---

## 12. 手工验收清单

1. 全新环境启动 → **活动栏最上面第一个图标是「项目」**（其后：文件、终端、浏览器、知识库、任务、通道、审查、技能；九个图标互斥切换，与「视图」菜单首项一致）→ 面板显示默认根 `<DSH_HOME>/oh-my-dsh/projects`，空态提示，且**此时磁盘上还没有该目录**。
2. 点「+」输入 `abc` → 目录被创建、卡片出现、徽标「已注册 · 0 个会话」；`app.log` 有注册成功日志；dsh web 重连后侧边栏出现该工作区。
3. 输入空串、`a/b`、`a:b`、`.x`、65 字符 → 提示规则且**不**建目录；输入已存在的 `abc` → 提示已存在并选中该卡片。
4. 卡片「新会话」→ dsh web 切到新会话（面板项目目录也随之变为该工作区）；先把 dsh web 断网再恢复以模拟侧栏未刷新 → 仍能落到目标会话（重试/重载兜底），日志有 `openDSHSession` 结果。
5. 依次点 文件 / 终端 / 知识库 / 任务 / 通道 / 审查 → 右栏切到对应面板，且内容以 `…/abc` 为根（文件树根、终端 cwd、wiki 根、任务/通道/审查的工作区）；知识库显示空态而不是别的仓库内容。
6. 在 dsh web 手动切到另一个工作区的会话 → 面板跟随重根（既有行为不回归），项目面板高亮切到对应卡片；任务/通道/审查刷新。
7. 设置窗口「项目」区块：改根目录并保存 → 面板立即刷新；相对路径被拒；「恢复默认」后 `shell/config.json` 里 `projectsRoot` 键消失；`⌥⌘P` 与菜单项 checkmark 同步（且「文件面板」已是 ⌥⌘F）。
8. QA：`DSH_PROJECTS_TEST=1 DSH_PROJECTS_TEST_ROOT=/tmp/ws DSH_UI_DEBUG=1` 启动 → 面板直接打开且落在 `/tmp/ws`。
9. `tests/projects-panel/run.sh`、`tests/dsh-rpc/run.sh`、`tests/l10n/run.sh` 全绿；`scripts/local-ci.sh swift`（含 swiftc 全量编译检查）通过。
10. **与快照/回退共存**：在 dsh 里新建一个工作区（面板注册）→ 用「会话快照…」回退到该工作区出现之前的快照 → 重开后项目面板仍正常（列目录、徽标按恢复后的注册表显示，不崩、不报错），且能再次创建/注册该工作区（`workspace/create` 幂等）。

---

## 13. 决策记录与后续可选项

**已定（本设计不再改动）**

| # | 决策 | 理由 |
|---|---|---|
| D1 | 只列 projects 根目录下的直属子目录 | 范围清晰、行为可预期；dsh web 侧边栏继续负责「全量工作区」 |
| D2 | 新建 = 只建目录 + 注册 | 最小、可预期；不做用户没要求的脚手架 |
| D3 | 不提供删除/移除/重命名 | 面板不引入破坏性操作；清理交给 Finder 与 dsh web |
| D4 | 活动栏第一位 + 视图菜单首项 | 「项目是入口」的心智模型；与其余八个面板顺序一致 |
| D5 | 不引入第二个「当前工作区」状态 | 避免面板选中项与 `ProjectDirectory` 两套状态互相覆盖 |
| D6 | 「预览面板」正名为「**文件面板**」、快捷键改 **⌥⌘F**，拆为独立改动**并已落地** | 同一个面板在活动栏/头部/README 里早已叫「文件」，只有视图菜单还叫「预览」；该改动不依赖本特性，已走 `feature/menu-files-panel`（PR #57）**合并进 main**（`0253b35`），「项目」面板只依赖它让出的 ⌥⌘P 空档（详见 §13.E） |

**后续可选项（明确不在本次范围）**

- 工作区重命名（目录改名 + 重新注册，需处理旧注册残留）；
- 创建工作区时的可勾选脚手架（`git init` / `AGENTS.md` / `.dsh/wiki`）；
- 列出并管理根目录之外的 dsh 工作区（跨根目录视图）；
- 与 Composer @ 引用（`docs/file-panel-composer-reference.md`）联动：把整个工作区作为会话引用；
- 工作区级「最近会话」列表（当前只提供「打开最近一条」，不做内嵌会话列表）。

### E. 配套的既有改动（**已落地**）

视图菜单里的「显示/隐藏 预览面板」改为「**显示/隐藏 文件面板**」，快捷键由 **⌥⌘P** 改为 **⌥⌘F**，把 **⌥⌘P** 让给「项目」。

> **状态**：该改动不依赖本特性（它只是让出快捷键），已从本分支拆出、走 `feature/menu-files-panel` 单独评审，并**已合并进 main**（PR #57 → `0253b35` `Merge pull request #57`）。本分支也已 rebase 到该 main 之上。**实现阶段对 §E 的内容只剩一件事**：新增「项目」面板自己的 `menu.toggleProjects`（⌥⌘P），其余全部已完成、**不要重复改动**。

- **理由**：同一个面板在活动栏（`bar.preview` = 文件 / Files）、面板头部、README 里**早就叫「文件」**，只有视图菜单这一处还叫「预览」，属于历史遗留（面板实现已从 `PreviewPanel.swift` 换成 `FilePanel.swift`）；改名后一个面板只有一个名字。
- **L10n 键同步改名** `menu.togglePreview` → `menu.toggleFiles`（值也改），不留名不符实的死键（`tests/l10n/run.sh` 对未引用键只 WARN，所以必须主动改）。
- **选择器 `togglePreviewPanel(_:)` 保持不改**：纯内部标识，改名收益小于改动面。
- **位置清单（已完成，记录备查）**：

  | 位置 | 现状 | 改为 |
  |---|---|---|
  | `platforms/macos/src/main.swift`（L10n 表） | `menu.togglePreview` = 显示/隐藏 预览面板 | `menu.toggleFiles` = 显示/隐藏 文件面板 |
  | `main.swift` `buildMenu()` 视图菜单项 | `keyEquivalent: "p"` + ⌥⌘ 掩码 | `keyEquivalent: "f"` |
  | `main.swift` `SettingsWindowController.shortcutRows` | `("menu.togglePreview", "⌥⌘P")` | `("menu.toggleFiles", "⌥⌘F")` ✅ |
  | `README.md` 面板章节标题 | 文件面板（`⌥⌘P` / 活动栏「文件」图标） | 文件面板（`⌥⌘F` / 活动栏「文件」图标） |
  | `.dsh/wiki/tasks.md` 验证点 | ⌥⌘P / ⌥⌘T / … | ⌥⌘F / ⌥⌘T / … ✅（「项目 ⌥⌘P + 九面板」随面板落地，见 §16） |
  | `.dsh/wiki/modules/main.md` 视图菜单清单 | ⌥⌘P … 八面板切换 | ⌥⌘F … ✅（同上，九面板随面板落地） |
  | `.dsh/wiki/modules/preview-panel.md` 头部入口 | 打开项目目录（`⌥⌘P` 同入口） | （`⌥⌘F` 同入口） |
  | `CHANGELOG.md` `[Unreleased]` | — | 新增 `### Changed` 一条（菜单文案正名 + 快捷键让位） |
- **本轮唯一待做**：`shortcutRows` 与「视图」菜单各增一行 `menu.toggleProjects` / ⌥⌘P（即 §5、§11.4 的首项接线），不再触碰 `menu.toggleFiles`。
- **快捷键占用（2026-09-24 在 main `0253b35` 上核对）**：`keyEquivalent` 集合 = `,` `Z` `a b c f h j l q r s t u v w x z`（`p` 已随 PR #57 释放，`f` 现由文件面板占用）；⌥⌘ 面板组现为 f/t/w/b/h/r/s 七个，**⌥⌘P 空档**，供「项目」使用，无冲突。

---

## 14. 升级耦合面登记（与影响清单的对应）

本设计新增/强化的耦合面，需在 `docs/dsh-version-impact.md` 落地时同步登记（本文件只登记对应关系，不改动该文档）：

| 面 | 条目 | 内容 | 失效表现 | 防御 |
|---|---|---|---|---|
| C（一元 RPC） | **C10a** | `workspace/create {request:{path}}`（幂等、路径须存在、参数名 `request`） | 新建的工作区不出现在 dsh web 侧边栏；会话落到 Ungrouped | 失败只降级为「未注册」+ 状态行提示，不阻塞目录创建；下次操作幂等重试 |
| C | **C10b** | `session/create {workspaceId\|cwd}` | 面板「新会话」没有反应 | 先 workspaceId 再退 cwd；失败进状态行 |
| C | **C10c** | `session/list` 的 `cwd`/`running`/`updatedAt` 字段 | 「在 dsh 中打开」挑不到会话 → 退化为新建 | 字段缺失时按「无会话」处理 |
| B（注入/ DOM） | **B10** | `__dshOpenSession` 依赖侧栏 `[role="treeitem"].sessionRow` 与标题文本（既有 R3） | 新会话建了但 web 不切过去 | nudge → 重试一次 → 重载页面 + `didFinish` 补打开；日志 `[dsh-opener]` |
| D（磁盘布局） | 沿用 **C4/R4** | 注册状态读取仍走 `storages/workspace.json`（domain workspace v2） | 徽标退化为「未注册」，功能不受影响 | 既有版本/域名护栏 + 诊断日志 |

升级 SOP 追加两条核对项（落地时写入影响清单 §5）：

1. 新建一个工作区 → dsh web 侧边栏是否出现该工作区；再点「新会话」→ 是否切到该会话（覆盖 C10a/C10b/B10）；
2. `workspace/create` 的参数名是否仍为 `request`（typert 贡献里 `wire` 字段），`session/create` 是否仍接受 `workspaceId`（覆盖 C10a/C10b）。

**编号已核对**（2026-09-24，main `0253b35`）：影响清单 A 面到 **A6**、B 面到 **B9**、C 面到 **C9**、D 面到 **D9**（含 D2b/c/d）、R 清单到 **R8** —— 故本次取 `C10a/b/c` 与 `B10`，不与既有条目撞号。

---

## 15. 实现顺序（提交切分）

全部在 `feature/projects-panel`（已 rebase 到 main，当前只含本设计文档）：

| # | 提交 | 内容 |
|---|---|---|
| 1 | `feat(projects): 纯模型 ProjectsCore + 无头单测` | 根目录解析 / 命名校验 / 目录列举 / 注册匹配（§3） |
| 2 | `feat(dsh): workspace/create 与 DshWorkspaceOps + dsh-rpc 用例` | §4 的 C10a/b/c |
| 3 | `feat(projects): 项目面板 + L10n + main.swift 接线` | §5、§10：`RightPanel` 加 `.projects`、活动栏首位、视图菜单首项 ⌥⌘P、`rightPanelKind` 持久化、`adoptProjectDirectory` 抽取（§7）、`didFinish` 待打开 |
| 4 | `feat(projects): 设置窗口「项目」区块 + QA 钩子` | §9、§11.4（含 `DSH_PANEL_TEST` 三处接线） |
| 5 | `test(projects): 控制器无头测试 + CI/local-ci 接线` | §11.2、§11.4 末条 |
| 6 | `docs(projects): 影响清单登记 + README/CONTRIBUTING/CHANGELOG + 知识库` | §14、§16 |

每步提交前 `git status` 确认只含本次改动；分支推送后开 PR（main 只接受 PR）。

---

## 16. 文档与发布物同步清单（实现阶段）

| 位置 | 需要改什么 |
|---|---|
| `docs/dsh-version-impact.md` | §3C 增 **C10a/C10b/C10c**、§3B 增 **B10**；§5 SOP 增两条核对项（内容见 §14）；与既有 C4/R4、R3 互引 |
| `README.md` | ① 「「视图」菜单提供**八**面板的显示/隐藏快捷键」→ **九**；② 面板章节列表新增「### 项目面板（`⌥⌘P` / 活动栏首位「项目」图标）」；③ 测试清单补 `tests/projects-panel/run.sh`（README 按 AGENTS.md **在当前分支直接改**，不另开 PR） |
| `CONTRIBUTING.md` | 测试清单补一行 `tests/projects-panel/run.sh` |
| `CHANGELOG.md` | `[Unreleased]` 的 `### Added` 增一条（项目面板 + 工作区快捷入口）；发布时按 `scripts/changelog.sh` 复核重排 |
| `.dsh/wiki/index.md` | 新增模块条目 `modules/projects-panel.md` |
| `.dsh/wiki/modules/projects-panel.md` | **新建**：定位 / 根目录与配置 / 卡片操作 / 三条流程 / 与 `ProjectDirectory` 的关系 / 失败模式 / QA 钩子 |
| `.dsh/wiki/modules/main.md` | 右栏插槽补第 9 个面板、活动栏顺序（项目在首位）、视图菜单 ⌥⌘P、`RightPanel` 枚举与 `rightPanelKind` 映射 |
| `.dsh/wiki/tasks.md` | 新增「管理项目 / 工作区」操作手册；测试清单补 `tests/projects-panel/run.sh`；QA 钩子表补 `DSH_PROJECTS_TEST[_ROOT]`；「加一个新右栏面板」清单若列 QA 钩子，同步 `DSH_PANEL_TEST` 的第九项 |
| 本文件 | 实现完成后把状态行由「设计定稿，待实现」改为「已实现（PR #NN）」并补实测记录 |

