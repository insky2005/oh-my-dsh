# Channel「项目开关」设计（全局 workspace 关联 + 未启用门控）

> 状态：✅ 决策已定（2026-08-23，待落地实现）
> 关联：docs/channel-design.md（配置模型/路由）、docs/channel-storage.md（存储）、docs/channel-association-model.md（关联模型）、core/lib/channel-runner.js、core/lib/channel-sessions.js、platforms/macos/src/ChannelPanel.swift、platforms/macos/src/main.swift

## 1. 问题

Channel 面板项目视图里每个通道有一个「项目开关」，但目前它几乎无效：

- 开关只增删项目内 `.dsh/channels.json` 的引用；面板 `rebuildProjectRows` 显示所有全局通道、`loadSessions` 只按 projectRoot 过滤（不看引用）→ **关掉后会话照常显示**；
- 运行时 `startChannelRunner`（main.swift）启动时**强制把该通道 ref 补回去**；
- runner 的 `resolveWorkspaceTag` 兜底会无视引用，把普通消息路由到当前/首个 workspace → **关掉后消息照常处理**。

结论：开关既不隐藏展示、也不拦截路由，需要重新设计。

## 2. 关键认知：project == workspace

面板里的「项目」即 dsh 的「workspace」（一个项目根目录对应的 dsh 工作区）。因此不引入独立的「项目」概念，**通道↔项目（workspace）的启用关联用已有的 workspace 存储即可**。

## 3. 决策

### 3.1 存储：全局 workspaces.json（Q1）

- 通道↔workspace 的启用关联存到**全局** `~/.dsh/channels/<channelId>.workspaces.json`，不再读写项目内 `.dsh/channels.json`。
- 格式沿用现有 `{ "<workspaceKey>": "<projectRoot>" }`（每通道一个文件，chmod 600）。
- **语义**：某 projectRoot 出现在该通道的 workspaces.json = 该工作区启用了该通道（「项目开关」ON）；不出现 = 关闭。
- 与消息归档的 `registerProjectRoot` 自增保持一致：路由被门控后，只有启用的 workspace 会被路由/归档，自动登记只会加入启用项；关闭时删除该项。
- 好处：不入仓库、无机器路径漂移；「一处登录、多项目复用」保留。取舍：项目接线不再随仓库走（本设计采纳该取舍）。

### 3.2 门控：未启用时直接提示（Q2）

门控作用于**实际要路由/驱动会话**的消息：当消息要路由到的目标 workspace 未启用该通道时，直接回复「该项目未启用该通道…」，不路由、不新建/不运行会话。触发点：
- **普通文本消息**：解析出目标 workspace 后，若该 workspace 未启用该通道 → 提示；不创建/不 prompt 会话；
- **`/new`**：目标 workspace 未启用 → 提示，不新建会话。

**放行（不做门控）**：
- 导航 / 只读命令：`#wN`（切换工作区）、`#sN`（切换会话）、`/sessions`(`/ses`)、`/switch`；
- 信息命令：`/help`、`/ping`、`/status`、`/workspaces`(`/wks`)。
> 注：`#wN`/`#sN` 是通道级工作区/会话导航，即使当前项目未启用也允许切换；但消息路由到未启用的 workspace 时仍会被拦截。

- **即时生效**：门控每次读取该通道全局 workspaces.json（启用集合缓存约 1s，避免突发消息重复读文件）；开关切换后下一条消息即反映（无需重启 App / runner）。
- 启用后行为与现状一致（按目标 workspace 路由）。

## 4. 改动范围（按子系统，供实现参考）

1. **core/lib/channel-sessions.js**：在现有 store 上加 enable 语义——`setWorkspaceEnabled(projectRoot, enabled)`、`isWorkspaceEnabled(projectRoot)`、`listEnabledWorkspaces()`（读写现有 workspaces.json，缺失视为空）；`registerProjectRoot` 保留作消息桶 key 推导，不作为 enable 来源。
2. **core/lib/channel-runner.js**：新增 `isEnabledForRoot(root)`（读该通道全局 workspaces.json，启用集合缓存约 1s）；在**普通文本路由点**与 **`/new`** 处对目标 workspace 做门控并回提示；导航（`#wN`/`#sN`）、`/sessions`/`/switch` 与信息命令放行；移除对 per-project refs 的路由依赖（adapter 由 `ensureChannelId` 保证，通道保持连接、重开无需重登）。
3. **core/bin/ohmy-core.js**：`channel run` 支持 `--project-root <root>`，透传 `projectRoot`。
4. **platforms/macos/src/main.swift**：`startChannelRunner` 删除读/写项目 refs 与「强制补 ref」逻辑，追加 `--project-root`；新增 L10n `channel.notEnabledInProject`。
5. **platforms/macos/src/ChannelPanel.swift**：移除 `loadRefs`/`saveRefs`/`ProjectRefsFile`/`ProjectChannelRef`；新增读/写 `~/.dsh/channels/<id>.workspaces.json` 的助手（enable 判断 = 任一 value == currentRoot；key 用 `ChannelStoreReader.workspaceKey(for:)` 派生）；`rebuildProjectRows` 中 `sessions = enabled ? loadSessions(...) : []`、未启用时折叠 + 标题行显示「未在项目启用」。

## 5. 兼容 / 迁移

- 惰性迁移：面板加载时若旧 `<项目>/.dsh/channels.json` 有该项目 refs 且全局 workspaces.json 未含 → 播种到该通道 workspaces.json（保留现有开关状态）。
- 关闭后历史消息桶仍保留（不删用户数据），只是不再展示/路由。
- 同名 workspace 消歧沿用现有 workspaceKey/disambiguate 规则。

## 6. 测试 / 验收

- runner 测试助手在临时 dshHome 写 `<channelId>.workspaces.json` 含 projectRoot（启用），保证现有路由语义不变；
- 新增：workspaces 不含项目根 → 普通消息回「未启用该通道」且不触发 session.create/prompt；含项目根 → 正常路由；`#wN` 导航放行（不门控）；channel-sessions 单测 set/isWorkspaceEnabled。
- 验收：`node --test core/tests/`、`swiftc -typecheck`、`tests/channel-panel/run.sh`。
