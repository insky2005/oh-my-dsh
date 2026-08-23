# Channel 面板完成状态总览

> 状态：✅ 总览文档（随 `feature/channel` 分支核对，2026-08-22）
> 更新：2026-08-22
> 关联：docs/channel-design.md（设计）、docs/channel-ui-commands.md（面板 UI + 指令设计）、docs/channel-commands.md（已实现指令清单）、docs/channel-storage.md（存储全局化设计）、docs/channel-issues.md（重复回复问题排查）
> 说明：汇总 Channel 面板（含 core 支撑层）的完成情况；每项标注状态并给出实现位置与验证证据。

## 1. 状态图例

| 标记 | 含义 |
|---|---|
| ✅ | 已完成（含真实验证） |
| 🚧 | 部分完成（骨架/首版已实现，待增强） |
| ⏳ | 设计中（设计稿已定稿，未实现） |
| 📋 | 待实现 |

## 2. 一句话总结

Channel 能力已跑通「微信扫码登录 → 长轮询收消息 → 指令/路由 → dsh 会话 → 回复回微信」**全链路**（真实微信 + 真实 dsh web 端到端验证）；macOS 面板 v2（引导卡片 + 扫码向导 + 项目视图 + 实时状态徽标）**已实现**并登记进编译清单。剩余工作主要是：钉钉/飞书适配器（M4）、消息/会话存储全局化改造落地、面板「Channel ▸ Session」消息分组 UI、以及第二优先级指令。

## 3. 分项完成状态

### 3.1 core 层（平台无关，Node）

| 组件 | 状态 | 实现位置 | 说明 |
|---|---|---|---|
| 统一抽象层（ChannelEvent / ChannelReply / 状态机 / Router / 管理编排） | ✅ | core/lib/channel.js | 5 态状态机、路由优先级（显式绑定 > 关键词 > 默认）、createChannelManager 编排、jobqueue.source="remote" 串行 |
| 凭据/配置存储 | ✅ | core/lib/channel-store.js | `~/.dsh/channels/<id>.json`（文件优先，chmod 600），App 与 CLI/代理共用；面板元数据存 UserDefaults |
| 微信 ClawBot 适配器（M2） | ✅ | core/lib/weixin-clawbot.js + weixin-clawbot-transport.js | 纯官方 iLink 协议（@tencent-weixin/openclaw-weixin 2.4.6 官方源码推导）；**严格串行长轮询**（修复 setInterval 破坏游标导致重复回复，见 channel-issues.md） |
| 消息分发 Router + 会话驱动（M3） | ✅ | core/lib/channel.js（router）+ core/lib/session-driver.js + core/lib/channel-runner.js | 已在真实 dsh web 端到端验证 |
| workspace 代号 + #tag 路由 | ✅ | core/lib/channel-workspaces.js | /wks 分配 #wN、#tag 路由（代号精确 > workspace 名）、回退规则（最近 → 第一个） |
| 指令解析与执行 v1 | ✅ | core/lib/channel-commands.js | /help /ping /status /workspaces(/wks) /new /sessions(/ses) /switch，清单见 channel-commands.md |
| 异步应答 + 忙门 | ✅ | core/lib/channel-runner.js | 先 ack「处理中」+ 后台生成 + 结果回推；同 conversation 在途时后续消息回「请等待」不入队（见 channel-association-model.md §8） |
| 快捷指令 #wN / #sN | ✅ | core/lib/channel-runner.js | 纯代号快捷切换；通道级状态持久化 `~/.dsh/channels/<id>.state.json`（lastWorkspace / 会话映射 / activeSession，重启可恢复） |
| 会话映射 + 消息持久化（决策 E，channel 作用域） | ✅ | core/lib/channel-sessions.js | **已全局化**：`~/.dsh/channels/<id>.sessions.json` + `<id>.workspaces.json` + `<id>.<workspaceKey>.<sessionId>.messages.json` 分桶（无会话入 system 桶）；项目目录不再产生消息/会话文件；MAX_MESSAGES=1000 滚动 |
| 会话复用（A）+ 工作区归属（C）+ 路由统一（B） | ✅ | session-driver.js、channel-runner.js、channel.js | sessionDriver.run 复用 event.sessionId；普通消息以 workspaceId 归属工作区；resolveRefBinding 先 refs 绑定后 workspace-tag 兜底（见 channel-association-model.md §7） |
| 第二优先级指令（/commit /test /issue /repo /clear /route /pwd） | 📋 | — | 后续（channel-ui-commands.md §3.3） |

### 3.2 macOS 面板（ChannelPanel.swift + main.swift）

| 组件 | 状态 | 说明 |
|---|---|---|
| 面板插槽（右栏 `rightPanelKind=channel` + 菜单显示/隐藏） | ✅ | main.swift 集成 |
| v2 状态机（引导页 ↔ 全局配置 ↔ 项目视图，顶部「全局配置」重开） | ✅ | ChannelPanelController |
| 引导卡片（微信 ClawBot / 钉钉 / 飞书 + 状态徽标） | ✅ | ChannelCardView（全宽卡片、SF 图标、外观自适应背景）；徽标打开视图时读 `~/.dsh/channels/<id>.state.json`，不轮询 |
| 扫码登录向导（提示 → 二维码 → 绑定成功） | ✅ | CIQRCodeGenerator **面板内渲染二维码**（不弹浏览器）；调 core `channel login --save`；成功后自动拉起 runner |
| 项目视图（Channel 行 + NSSwitch 开关 + 可展开会话 + 消息列表） | ✅ | ProjectRowView + ChannelSessionRow；开关写 `.dsh/channels.json` 引用；会话/消息读全局 store（ChannelStoreReader，D） |
| 启动自动拉起 / 退出关闭 runner | ✅ | applicationDidFinishLaunching → startConfiguredChannelRunners()（已启用全局 channel 逐个拉起）；退出 terminate 清理；同 channelId 去重 |
| 钉钉 / 飞书卡片点击 | 🚧 | 卡片已渲染（说明标注「待实现」），点击仅 NSSound.beep，未接适配器 |
| 会话/消息分组 UI 展示（按 Channel ▸ Session 的消息列表） | ✅ | ChannelSessionRow 展开显示该会话消息（读全局分桶 messages） |
| 即时「收到」应答 | 📋 | 低优先 TODO |

### 3.3 测试与验证

| 项 | 状态 | 说明 |
|---|---|---|
| core 全量单测 | ✅ | `node --test core/tests/` **148 全绿**（2026-08-22 核对；其中 channel 相关 71 项） |
| 传输层回归（mock HTTP） | ✅ | core/tests/e2e-channel.test.js：getupdates / -14 过期 / 无 token / sendmessage 报文 / QR 登录，不依赖真实 dsh web |
| 真实微信 E2E | ✅ | 扫码登录拿 bot_token → getupdates 收入站（含 context_token）→ sendmessage 回传回复，用户确认收到；印证主动发送须带 context_token |
| 重复回复回归 | ✅ | 严格串行长轮询修复后 /help 只回 1 条（channel-issues.md） |
| Swift 编译清单 | ✅ | ChannelPanel.swift 已登记 build-app.sh + local-ci swiftc（3e69783 修复漏登） |

## 4. 里程碑进度（channel-design.md §10）

| 里程碑 | 内容 | 状态 |
|---|---|---|
| M0 | 设计稿 | ✅ |
| M1 | 统一抽象层 + Router 骨架 + 配置面板（全局 + 项目引用）+ 全局配置模型与凭据存储 | ✅ |
| M2 | 微信 ClawBot 适配器（core 内首个实现） | ✅ |
| M3 | 消息分发路由（项目引用匹配 + 会话驱动 + 回复回传） | ✅ |
| M4 | 钉钉 / 飞书适配器（复用统一抽象） | 📋 待实现 |
| 跨平台 | Windows（M2 里程碑）/ Linux（M3 里程碑）壳层复用 core | 📋 随各自里程碑 |

## 5. 待办清单（按优先级）

1. 📋 **存储全局化改造落地**（channel-storage.md）：createChannelSessions 改按 channel 作用域 + 全局分桶 + 惰性迁移 + `channel migrate` CLI + 本仓库自迁移 + `.dsh/channels.json` 落位为 `.dsh/channels/channels.json` 并提交（当前旧路径文件仍未跟踪）。
2. 📋 **钉钉 / 飞书适配器**（M4）+ 假平台适配器一致性回归用例。
3. 📋 **面板消息分组 UI**：按 Channel ▸ Session 展示实时消息列表。
4. 📋 **第二优先级指令**（/commit /test /issue /repo /clear /route /pwd）。
5. 📋 即时「收到」应答（低优先）。

## 6. 文档与实现偏差（2026-08-22 核对）

| 文档 | 问题 | 处理 |
|---|---|---|
| docs/channel-ui-commands.md | 状态行与 §6 第 5 步、§7 均写「面板 v2 UI 待实现」，实际已实现（751a933 起多轮提交） | ✅ 本次已修正 |
| docs/channel-design.md §10 | M1 未标状态（实际已完成） | 以本总览 §4 为准 |
| main.swift L10n | `channel.wizard.scanning` 文案「二维码已在新标签页打开」与面板内渲染实现不符 | 小问题，待更新文案 |

## 7. 关键提交（feature/channel 分支）

| 提交 | 内容 |
|---|---|
| cd95874 | 指令体系 v1 + 会话映射/消息持久化 + runner 指令优先路由 |
| 751a933 | 面板 v2 UI（引导卡片 → 配置向导 → 项目视图） |
| affaaa7 | v2 打磨：全宽卡片 + 面板内二维码 + 项目 Channel 行/开关/展开会话 |
| d2d27f5 | /wks 代号 + #tag 路由 + 回退规则（131 单测全绿，live dsh 验证） |
| afa46d5 | **严格串行长轮询**（修复重复回复根因） |
| 3644e6a | 启动自动拉起已配置 runner / 退出关闭 |
| 2e6e7d5 | runner 接入 #wN/#sN 快捷指令 + 连接状态上报 |
| eee866a | 指令集整理（/help 分组）+ channel-commands.md 清单 |
| dae1597 | 全局配置视图实时连接状态徽标（读 state.json，不轮询） |
| 2d42f04 | /new 优化（无内容建会话等首条激活、有内容立即 prompt） |