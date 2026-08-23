# Channel – Message – Session 关联模型（核查与调整方案）

> 状态：✅ 核查+实施（A/B/C/D 已于 2026-08-22 在 core 落地，见 §7 实施记录）
> 更新：2026-08-22
> 关联：docs/channel-design.md（统一抽象/配置模型）、docs/channel-storage.md（存储全局化）、docs/channel-status.md（完成状态）、docs/channel-commands.md（指令）、.dsh/wiki/modules/channel-panel.md、core/lib/channel-runner.js、core/lib/channel.js、core/lib/session-driver.js、core/lib/channel-sessions.js、core/lib/channel-store.js、core/lib/channel-workspaces.js、platforms/macos/src/ChannelPanel.swift
> 说明：基于需求「Channel（通道）↔ Message ↔ Session（含 Workspace）关联模型」对现有设计逐项核查，列出需要做的调整。**本文档只做核查与方案，不实现代码**；调整项见 §5 落地优先级，供后续单独 feature/fix 分支实施。

## 1. 需求模型（规范化）

用户给定的关联模型：

1. **Channel = 对话的通道**：一个微信账号对应一个 channel（channelId 全局唯一）。
2. **Message = 经通道进入 oh-my-dsh 的消息**：收到消息后，查「当前工作区、当前会话」，把消息作为 prompt 转发给 dsh web 的 **Session**（会话）。
3. 于是存在 **channel ↔ message ↔ session** 的关联。

规范化为实体关系：

- `Channel(1) ──(N)── Conversation`：一个通道下多个会话/群；
- `(Channel, Conversation) ──(1)── Session`：一条会话映射，绑定到唯一 dsh 会话；
- `Session ──(N)── Message`：会话内往返消息（in/out）；
- `Session ──(1)── Workspace`：会话归属某个工作区（cwd/workspaceId）。

## 2. 现状核查（已实现）

### 2.1 已满足的部分

| 需求点 | 实现 | 出处 |
|---|---|---|
| Channel 实例（一账号一通道，channelId 唯一） | `GlobalChannel`，UserDefaults `channel.global.list`；凭据 `~/.dsh/channels/<id>.json` | ChannelPanel.swift:17,585；channel-store.js:54 |
| 入站消息事件（channelId/conversationId/…） | `ChannelEvent{channelId, platform, conversationId, sender, text?, media?, ts}` | core/lib/channel.js:37 |
| channelId↔conversationId↔sessionId 关联映射 | runner 用 `runtime.setSession(conversationId, {sessionId, projectRoot})` | channel-runner.js:320；channel-store.js:145,152 |
| 消息作 prompt 转发进 dsh 会话 | session.create/rename/prompt(queue)/轮询/lastMessage | session-driver.js:151 |
| 消息归档（关联 channel/conversation/session） | `{channelId, conversationId, sessionId, dir, text, ts}`，`<root>/.dsh/channels/<id>.messages.json` | channel-sessions.js:104 |
| 按「当前工作区」路由（#tag > last > first） | `resolveWorkspaceTag` | channel-workspaces.js:93 |
| 通道级「当前会话/工作区」状态 | `~/.dsh/channels/<id>.state.json`（lastWorkspace/activeSessionId/连接态） | channel-store.js:125 |

### 2.2 偏差 / 缺口（需调整）

| # | 需求意图 | 现状 | 结论 | 出处 |
|---|---|---|---|---|
| G1 | 消息转发到「当前/关联会话」、**多轮复用同一会话** | **已修复（A）**：sessionDriver.run 尊重 `event.sessionId`，有则复用、无则 create；runner 先按 store 映射/复用再 enqueue | ✅ | session-driver.js run()；channel-runner.js |
| G2 | 按「当前工作区+当前会话」路由 | **已修复（B）**：refs 显式绑定（conversation/keyword）优先，否则 workspace-tag（#tag>last>first）兜底；handleEvent 对已绑定事件的合成 ref 兜底 | ✅ | channel.js resolveRefBinding；channel-runner.js |
| G3 | session 归属 workspace | **已修复（C）**：普通消息路由到 workspace 后以 `workspaceId` 创建/复用会话（无 workspace 才回退 cwd） | ✅ | channel-runner.js；session-driver.js createSession |
| G4 | 关联存储单一事实来源 | **已修复（D）**：createChannelSessions 改按 channel 作用域（全局 `~/.dsh/channels/`：sessions.json + workspaces.json + `channelId.workspaceKey.sessionId.messages.json` 分桶）；runner 会话映射与消息归档都走同一全局 store；项目目录不再产生消息/会话文件 | ✅ | channel-sessions.js；channel-runner.js |
| G5 | 面板项目视图展示 Channel▸Session(+Message) 关联 | 项目视图 `loadSessionNames` 读项目 `.dsh/channels/<id>.sessions.json`（G4 的死文件 → 恒空），不读消息、不读 state.json 映射 | **不满足** | ChannelPanel.swift:502 |

## 3. 需要做的调整（对应 §2.2）

### A. 会话复用（G1，行为正确性 P0）
让 session-driver 的 `run` 尊重 `event.sessionId`：已有映射则**复用该会话直接 prompt**，无则 `create` 后再写映射。保证一次会话、多轮对话，与 channel-sessions.js 注释「multi-turn chats keep one session until /new or /switch」一致。
- 改动点：`core/lib/session-driver.js` run 逻辑 + runner 传参会话 id；新增单测（core/tests/channel-runner.test.js 断言同一 conversation 复用同一 sessionId、跨 conversation 各自独立）。

### B. 路由语义统一（G2，行为正确性 P0）
消除双轨，明确唯一路由来源：以**通道级「当前工作区」（lastWorkspace / #tag）**为权威（贴合需求）；项目引用 refs 的 `routingConversations/keywords/default` 降级为「绑定/默认兜底」，与 workspace-tag 对齐。
- 改动点：`core/lib/channel-runner.js` 普通消息路径 + `core/lib/channel.js` Router 的调用边界；文档（channel-design.md §6）同步更新。

### C. 会话 ↔ 工作区归属（G3，行为正确性 P0）
普通消息路由解析出 workspace 后，用 **`workspaceId`** 创建/复用会话（对齐 /new 路径与 dsh web 客户端），使会话归入工作区而非 Ungrouped。
- 改动点：`core/lib/session-driver.js`（支持按 workspaceId 复用）+ `core/lib/channel-runner.js` 普通路径；新增断言「会话出现在 workspace.sessionIds」。

### D. 关联存储单一事实来源（G4，数据一致性 P1）
落地 `docs/channel-storage.md`：消息/会话迁至全局 `~/.dsh/channels/`，按 `channelId.workspaceKey.sessionId.messages.json` 分桶（无会话入 `system` 桶）；`createChannelSessions` 改按 channel 作用域；停用/删除项目 sessions.json 死路径；含惰性迁移 + `channel migrate` CLI + 本仓库自迁移。

### E. 面板项目视图（G5，UI P2）
项目视图改从 **channel 作用域存储**（全局化后 `~/.dsh/channels/<id>.sessions.json` + 分桶消息）取会话与消息，展示 **Channel ▸ Session ▸ Message** 列表；数据源与 D 保持一致。
- 改动点：`platforms/macos/src/ChannelPanel.swift`（loadSessionNames → 全局存储；新增消息列表 UI）；与 channel-status.md §3.2「会话/消息分组 UI 📋 待办」衔接。

### F. 模型定义补全（文档）
文档化三种粒度并让实现一致：
- **通道级当前工作区**（lastWorkspace，channel 作用域）；
- **每 conversation 会话绑定**（(channelId,conversationId)→sessionId，路由权威）；
- **通道级 active 会话**（activeSessionId，服务 /status、/new 激活、#sN）。

## 4. 数据流（调整后目标）

```
平台(微信) → adapter.onEvent → ChannelEvent{channelId, conversationId, text, media, ts}
  → runner: 指令/快捷 直接处理（不经 Router）
  → 普通消息: resolveWorkspaceTag(#tag>last>first) 确定当前工作区
      → 会话映射: runtime.getSession(conversationId) 已有则复用；
                   无（或 #tag 切工作区）→ session.create({workspaceId}) + 写映射
      → 转发 prompt（复用会话）→ 轮询 running → 取最后 assistant 消息
      → appendMessage(in/out, 带 sessionId/workspaceKey)
      → adapter.send(conversationId, reply)
```

## 5. 落地优先级与影响面

| 优先级 | 调整 | 改动文件 | 验证 |
|---|---|---|---|
| P0 | A 会话复用 | session-driver.js、channel-runner.js | node --test core/tests/ |
| P0 | C 工作区归属 | session-driver.js、channel-runner.js | 新增 workspaceId 断言 |
| P0 | B 路由统一 | channel-runner.js、channel.js、channel-design.md | core 单测 |
| P1 | D 存储全局化 | channel-sessions.js、channel-store.js、CLI | channel-storage.md 验收标准 |
| P2 | E 面板项目视图 | ChannelPanel.swift | 手动 QA |

> 与 docs/channel-status.md §5 待办衔接：A/B/C 为「会话驱动/路由」行为正确性，D 即已列「存储全局化改造」，E 即已列「面板消息分组 UI」。

## 6. 明确不在本文档范围

- 钉钉/飞书适配器（M4）不在本文；

## 7. 实施记录（A/B/C/D/E 已于 2026-08-22 落地）

| 项 | 改动 | 文件 | 测试 |
|---|---|---|---|
| A 会话复用 | sessionDriver.run 复用 event.sessionId（存在则不再 create/rename），返回 sessionId | core/lib/session-driver.js | channel-association.test.js「A」 |
| C 工作区归属 | 普通消息以 workspaceId 创建/复用会话，无 workspace 才回退 cwd | core/lib/channel-runner.js、session-driver.js | channel-association.test.js「C」 |
| B 路由统一 | 新增 resolveRefBinding（conversation/keyword 显式绑定），runner 先 refs 绑定后 workspace-tag 兜底；handleEvent 对已绑定事件合成 ref | core/lib/channel.js、channel-runner.js | channel-association.test.js「B」 |
| D 存储单一来源 | createChannelSessions 改按 channel 作用域全局存储（sessions/workspaces/分桶消息）；runner 会话映射与消息都走同一 store；忽略历史迁移（按需求） | core/lib/channel-sessions.js、channel-runner.js | channel-sessions.test.js（重写） |
| E 面板项目视图数据源 + 消息列表 | 新增 ChannelStoreReader.swift（纯 Foundation 读全局 sessions/分桶消息）；ChannelPanel 项目视图改读全局 store，会话行展开显示消息列表 | platforms/macos/src/ChannelStoreReader.swift、ChannelPanel.swift | tests/channel-panel/run.sh（无头单测） |

> 验证：`node --test core/tests/` **154 全绿**（基线 148 + A/B/C/D + /new 会话绑定回归）；`tests/channel-panel/run.sh` 无头单测通过；`scripts/local-ci.sh swift` 全量 swiftc 编译检查通过。

> **修复记录（2026-08-22）**：/new 创建的会话此前未绑定到发起 conversation，导致 /new Hello 后下一条普通消息又新建会话。已修复——/new（含/不含内容）后把新建会话写入 conversation→session 映射；pending 激活路径同步写入映射。回归用例见 channel-association.test.js「/new binds …」。