# 使用问题记录（UX 反馈）

> 用途：记录日常使用中发现的体验问题与改进点，逐条跟踪到实现与验收。
> 记录日期：2026-09-21 · 版本基线：当前 `main` 后的开发分支
> 状态图例：🔲 待处理 · 🔧 进行中 · ✅ 已完成 · 💬 待讨论

## 汇总

| # | 面板 | 问题 | 类型 | 优先级 | 状态 |
|---|---|---|---|---|---|
| 1 | Files | 目录树缺少「新建文件夹 / 新建文件」入口 | 功能缺失 | 中 | ✅ |
| 2 | Files | 右上角「在面板中打开当前项目目录」应支持用外部应用打开 | 交互改进 | 中 | ✅ |
| 3 | Terminal | 滚轮滚动方向与其他面板相反 | Bug | 高 | ✅ |
| 4 | Terminal | 双击不能选词；拖选后需再按 ⌘C 才能复制 | 交互改进 | 中 | ✅ |
| 5 | Terminal | 终端页签未按 workspace 隔离/记忆 | 交互改进 | 低 | ✅ |
| 6 | Shell | 长时间运行后手动刷新 WebView → dsh web 页面打不开（疑似 key 失效） | Bug | 高 | 🔧 |
| 7 | Files | 大文件（3000+ 行）在磁盘变更后重新加载时卡住应用 | Bug | 高 | ✅ |
| 8 | Files | 图片预览按原始尺寸显示，不能自适应也不能缩放 | 交互改进 | 中 | ✅ |

> 实现分支 `feature/ux-feedback-fixes`（#1–#6 均已落地；#6 的自愈路径另有真实环境回归待做，见该条目「验收」）。

---

## 1. Files 面板目录树：新建文件夹 / 新建文件

**现象**：目录树只能浏览，无法就地新建文件或文件夹，必须切到 Finder 或外部编辑器。

**期望**：
- 树节点右键菜单（以及空白区右键）提供「新建文件」「新建文件夹」；
- 新建项插入在被点节点内部（点文件则插入其同级目录），选中新节点并进入重命名编辑态；
- 同级重名给出提示或自动加序号；创建失败（无权限）给出可见反馈。

**相关代码**：
- `platforms/macos/src/FilePanel.swift` —— `treeOutline`（NSOutlineView，L67）、`TreeNode` / `loadChildren`、`setTreeRoot`（L592）；
- 目前该文件内没有任何 `NSMenu`/`menu(for:)` 实现（已 grep 确认），右键菜单需要从零加。

**后续补充（QA 反馈）**：目录树右键菜单新增 **重命名** 与 **删除**。

- 重命名：输入框预填原名并整段选中，同目录内改名；重名/非法名/失败都有可见反馈；**已打开的页签会跟着改名重新指向**（重命名文件夹时，其下所有已打开文件同样跟随），未保存的编辑继续有效、保存到新路径；
- 删除：确认后**移到废纸篓**（不做不可恢复的 unlink）；被删条目下的页签自动关闭；若系统不可用（如回收站不可写）则拒绝删除并保留文件与页签，不会静默丢数据；
- 菜单项校验：项目根目录本身不可重命名/删除（`NSMenuDelegate.menuNeedsUpdate`）。

**菜单顺序与条件（QA 反馈）**：菜单改为动态构建，分三组：**新建文件夹 → 新建文件 ｜ 重命名 → 删除 ｜ 在 Finder 中显示**（两组分隔线）；右键点在**文件**上时不显示「新建文件夹」（菜单是针对该文件的），点在**空白处**时只显示新建两项，点**项目根目录**时重命名/删除置灰。判定逻辑抽到纯模型 `FilePanelTreeMenu.swift`（`TreeMenuModel.entries(hasRoot:hasRow:isRoot:isFile:)`），由 `tests/file-panel/tree-menu-tests.swift` 覆盖。

**待定**：拖拽移动仍未做。

**实现**（`feature/ux-feedback-fixes`）：`FilePanel.swift` 目录树右键菜单（`treeOutline.menu`，`clickedRow` 定位目标目录）+ `promptForNewItem(isDir:)` 名称输入框 + `createItem(named:isDir:in:)`（重名/非法名/失败均给出可见反馈，成功后展开并选中新节点，文件自动在标签页打开）；文案键 `files.newFile` / `files.newFolder` / `files.newItemLocation` / `files.create` / `files.invalidName` / `files.alreadyExists` / `files.createFailed` / `files.revealInTree`。

---

## 2. Files 面板右上角按钮：可选外部应用打开项目目录

**现象**：右上角按钮是固定行为「在面板中打开当前项目目录」，想用外部工具打开项目时只能另开 Finder / IDE。

**期望**：
- 点击展开下拉菜单，列出可选外部应用：Finder、VS Code / Cursor / Windsurf 等编辑器、JetBrains 系列、iTerm2 / Terminal.app 等终端；
- 未安装的应用不出现或置灰；记住上次选择作为默认动作（下次单击直接用它）。

**相关代码**：
- `platforms/macos/src/FilePanel.swift` —— `projectButton`（L165-170）、`openProjectDirectory`（L521）、`revealInFinder`（L425）；
- `platforms/macos/src/PreviewPanel.swift` —— 同名按钮（L549-554、L839），需一并考虑（面板基件约定）；
- 文案：`platforms/macos/src/main.swift` 的 `L10n.table`，已有 `preview.openProject` / `preview.openProjectHint`（L165-166），新增 key 必须中英成对。

**实现思路**：按已知 bundle id 用 `NSWorkspace.urlForApplication(withBundleIdentifier:)` 探测安装情况；`NSWorkspace.open(_:withApplicationAt:configuration:)` 打开目录；选择持久化到 `ShellConfig`（如 `openProjectWithApp`）。

**实现**（`feature/ux-feedback-fixes`）：新增纯模型 `OpenWithApps.swift`（`OpenWithCatalog`：面板 / Finder / 13 个编辑器与 IDE / 8 个终端，按 bundle id 探测是否安装）+ `FilePanel.openProjectWithRememberedTarget()`、`showOpenWithMenu()`（含「选择其它应用…」文件选择器，按 bundle id 或路径记忆）。

**UI 返工（QA 反馈）**：原来头部是纯图标按钮，功能要靠 tooltip 才看得懂，菜单还弹在按钮上方（挡住头部）。现在：

- 新增共享控件 **`PanelMenuButton`**（`PreviewPanel.swift`）：Core Graphics 自绘的「图标 + 文字 + ▾」菜单按钮，带 hover 高亮、指针光标、菜单打开期间保持高亮；窄面板下自动退化为「图标 + ▾」chip，不会把文字压烂；
- 头部两个按钮改为 **「打开项目 ▾」** 与 **「当前文件 ▾」**（后者合并了原来的「默认应用打开」+「在 Finder 中显示」，菜单里另有「复制路径」）；
- **点击整颗按钮就是打开菜单**（不再做「主区=记住的应用、chevron=菜单」的分裂按钮——那会让用户在选过一次之后找不到「再选一次」的入口）；上次选择在菜单里打勾，**⌥点击**按钮才是「直接用上次的方式 / 默认应用打开」的快捷操作；
- 菜单统一从按钮**下方**弹出（`popBelow(_:_:)`），不再压在头部标题上。

**第二轮 UI 返工（QA 反馈）**：

- 第二个按钮改名为 **「打开文件 / Open File」**（原来叫「当前文件」）；
- 它**只在面板里选中了文件时可用**：文件夹标签页或什么都没打开时置灰（`updateHeader(for:)` 用 `isDirectory(path)` 判定，`showEmptyState()` 兜底置灰）。此前它在外观上一直可用，但点击后 `currentTabPath` 为空会被 guard 直接吞掉 —— 表现就是「下拉没反应」；现在不会再有「看起来能用、点了没动静」的状态，日志里也会有 `preview file menu: no file tab is selected` 便于确认。

**验收**：Finder / 至少一个 IDE / 一个终端能正确打开当前项目目录；重启 App 后记忆生效 —— 待手动 QA。

---

## 3. Terminal 面板滚动方向与其他面板相反

**现象**：终端面板上下滚动方向和其他面板（dsh web / 文件树等）相反。

**相关代码**：`platforms/macos/src/TerminalPanel.swift` `scrollWheel(with:)`（L1125-1141）。

**疑点**：实现只读 `event.scrollingDeltaY` 并直接换算步长，未考虑 `isDirectionInvertedFromDevice`（自然滚动开关）与系统滚动语义；而其他面板走 NSScrollView 的标准行为，二者因此不一致。源码注释也留了「If QA finds the direction inverted, flip this sign」。

**实现**（`feature/ux-feedback-fixes`）：`TerminalPanel.swift` `TerminalView.scrollWheel(with:)` 改为 NSScrollView 语义（正 `scrollingDeltaY` → 显示更早的行）。

**后续修正（QA 反馈）**：第一版把 delta 按「1 点 = 1 行」换算，手势被放大成匀速滚动，丢掉了原来的惯性刹车感。现改为：触控板精确 delta 按 **4 点 = 1 行**（与改版前的灵敏度一致）并保留小数累加器，动量阶段的衰减 delta 自然体现为「先快后慢」；鼠标滚轮（非精确 delta）一格 = 一行。

**验收**：触控板（自然滚动开/关）与鼠标滚轮两种设备下，终端滚动方向与文件树一致：内容朝向与手势方向一致（即手势「上滑看下文」）—— 待手动 QA。

---

## 4. Terminal 面板：双击选词 + 选中自动复制

**现象**：双击无法快速选中单词；拖选文本后仍需 ⌘C 才能复制粘贴。

**期望**：
- 双击选中单词（路径/URL 类文本建议把 `/ - . _ :` 等视作词内字符），三击选中整行；
- 拖选结束（mouseUp）自动写入剪贴板，可直接 ⌘V 粘贴，无需 ⌘C；
- 自动复制提供开关（默认开），避免污染剪贴板、也兼容无选区时 ⌘C 发 SIGINT 的既有语义。

**相关代码**：
- `mouseDown/mouseDragged/mouseUp`（L1164-1191）：目前只做单点锚定 + 拖选，`mouseUp` 仅在原地点击时清空选区，未使用 `event.clickCount`；
- `copy(_:)`（L1200-1213）：有选区复制、无选区发 `\x03`（SIGINT）——自动复制不能破坏这个无选区语义。

**实现**（`feature/ux-feedback-fixes`）：`mouseDown` 增加 `clickCount` 分支（双击选词 / 三击整行，词边界把路径、URL、参数完整保留，点分隔符则选该分隔符连续段）；`mouseUp` 在拖选结束时调用 `copySelectionIfAutoCopy()`；开关 `terminal.autoCopy`（默认开）由「设置 → 终端：选中文本即复制」控制；⌘C 仍保留「无选区时发 SIGINT」的语义。

**后续修正（QA 反馈）**：双击选词后原来无法继续拖动扩选。现在双击/三击会带着**选择单位**进入拖拽：双击后拖动按「整词」扩选（锚定那个词始终完整，指针下的词整词并入），三击后按「整行」扩选；普通拖拽仍是逐格选择。

**验收**：双击选词、三击选行；双击后拖动可选多个词；拖选后直接 ⌘V 得到刚选中的文本 —— 待手动 QA。

---

## 5. Terminal 面板页签按 workspace 隔离 / 记忆

**现象**：终端页签是全局的，切换 workspace（session）后各项目的终端混在同一排页签里。

**期望**：像 Files 面板一样按当前 workspace 过滤显示；切走时隐藏但不销毁会话（进程继续存活），切回后瞬间恢复原页签与滚动位置。

**相关代码**：
- 参照 `platforms/macos/src/FilePanel.swift` `setProjectDirectory(_:)`（L538）—— 收到 dsh 会话/workspace 变化回调时只重指目录树，已打开的预览页签保持不动；
- 终端侧 `TerminalPanel.swift` 目前没有对应钩子，需在 `TerminalPanelController` 增加 `setWorkspace(id:path:)` 之类入口，并在 shell 的 dshSession 处理器（`main.swift`）里调用。

**实现**（`feature/ux-feedback-fixes`）：新增纯模型 `TerminalWorkspaceTabs.swift`（页签 → workspace 映射、每 workspace 的「上次选中」、`forget/forgetAll`、无法解析项目目录的兜底页签标记为全局可见）；`TerminalPanelController.setWorkspaceDirectory(_:)` + `syncTabVisibility()` 只隐藏**不终止**——切回来仍是同一个会话；⌘1…9 / ⌘⇧[ ] 只在当前 workspace 的页签间切换；shell 的 `dshSession` 处理器（`main.swift`）与「打开终端面板」路径都会同步 workspace。

**后续修正（QA 反馈）**：切到「没有活终端」的 workspace 时，只要终端面板可见就**自动开一个**，不用再手动点「+」；面板不可见时不开（避免用户只是路过某个 workspace 也白白拉起 shell）。

**待定**：隐藏期间会话数量上限与内存占用策略（当前不设上限，与「不杀会话」的取舍一致）。

---

## 6. 长时间运行后手动刷新 WebView → dsh web 页面打不开（疑似 key 失效）

**现象**：oh-my-dsh 连续运行很久（小时～天级）后，在 WebView 里手动刷新 dsh web，页面打不开；
使用者描述为「key 失效」。

**现场核对（2026-09-21 04:30 UTC，针对已运行 22.5 h 的实例）**

| 实测 | 结果 |
|---|---|
| `GET /`（不带 cookie） | 401 + text/plain：`dsh web authentication required; reopen the URL printed by dsh web.` |
| `GET /?token=<自报入口 token>` | 303 + `Set-Cookie: dsh-auth-…`（Max-Age=2592000，30 天）→ **启动 token 不随时间失效** |
| 用 WebView 实际持有的 cookie（从 `~/Library/HTTPStorages/com.ohmydsh.app.binarycookies` 解出：authority `127.0.0.1:3080`、issuedAt 2026-09-20 05:54:51Z、expiresAt +30d）请求 `/` | **200 + 24 KB 页面（含 `__DSH_BOOT__`）** |
| 该实例的 dsh web 进程 | 仍在 3080 监听（node pid 16288，即 server.log 里自报 token 的进程） |
| app.log | 自 05:54:51 起只有一次 `page did finish loading`，期间无刷新、无失败记录 |

结论：**这一刻 token、cookie、服务三者都健康**，问题不在「凭证本身到期」。另外手动刷新目前**完全不留日志**
（`reloadPage()` 不写 app.log；401 页面会被 `didFinish` 当成正常加载），所以复现过一次也查不到。

**相关代码**

- 刷新入口：`platforms/macos/src/main.swift` `reloadPage()`（L4618，调 `webView.reload()`）——**没有绑定任何菜单/快捷键**（用户只能右键 WebView → 重新载入；⌘R 是 Review 面板）；
  - 该右键「重新载入」是 **WKWebView（WebKit 系统默认上下文菜单）**提供的，不是 dsh web 页面提供的：dsh web 前端 bundle 里没有任何自建右键菜单/对 `contextmenu` 的 `preventDefault`（5 处出现全是 React 内部事件名表），壳层也没给主 WebView 加 `menu(for:)`/`willOpenMenu`，全仓库唯一的自定义右键菜单在 CEF 浏览器面板（`BrowserPanel.swift:979`）；主 WebView 无子类、未开 developerExtras。
  - 因此它的行为就等于 `webView.reload()`：**重新请求当前 URL（`http://127.0.0.1:<port>/`，不带 token），只靠 cookie 认证**，不会走 `/?token=` 那条重新签发 cookie 的路径——这正是「一旦 cookie 不被接受就 401 打不开」的结构性原因，也说明修复要由壳层提供走 token 的刷新入口（方案 1+4）。
- 首屏加载：`startServer()` → `webView.load(URLRequest(url: entryURL))`（L3077，entryURL 是 dsh 自报的带 token 地址）；
- 端口/token 生命周期：`ServerManager.start()`（L1368，端口冲突就换随机端口）、`stop()`（L1623，**不清 `entryURL`/`port`**）；
- 服务重启路径：`restartServerAfterUpgrade()`（L3122）；
- 凭证：dsh `dsh-client-connection` `BrowserAuth`（token 仅存进程内；cookie 用 `$DSH_HOME` 持久签名密钥，绑定 authority，默认 30 天）；
- 无服务看门狗：`terminationHandler` 只用于 channel runner 登录进程（L4243），spawn 出来的 dsh web 死了没人管。

**候选成因（按可能性排序）**

- **A1 端口/实例错位**：壳层每次启动都用随机端口（3080 被占就换），WebView 记着启动时的 URL；若旧实例/别的进程后来占了同一端口，刷新会打到「不是我们的服务」→ 401（cookie 的 authority 与签名都不匹配）。
- **A2 服务被静默拖死**：长时间运行后 node 侧卡死/退出，壳层没有看门狗，刷新 → 连接失败/白屏。
- **A3 WebView 侧网络状态陈旧**：长时运行后 keep-alive 连接失效、WebKit 网络进程异常 → 刷新报网络错误（不落到 401）。
- **B 凭证失效类**（本次未复现）：cookie 被清（janitor 只在启动/退出跑，理论不中途清）、30 天到期、dsh 签名密钥因 `$DSH_HOME/.credentials.yaml` 重建而更换。
- **C 插件包请求失败**（历史 431 问题）：页面拿到了 index 但 bundle script 加载失败，看起来像「页面打不开」；本次实测只剩 1 个 cookie，暂不成立。

**使用者补充（2026-09-21，关键）**

1. 失败页面显示的就是纯文本 `dsh web authentication required…` → **确认是 401**（不是白屏、不是网络错误页）；
2. 当时 **Files / Terminal / Review 面板全部正常** → 服务活着，且壳层的 token 通道正常（面板走 `DshWebRPC`，用 token 现换 cookie）→ **死的只是 WebView 手里那一份 cookie**；
3. 刷新方式：WebView 右键「重新载入」（= WebKit 默认菜单的 Reload = 裸 `reload()`）；
4. **触发动机**：刷新之前 dsh web 的**对话区已经不出新内容、也无法操作**（页面像卡死）——刷新本来是想恢复它。

据此收敛：

- **排除 A2**（服务没死：面板正常）与 **A3**（不是网络层错误：拿到了 401 响应体）、**排除 C**（页面正常渲染出了 dsh 的 401 文本，不是插件包加载失败）；
- 留下 **A1 / B**：刷新请求到达了服务，但 WebView 那份 cookie 不被接受（不存在 / authority 不匹配 / 签名不再被认）；
- 新增 **A4「页面底下被换了服务」**（最能解释第 4 点）：长时运行中 dsh web 被重启过（自动升级路径 `restartServerAfterUpgrade()` L3122，或升级失败回滚后的重启 L3356）——旧页面到旧服务的连接随之断开（**对话区卡死**），而 `startServer()` 里的 `DshWebCookieJanitor.purgeStale(keeping: 新 authority)`（L3074）会清掉旧端口的 cookie；此后**旧 URL + 没有可用 cookie** → 右键 Reload 裸请求 `/` → 401。面板不受影响，因为它们每次都用 token 重新换 cookie。

**刷新入口与快捷键（回答「右键 Reload 与 ⌘R 能否一致」）**

- 现状：右键「重新载入」由 **WKWebView 系统菜单**提供（见上）；**⌘R 目前没有绑定任何菜单项**（⌥⌘R 才是 Review 面板，见 `main.swift` L3831-3832），也就是说今天按 ⌘R 并不等于刷新。
- 目标不是「把裸 reload 复制一份给 ⌘R」，而是**让两条路都不再依赖那份会失效的 cookie**：
  - **做法 A（推荐，一处修复两处受益）**：新增「视图 → 重新加载页面 ⌘R」走方案 1（`entryURL` 重新认证）；**同时**按方案 3 拦截主框架 401 自动自愈 → 右键 Reload 即使触发也会被自动救回，两者结果一致。
  - **做法 B（字面一致，更彻底）**：把主 WebView 换成 `WKWebView` 子类，override `menu(for:)`，用自家「重新加载页面（重新认证）」替换系统那个 Reload 项 → 右键菜单直接调用壳层逻辑，⌘R 与右键完全同一实现。代价是新增一个约 20 行的子类（只改菜单构造，不动渲染，风险低）。

**建议方案（自愈式刷新，一次覆盖 A/B/C）**

1. **刷新=重新认证，而不是裸 reload**：`reloadPage()` 改为加载 `server.entryURL`（带 token 的入口地址）——303 会重新落一份 30 天 cookie 并回到 `/`。token 与进程同生命周期（实测 22 h 后仍有效），所以对 A1/B 自愈；视觉上只多一次重定向。旧版 dsh（无 token）回退到现在的 `webView.reload()`。
2. **刷新前做存活判定 + 自愈**：先用 `isDSHServing(port:)` / `tokenAccepted(port:token:)` 探测；失败则 (a) 重读 server.log 里最新自报入口地址（服务重启后端口/token 会变）、(b) 若是自己 spawn 的服务且已死 → `startServer()` 重拉并重新派发 `serverReady` / `DshWebRPC.token` / channel runner 的 port+token、(c) 仍不可恢复 → 走已有的 `showStatus(..., retry: true)` 错误态。
3. **主框架 401/失败拦截**：`decidePolicyFor navigationResponse` 里识别主框架 401（text/plain 的 `dsh web authentication required`）→ 自动按方案 1 重试一次；`didFailProvisionalNavigation`（L3646）已有错误态，补一次自动重试。
4. **给刷新一个正式入口**：菜单「视图 → 重新加载页面」+ **⌘R**（当前未占用；⌥⌘R 仍是 Review 面板），`reloadPage()` 与方案 1 合并；配合方案 3，使 ⌘R 与右键「重新载入」结果一致（做法 A/B 见上）。
5. **先补诊断日志**（成本最低、收益最大）：记录每次刷新（URL / 是否带 token / 探测结果 / 响应状态 401·403·200 / cookie 是否存在及 authority / 服务进程是否存活 / 端口是否仍是启动时记录的那个）。下次复现即可定位，不必再猜。

**实现**（`feature/ux-feedback-fixes`，对应上面的方案 1 + 3 + 4 + 5）

- **⌘R 入口**：视图菜单新增「重新加载页面 ⌘R」（此前 ⌘R 未绑定，⌥⌘R 仍是 Review 面板）→ `reloadPage()` → `reloadPageReauthenticating(reason:)`（`main.swift`）。
- **刷新=重新认证**：`reloadPageReauthenticating` 优先加载 `server.entryURL`（带启动 token 的入口地址，303 会重新落一份 30 天 cookie）；无 token（旧版 dsh）或服务已不在时回退 `webView.reload()`。
- **401 拦截自愈**：`decidePolicyFor navigationResponse` 识别主框架 401 → `retryWithFreshAuth(reason:)` 用 token 重新认证（右键菜单那个 WebKit 原生 Reload 因此也会被自动救回）；`didFailProvisionalNavigation` 同样先自愈一次（自己 spawn 的 dsh web 已死则 `startServer()` 重拉），再落到错误态。自愈带一次性守卫 `loadRecoveryAttempted`（成功加载后重新武装），不会打转。
- **诊断日志**：每次刷新记录 `port / ourServerAlive / entryToken / sinceLast`，并用 `logAuthCookieState(reason:)` 打印当前 authority 对应的 `dsh-auth-*` cookie 是否存在、过期时间、以及其它残留 cookie 数；加载失败还会带上服务是否存活与端口。
- **健壮性顺带修复**：`ServerManager.stop()` 现在会清空 `entryURL` 与 `process`，避免服务重启后旧 token 被刷新路径或面板 RPC 复用；新增 `server.isRunning` 供上述判定使用。

**验收**

- 连续运行 >24 h 后手动刷新，页面正常；
- 手动 kill 掉 dsh web 进程后刷新 → 自动重拉并恢复正常，日志有完整记录；
- 3080 被别的 dsh web 占用时启动 → 刷新不被别人实例的 401 打死。

**验收补充**

- ⌘R 与右键「重新载入」结果一致，且两者都能在 cookie 失效时自愈（不再出现 401 纯文本页）；
- 长时运行后「对话区卡住」时，用 ⌘R 能一键恢复到可用状态（这正是使用者触发刷新的原始动机，值得单列回归用例）。

---

## 7. 大文件（3000+ 行）磁盘变更后重新加载把应用卡住

**现象**：Files 面板打开一个大文件（3000+ 行），当文件在磁盘上被修改、面板自动重新加载时，整个应用卡住。

**根因（代码定位）**

1. **一次重载触发两遍全文件高亮**：`CodeEditorView.reloadFromDisk()` 先 `codeTextView.string = newText` —— 替换整段文本会让 `CodeAttributedString.processEditing()` 对**被替换的整段**（即全文）做一次 highlight；紧接着又 `cas.language = language`，而 `language.didSet` 是 `highlight(NSMakeRange(0, length))` —— **再来一次全文高亮**。每次高亮 = 后台 JS 高亮全文 + 主线程逐段 `setAttributes` 全文档（并触发整篇重排版）。3000+ 行时这就是秒级主线程卡顿。
2. **写文件过程中每 2s 重载一次**：`treeWatcherTick`（间隔 2s）→ `refreshOpenTabsIfChanged()`，只要 mtime 变了就重载。agent 反复写同一个文件时，每一跳都付一次上面那个代价 → 表现为持续卡死。
3. 附带：读取文件用的是主线程 `Data(contentsOf:)`。

**修复（`feature/ux-feedback-fixes`）**

- 新增纯策略 `EditorLoadPolicy.swift`（可单测）：**写文件稳定性窗口 0.6s**；**高亮分块大小**（300 行 / 32 KB）；高亮「安全阀」只对**极端文件**（>4 万行或 >4 MB，如一整份压缩产物/日志）才退化为纯文本。
- `reloadFromDisk()` 改为**后台读取 + 主线程应用**，并用 generation 计数保证「最后一次请求胜出」（慢读不会把旧内容塞回编辑器）。
- 应用新内容时：用新加的 `CodeAttributedString.setLanguage(_:automaticallyHighlighting:)`（vendored Highlightr 的**本地新增**，已注释标注）抑制两条自动高亮路径（替换文本触发的段落高亮 + `language` didSet 的全文高亮），再 `beginEditing/endEditing` 一次性替换文本。
- `refreshOpenTabsIfChanged()` 增加**稳定性窗口**：mtime 在 0.6s 内还在变的文件先不重载（且**不吃掉**这次变化），因此「agent 连续写文件」只会在写完后重载**一次**，日志里会看到 `preview reload deferred (still being written)` 与重载耗时。

**高亮不再"按大小关闭"，改为分块着色（第二轮修正，QA 反馈）**

第一版用「超过 2000 行 / 256 KB 就不高亮」换性能，QA 认为不可取 —— 3000 行文件失去配色确实说不过去。现在：**正常源文件一律保留语法高亮**，性能由三件事保证：

1. **分块着色**：`CodeEditorView.highlightInChunks()` 按「整行」切片（300 行 / 32 KB 一片，切分逻辑是纯函数 `EditorLoadPolicy.highlightChunk(in:from:)`），每片之间 `DispatchQueue.main.async` 让出主线程 —— 大文件自上而下渐进上色，UI 全程可响应；切换深浅色主题的重着色也走这条路（suppress 标记同时罩住 vendor 的 `themeChanged`）。
2. **一次重载只有一次高亮**（不再「段落高亮 + didSet 全文高亮」两遍）。
3. **写文件期间不重复重载**（0.6s 稳定性窗口）+ 读取在后台线程。

安全阀只留给极端文件（>4 万行或 >4 MB 的日志/压缩产物），命中时会写日志说明。

**验证**：`tests/file-panel/editor-load-policy-tests.swift` 23 条断言全绿（行数统计；3000 行与 20000 行**仍高亮**；安全阀边界；字节阈值与多字节；分块覆盖全文不重不漏且**不切行**；超长单行独占一片；稳定性窗口与时钟偏斜）；`tests/file-panel` 与 `scripts/local-ci.sh swift` 全绿。**待手动 QA**：打开 3000+ 行文件，用外部命令连续改写，确认面板不卡、颜色渐进恢复、内容同步。

**已知遗留**：目录树 watcher 每 2s 会对所有可见目录做一次 `stat` + 目录列举（主线程）；超大仓库下仍可能偏重，可后续按需异步化。
---

## 8. 图片预览：改为自适应尺寸 + 手动缩放

**现象**：Files 面板打开图片时按**原始尺寸**显示（`NSImageView.frame = image.size` 放进滚动视图）——大截图只能看到一角，小图标又小得看不清，且没有任何缩放手段。

**实现（`feature/ux-feedback-fixes`）**

- 新增 `ImagePreviewView.swift`：打开时/面板尺寸变化时**按比例适应窗口**（`ImageZoom.fitMagnification`，等比、以较紧的一边为准，**不放大超过 100%**，避免把小图标糊掉）；用户手动缩放后不再自动重新适应（以用户为准），直到 ⌘0、双击或重新打开文件。
- 缩放方式：触控板**捏合**（NSScrollView magnification）、**⌘+ / ⌘− / ⌘0**、**⌘+滚轮**、**双击**（适应窗口 ↔ 100% 切换）；放大后可直接拖拽/滚动条平移。缩放范围 5%–1600%，单步 ×1.25。
- 右下角浮动**百分比角标**（跟随 magnification 变化，KVO 驱动）；悬停提示写明操作方式（`preview.imageZoomHint`，中英成对）。
- 缩放数学抽成纯模型 `ImageZoom.swift`（适应比例/夹取/单步），视图只管 AppKit。

**验证**：`tests/file-panel/image-zoom-tests.swift` 17 条断言（宽图按宽、窄图按高、方形、小图不放大、零尺寸回退 100%、上下限夹取、NaN 兜底、单步乘除、边界不动、40 次连续放大单调且收敛到上限）全绿；`tests/file-panel` 与 `scripts/local-ci.sh swift` 全绿。**待手动 QA**：打开大截图应整幅可见且不变形；⌘+/⌘−/⌘0、⌘滚轮、双击、捏合都能缩放；放大后可拖拽平移。
---

## 备注

- 本文件仅记录问题清单，**未改代码、未开分支**；开始实现时按 `docs/git-workflow.md` 先切 `feature/*` 或 `fix/*` 分支。
- 每项完成后把状态改为 ✅，并在该条目下补一行实现位置（文件 + 函数）与验证结论。
