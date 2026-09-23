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
| A3 | 外部已启动实例（4080/3080 上的 `dsh web`） | 0.1.2 起 `/api` 只认「本进程 launch token 换来的 cookie」，**别人的实例永远拿不到 token** | 若去复用：`webToken == nil` → 所有原生 RPC 401 → wiki 生成/任务面板静默失败（§4.4 实战） | `ServerManager.start()`：**复用逻辑已于 2026-09-12 整体删除，永远自拉起**；对照 `reapRecordedOrphan()`（回收自己上次残留的实例） | 启动 `app.log` 必须是 `using node=… port=<n>` + `dsh web is up on http://127.0.0.1:<n>/?token=…`（**不应**再出现 `reusing existing dsh web …`） |
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
| B9 | 输入框（composer）DOM + 节点登记表：`[data-composer-input]`（contenteditable）、`el.__lexicalEditor`（Lexical 挂在根元素上）、`editor._nodes[type].klass`、`editor._pendingEditorState._nodeMap["root"]`、chip 类型名 `reference-chip`（字段 `{source, ref, label, appearance, clipboardText}`） | 上游换编辑器（textarea / 另一套富文本）、改槽位标记、或改 chip 节点类型名与字段 | Files 面板右键「添加到对话」**不插入**（面板/日志报 `no-composer` / `no-editor` / `unknown-composer`，不静默） | `composerReferenceScript` + `insertComposerReference()` | 右键任一文件 → 输入框出现引用 chip（或 `app.log: composer reference inserted (chip)`）；自动化见 §5 的 B 面 |

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
| D2 | `skills/<name>/SKILL.md` | dsh 发现，我们写入 | 启动时安装内置 skill（缺失即装、托管标记、用户改过不覆盖）；技能面板在**非内置**技能上改写 `user-invocable` / `disable-model-invocation` 两行 | 内置 skill（web-dev-tools / repo-knowledge / issue-resolve）不被 dsh 发现；开关写了但 dsh 不认 | `SkillInstaller.swift`（安装）、`SkillsCore.swift`（frontmatter 读写/扫描）、`SkillSources.swift`（安装/移除） |
| D2b | 技能调用 frontmatter 键名：`user-invocable`（默认 true）、`disable-model-invocation`（默认 false）；**旧驼峰键会让 dsh 忽略整个技能** | 键名若改（或默认值反转），面板开关的语义/写出的键会失配 | 开关看似生效但技能可见性不变；写错键还会让技能整个消失 | `SkillsCore.swift` `SkillFrontmatterIO`（只写规范键、切回默认即删键）；`tests/skills-panel/run.sh` | 改一个技能的两个开关 → dsh 新会话里模型目录/用户技能列表随之变化 |
| D2c | 技能根与优先级：`<ws>/.dsh/skills`(100) > `<ws>/.agents/skills`(200) > `$DSH_HOME/skills`(400) > `~/.agents/skills`(500) | 新增/调整根会让面板的级别标注与去重判断失准 | 面板标错级别、或把被遮蔽的技能当成生效技能 | `SkillsCore.swift` `SkillRoots` / `SkillScanner`（rank 升序 + `shadowedBy`） | 面板「已安装」列表中同名技能的级别与被遮蔽标记 |
| D2d | `shell/skills.json`（我们自己的）：registries / invocation / installed | 与 dsh 无关（壳层自有） | 面板设置丢失（registry、开关记录） | `SkillsCore.swift` `SkillStore`；缺失即按空配置处理 | 改一个 registry 或开关后重启 App，设置仍在 |
| D3 | `channels/*` | **我们**（放在 dsh home 下） | 凭据/会话映射/消息归档/workspace 启用/state | 通道配置丢失 | core `channel-store/sessions/runner` |
| D4 | `shell/config.json` | **我们** | 壳层设置（语言/主题/面板宽度/registry…） | 面板宽度、语言回默认 | core `settings.js` + `ShellConfig.swift` |
| D5 | `browser-api.port` | **我们** | 浏览器面板 REST 端口文件的约定位置，供 web-dev-tools 技能发现 | Agent 技能找不到浏览器面板 API | main.swift 启动段 + `SkillInstaller` 文案 |
| D6 | `sessions/<workspace-slug>/<session-id>/`：**会话日志文件名是「世代命名」**（世代 0 = `session.jsonl`，之后 `session.v<N>.jsonl`；压缩再加 `.zstd`） | dsh | **读**（审查面板的审计数据源，见 D8） | 新会话列不出来（空面板）、迁移过的会话读到**冻结归档**而停旧 | `core/lib/review-log.js` `sessionLogCandidates()` |
| D8 | `sessions/` 里的当前世代：0.1.2 写 `session.jsonl`，**0.1.5 写 `session.v3.jsonl`** | dsh | **读**：按规范名枚举 + **世代最大者优先**（同代压缩优先） | `review: listed 0/N sessions` / `audit FAILED`（不报错、只是空） | `core/lib/review-log.js` `parseSessionLogName` / `sessionLogCandidates`；`core/tests/review-log.test.js` |
| D7 | dev 隔离：`~/.dsh-dev`（+ `browser-dev` 迁移） | 我们 | 开发版独立 home，避免污染正式版 | dev 读到正式版数据 | main.swift `applyDevIsolation()` |
| D9 | `credentials`、`profiles` | dsh | 目前**不直接读**（仅 dsh 自己用） | — | — |

### E. 分发、升级与运行时

| # | 依赖的 dsh 契约 | 版本变化/风险 | 断裂表现 | 代码位置 | 验证方式 |
|---|---|---|---|---|---|
| E1 | npm 包 `@deepseek-ai/dsh` + 运行时整树嵌入 `Contents/Resources/runtime/dsh` | 包结构/lib 布局变化 | 找不到 `lib/bin.js` | `build-app.sh`（`DSH_PACKAGE_SPEC` 两处 + 打印行） | 构建产物 `runtime/dsh/node_modules/@deepseek-ai/dsh/package.json` |
| E2 | 本机/内置 Node ≥ **22.0.0**（dsh rc.6 起 zstd ESM 导出等） | 若提高到 24+ | 启动即崩/加载插件失败 | main.swift `resolveNode()`（跳过过老系统 node） | 日志 `skipping too-old system node` |
| E3 | dsh 包内 npm 依赖需在安装后跑 lifecycle（`postinstall` 找 `node`） | PATH 精简时 exit 127 | 升级中断 | 升级子进程前置 PATH 注入 | 升级日志 |
| E4 | 版本自描述：安装后读 `package.json version`；registry 版本列表选「下一个候选」 | 版本号/发布渠道变化 | 升级判定错 | core `upgrade.js`（`latestVersion/nextStepTarget/pinSpec/buildPrefetchArgs/buildApplyArgs`） | `ohmy-core upgrade …` |
| E5 | 升级方式：**原地 `npm install <spec>` 装进 `runtime/dsh`，不重装 App** | 上游若改为非 npm 分发 | 升级功能失效 | main.swift `DSHUpdater` + `upgrade.js` | 升级一次，看 `runtime/dsh` 版本 |
| E6 | 「重启服务即生效」：升级后杀自己拉起的 dsh web 并重拉 | dsh 若引入缓存/守护进程 | 版本升级了但 UI 还是旧的 | main.swift 升级后重启段 | `app.log` |
| **E7** | 运行时**依赖闭包**：dsh 用 caret 范围声明 cordis 插件（`^1.0.17` 等），`npm install <spec>` 会装**当天最新的 1.x** | 上游一发新版插件，**旧 dsh 就可能起不来**（实测 0.1.2-rc.1 + `cordis-plugin-hmr` 1.0.19 → 启动即抛 `user patch-layer watching requires the Cordis HMR service`） | 构建"成功"、App 里 dsh web 直接退出（启动失败/白屏） | `build-app.sh`：`platforms/macos/runtime-locks/<spec>/package-lock.json` + **`npm ci`**，装完后做**启动冒烟**（失败即构建失败） | 构建日志 `using committed runtime lock …` + `smoke: dsh web came up` |

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
| A3 | 外部已启动的 0.1.2 实例判不可用 → 另起实例 | 按设计不复用（同 `DSH_HOME` ⇒ 同一份 workspace/会话/设置，复用只省一个进程） | 2026-09-12 升级为**彻底删除复用分支**（原实现仍会复用一个「探针被骗过」的实例，见 §4.4） |
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

### 4.4 复盘：复用别人的 dsh web → wiki 生成静默失败（2026-09-12）

**症状**：装好的正式版（1.14.0）点 Wiki 面板的「+（生成或更新知识库）」无任何反应，`app.log` 里既没有 `wiki generation started` 也没有报错；开发版同一操作正常。

**根因（三段叠在一起）**：

1. **3080 被自己上次的残留实例占着**：`applicationWillTerminate` 只停「本次自拉起的」服务，崩溃 / 强杀 / 复用过的实例都留着。实测 `lsof -p <pid>` 显示 3080 的进程 `stdout/stderr = ~/Library/Logs/oh-my-dsh/server.log`、`cwd = HOME`——正是 `ServerManager` 拉 dsh web 的写法，即**壳层自己上次留下的孤儿**（同机另有 5 个同类残留）。
2. **探针被骗，误判为「可复用的老实例」**：`isDSHServing()` 用 `URLSession.shared`，它共享 app 持久 cookie 存储；那里躺着一张仍未过期的 `dsh-auth-*`（authority `127.0.0.1:3080`，30 天有效期）。实测同一 URL：
   ```
   GET http://127.0.0.1:3080/                → 401
   GET http://127.0.0.1:3080/ + 那张 cookie   → 200，页面含 __DSH_BOOT__
   ```
   于是「页面里有 `__DSH_BOOT__` ⇒ 老版本、无需鉴权、可以复用」判错——它其实是需要 token 的 0.1.2。（磁盘缓存同理可骗过探针。）
3. **复用即无 token**：复用分支写死 `entryURL = URL(string: "http://127.0.0.1:3080")`（不带 `?token=`）→ `server.webToken == nil` → `DshWebRPC.token = nil` → 而 `DshWebRPCTransport` 是**独立 ephemeral session**（自己的空 cookie 存储）→ `session/create`、`session/prompt` 全部 **401** → `WikiRPC.createSession` 返回 nil → 旧 `generationFailed()` 在「还没有在途生成」时**什么都不做** → 点了没反应。旁证：该次启动的 channel runner 命令行里**没有 `--dsh-token`**。

**为什么开发版复现不出来**：`applyDevIsolation()` 当年强制 `DSH_NATIVE_FORCE_SPAWN=1`，**跳过复用分支**，永远自拉起并拿到 token。

**处置（本次）**：

- `ServerManager.start()`：**删除复用分支**，永远自拉起（`DSH_NATIVE_FORCE_SPAWN` 一并移除）；
- 探针改为**专用 session**（`httpCookieStorage = nil`、`httpShouldSetCookies = false`、`.reloadIgnoringLocalCacheData`、`urlCache = nil`），不再被持久 cookie / 磁盘缓存欺骗；
- 新增 `reapRecordedOrphan()`：拉起时把 `{pid, port, token}` 记到 `$DSH_HOME/shell/dsh-web.json`，下次启动若该实例仍在（用 token 探活证明是自己的）→ 先回收再拉起，杜绝「上次没关干净」累积；
- `app.log` 在 `webToken == nil` 时明确告警（原生 RPC 将 401），不再静默；
- Wiki 面板在「会话压根没起来」时状态条显示「生成失败（详见日志）」并写日志（不再是一次无效点击）；
- `DshWebRPC`：只有端点真的不存在（404/405）才降级到点号方法，超时/401/业务错误不再把该端点永久钉死；cookie 换成功才记为已认证；`WikiRPC.createSession` 在 workspaceId 被拒时回退 `cwd` 建会话（保证「能在对应 workspace 起出会话」）。

**教训**：① 「能不能复用」不能用「页面长什么样」来判断，必须用「我有没有它的 token」；② 任何**把失败记成状态**的缓存（端点选面、认证标记）都会把一次抖动放大成永久故障；③ 复用会让生命周期变成别人的——**自己拉起的自己收**，收不了就下次启动收。

### 4.3 定位手法（下次照做）

1. 先看**症状日志**：`~/Library/Logs/oh-my-dsh/app.log`、`server.log`（含 token 行）、`channel-runner-<id>.log`。
2. 拿 token 直接打接口（cookie jar）：
   `TOK=$(sed -n 's#.*/?token=\([A-Za-z0-9_-]*\).*#\1#p' ~/Library/Logs/oh-my-dsh/server.log | head -1)`
   `curl -s -i "http://127.0.0.1:<port>/?token=$TOK"` → 抄下 `dsh-auth-*` 到 `-b` cookie；
   `curl -s -b "$JAR" -X POST http://127.0.0.1:<port>/api/session/list -d '{"type":"client-request","rpcId":"x","method":"session/list","payload":{"args":{"_request":{}}}}'`。
3. **端点清单从包里读，不靠猜**：`runtime/dsh/node_modules/@deepseek-ai/*/lib/typert.host.js` 里的 `id: '@deepseek-ai/<pkg>#<service>/<method>'` + 参数条目的 `name: '<request|_request>'` 即参数包裹字段名。
4. 判断鉴权实现：`dsh-client-connection/lib/index.js` 的 `requestRejection` / `BrowserAuth.isAuthenticated`（是否只认 cookie）。


### 4.5 实例复盘：0.1.2-rc.1 → 0.1.5-rc.2（2026-09-23 完成审计；**升级暂缓**，等会话快照/回退功能上线后执行）

**这次上游只动了一处会让壳层静默出错的地方：会话日志的文件名。**

- **静态比对**（0.1.2-rc.1 的 223 个 `@deepseek-ai/*` 包 vs 0.1.5-rc.2 的 233 个）：RPC 端点**只增不减**
  （新增 `workspaceFiles/*`、`fileUploads/upload`、`sessionFeedback/record`、`goals/get`），壳层用到的端点
  一个没消失，参数包裹字段（`_request` / `request` / `parentSessionId`）逐个核对**完全一致**；`dsh-auth-*`
  cookie、`dsh web: <带 token 的 URL>` 就绪行、`workspace.json` 的 domain `workspace` v2、技能四根与
  rank(100/200/400/500)、frontmatter 规范键都未变；客户端仍走 `window.fetch` + `client-request` 信封，
  侧栏仍是 `[role="treeitem"]` + `sessionRow`，文件打开仍是 `session/openWorkspacePath`。
- **唯一断裂**：会话日志按 **Session 格式世代**命名（`session.jsonl` → `session.v3.jsonl`，`.zstd` 叠加），
  0.1.5 新建会话直接写**世代 3**，迁移过的老会话把原来的文件留成冻结归档。审查面板只认世代 0 ⇒ 新会话
  列不出来（`review: listed 0/N sessions` + `audit FAILED`），老会话停旧。修法与用例见 §6.4 / R7。
- **升级 SOP 增加两条核对项**：D 面「活日志文件名 + 审查面板能否列出并审计」、收尾「八面板全量扫描」
  （新增 QA 钩子 `DSH_PANEL_TEST`，一次跑完八个面板并各落一张截图）。
- **逐面实测记录**（含命令与日志原样）：`docs/plans/dsh-015rc2-compat-audit.md`。

## 5. 每次 dsh 升级的执行清单（SOP）

### 升级前
- [ ] 看上游变更：`npm view @deepseek-ai/dsh@<ver>` / 解包 `lib` diff；重点搜 `requestRejection`、`typert.host.js` 端点名、`storages/` 路径。
- [ ] 确认目标版本与 Node 要求（E2），以及是否仍是 npm 原地升级（E5）。
- [ ] **在隔离环境先升**：开发版（`~/.dsh-dev`）先行，正式版不动（A/D7）。

### 升级后（逐面验证，失败即按 §3 定位）
- [ ] A 启动：App 起得来、日志有 `using node=… port=<n>` + `dsh web is up on …/?token=…`、WebView 首屏正常（非 401）；**不应出现 `reusing existing dsh web`**（复用已删除），也不应出现 `advertised no launch token` 告警。
- [ ] B 注入：切会话 → `ProjectDirectory` 跟随（终端/预览/wiki/tasks 目录变）；面板点会话行 → web 跳转；点文件链接 → 文件面板打开；**右键文件夹「添加到对话」→ 输入框出现引用 chip**（B9；无头复现见下）。
- [ ] C 频道：微信 `/help` `/ping` `/status` `/wks` `/ses` `/new …` + **发一句普通消息**看是否回推答案（覆盖 C5–C7）。
- [ ] C 工作区：`/wks` 能列出**面板已启用**的 workspace（覆盖 C4）。
- [ ] D 会话日志：新建一个会话，看 `$DSH_HOME/sessions/<slug>/<id>/` 里**活日志的文件名**（世代名）是否仍是壳层认识的那一种；再看审查面板能否**列出**它、能否审计出一条真实会话的改动（R7；命令见 §6.4）。老会话被迁移后会同时存在冻结归档与活日志，面板必须读活的那份。
- [ ] D 布局：`storages/workspace.json` 仍在、`unit.version` 仍为 **2**、工作区数量与面板一致（R4；命令见 §6.2）——变了就要同时改 `core/lib/workspace-store.js` 与 `platforms/macos/src/DshWebRPC.swift` 的读取器并补用例。
- [ ] E 升级链路本身：`ohmy-core upgrade` 能判定「下一步」；升级后服务重启、版本事实刷新。
- [ ] 其它面板回归：wiki 生成、issue-runner 跑一条、浏览器面板、终端、文件预览。

### 自动化（CI 已有，勿漏）
- [ ] `node --test core/tests/`（当前 212 全绿）
- [ ] `tests/wiki-panel/run.sh`、`tests/channel-panel/run.sh`、`tests/browser-panel/run.sh`、`tests/skills/run.sh`、`tests/terminal-emulator/run.sh`
- [ ] `scripts/local-ci.sh swift`（swiftc 全量编译检查）；发版走 `scripts/local-ci.sh dev` / `local-release.sh`

### 收尾
- [ ] 八面板全量扫描（一条命令）：开发版启动时带
      `DSH_HOME=$HOME/.dsh-dev DSH_UI_DEBUG=1 DSH_PANEL_TEST="files,terminal,wiki,tasks,browser,channel,review,skills"`，
      每个面板会各落一张 `~/Library/Logs/oh-my-dsh/panel-<name>-debug.png`；逐张看（或 OCR）确认面板**真的渲染出内容**
      而不是空壳。此前只有六个单面板钩子，且缺的恰是没有快捷键、脚本点不到的 tasks 与 channel。
- [ ] `core/tests/` 全绿 + 面板测试套件（`scripts/local-ci.sh swift`）。
- [ ] 更新 `docs/plans/` 下最新的那份审计（本次：`docs/plans/dsh-015rc2-compat-audit.md`）与本清单 §3/§4。
- [ ] `CHANGELOG.md` 的 `[Unreleased]` 记录「适配点 + 修复点」，注明受影响面板。
- [ ] 版本推进：`scripts/version.sh` 的 `FALLBACK_VERSION/BUILD`、`build-app.sh` 的 `DSH_PACKAGE_SPEC`（两处 + 打印行）、README/`docs/productization.md` 的版本矩阵。


## 6. 遗留风险与再评估触发条件

| 风险 | 说明 | 触发再评估 |
|---|---|---|
| ~~R1 Swift 原生 RPC 无 cookie~~（2026-09-10 已修） | `WikiRPC`、`IssueRunnerPanel`、`DSHSessionRPC` 现统一走 `DshWebRPC.swift`：先试 0.1.2 斜杠端点（`payload.args.<request\|_request>`）再回退点号方法，按**端点**记忆所选面；token 由壳层 `ServerManager.webToken` 注入，经一个**独立 ephemeral URLSession** 访问 `/?token=…` 种下 `dsh-auth-*` cookie（WebView 的 cookie 在 WebKit 数据存储里、与 URLSession 的 `HTTPCookieStorage` 互不共享，故必须自行换取），401 时自动重换一次；`workspace.list` 在 0.1.2 不存在，回退读 `$DSH_HOME/storages/workspace.json`（`DshWorkspaceStore`，与 core 同一份契约） | 已修；2026-09-12 追加：只有 404/405 才降级（超时/401/业务错误不再把端点永久钉死）、cookie 换成功才记为已认证、workspaceId 被拒回落 `cwd` 建会话（§4.4） |
| ~~R2 复用外部实例~~（**2026-09-12 复用逻辑已整体删除**） | 外部实例的 token 只存在于它自己的 stdout，无法获取；复用必然 `webToken == nil` ⇒ 原生 RPC 全 401（§4.4 实战踩过）。现在 **永远自拉起**，并回收自己上次残留的实例（`$DSH_HOME/shell/dsh-web.json` + token 探活）| 只有出现「必须与某个已启动实例共享**内存态**（未落盘状态、正在跑的 turn 视图）」的需求时才重估 |
| **R3 注入脚本依赖 fetch + DOM**（**仍在**，且已实测出过坏点） | 三个注入脚本直接依赖 dsh web 客户端实现：fetch 形态与信封、方法名白名单、sessionId 位置、侧栏 `[role=treeitem].sessionRow` DOM、文件打开 RPC 端点。上游改传输（已有 WebSocket mux）或改 DOM 就**静默失效**。2026-09-10 实测发现 `sessionOpenerScript` 在 0.1.2 下一直是坏的（写死点号 method 打到斜杠端点，服务端 \`method does not match endpoint\`），已修为运行时双面 —— 详见 §6.1 | 升级后 B 面三项验证任一失败即命中 |
| **R4 `workspace.json` 兜底是私有布局**（**仍在**，已加护栏） | 兜底读的是 dsh 内部带 schema/版本号的私有域存储（`defineDomain({name:'workspace',version:2})`，还有 `pendingMutation` 恢复标记），上游可随时改字段/搬文件/升版本；读不懂 = 上述五处**静默变空**。现已加域名+版本校验、诊断日志、单一实现收口（见 §6.2） | 升级后 `unit.version` 变化，或工作区列表突然为空而接口没变 |
| **R7 会话日志「世代命名」**（0.1.5 实测踩过，已修） | 审查面板直接读 dsh 落盘的会话日志，而**文件名里编码了 Session 格式世代**（0.1.2 = `session.jsonl`，0.1.5 = `session.v3.jsonl`，压缩加 `.zstd`）；迁移过的会话还会把老文件留成冻结归档。只认世代 0 的名字 ⇒ 新会话一条都列不出来、老会话永远停旧，**不报错**。已改为按规范名枚举 + 世代最大者优先（见 §6.4） | 上游再提世代（出现 `session.v4.jsonl`）时**不需要改代码**（规则是「取最大世代」），但若换成非 `session*.jsonl` 的容器/目录名就要重估 |
| **R8 运行时闭包漂移**（2026-09-23 实测踩到，已修） | 只钉 `DSH_PACKAGE_SPEC` **不够**：dsh 的 cordis 工具链是 caret 范围，`npm install` 会随上游发版改闭包。实测重建 0.1.2-rc.1 得到 `cordis-plugin-hmr 1.0.19`（生产包是 1.0.17）后，**dsh 自己启动就抛** `user patch-layer watching requires the Cordis HMR service`（profile 的 `patchReload: "live"` 需要 HMR 服务，而新插件在旧 loader 下起不来）。已改为**提交 lockfile + `npm ci` + 构建期启动冒烟**（见 §6.5） | 每次新增/变更 dsh spec（要配一份新 lock）；上游换掉 cordis 工具链或改 profile 机制时重估 |
| R5 单一版本策略 | 只为「内置版本」做适配，老版本兼容靠回退（C1）；回退在两侧都失效时会静默出空结果 | 引入第二个受支持版本时重估 |
| **R6 `dsh-auth-*` cookie 按 authority 命名、无限累积**（2026-09-13 已修） | dsh 0.1.2+ 的浏览器 cookie 名 = `"dsh-auth-" + base64url(sha256(authority))`，authority 是**该实例的 host:port**；cookie 又不区分端口 ⇒ 每次自拉起一个新端口就多留一只（~226 B / 30 天 TTL），只增不减。累积 Cookie 头一旦把 **~2.1 KB 的插件 batch URL** 顶过 node 的 16 KiB 头上限（第 63 只）即 **431** → 界面「Failed to load plugins」。壳层已按「退出清理 + 启动清理 + node 头上限保险带」处置（见 §6.3） | 上游改 cookie 命名/鉴权载体（不再按 authority 派生），或 dsh 把插件 batch 换成多条更短 URL 后重估 |


### R3 详解：注入脚本（这是**当前唯一还在「静默失效」风险里**的一面）

壳层往 WKWebView 注入四个脚本（`rebuildWebView()` 里 `WKUserScript(injectionTime: .atDocumentStart)`，随每次重建 WebView 重装），它们**直接依赖 dsh web 客户端内部实现**，一旦上游改动就静默失效（没有报错、没有弹窗，只是某个功能不动作）：

| 脚本 | 依赖的 dsh web 细节 | 失效后的症状 | 现状 |
|---|---|---|---|
| `sessionTrackerScript`（B1–B4） | ① 一元 RPC 走 `window.fetch`；② 方法名白名单 `session.history/prompt/rename/selectModel` + `subagent(s).list`（点号与斜杠两套都认）；③ sessionId 在 `payload.args.*` 或 `payload.*`；④ **每次切会话必然发一次 `subagents/list`（带 parentSessionId）**这一非幂等时序 | web 里切会话 → 面板/终端/预览/wiki/tasks 的项目目录**不跟随** | ✅ 0.1.2 实测可用 |
| `sessionOpenerScript`（B5/B6） | ① 会话列表 RPC 的**请求形状**（斜杠 vs 点号、是否 `args` 包裹）；② `projections.values.title`；③ 侧栏 DOM：`[role="treeitem"]` + `className` 含 `sessionRow` + 行文本等于标题 + `aria-expanded` 折叠组 | 面板点会话行 → 不跳转（`[dsh-opener] no-session / row-not-found`） | ⚠️ **0.1.2 下原本就是坏的**（见下），已于 2026-09-10 修 |
| `previewInterceptorScript`（B7） | ① 文件打开走 fetch 的一元 RPC（`host.openPath` / `session/openWorkspacePath`）；② 路径在 `payload.args.request.path` 等位置；③ 能用 **假 `server-response`** 吞掉这次请求（客户端 promise 正常 resolve） | 点消息里的文件 → 不由面板打开，改弹系统默认应用（或什么都不发生） | ✅ 0.1.2 实测可用 |
| `composerReferenceScript`（B9） | ⚠️ 实测踩过：脚本正文里**不能出现单反斜杠转义**（Swift 字符串字面量会先吃掉它），必须保持「零转义」并靠 `tests/file-panel/run.sh` 的 lint 钉住 —— 详见 `docs/file-panel-composer-reference.md` §4.5。依赖：① 输入框 contenteditable 的槽位标记 `[data-composer-input]`；② Lexical 把实例挂在根元素上（`el.__lexicalEditor`）；③ 节点类可从 `editor._nodes[type].klass` 取（chip 类**模块私有**，只能从这里拿）；④ 更新回调里能读到 `editor._pendingEditorState._nodeMap["root"]` | 右键「添加到对话」不插入；若 chip **类型名对不上**则整个输入框功能不受影响（我们只在自己那条路径上失败并报原因） | ✅ 0.1.2-rc.1 实测可用（WKWebView 内插入 `reference-chip`，状态 JSON 含 `ref`/label，装饰器渲染出 chip；见 `docs/file-panel-composer-reference.md`） |

**已实测确认的坏点（0.1.2-rc.1，2026-09-10）**：`__dshOpenSession` 当时固定发 `POST /api/session/list` 但 body 里写 `method:"session.list"`、payload 也不包 `args`，服务端直接拒绝：

```
gateway/bad-request: method "session.list" does not match endpoint "session/list"
```

而且它在 0.1.1 上同样不通（那条斜杠路径不存在）—— 一个写死单版本形状的注入脚本，**两个世代各坏一次**。已改为运行时双面：先按 0.1.2 形状（`session/list` + `payload.args._request`）请求，拿不到再回退点号（`/api/session.list` + `payload`），并对失败原因打 `[dsh-opener]` 日志。

**为什么这类风险难发现**：三个脚本都是「成功时无感、失败时无声」。现有可观测手段：`DSH_UI_DEBUG=1`（新增：页面加载后打印 `dsh injected bridges: {tracker, opener, preview, rows}`）、`DSH_SESSION_DEBUG=1`（dump `__dshSessionSeen` / 最后跟踪到的会话）、`DSH_PREVIEW_DEBUG=1`（自检拦截器是否装上、并伪造一次 `host.openPath` 验证）、页面 console 里的 `[dsh-opener]` 日志。

**升级时的判据（写进 §5 的 B 面验证）**：切会话看目录是否跟随 → 面板点会话行看 web 是否跳转 → 点文件链接看是否在文件面板打开；三项任一失败即 R3 命中。真要大改时，替代方案是**放弃 hook HTTP 层**，改为在页面内直接读 dsh 客户端自己的状态（或让 core 通过 dsh API 查询），见审计文档 §四.3。

### R4 详解：`workspace.json` 兜底是 dsh 的**私有布局**

**为什么必须用它**：dsh ≥ 0.1.2 删掉了 `workspace.list`，工作区改由 `workspace/follow` **流式**下发（是长连接流，不适合一次性读取）。而壳层有三处**必须**拿到「有哪些工作区」：频道 `/wks` 与门控、面板项目目录解析、wiki/issue-runner 的工作区归属。唯一可离线枚举的来源，就是 dsh 自己持久化的那份存储。

**我们依赖的是什么**（`$DSH_HOME/storages/workspace.json`）：

```json
{
  "unit":   { "name": "workspace", "version": 2 },
  "global": { "initialized": true, "workspaceIds": ["<id>", "…"], "archivedSessionIds": [], "pendingMutation": {…}? },
  "tables": { "workspaces": { "<workspaceId>": { "path", "title", "sessionIds", "createdAt", "updatedAt" } } }
}
```

**问题所在**：这不是 API，而是 dsh 内部由 `defineDomain({ name: "workspace", version: 2, … })` 定义的**带 schema 的私有域存储**（`@deepseek-ai/dsh-workspace/lib/invariant.js`）。它自带版本号（v2）、zod 校验，甚至还有 `pendingMutation` 这种「两次写入之间被打断」的恢复标记 —— 换句话说，**上游随时可能改字段名、搬走文件、或把 version 提到 3 并做迁移**，而这一切不会有任何兼容性承诺或变更通知。我们的读取器一旦读不懂，表现就是这个兜底「静默变空」。

**会静默空掉的五处**（都不报错，只是功能不可用）：

| 消费者 | 断裂表现 |
|---|---|
| 频道 `/wks` | 回「没有可用的 workspace」 |
| 频道门控 `isEnabledForRoot` | 路径列表空 → 普通消息被回「该项目未启用该通道」 |
| 频道 `/ses` | `listWorkspaceSessions` 拿不到 workspace 的 `sessionIds` → 会话列表空 |
| 面板项目目录（终端/预览/wiki/tasks） | `persistedWorkspacePath` 取不到 → 退回 home |
| wiki / issue-runner | `resolveWorkspaceId` 为 nil → 会话落到 Ungrouped；`listWorkspacePaths` 空 |

另外三个**次要但真实**的坑：

1. **它是内存注册表的落盘副本**：dsh 以内存表为准、变更时刷盘；我们读到的可能比运行中的服务慢一拍（刚建的工作区还没落盘），或在**同 DSH_HOME 跑两个实例**时读到另一个实例写下的内容（见 R2 的注意点）。
2. **写入不是单条原子事务**：`global.workspaceIds`（顺序）与 `tables`（记录）是两次写，中间被打断会留下 `pendingMutation`；dsh 启动时会自我修复（`validateStoredState`），我们读到中间态时可能看到「顺序里有、记录里没有」的工作区（已过滤掉，不会崩，但会少一项）。
3. **恢复标记/归档语义**：`archivedSessionIds`、`pendingMutation` 我们**不解释**，只读 path/title/sessionIds。

**已做的缓解（不是修复，是让失败可见 + 收口）**：

- **域名校验 + 版本校验**：core 与 Swift 两侧读取器都会检查 `unit.name === "workspace"` 与 `unit.version === 2`；版本对不上时**仍然尽力解析**（形状可能兼容），但会明确报出来：
  ```
  [workspace-store] persisted workspace store …/storages/workspace.json is domain workspace v3,
                    this build understands v2 — read best-effort
  ```
  形状意外（没有 `tables.workspaces`）同样报 `unexpected shape`；**文件不存在则保持安静**（dsh ≤ 0.1.1 本来就正常没有它）。
- **日志出口**：core 侧走频道 runner 日志（`~/Library/Logs/oh-my-dsh/channel-runner-<id>.log`），Swift 侧走 `app.log`（`AppLog`）——不再出现「工作区列表莫名空了但日志里什么都没有」。
- **单一实现收口**：原先有**三份**各自解析这个私有格式的代码（core `workspace-store.js`、Swift `DshWorkspaceStore`、`main.swift` 的 `persistedWorkspacePath`）。现在 `main.swift` 那份改为调用 `DshWorkspaceStore`，只剩 core 与 Swift 两处（跨语言无法合并），上游一改只需动这两处。
- **测试钉住契约**：core 4 条 + Swift 4 条用例覆盖「版本不匹配仍尽力解析并报错」「形状意外报错」「文件缺失保持安静」，外加解析出的顺序/字段断言。
- **只读、绝不写**：我们从不在这个文件上写任何东西，最坏情况是不会破坏 dsh 的数据。

**升级时怎么验（§5 的 D 面）**：

```bash
DSH_HOME=${DSH_HOME:-$HOME/.dsh}
python3 -c "import json,sys; d=json.load(open('$DSH_HOME/storages/workspace.json')); \
print('domain', d.get('unit'), 'workspaces', len(d.get('tables',{}).get('workspaces',{})))"
```

期望看到 `domain {'name': 'workspace', 'version': 2}` 且工作区数量与面板一致；**version 变了就按 §6.2 更新两侧读取器并补用例**，同时确认 `/wks` 仍列得出工作区。

### R6 详解：`dsh-auth-*` cookie 按 authority 命名 → 累积压垮请求头

**我们依赖的是什么**（`@deepseek-ai/dsh-client-connection`，0.1.2+）：浏览器会话 cookie 由 launch token 换取（`GET /?token=…` → 303 + `Set-Cookie`），

```js
cookieName(authority) = "dsh-auth-" + base64url(sha256(authority))   // authority = "127.0.0.1:<port>"
sessionCookie(...)     = "<name>=<value>; Max-Age=2592000; Path=/; Expires=…; HttpOnly; SameSite=Strict"
```

服务端**按名字精确取自己那一只**（`cookieValue()` 按 `;` 切分，忽略其它 cookie）；cookie 值里签着 `{version, authority, issuedAt, expiresAt}`。

**为什么会炸**：cookie 按 (domain, path) 匹配、**不区分端口**（RFC 6265），所以壳层每次启动自拉起的新实例（随机端口）都落进**同一份** WKWebView cookie 列表；名字里带 authority ⇒ 新端口**不复用旧名**（这是 dsh 故意的：多实例并存时互不覆盖）⇒ 只增不减，每只 ~226 B。

**唯一被压垮的是那一条请求**：client-modules 的 application batch 把 45 个插件拼成**同一条 ~2.1 KB 的 combo URL**（`/plugins/??a/client.js,b/client.js,…&rev=…`），而 node http 默认 `maxHeaderSize = 16 KiB`。累积 `Cookie:` 头 > ~14.1 KB（第 63 只）时「请求行 + 请求头」整体超限，服务端回 **431 Request Header Fields Too Large**（空 body）；`<script src>` 收到 4xx 触发的是 **element 的 error 事件**（不是 JS 异常），client-modules 于是报 `client-modules: bundle script … failed to load` → 界面 **Failed to load plugins**。紧挨着的 bootstrap（路径仅 ~80 B）仍 200，所以现象是「外壳能渲染、插件全挂」。

**实测数据**（curl 对同一台 dsh web，2026-09-13）：

| 请求 | Cookie 头 | 结果 |
|---|---|---|
| batch（2,165 B 路径）+ 68 只 cookie | 15,502 B | **431** |
| bootstrap（80 B 路径）+ 68 只 cookie | 15,502 B | 200 |
| batch + 40 只 cookie | 9,118 B | 200（3,718,152 B） |
| batch + 1 只 cookie | 226 B | 200 |

阈值扫描：62 只 = 14,134 B → 200；**63 只 = 14,362 B → 431**。旁证：WebKit 磁盘缓存里每次**失败**启动只有 bootstrap 落盘、batch 从不落盘（431 不进缓存）；换一个全新 cookie 存储（同二进制、同 dsh、同 `DSH_HOME`、同 URL）立刻抓到 3.7 MB bundle；`~/Library/HTTPStorages/com.ohmydsh.app.dev.binarycookies` 实测 **68 只未过期** cookie、69 个端口，正式版当时 2 只（同一个坑，只是还没到）。

**处置**（`platforms/macos/src/DshWebCookieJanitor.swift`，测试 `tests/dsh-auth-cookies/run.sh`）：**启动**加载入口 URL 之前清掉所有非本次 authority 的 `dsh-auth-*`（保留当前那只，中途重载无 token 的 `webView.url` 不掉凭据）；**退出**清掉本次留下的（`applicationWillTerminate`，异步 + 泵 run loop 有界等待 1.5 s，best effort——真正的保证是启动清理）；spawn dsh web 时给 `NODE_OPTIONS` 追加 `--max-http-header-size=65536` 作保险带（环境已显式设置则原样保留）。清理**只碰 `dsh-auth-*`**：UI 偏好在 localStorage、会话/工作区在 `$DSH_HOME`、壳层配置在 `$DSH_HOME/shell/config.json`、Browser 面板（CEF）另有自己的 cookie 存储。

**升级时怎么验**（并进 §5 的 A 面）：① 启动后 `app.log` 有 `dsh cookies: purged N stale …`；② `~/Library/HTTPStorages/<bundleid>.binarycookies` 的 cookie 数稳定在 1（不再随启动次数增长）；③ `curl -H "Cookie: <造一堆>" "<batch URL>"` 回 200 而非 431（保险带生效）。若上游改了 cookie 命名规则或鉴权载体（例如换成 header），本清理只会「清不掉」（不再有害），但护栏同时失效——按上表重估。

### R7 详解：会话日志的「世代命名」（审查面板的数据源）

**我们依赖的是什么**：审查面板的审计数据来自 dsh 自己落盘的会话日志
`$DSH_HOME/sessions/<workspace-slug>/<session-id>/\<logfile\>`，容器是「多条独立可解码的 Zstandard 帧」的
JSONL（见 `docs/review-panel-design.md`）。**文件名本身带版本语义**（`@deepseek-ai/dsh-session-format`）：

```js
sessionFormatLogFilename(v) = v === 0 ? "session.jsonl" : \`session.v${v}.jsonl\`;   // 压缩存贮再加 ".zstd"
```

- 0.1.2-rc.1：新会话 = `session.jsonl.zstd`（世代 0）；
- 0.1.5-rc.2：新会话 = **`session.v3.jsonl.zstd`**（世代 3）；
- **被迁移的会话两份并存**：原来的 `session.jsonl.zstd` 成为冻结归档，活日志是 `session.v3.jsonl.zstd`
  （实测同一会话：归档 19 条事件 / 活日志 22 条，之后的新事件只进活日志）。

**为什么难发现**：读不到文件不是错误，只是「这个会话没有日志」——列表少几行、审计树空白，日志里只有
`review: listed 0/N sessions` 这种**看起来正常**的行。而且它只在**新建/迁移过**的会话上出现，老 home 里
世代 0 的存量会话一切照旧，很容易漏。

**修法**（`core/lib/review-log.js`）：

1. 规范名解析 `parseSessionLogName(name)`：`^session(?:\.v([1-9][0-9]*))?\.jsonl(\.zstd)?$` —— 只认规范名，
   `.v0`、大写 `V`、前导零、`.tmp`/`.gz` 之类一律不算（dsh 自己也不把它们当已提交世代）；
2. `sessionLogCandidates(dir)`：枚举目录里所有规范日志，**世代号降序**、同代**压缩优先**；
3. `sessionLogFile()` = 候选里的第一个；`listSessionLogs()` / `auditSession()` 自动跟着走；
4. 用例 6 条钉住契约（`core/tests/review-log.test.js`）：只有新世代文件时能发现并审计、迁移会话读**活日志**
   而不是归档、非规范名忽略、世代 0 仍兼容、压缩与非压缩两种新世代文件。

**升级时怎么验**（写进 §5 的 D 面）：

```bash
# ① 新建一个会话，看活日志的文件名
ls ~/.dsh-dev/sessions/*/<session-id>/            # 期望会话名里的世代号能被 sessionLogCandidates 认出
# ② 壳层读取器（用 App 内置 node，≥22.15 才有 zstd）
node -e "const c=require('./core'); const l=c.listSessionLogs({dshHome:process.env.HOME+'/.dsh-dev',limit:-1});
         console.log(l.total, l.sessions.map(s=>s.file.split('/').pop()))"
# ③ 面板侧：app.log 里应出现 "review: listed N/M sessions … diagnostics=0"，而不是 "listed 0/…" / "audit FAILED"
```

**未来触发**：上游再提世代（`session.v4.jsonl`）**不需要改代码**——规则是「取最大世代」；但若把日志换成
非 `session*.jsonl` 的容器名/目录结构，本条与 §3 D6/D8 要一起重估。

### R8 详解：运行时依赖闭包漂移（只钉 dsh 版本不够）

**现象**（2026-09-23）：新构建的开发版启动即崩，`dsh web` 打印入口 URL 后立刻抛：

```
Error: dsh: user patch-layer watching requires the Cordis HMR service
    at watchUserPatches (…/dsh-app-boot/lib/index.js:1078:28)
```

**定位**：与 profile、与 `~/.dsh-dev`、与本次改动都无关——用**全新空 home** 也会复现，而同版本的**已安装生产包**不报错。
对比两棵树的闭包：

| 包 | 今天重建（坏） | 生产包（好） |
|---|---|---|
| `@deepseek-ai/cordis-plugin-hmr` | **1.0.19** | 1.0.17 |
| `cordis-plugin-loader` | **1.0.5** | 1.0.3 |
| `cordis-plugin-include` | **1.0.9** | 1.0.7 |
| `cordis-plugin-timer` | **1.1.6** | 1.1.4 |

dsh 的 `package.json` 用 caret 声明这些插件（`^1.0.17`），所以 `npm install @deepseek-ai/dsh@0.1.2-rc.1` 拿到的是**今天最新的 1.x**；
新版 HMR 插件在 0.1.2-rc.1 的 loader 下无法实例化 → `ctx.get("hmr") === undefined` → profile 的 `patchReload: "live"` 走到 `watchUserPatches` 抛错退出。
把 `hmr` 单独钉回 1.0.17 **不够**（仍报错）——漂移是整组的。

**修法**（`build-app.sh`）：

1. 仓库内每个受支持的 dsh spec 配一份**已知可启动**的闭包锁：`platforms/macos/runtime-locks/<spec>/{package.json,package-lock.json}`
   （0.1.2-rc.1 那份从"真能启动"的生产运行树导出，583 个包、`lockfileVersion: 3`）；
2. 构建时用 **`npm ci`**（不是 `npm install`）复现该闭包，主 registry 失败回退官方源；没有 lock 的 spec 走老路并**大声警告**；
3. **装完做启动冒烟**：`smoke_runtime()` 用刚装好的树起一次 `dsh web`，40 秒内必须打出入口 URL 且进程存活，否则**构建失败**并打印日志
   （可用 `DSH_SKIP_RUNTIME_SMOKE=1` 跳过，仅限离线调试）；
4. runtime 缓存键加上 lock 指纹（`node|spec|arch|lockHash`），改锁即重建，避免复用旧树。

**升级时怎么验**：构建日志必须出现 `using committed runtime lock: …` 与 `smoke: dsh web came up`；若出现 `WARNING: no committed lock for <spec>`，说明这个 spec 还没配锁，先补一份再发。

**同源教训（快照树池）**：抓树必须**只在"这棵树已经启动成功"之后**（壳层挂在页面加载完成时抓，见 `docs/session-snapshot-rollback-design.md` §6）——否则"构建坏了但 App 起来了"会把一棵从没启动成功的树存进池，回退时又把坏树换回来（2026-09-23 用户实测踩到）。

**教训**：① 「钉版本」要钉到**闭包**（lockfile），只钉顶层包等于没钉；② 构建"成功"不等于产物能用——**能启动**才是验收标准，所以把冒烟放进构建；③ 这类漂移**只影响旧版本**（新 dsh 与新插件自洽），正是"长期停在一个旧 dsh 上"的隐性代价。

## 7. 参考

- 实战审计（0.1.2 逐项状态与实测契约）：`docs/plans/dsh-012rc1-compat-audit.md`
- 实战审计（0.1.2-rc.1 → 0.1.5-rc.2，含八面板全量验证）：`docs/plans/dsh-015rc2-compat-audit.md`
- Files 面板 → 输入框引用（B9 的实现与实测）：`docs/file-panel-composer-reference.md`
- 频道侧实现与状态：`docs/channel-status.md`、`docs/channel-commands.md`、`docs/channel-project-switch.md`
- 产品化与版本策略：`docs/productization.md` §8；发布流程：`docs/release-process.md`
- 代码锚点：`platforms/macos/src/main.swift`（ServerManager / DSHSessionRPC / 注入脚本 / 升级）、`platforms/macos/src/WikiPanel.swift`（WikiRPC）、`platforms/macos/src/IssueRunnerPanel.swift`、`platforms/macos/src/DshWebCookieJanitor.swift`、`core/lib/dsh-rpc.js`、`core/lib/workspace-store.js`、`core/lib/session-driver.js`、`core/lib/channel-runner.js`、`core/lib/upgrade.js`、`platforms/macos/build-app.sh`
- 仓库知识库：`.dsh/wiki/modules/main.md`、`.dsh/wiki/modules/channel-panel.md`、`.dsh/wiki/data-model.md`（RPC 信封）

