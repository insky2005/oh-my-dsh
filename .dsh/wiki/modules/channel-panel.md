---
title: 模块：通道（Channel）—— 消息平台接入 + 远程驱动 dsh
tags: [module, channel, weixin, clawbot, dingtalk, stream, adapter, router, session-driver, qrcode, commands, association]
updated: 2026-08-26T14:29:30Z
sources: [platforms/macos/src/ChannelPanel.swift, platforms/macos/src/ChannelStoreReader.swift, platforms/macos/src/main.swift, core/lib/channel.js, core/lib/channel-runner.js, core/lib/channel-commands.js, core/lib/channel-store.js, core/lib/channel-sessions.js, core/lib/channel-workspaces.js, core/lib/weixin-clawbot.js, core/lib/weixin-clawbot-transport.js, core/lib/session-driver.js, core/lib/dingtalk.js, core/lib/dingtalk-stream-transport.js, core/lib/dingtalk-access.js, core/lib/dingtalk-device.js, core/tests/dingtalk.test.js, core/tests/dingtalk-stream-transport.test.js, core/tests/dingtalk-access.test.js, core/bin/ohmy-core.js, core/vendor/qrcode-terminal/, docs/channel-design.md, docs/channel-commands.md, docs/channel-status.md, docs/channel-storage.md, docs/channel-association-model.md, docs/channel-issues.md, docs/channel-project-switch.md, docs/channel-dingtalk-stream.md]
manual: false
---

# 模块：通道（Channel）—— 消息平台接入 + 远程驱动 dsh

## 定位

把外部消息平台（当前实现：微信 ClawBot / 官方 iLink 协议、钉钉 / dingtalk-stream 原生适配器）接入壳层：扫码登录 → 收消息 → 斜杠指令 / #tag 路由 → 驱动 dsh 会话 → 回复回原平台。设计遵循「统一协议 + 平台适配器」（docs/channel-design.md）：平台差异收敛到适配器层，路由/状态机/会话驱动一律平台无关、放 core/（Node），macOS 面板只做配置 UI 与状态展示，为后续飞书适配器（M4）预留。

2026-08-22 随 **PR #23（feature/channel）合并进 main**；2026-08-23 随 **PR #28（feature/channel-association）** 落地 **Channel–Message–Session 关联模型**（会话复用 A / 路由统一 B / 工作区归属 C / 存储全局化 D / 面板项目视图 E），见 docs/channel-association-model.md；同日随 **PR #30（feature/channel-project-switch）** 落地 **Channel「项目开关」**——通道↔项目（workspace）启用关联存全局 `~/.dsh/channels/<channelId>.workspaces.json`，开关真正**门控路由**（未启用回「该项目未启用该通道」、不建会话），见 docs/channel-project-switch.md。README 已收录通道章节；设计/指令/完成状态/存储/问题排查见 docs/channel-*.md。

## core 层（平台无关，Node）

### 统一抽象 core/lib/channel.js
- CHANNEL_STATES 五态状态机：disconnected / connecting / connected / reconnecting / auth-expired（鉴权失效统一归一到 auth-expired，适配器负责受控重连/重新登录）；
- ROUTE_PRIORITY 路由优先级：显式会话绑定(3) > 关键词/前缀(2) > 默认兜底(1)——一条消息一次命中一个项目，冲突取最高并记日志（确定性）；resolveRefBinding（B）：先按 conversation/keyword 显式绑定解析，否则 workspace-tag（#tag>last>first）兜底；handleEvent 对已绑定事件合成 ref；
- normalizeEvent 把入站消息规范化为平台无关 ChannelEvent：{channelId, platform, conversationId, sender, text?, media?, ts}（conversationId 必填，缺失抛错）；
- createRouter（项目引用匹配）+ createChannelManager（编排：token → 适配器 → 会话驱动 → 回复），串行队列复用 core/lib/jobqueue.js（source: remote，与 issue-runner 同队列不同来源）。

### 凭据存储 core/lib/channel-store.js
- 账号/token 落 ~/.dsh/channels/<channelId>.json（chmod 600）；**读取文件优先、Keychain 兜底**（零弹窗，同 GitHub token 模式）；dshHome 解析 dshHome || DSH_HOME || ~/.dsh。

### 微信 ClawBot 适配器（M2，core/lib/weixin-clawbot.js + weixin-clawbot-transport.js）
- **纯官方 iLink Bot 协议**（ilinkai.weixin.qq.com，按 @tencent-weixin/openclaw-weixin 2.4.6 官方源码推导，不参考非官方逆向）；登录/收/发/媒体/通知全覆盖；
- **严格串行长轮询**（afa46d5 修复）：getupdates 用串行 while 循环（阻塞到新消息或长轮询超时），**禁用 setInterval**——后者破坏服务端 get_updates_buf 游标推进导致同一消息反复返回/重复回复（实测同一 /help 被处理 6 次，见 docs/channel-issues.md）；
- 主动发送须带 context_token（从入站消息获得，有时效）；-14 token 失效归一到 auth-expired。

### 钉钉适配器（M4 提前落地，2026-08-26，PR #39 feature/channel-dingtalk-stream）
- **dingtalk-stream 原生适配器**（核心架构决策：钉钉 = core/ 适配器，非官方插件托管，见 docs/channel-dingtalk-stream.md）：`core/lib/dingtalk-stream-transport.js`（DWClient 封装：connect/收/回/去重/access-token 缓存刷新，TOPIC_ROBOT 回调归一化 `{conversationId, sender, text, msgId, sessionWebhook, ts, msgtype}`，非 text 降级文本提示，回执 `socketCallBackResponse(msgId)` + msgId seen 去重防服务端 60s 重推）+ `core/lib/dingtalk.js`（ChannelAdapter，platform=dingtalk，仿 weixin-clawbot.js）+ `core/lib/dingtalk-access.js`（管理员绑定口令 auth）+ `core/lib/dingtalk-device.js`（device-code 扫码注册）；
- **扫码创建应用（device-code）**：`core/bin/ohmy-core.js` 新增 `channel login-dingtalk`（init/begin 得二维码 → 面板内渲染 → 手机钉钉扫码自动创建企业内部应用+机器人 → 本地轮询 poll 得 AppKey/AppSecret 写 channel store，chmod 600）；已配置通道不重复扫码、重开向导自动恢复 /bind 口令；备选手动填 AppKey/AppSecret；
- **owner-binding 安全门**：/bind <口令>（口令本机生成、见面板或运行日志）——未绑定管理员前**拒绝所有人**，仅绑定管理员可驱动本机 dsh；绑定成功回两条消息（确认 + 完整 /help 输出）；绑定状态存 `~/.dsh/channels/<channelId>.binding.json`（chmod 600）；钉钉无「正在输入」，以文字 ack 代替 sendTyping；
- **runDingTalkChannel**（channel-runner.js）：镜像 runWeixinChannel 的编排（buildDingTalkAdapters + createChannelManager/SessionDriver/ChannelSessions/CommandRunner/Queue 复用），写入**同一 channel store**，面板项目视图零改动复用；runChannel 新增可选 access gate（dingtalk owner-binding：消费 /bind、拒绝未授权）；
- 工作区语义与微信完全一致：runner 自身做**每会话跨项目路由**，不依赖插件单工作区。

### 会话驱动 core/lib/session-driver.js
- run(event, projectRef)：**复用会话（A）**——sessionDriver.run 尊重 event.sessionId：已有会话映射则**直接复用该会话 prompt**（多轮对话续接），无则 create 后写映射；createSession 支持按 workspaceId 归属工作区（C，无 workspace 才回退 cwd）→ rename → prompt（mode: queue）→ 轮询 running → 取最后一条 assistant 消息 → ChannelReply；RPC 信封（client-request）与 IssueRunner 面板一致。

### 指令 / 路由 / 状态（channel-commands / channel-workspaces / channel-runner / channel-sessions）
- **斜杠指令 v2**（channel-commands.js）：全局 /help（分组清单）/ /ping / /status（通道/连接/当前工作区/当前会话）；工作区指令 /workspaces(/wks)、/sessions(/ses)（无内容列出 / 有内容切换，等同 #wN/#sN）、/new [内容]（统一回 创建新会话 #sN (sessionId)，无内容建占位 New Session（dsh 标题由 dsh web 按首条消息自动命名）等首条消息激活、有内容 prompt=内容并回推答案）；未知 /xxx 回「未知指令」；响应发送前经 toPlainText 去 markdown 符号，路径以 ~ 开头不泄露用户目录；
- **快捷指令**（channel-runner.js）：纯代号 #wN（设置当前工作区，会话置 n/a 并附最近 5 条会话）/ #sN（设置当前会话）；消息含 #w1 或 #<workspace名> 时按 **#tag 路由**到对应项目（代号从发给会话的文本剥离）；回退规则：最近提到的 workspace → 第一个 workspace；
- **workspace 代号**（channel-workspaces.js）：/wks 按 path 排序分配 #wN（名称取 dsh web workspace title）；`/wks <裸数字>` 按下标切换工作区（2026-08-26，镜像 /ses <N>）；#tag 路由（代号精确 > workspace 名）；toHomePath 用 ~ 缩短路径；
- **会话映射 + 消息持久化（全局化 D，channel-sessions.js）**：2026-08-22 起按 **channel 作用域全局存储**于 ~/.dsh/channels/——<channelId>.sessions.json（会话映射，按 sessionId 保留全部会话，/new 重绑定 conversation 不删历史）、<channelId>.workspaces.json（workspaceKey ↔ projectRoot 注册表，同名项目加 6 位路径哈希后缀消歧；**同时承担「项目开关」启用语义**：某 projectRoot 出现在该通道的 workspaces.json = 该工作区启用了该通道，见 docs/channel-project-switch.md——新增 `listEnabledWorkspaces` / `isWorkspaceEnabled` / `setWorkspaceEnabled`，`registerProjectRoot` 保留作消息桶 key 推导、不再作为启用来源）、<channelId>.<workspaceKey>.<sessionId>.messages.json 分桶（sessionId 缺省入 system 桶）；消息记录 {channelId, conversationId, sessionId, dir: in|out, text, ts, projectRoot}，MAX_MESSAGES=1000 滚动；**项目目录不再产生消息/会话文件**（旧格式惰性迁移，含 channel migrate CLI，见 docs/channel-storage.md）；
- **通道级状态**：runner 写 ~/.dsh/channels/<channelId>.state.json（lastWorkspace / 会话映射 / activeSession），重启可恢复；面板打开全局配置视图时读它一次显示连接状态徽标（不轮询）；channel run 默认 dshHome=~/.dsh、同 channelId 去重（346ed7b）、SIGTERM 立即退出（208e618，不阻塞 App 退出）。

### 异步应答 + 忙门 + sendTyping（2026-08-22 实施，channel-association-model.md §8）
所有路由到会话的消息统一采用 **typing 指示 + 后台生成 + 结果回推**：① 解析工作区/会话、记录 in 消息；② **立即 sendTyping(status=1)**（微信原生「对方正在输入…」，onEvent 循环不阻塞）；③ **后台**跑 sessionDriver.run 生成（dispatchGeneration，fire-and-forget）；④ 生成完成**回推答案**（adapter.send，best-effort）+ sendTyping(status=2) 取消 typing。**忙门（per-conversation busy gate）**：同一 conversation 同时**至多一条生成**在途（槽位在进入普通消息分支时同步预留）——空闲时来消息 → sendTyping + 后台生成；在途时再来消息（含 /new 带内容）→ 回「请等待，前一条消息还在处理中」，**不入队**（不积压）；完成/失败释放忙门。sendTyping 实现照官方 openclaw-weixin：getConfig（ilink/bot/getconfig 拿 typing_ticket）→ sendTyping（ilink/bot/sendtyping，{ilink_user_id, typing_ticket, status}）。权衡：回推依赖入站 context_token（有时效）；长生成超期推送失败时兜底提示可用 #sN / /status 查看。

### Channel「项目开关」（2026-08-23 落地，docs/channel-project-switch.md）

「项目」即 dsh 的 workspace（项目根目录对应工作区），不引入独立项目概念。**通道↔workspace 的启用关联存全局** `~/.dsh/channels/<channelId>.workspaces.json`（chmod 600；某 projectRoot 出现在该通道的 workspaces.json = 该工作区启用了该通道；不再写项目内 `.dsh/channels.json`）。

- **门控（channel-runner.js）**：新增 `isEnabledForRoot(root)`（读该通道全局 workspaces.json，启用集合缓存约 1s，开关切换后下一条消息即生效、无需重启 runner）。门控作用于**实际要路由/驱动会话**的消息：**普通文本消息**与 **/new** 解析出目标 workspace 后，若未启用该通道 → 回「该项目未启用该通道，请在面板「通道」项目视图开启后使用」、不创建/不运行会话；**#wN** 目标 workspace 未启用 → 禁止切换并回提示；**#sN / /sessions(/ses)**（含带内容切换）当前 workspace 未启用 → 回提示；**/workspaces(/wks)** 无内容**只列已启用**该通道的 workspace、带内容切到未启用 workspace → 回提示；**始终放行**：/help /ping /status；
- **core 存储（channel-sessions.js）**：新增 `setWorkspaceEnabled(projectRoot, enabled)` / `isWorkspaceEnabled(projectRoot)` / `listEnabledWorkspaces()`（读写现有全局 workspaces.json，缺失视为空）；`registerProjectRoot` 保留作消息桶 key 推导，不作为 enable 来源；
- **面板（ChannelPanel.swift）**：移除 `loadRefs`/`saveRefs`/`refs`/`ProjectRefsFile` 作启用来源；新增 `channelWorkspacesPath`/`enabledRoots(for:)`/`isChannelEnabled`/`setChannelEnabled`（读/写全局 workspaces.json，key 用 `ChannelStoreReader.workspaceKey(for:)` 派生）；`rebuildProjectRows` 中 `sessions = enabled ? loadSessions(...) : []`、未启用时折叠且标题行显示 L10n `channel.notEnabledInProject`（「未在项目启用」）；`ProjectChannelRef` 保留仅作**一次性惰性迁移**（`migrateLegacyRefsIfNeeded`：若旧 `<项目>/.dsh/channels.json` 有该项目 refs 且该通道尚无全局 workspaces.json，播种启用——迁移只播种一次，此后全局文件为权威，用户关掉不会又被重开）；
- **main.swift**：`startChannelRunner` **删除**读/写项目 refs 与「强制补 ref」逻辑，追加 `--project-root` 传活动 workspace 根；新增 L10n `channel.notEnabledInProject`；
- **测试**：channel-runner.test.js 新增 project-switch 用例（OFF 普通消息回「未启用」且不建会话 / ON 正常路由 / #w1 门控 / #sN 门控 / /sessions 门控 / /workspaces 只列已启用）；channel-sessions.test.js 新增 set/isWorkspaceEnabled 持久化断言。

### CLI core/bin/ohmy-core.js
channel 子命令：route <refsJson> <conversationId> <text>（路由匹配）、normalize <eventJson>、state <current> <next>（状态机迁移）、login [--save <file>]（扫码登录）、login-dingtalk（钉钉 device-code 扫码注册：init/begin 得二维码 → poll 得 AppKey/AppSecret）、listen <token> [--once]（长轮询收消息）、reply <token> <to> <text>（回复）、run <channelId> <port> <refsJson> [--dsh-home <dir>] [--project-root <root>]（端到端循环；--project-root 指定项目=workspace 根，供「项目开关」门控；dingtalk 通道经 runDingTalkChannel 编排）、migrate [projectRoot] [--dsh-home <dir>]（旧项目格式惰性迁移）。CLI 二维码渲染用 vendored core/vendor/qrcode-terminal/。

## macOS 面板 ChannelPanel.swift（约 1315 行）+ ChannelStoreReader.swift（97 行）

- ChannelPanelController（NSObject）+ ChannelRootView；右栏插槽 RightPanel.channel（main.swift，rightPanelKind 持久化映射新增 channel），活动栏 + 视图菜单切换；
- **v2 状态机**：无全局配置 → 引导页（微信 ClawBot / 钉钉 / 飞书三张 ChannelCardView 全宽卡片 + 连接状态徽标）；有全局配置 → 项目视图；顶部「全局配置」按钮可切回（可收起/重开）；
- **扫码登录向导**：面板内 CIQRCodeGenerator 渲染二维码（不弹浏览器）。**微信**经 AppDelegate.runChannelLogin 调 core channel login --save → 成功写 ~/.dsh/channels/<id>.json → 自动拉起 runner；微信绑定页展示**已配置状态 + 显式「重新登录」**按钮（避免误替换已绑定 token）；离开向导（scan/done）任一步骤取消仍在跑的登录子进程。**钉钉**走 device-code 扫码向导（channelLoginRunner 分发到 runDingTalkLogin：init/begin → 面板渲染二维码 → 手机钉钉扫码自动创建应用 → 本地 poll 得 AppKey/AppSecret 写 channel store → 起 runner）；已配置钉钉通道不重复扫码、重开向导自动恢复 /bind 口令，step 0 锁定显示 Done；向导任一步「返回」取消（可能残留的）登录子进程；全局配置页新增 **unbind**（解绑：清 channel 配置 + 停 runner）；
- **项目视图（数据源 E）**：ProjectRowView（Channel 行 + 原生 NSSwitch 开关）→ `toggleProjectChannel` 经 `setChannelEnabled` 写**全局** `~/.dsh/channels/<channelId>.workspaces.json`（不再写项目 .dsh/channels.json，见上文「项目开关」）；通道标题行展示「图标 + 平台名 (channelId) + 会话数」（未启用时该行显示 `channel.notEnabledInProject`「未在项目启用」）、启用开关靠右，整行独立背景；展开区经 **ChannelStoreReader**（纯 Foundation，无 AppKit、可无头单测）读**全局 store**——loadSessions 过滤当前 projectRoot 的会话（读 <channelId>.sessions.json，按 updatedAt 降序）、loadMessages 读每个会话的分桶 <channelId>.<workspaceKey>.<sessionId>.messages.json；会话行独立区块可点开/收起，消息按对话气泡展示（提问 in 靠右、回复 out 靠左）；状态徽标打开视图时读 state.json 一次（不轮询）；
- **项目视图实时刷新（live-refresh，2026-08-24）**：project 模式起 ~1.5s 的 Timer（RunLoop .common），每 tick 用 `computeProjectSignature()`（对每个启用 channel 的 `loadSessions` 汇总 sessionId/updatedAt/name/消息数/最后一条 ts+dir+text）对比上次签名，**变了才** `rebuildProjectRows()` 全量重建（保留折叠/展开状态），对话回复后视图自动更新；`ensureLoaded` 启动、`deinit` 失效；
- **与 dsh web 会话双向联动（2026-08-24，docs/channel-web-session-link.md）**：面板↔web 会话**以 sessionId 对应（不用 name）**。面板 → web：**点击会话行**（单一手势）同时展开/收起消息并 `onOpenSession(sessionId)` → main.swift 注入的 `sessionOpenerScript` 暴露 `window.__dshOpenSession(id)`（`session.list` 按 sessionId 解析标题 → 展开折叠组 + 异步重试 → 点击侧边栏行）；web → 面板：`dshSession` handler 追加 `channelPanel?.setActiveSession(sid)`，把 follow 目标直接写入**单一展开状态** `collapsedSessionIds`——命中则只展开该会话、其余行收起，未命中则所有会话行收起（channel 列表仍按 enabled 显示、会话可见）；手动点击会话行也读写同一集合，故手动展开/收起与 web follow 不打架；
- **生命周期**：applicationDidFinishLaunching → startConfiguredChannelRunners()（逐个拉起已启用全局 channel，微信 runWeixinChannel / 钉钉 runDingTalkChannel）；退出 applicationWillTerminate 清理 runner；同 channelId 去重；runner stdout/stderr 经 main.swift 路由到 ~/Library/Logs/oh-my-dsh/channel-runner-<channelId>.log（暴露 [weixin-clawbot] getConfig/sendTyping、[dingtalk] 等 core 调试日志，不再丢弃）；
- 钉钉卡片已可**扫码接入并运行**（2026-08-26，PR #39）；飞书卡片仍标注「待实现」、点击仅 NSSound.beep；即时「收到」应答为低优先待办。

## 数据流（入站 → 会话 → 回复）

平台(微信 iLink / 钉钉 Stream) → adapter.onEvent → ChannelEvent → runner：先 parseCommand（指令 → 直接回复，不建项目会话）→ 否则按 association 模型解析——resolveWorkspaceTag(#tag>last>first) 定当前工作区 → 会话映射 runtime.getSession(conversationId) 已有则**复用**、无（或 #tag 切工作区）→ session.create({workspaceId}) + 写映射 → **sendTyping(status=1)**（微信原生 / 钉钉文字 ack）→ 后台 session.prompt(mode: queue) → 轮询 running → 取最后 assistant 消息 → **回推** ChannelReply（微信带 context_token / 钉钉 POST sessionWebhook）+ sendTyping(status=2) → adapter.send 回客户端；同一 conversation 在途时回「请等待」不入队。系统/指令消息（无项目上下文）落入**通道级全局桶**，仅 dsh 会话消息按项目（workspace key）分桶。

## 测试与验证

- node --test core/tests/ **186 全绿**（2026-08-26 实测；指令体系 v2 171 后新增 dingtalk 适配器/transport/access 用例；channel 相关含 channel/commands/runner/sessions/workspaces/weixin-clawbot/dingtalk/e2e-channel/channel-association/channel-busy/project-switch 等）；
- e2e-channel.test.js：mock HTTP 覆盖传输层（getupdates 映射 / -14 过期 / 无 token / sendmessage 报文 / QR 登录），不依赖真实 dsh web、不做会话创建；
- channel-association.test.js：断言 A（同一 conversation 复用同一 sessionId、跨 conversation 独立）、B（refs 显式绑定）、C（会话归属 workspaceId）、/new 绑定 conversation 后下一条普通消息复用而非新建；
- channel-sessions.test.js（重写）：全局分桶存储、按 sessionId 保留全部会话（re-binding 保留旧会话）、set/isWorkspaceEnabled 项目开关持久化；channel-busy.test.js：忙门/异步应答；channel-runner.test.js：含「项目开关」门控用例（普通消息/#wN/#sN//sessions 未启用回「未启用该通道」，/workspaces 只列已启用）+ /sessions、/workspaces 带内容切换用例；
- tests/channel-panel/run.sh（channel-tests.swift）：ChannelStoreReader 无头单测（读全局 sessions/分桶消息过滤 projectRoot）；
- 真实微信端到端已验证：扫码登录拿 bot_token → getupdates 收入站（含 context_token）→ sendmessage 回传，用户确认收到；
- Swift 编译清单：ChannelPanel.swift / ChannelStoreReader.swift 由 swift-sources.sh 单一来源自动收录（不再逐个登记）。