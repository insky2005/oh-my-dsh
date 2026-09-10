# dsh 版本升级对 oh-my-dsh 的影响清单

> 目的：oh-my-dsh **不修改 dsh 源码**，只做「壳 + core + 运行时」封装，因此 dsh 每次升级都可能从**接口、鉴权、文件布局、启动参数、分发方式**五个方向把壳层打断。
> 本文是**升级前/升级后逐项核对的单一清单**：先看 §2 总览，再按 §3 明细表定位「依赖了 dsh 的什么契约」，最后走 §5 的执行清单。
> 关联文档：`docs/plans/dsh-012rc1-compat-audit.md`（0.1.2 实战审计）、`docs/productization.md` §8（升级策略）、`docs/release-process.md`。
> 维护方式：每次 dsh 升级后，把新踩到的断裂点补进 §3 对应行 + §4 复盘一节。

## 1. 结论（先看这三条）

1. **升级风险集中在 5 个面**：① 进程与 HTTP RPC（含鉴权）② Web 页面注入脚本/DOM ③ `$DSH_HOME` 磁盘布局 ④ CLI 启动参数与就绪协议 ⑤ npm 分发与 Node 版本。其余（CEF 浏览器面板、终端 PTY、文件预览、Wiki 面板 UI）与 dsh 无耦合，基本不受影响。
2. **同一个根因常常波及多个面板**：「壳层用裸 HTTP + 老点号 RPC + 无鉴权直连 dsh web」这一个假设，在 0.1.2 一次性打断了会话目录跟随、面板点开会话、预览打开文件、wiki 生成、issue-runner 流水线、频道指令六处（见 §4）。
3. **必须有「双版本兼容」还是「单版本适配」的取舍**：当前策略是**内置 dsh 固定版本（`DSH_PACKAGE_SPEC`）+ 以该版本为目标适配**（不做长期双兼容），但**已知面**（如一元 RPC、workspace 列表）仍保留回退，成本低、收益高（见 §3C）。

## 2. 五个耦合面总览

| # | 耦合面 | 契约本质 | 典型断裂表现 | 现状防御 |
|---|---|---|---|---|
| A | 进程 / 就绪 / 鉴权 | spawn `dsh web --no-open --port N`；就绪信号；每实例 token+cookie | App 判「dsh web 启动失败」白屏；所有 native RPC 401 | 读 dsh 自报的带 token 入口地址；runner 用 token 换 cookie |
| B | Web 页面 / DOM / 注入脚本 | `window.__DSH_BOOT__`、客户端 fetch 信封与方法名、侧栏 DOM 结构 | 切会话不跟随目录；面板点开会话失败；预览不拦截文件打开 | 注入脚本同时认新旧方法名与 payload 形状；DOM 选择器兜底重试 |
| C | 一元 RPC（会话/工作区） | `POST /api/<method>` + client-request 信封 + 参数形状 | /wks 回「没有可用的 workspace」；会话建不出来；消息无回复 | core 版本无关传输层（斜杠端点 ⇄ 点号方法 + cookie）；workspace 磁盘兜底 |
| D | `$DSH_HOME` 磁盘布局 | `storages/workspace.json`、`skills/`、sessions、credentials | 项目目录解析不到；内置 skill 不被发现 | 只读/写明确子路径；列出「我们依赖的」与「我们自己的」边界 |
| E | 分发与升级 | npm 包 + Node 版本要求 + 运行时布局 | 升级后启动失败；升级脚本 exit 127 | 固定 `DSH_PACKAGE_SPEC`；分步升级 + 备份回滚；Node ≥22 过滤 |


## 3. 明细清单

> 「代码位置」列给出当前实现锚点；升级后先看这些位置是否仍成立。

### A. 进程、就绪与鉴权

| # | 依赖的 dsh 契约 | 版本变化/风险 | 断裂表现 | 代码位置 | 验证方式 |
|---|---|---|---|---|---|
| A1 | 自拉起命令：`node <dsh>/lib/bin.js web --no-open --port <port>`；可 `--port` 指定任意端口 | 参数名/子命令若变（`web` → 其他）则拉不起来 | App 弹「dsh web 启动失败」 | main.swift `ServerManager.start()`（spawn 段） | 开发版启动后 `lsof -iTCP -sTCP:LISTEN` 看端口 + WebView 首屏 |
| A2 | 就绪自报：stderr/stdout 打印 `dsh web: http://127.0.0.1:<port>/?token=…`（0.1.2+）；旧版靠根页面含 `__DSH_BOOT__` | 0.1.2 起裸 GET `/` 返回 401（无 `__DSH_BOOT__`） | 就绪判定超时 → 判定启动失败（白屏 overlay） | `servedEntryURL()` / `isDSHServing()` | `cat ~/Library/Logs/oh-my-dsh/server.log`（含 token 行） |
| A3 | **复用**外部已启动实例：裸 GET 3080 判 `__DSH_BOOT__` | 0.1.2 外部实例裸 GET 401 → **判为不可用**，App 另起一个空闲端口实例（**按设计，不复用**：token 每进程随机且只在该进程 stdout，拿不到；同 `DSH_HOME` 下数据本就共享，复用只省一个进程） | 行为正确，日志已说明原因 | `ServerManager.start()` 复用分支 + `isDSHAuthenticated()` | 起一个 0.1.2 dsh web 在 3080，再启动 App，看 `app.log` 的 not adopting 行 |
| A4 | Web 鉴权：`/?token=…` → 303 + `dsh-auth-*` Cookie（authority `127.0.0.1:<port>` 绑定），`/api` **只认 cookie**（query token 无效） | 0.1.2 首次引入 | WebView 白屏（401）；native RPC 全部 401 | WebView 直接加载 servedURL（带 token）；core `dsh-rpc.authenticate()` 换 cookie | `curl -i "http://127.0.0.1:<port>/?token=…"` 看 `set-cookie` |
| A5 | 每实例 token **随机**（进程内生成），只在自报 URL 里出现 | 任何「读文件拿 token」的想法都不成立 | native/子进程拿不到 token → 401 | 壳层 ServerManager.`entryURL`/`webToken` → `--dsh-token` | 重启 App 后 token 变化（`server.log` 对比） |
| A6 | dsh 子进程环境：`DSH_HOME`、登录 shell PATH | 新增必需环境变量（未来可能） | dsh web 起不来或行为异常 | spawn 处 `penv` 拼装 | `ps eww` / 日志打印 |

### B. Web 页面注入脚本与 DOM

| # | 依赖的 dsh 契约 | 版本变化/风险 | 断裂表现 | 代码位置 | 验证方式 |
|---|---|---|---|---|---|
| B1 | 客户端走 `window.fetch` + `POST /api/*` + `{type:"client-request", method, payload}` 信封 | 若改 WebSocket/其他传输则拦不到 | 会话跟踪失效、预览不拦截文件打开 | `sessionTrackerScript` / `previewInterceptorScript` | 注入 `DSH_PREVIEW_DEBUG=1` 看日志命中 |
| B2 | 方法名集合：`session.history/prompt/rename/selectModel`、`subagent.list`；0.1.2 变 `session/history`…`subagents/list` | 0.1.2 点号→斜杠 | web 切会话不再通知壳层 → 项目目录不跟随 | 同上（已同时认两套名字） | 手工切会话，看 `app.log: project directory followed session` |
| B3 | sessionId 位置：旧 `payload.sessionId/parentSessionId`；0.1.2 `payload.args.*` / `args.request.sessionId` | 0.1.2 移位 | 同上 | 同上（多路取值） | 同上 |
| B4 | 「每次切会话必然触发 `subagents/list`（带 parentSessionId）」这一时序特性 | 客户端若改为幂等/懒加载 | 重复点开同一会话不通知 | `sessionTrackerScript` 设计依赖 | 反复点同一会话行 |
| B5 | 侧栏会话行 DOM：`[role="treeitem"]` 可点行 + 标题文本 | DOM 改版 | 面板点会话行无法定位 web | `sessionOpenerScript`（含 8 次重试） | 面板点会话行 → web 侧栏跳转 |
| B6 | 标题来源：`session/list` → `items[].projections.values.title`（dsh web 按首条消息自动命名） | 字段路径变化 | 面板/指令显示的会话名为空 | `sessionOpenerScript` / `sessionDriver` / ChannelStoreReader | `/ses` 回复里的标题 |
| B7 | 文件打开 RPC：旧 `/api/host.openPath`；0.1.2 `session/openWorkspacePath`（路径在 `payload.args.request.path`） | 0.1.2 迁移 | 预览面板不再拦截文件打开 → 弹系统默认应用 | `previewInterceptorScript`（已双匹配 + 多路取路径） | 消息流里点文件 → 是否在文件面板打开 |
| B8 | 根页面注入 `window.__DSH_BOOT__` | 0.1.2 起仅鉴权后可读 | 仅影响旧版就绪判定（已由 A2 覆盖） | `isDSHServing()` | 同上 |

### C. 一元 RPC（会话 / 工作区）

| # | 依赖的 dsh 契约 | 版本变化/风险 | 断裂表现 | 代码位置 | 验证方式 |
|---|---|---|---|---|---|
| C1 | 端点命名：≤0.1.1 点号 `/api/session.list`；0.1.2 **斜杠** `/api/session/list` | 0.1.2 变更，且**不是所有端点同时存在**（无 `workspace/list`） | 404 / 指令失效 | `core/lib/dsh-rpc.js`（按端点记忆所选面，先斜杠后点号） | `curl` 探针（§6） |
| C2 | 参数信封：≤0.1.1 `payload = 参数`；0.1.2 `payload.args.<request\|_request>`（**字段名按端点不同**，错名回 `gateway/arguments-invalid`） | 0.1.2 变更 | 400/参数错误 | 同上（`field` 描述符） | 同上 |
| C3 | 鉴权：0.1.2 `/api` 需 cookie（A4） | 0.1.2 新增 | 401 | `dsh-rpc.authenticate()` + token 传递链 | 同上 |
| C4 | 工作区列表：≤0.1.1 `workspace.list`；0.1.2 **移除**（改 `workspace/follow` 流式） | 0.1.2 移除 | **/wks 回「没有可用的 workspace」**（本次主诉） | `core/lib/workspace-store.js`（RPC → `$DSH_HOME/storages/workspace.json` 兜底） | 微信 `/wks`；或 `node -e` 调 listWorkspaces |
| C5 | 会话列表字段：`items[].{sessionId,updatedAt,running,blank,cwd,projections.values.title,projections.asOfSeq}` | 字段重命名/移除 | 会话名空、轮询 running 判错 | `session-driver.fetchSessionItems` | 同上 |
| C6 | 回复读取：≤0.1.1 `session.history`/`session.search`；0.1.2 `session/page`（`throughSeq` **必须**取 `projections.asOfSeq`，越界回 `past cursor`） | 0.1.2 变更 | 频道回复变成「(会话未产生可读取的回复文本)」 | `session-driver.lastMessage` | 发一条普通消息看回复 |
| C7 | 写操作：`session/create`（`workspaceId\|cwd`）、`session/rename`、`session/prompt`（0.1.2 必填 `requestId` + `mode` + `content[]`）、`session/cancel` | 0.1.2 增字段 | 建会话/发消息失败 | 同上 + `channel-runner` | 微信发一句话 / `/new` |
| C8 | 消息内容形状：`event.data.message.content[]`（含 `reasoning`/`tool-call` 片段） | 可能新增片段类型 | 内部推理被转发到微信 | `extractText`（过滤 reasoning/tool-call） | 发一句触发思考的提问 |
| C9 | 传输入口 host 必须是 `127.0.0.1:<port>`（cookie 按 authority 绑定） | — | 换成 localhost 时 cookie 不匹配 → 401 | `dsh-rpc.ctxOf` | 同上 |

### D. `$DSH_HOME` 磁盘布局

| # | 路径 | 归属 | 依赖方式 | 断裂表现 | 代码位置 |
|---|---|---|---|---|---|
| D1 | `storages/workspace.json`（`tables.workspaces[<workspaceId>] = {path,title,sessionIds,…}` + `global.workspaceIds` 顺序） | dsh | **读**：工作区列表兜底 + 会话→项目目录映射 | 工作区/项目目录取不到 | core `workspace-store.js`、main.swift `persistedWorkspacePath` |
| D2 | `skills/<name>/SKILL.md` | dsh 发现，我们写入 | 启动时安装内置 skill（缺失即装、托管标记、用户改过不覆盖） | 内置 skill（web-dev-tools / repo-knowledge / issue-resolve）不被 dsh 发现 | `SkillInstaller.swift` |
| D3 | `channels/*` | **我们**（放在 dsh home 下） | 凭据/会话映射/消息归档/workspace 启用/state | 通道配置丢失 | core `channel-store/sessions/runner` |
| D4 | `shell/config.json` | **我们** | 壳层设置（语言/主题/面板宽度/registry…） | 面板宽度、语言回默认 | core `settings.js` + `ShellConfig.swift` |
| D5 | `browser-api.port` | **我们** | 浏览器面板 REST 端口文件的约定位置，供 web-dev-tools 技能发现 | Agent 技能找不到浏览器面板 API | main.swift 启动段 + `SkillInstaller` 文案 |
| D6 | `sessions/`、`credentials`、`profiles` | dsh | 目前**不直接读**（仅 dsh 自己用） | — | — |
| D7 | dev 隔离：`~/.dsh-dev`（+ `browser-dev` 迁移） | 我们 | 开发版独立 home，避免污染正式版 | dev 读到正式版数据 | main.swift `applyDevIsolation()` |

### E. 分发、升级与运行时

| # | 依赖的 dsh 契约 | 版本变化/风险 | 断裂表现 | 代码位置 | 验证方式 |
|---|---|---|---|---|---|
| E1 | npm 包 `@deepseek-ai/dsh` + 运行时整树嵌入 `Contents/Resources/runtime/dsh` | 包结构/lib 布局变化 | 找不到 `lib/bin.js` | `build-app.sh`（`DSH_PACKAGE_SPEC` 两处 + 打印行） | 构建产物 `runtime/dsh/node_modules/@deepseek-ai/dsh/package.json` |
| E2 | 本机/内置 Node ≥ **22.0.0**（dsh rc.6 起 zstd ESM 导出等） | 若提高到 24+ | 启动即崩/加载插件失败 | main.swift `resolveNode()`（跳过过老系统 node） | 日志 `skipping too-old system node` |
| E3 | dsh 包内 npm 依赖需在安装后跑 lifecycle（`postinstall` 找 `node`） | PATH 精简时 exit 127 | 升级中断 | 升级子进程前置 PATH 注入 | 升级日志 |
| E4 | 版本自描述：安装后读 `package.json version`；registry 版本列表选「下一个候选」 | 版本号/发布渠道变化 | 升级判定错 | core `upgrade.js`（`latestVersion/nextStepTarget/pinSpec/buildPrefetchArgs/buildApplyArgs`） | `ohmy-core upgrade …` |
| E5 | 升级方式：**原地 `npm install <spec>` 装进 `runtime/dsh`，不重装 App** | 上游若改为非 npm 分发 | 升级功能失效 | main.swift `DSHUpdater` + `upgrade.js` | 升级一次，看 `runtime/dsh` 版本 |
| E6 | 「重启服务即生效」：升级后杀自己拉起的 dsh web 并重拉 | dsh 若引入缓存/守护进程 | 版本升级了但 UI 还是旧的 | main.swift 升级后重启段 | `app.log` |

### F. 侧通道（与 dsh 解耦，但同属运行时）

| # | 项 | 说明 | 代码位置 |
|---|---|---|---|
| F1 | CEF/Chromium 浏览器面板（CDP 默认 9333，dev 9433） | 自包含，不依赖 dsh | `BrowserPanel/BrowserCDP/CEFShim` |
| F2 | Browser API HTTP（默认 3081，dev 4081） | 我们自己的服务 | `BrowserAPI.swift` |
| F3 | 终端 PTY + ANSI 模拟器 | 自包含（core `ansi.js` 与 Swift 复用同一测试） | `TerminalPanel.swift` |
| F4 | 项目目录来源优先级：`ProjectDirectory`（跟随 web 会话）→ 磁盘 `workspace.json` → home | 与 C4/D1 联动 | main.swift `resolveProjectDirectory` |

> **不属于「升级影响」**但常被误判：dsh 上游模型/工具行为变化导致的输出风格差异、微信/钉钉平台自身接口变化。


## 4. 实例复盘：0.1.1 → 0.1.2-rc.1（2026-09，已实测）

### 4.1 dsh 侧变了两件事

1. **Web 鉴权**：`/api` 只认 cookie；`GET /?token=<launch token>` → 303 + `dsh-auth-*`；token 每进程随机。
2. **内部 API 换代**：点号方法名 → **斜杠端点** + `payload.args.<request|_request>`；`session.history/search` 移除（改 `session/page`）；**`workspace.list` 移除**（改 `workspace/follow` 流式）。

### 4.2 逐项影响与处置

| 面 | 0.1.2 下的表现 | 处置 | 状态 |
|---|---|---|---|
| A1/A2/A4 | 裸 GET 401 → App 判启动失败、WebView 白屏 | 读自报的带 token 地址做就绪判定 + 加载该地址 | 已修 |
| A3 | 外部已启动的 0.1.2 实例判不可用 → 另起实例 | 按设计不复用（同 `DSH_HOME` ⇒ 同一份 workspace/会话/设置，复用只省一个进程）；`isDSHAuthenticated()` 把这个判断写进日志，避免「怎么又起了一个实例」无从解释 | 已定论 |
| B1–B3 | web 切会话不通知壳层 → 项目目录不跟随 | 注入脚本同时认点号/斜杠 method 与 `payload.args` | 已修 |
| B7 | 点文件链接不再被拦截 | 拦截脚本加 `session/openWorkspacePath` + `args.request.path` | 已修 |
| B5 | 面板点开会话标题解析 404 | fetch 路径改 `/api/session/list` | 已修（DOM 点行本就可用） |
| C1–C3 | **所有 native/子进程 RPC 401/404** | core 新增 `dsh-rpc.js`（双面 + cookie）；runner 用 `--dsh-token` | 已修 |
| C4 | **微信 `/wks` 回「没有可用的 workspace」**（用户主诉） | 工作区列表读 `storages/workspace.json` 兜底 —— **无 token 也能列出** | 已修 |
| C5/C6/C7 | `/ses` 空、回复读不到、建会话失败 | session/list + session/page（cursor）+ `requestId` | 已修 |
| C8 | 内部推理可能被转发 | extractText 过滤 reasoning/tool-call | 已修 |
| B1/B2 会话 cwd / 项目目录 | `/api/session.list` 404 → cwd 取不到 | 磁盘 `workspace.json` 兜底（按 sessionId 找所属 workspace） | 已修 |
| **Swift 原生 RPC（WikiRPC / IssueRunnerPanel / DSHSessionRPC）** | 点号端点 + **无 cookie** → wiki 生成、issue-runner 建会话/发消息、`workspace.list` 扫描全部失败（DSHSessionRPC 有磁盘兜底，其余没有） | 新增 `DshWebRPC.swift`：原生侧同一套双面 + token→cookie；`workspace.list` 走 `DshWorkspaceStore`（RPC → 磁盘）；三处消费者全部改接 | 已修 |
| 注入脚本 | 若客户端改传输（WebSocket/Gateway）则拦不到 | 目前客户端仍走 fetch | 风险待观察 |

### 4.3 定位手法（下次照做）

1. 先看**症状日志**：`~/Library/Logs/oh-my-dsh/app.log`、`server.log`（含 token 行）、`channel-runner-<id>.log`。
2. 拿 token 直接打接口（cookie jar）：
   `TOK=$(sed -n 's#.*/?token=\([A-Za-z0-9_-]*\).*#\1#p' ~/Library/Logs/oh-my-dsh/server.log | head -1)`
   `curl -s -i "http://127.0.0.1:<port>/?token=$TOK"` → 抄下 `dsh-auth-*` 到 `-b` cookie；
   `curl -s -b "$JAR" -X POST http://127.0.0.1:<port>/api/session/list -d '{"type":"client-request","rpcId":"x","method":"session/list","payload":{"args":{"_request":{}}}}'`。
3. **端点清单从包里读，不靠猜**：`runtime/dsh/node_modules/@deepseek-ai/*/lib/typert.host.js` 里的 `id: '@deepseek-ai/<pkg>#<service>/<method>'` + 参数条目的 `name: '<request|_request>'` 即参数包裹字段名。
4. 判断鉴权实现：`dsh-client-connection/lib/index.js` 的 `requestRejection` / `BrowserAuth.isAuthenticated`（是否只认 cookie）。


## 5. 每次 dsh 升级的执行清单（SOP）

### 升级前
- [ ] 看上游变更：`npm view @deepseek-ai/dsh@<ver>` / 解包 `lib` diff；重点搜 `requestRejection`、`typert.host.js` 端点名、`storages/` 路径。
- [ ] 确认目标版本与 Node 要求（E2），以及是否仍是 npm 原地升级（E5）。
- [ ] **在隔离环境先升**：开发版（`~/.dsh-dev`）先行，正式版不动（A/D7）。

### 升级后（逐面验证，失败即按 §3 定位）
- [ ] A 启动：App 起得来、日志有 `dsh web is up on …/?token=…`、WebView 首屏正常（非 401）。
- [ ] B 注入：切会话 → `ProjectDirectory` 跟随（终端/预览/wiki/tasks 目录变）；面板点会话行 → web 跳转；点文件链接 → 文件面板打开。
- [ ] C 频道：微信 `/help` `/ping` `/status` `/wks` `/ses` `/new …` + **发一句普通消息**看是否回推答案（覆盖 C5–C7）。
- [ ] C 工作区：`/wks` 能列出**面板已启用**的 workspace（覆盖 C4）。
- [ ] D 布局：`storages/workspace.json` 仍存在且字段未变（D1 兜底是否还有效）。
- [ ] E 升级链路本身：`ohmy-core upgrade` 能判定「下一步」；升级后服务重启、版本事实刷新。
- [ ] 其它面板回归：wiki 生成、issue-runner 跑一条、浏览器面板、终端、文件预览。

### 自动化（CI 已有，勿漏）
- [ ] `node --test core/tests/`（当前 212 全绿）
- [ ] `tests/wiki-panel/run.sh`、`tests/channel-panel/run.sh`、`tests/browser-panel/run.sh`、`tests/skills/run.sh`、`tests/terminal-emulator/run.sh`
- [ ] `scripts/local-ci.sh swift`（swiftc 全量编译检查）；发版走 `scripts/local-ci.sh dev` / `local-release.sh`

### 收尾
- [ ] 更新 `docs/plans/dsh-012rc1-compat-audit.md`（或新起一份审计）与本清单 §3/§4。
- [ ] `CHANGELOG.md` 的 `[Unreleased]` 记录「适配点 + 修复点」，注明受影响面板。
- [ ] 版本推进：`scripts/version.sh` 的 `FALLBACK_VERSION/BUILD`、`build-app.sh` 的 `DSH_PACKAGE_SPEC`（两处 + 打印行）、README/`docs/productization.md` 的版本矩阵。


## 6. 遗留风险与再评估触发条件

| 风险 | 说明 | 触发再评估 |
|---|---|---|
| ~~R1 Swift 原生 RPC 无 cookie~~（2026-09-10 已修） | `WikiRPC`、`IssueRunnerPanel`、`DSHSessionRPC` 现统一走 `DshWebRPC.swift`：先试 0.1.2 斜杠端点（`payload.args.<request\|_request>`）再回退点号方法，按**端点**记忆所选面；token 由壳层 `ServerManager.webToken` 注入，经一个**独立 ephemeral URLSession** 访问 `/?token=…` 种下 `dsh-auth-*` cookie（WebView 的 cookie 在 WebKit 数据存储里、与 URLSession 的 `HTTPCookieStorage` 互不共享，故必须自行换取），401 时自动重换一次；`workspace.list` 在 0.1.2 不存在，回退读 `$DSH_HOME/storages/workspace.json`（`DshWorkspaceStore`，与 core 同一份契约） | 已修；若是**复用外部已启动**的 0.1.2 实例仍拿不到 token（见 R2），此时原生 RPC 退化为磁盘兜底 |
| ~~R2 复用外部 0.1.2 实例~~（2026-09-10 定论：不做） | 外部实例的 token 只存在于它自己的 stdout，无法获取；但**只要 `DSH_HOME` 相同，壳层自拉起的实例与外部实例就是同一份数据**（workspaces / sessions / settings / channels 全在 `$DSH_HOME` 下），复用只省一个进程，不值当。**唯一注意**：同一个 `DSH_HOME` 上不要长期并行跑两个 dsh web（两者都往同一批文件持久化），验完外部实例就关掉它 | 只有出现「必须与某个已启动实例共享**内存态**（未落盘状态、正在跑的 turn 视图）」的需求时才重估 |
| R3 注入脚本依赖 fetch + DOM | B1/B5：客户端改传输或改版侧栏结构即失效 | 升级后 B 面验证项失败 |
| R4 `workspace.json` 兜底是私有布局 | D1 属 dsh 内部持久化格式，可能改名（如 `storages/` 结构调整） | 工作区列表突然为空且接口也没变 |
| R5 单一版本策略 | 只为「内置版本」做适配，老版本兼容靠回退（C1）；回退在两侧都失效时会静默出空结果 | 引入第二个受支持版本时重估 |


## 7. 参考

- 实战审计（0.1.2 逐项状态与实测契约）：`docs/plans/dsh-012rc1-compat-audit.md`
- 频道侧实现与状态：`docs/channel-status.md`、`docs/channel-commands.md`、`docs/channel-project-switch.md`
- 产品化与版本策略：`docs/productization.md` §8；发布流程：`docs/release-process.md`
- 代码锚点：`platforms/macos/src/main.swift`（ServerManager / DSHSessionRPC / 注入脚本 / 升级）、`platforms/macos/src/WikiPanel.swift`（WikiRPC）、`platforms/macos/src/IssueRunnerPanel.swift`、`core/lib/dsh-rpc.js`、`core/lib/workspace-store.js`、`core/lib/session-driver.js`、`core/lib/channel-runner.js`、`core/lib/upgrade.js`、`platforms/macos/build-app.sh`
- 仓库知识库：`.dsh/wiki/modules/main.md`、`.dsh/wiki/modules/channel-panel.md`、`.dsh/wiki/data-model.md`（RPC 信封）

