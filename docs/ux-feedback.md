# 使用问题记录（UX 反馈）

> 用途：记录日常使用中发现的体验问题与改进点，逐条跟踪到实现与验收。
> 记录日期：2026-09-21 · 版本基线：当前 `main` 后的开发分支
> 状态图例：🔲 待处理 · 🔧 进行中 · ✅ 已完成 · 💬 待讨论

## 汇总

| # | 面板 | 问题 | 类型 | 优先级 | 状态 |
|---|---|---|---|---|---|
| 1 | Files | 目录树缺少「新建文件夹 / 新建文件」入口 | 功能缺失 | 中 | 🔲 |
| 2 | Files | 右上角「在面板中打开当前项目目录」应支持用外部应用打开 | 交互改进 | 中 | 🔲 |
| 3 | Terminal | 滚轮滚动方向与其他面板相反 | Bug | 高 | 🔲 |
| 4 | Terminal | 双击不能选词；拖选后需再按 ⌘C 才能复制 | 交互改进 | 中 | 🔲 |
| 5 | Terminal | 终端页签未按 workspace 隔离/记忆 | 交互改进 | 低 | 💬 |
| 6 | Shell | 长时间运行后手动刷新 WebView → dsh web 页面打不开（疑似 key 失效） | Bug | 高 | 💬 |

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

**待定**：是否同时做重命名 / 删除 / 拖拽移动（范围问题，实现前先确认）。

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

**验收**：Finder / 至少一个 IDE / 一个终端能正确打开当前项目目录；重启 App 后记忆生效。

---

## 3. Terminal 面板滚动方向与其他面板相反

**现象**：终端面板上下滚动方向和其他面板（dsh web / 文件树等）相反。

**相关代码**：`platforms/macos/src/TerminalPanel.swift` `scrollWheel(with:)`（L1125-1141）。

**疑点**：实现只读 `event.scrollingDeltaY` 并直接换算步长，未考虑 `isDirectionInvertedFromDevice`（自然滚动开关）与系统滚动语义；而其他面板走 NSScrollView 的标准行为，二者因此不一致。源码注释也留了「If QA finds the direction inverted, flip this sign」。

**验收**：触控板（自然滚动开/关）与鼠标滚轮两种设备下，终端滚动方向与文件树一致：内容朝向与手势方向一致（即手势「上滑看下文」）。

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

**验收**：双击选词、三击选行；拖选后直接 ⌘V 得到刚选中的文本。

---

## 5. Terminal 面板页签按 workspace 隔离 / 记忆

**现象**：终端页签是全局的，切换 workspace（session）后各项目的终端混在同一排页签里。

**期望**：像 Files 面板一样按当前 workspace 过滤显示；切走时隐藏但不销毁会话（进程继续存活），切回后瞬间恢复原页签与滚动位置。

**相关代码**：
- 参照 `platforms/macos/src/FilePanel.swift` `setProjectDirectory(_:)`（L538）—— 收到 dsh 会话/workspace 变化回调时只重指目录树，已打开的预览页签保持不动；
- 终端侧 `TerminalPanel.swift` 目前没有对应钩子，需在 `TerminalPanelController` 增加 `setWorkspace(id:path:)` 之类入口，并在 shell 的 dshSession 处理器（`main.swift`）里调用。

**待定**：隐藏期间会话保活的数量上限与内存占用策略；是否需要「会话随 workspace 关闭而回收」开关。

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

**建议方案（自愈式刷新，一次覆盖 A/B/C）**

1. **刷新=重新认证，而不是裸 reload**：`reloadPage()` 改为加载 `server.entryURL`（带 token 的入口地址）——303 会重新落一份 30 天 cookie 并回到 `/`。token 与进程同生命周期（实测 22 h 后仍有效），所以对 A1/B 自愈；视觉上只多一次重定向。旧版 dsh（无 token）回退到现在的 `webView.reload()`。
2. **刷新前做存活判定 + 自愈**：先用 `isDSHServing(port:)` / `tokenAccepted(port:token:)` 探测；失败则 (a) 重读 server.log 里最新自报入口地址（服务重启后端口/token 会变）、(b) 若是自己 spawn 的服务且已死 → `startServer()` 重拉并重新派发 `serverReady` / `DshWebRPC.token` / channel runner 的 port+token、(c) 仍不可恢复 → 走已有的 `showStatus(..., retry: true)` 错误态。
3. **主框架 401/失败拦截**：`decidePolicyFor navigationResponse` 里识别主框架 401（text/plain 的 `dsh web authentication required`）→ 自动按方案 1 重试一次；`didFailProvisionalNavigation`（L3646）已有错误态，补一次自动重试。
4. **给刷新一个正式入口**：菜单「视图 → 重新加载页面」+ 快捷键（避免依赖 WebView 右键菜单）；`reloadPage()` 与方案 1 合并。
5. **先补诊断日志**（成本最低、收益最大）：记录每次刷新（URL / 是否带 token / 探测结果 / 响应状态 401·403·200 / cookie 是否存在及 authority / 服务进程是否存活 / 端口是否仍是启动时记录的那个）。下次复现即可定位，不必再猜。

**验收**

- 连续运行 >24 h 后手动刷新，页面正常；
- 手动 kill 掉 dsh web 进程后刷新 → 自动重拉并恢复正常，日志有完整记录；
- 3080 被别的 dsh web 占用时启动 → 刷新不被别人实例的 401 打死。

**待确认**（使用者补充即可定位到具体成因）

1. 刷新失败时页面上具体显示什么？（纯文本 `dsh web authentication required…` / 白屏 /「无法连接」/ 浏览器错误页）
2. 当时其他面板（Files / Terminal / Review）还正常吗？（用于区分「服务死了」与「只是 WebView 凭证」）
3. 刷新方式：WebView 右键「重新载入」，还是其他操作？

---

## 备注

- 本文件仅记录问题清单，**未改代码、未开分支**；开始实现时按 `docs/git-workflow.md` 先切 `feature/*` 或 `fix/*` 分支。
- 每项完成后把状态改为 ✅，并在该条目下补一行实现位置（文件 + 函数）与验证结论。
