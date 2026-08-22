# Channel 消息存储设计（全局化改造）

> 状态：📝 设计稿（2026-08-22 定稿，待实现）
> 更新：2026-08-22
> 关联：docs/channel-design.md（§4 配置模型）、docs/channel-ui-commands.md（§2.4 决策 E / §3.8）、core/lib/channel-sessions.js、core/lib/channel-store.js、core/lib/channel-runner.js、platforms/macos/src/ChannelPanel.swift、platforms/macos/src/main.swift

## 1. 背景与问题

当前 channel 的**消息日志**（用户聊天内容，与项目代码无关）和**会话映射**落在每个项目目录下：

| 数据 | 现状路径 | 写入方 |
|---|---|---|
| 凭据/账号 | `~/.dsh/channels/<channelId>.json`（chmod 600） | `core/lib/channel-store.js` ✅ 已全局 |
| 项目引用配置（开启的 channel） | `<项目>/.dsh/channels.json`（未提交） | ChannelPanel / main.swift |
| 会话映射 | `<项目>/.dsh/channels/<channelId>.sessions.json` | `core/lib/channel-sessions.js` |
| 消息日志 | `<项目>/.dsh/channels/<channelId>.messages.json` | `channel-sessions.js`（appendMessage） |

每次在项目 A 绑定某 channel，项目 A 里就会出现该 channel 的会话/消息文件——消息与项目无关却污染项目目录（本仓库当前就有 `weixin-clawbot-E68A6BA2.messages.json` 17KB 实例）。

## 2. 目标

- 消息 + 会话映射 → **全局 `~/.dsh/channels/`**；项目内只保留**引用配置**；
- 消息按 **`channelName.workspaceName.sessionId.messages.json`** 分桶存放；
- 项目内可反向定位：`channels.json` 的 refs（channelId + workspaceRoot）→ 全局文件名可确定推导。

## 3. 新存储布局

```
~/.dsh/channels/
  <channelId>.json                                    # 凭据/账号（不变）
  <channelId>.sessions.json                           # 会话映射（从项目迁来；记录含 projectRoot）
  <channelId>.workspaces.json                         # workspaceKey ↔ projectRoot 注册表（新增）
  <channelId>.<workspaceKey>.<sessionId>.messages.json    # 会话消息归档
  <channelId>.<workspaceKey>.system.messages.json     # 无会话消息（/help 等指令，sessionId=null）

<项目根>/.dsh/channels/channels.json                  # 项目 channel 引用/路由配置（提交进 git）
```

示例（channelId=`weixin-clawbot-E68A6BA2`、项目=`~/c/work.ai/deepseek-harness/helloharness`、会话=`session-97e994b0-…`）：

```
~/.dsh/channels/weixin-clawbot-E68A6BA2.json
~/.dsh/channels/weixin-clawbot-E68A6BA2.sessions.json
~/.dsh/channels/weixin-clawbot-E68A6BA2.workspaces.json
~/.dsh/channels/weixin-clawbot-E68A6BA2.helloharness.session-97e994b0-….messages.json
~/.dsh/channels/weixin-clawbot-E68A6BA2.helloharness.system.messages.json
helloharness/.dsh/channels/channels.json
```

## 4. 命名细则

- **channelName = channelId**：唯一标识，文件名安全字符（如 `weixin-clawbot-E68A6BA2`）；
- **workspaceKey**：项目根路径 basename 清洗后（保留 `A-Za-z0-9._-` 与 CJK，空白/其他 → `-`，超 48 字符截断）。**冲突消歧**：`workspaces.json` 注册表登记 `key ↔ projectRoot`，新建条目若 key 已被不同 projectRoot 占用 → 该 key 改 `basename-<sha1(projectRoot).slice(0,6)>`；清洗后为空（罕见）→ `ws-<hash6>`；
- **sessionId**：dsh 会话 id（`session-<uuid>`，文件名安全）；`sessionId=null`（指令/系统消息）→ 固定 `system` 桶；
- **dshHome 解析**：`dshHome || process.env.DSH_HOME || ~/.dsh`（与 channel-store 一致）；
- **消息记录 schema 不变**：`{ channelId, conversationId, sessionId, dir: "in"|"out", text, ts }`，每条记录附 `projectRoot` 字段；每文件保留 MAX_MESSAGES=1000 滚动上限。

## 5. store 设计

`createChannelSessions` 由「按 projectRoot 作用域」改为**按 channel 作用域**：

```
createChannelSessions({ channelId, dshHome, defaultProjectRoot })
```

原因：`#wN` 路由可把不同会话路由到不同项目，消息归档文件必须跟随**会话所属项目**（映射记录里的 projectRoot），而非 runner 启动时的首个 ref 项目。

- `appendMessage({ conversationId, sessionId, dir, text, ts, projectRoot? })`：projectRoot 缺省时取该 conversation 映射记录的 projectRoot，再无则 `defaultProjectRoot`；目标文件 = 由此 projectRoot 派生的 workspaceKey 对应的（sessionId ?? `system`）桶；
- `listMessages(conversationId)`：扫描本 channel 下该 workspace 全部消息桶文件（含 system），按 conversationId 过滤、按 ts 排序合并（会话轮换 `/new` 后历史在新旧文件间续接）；
- `getSession/setSession/listSessions` 语义不变，落盘到全局 `<channelId>.sessions.json`（与设计文档 §3.4 原文一致，消除文档↔实现分歧）。

## 6. 数据迁移方案

- **惰性迁移（主力）**：`createChannelSessions` 构造时，若新位置文件缺失且旧路径（`<projectRoot>/.dsh/channels/<channelId>.sessions.json|.messages.json`）存在 → 读取 → 按 sessionId 分组写入新桶（null → system 桶）→ **新文件全部写成功后**删除旧文件；sessions 并入全局 `<channelId>.sessions.json`（按 conversationId 合并取新）。天然幂等：旧文件已删即跳过；崩溃重跑靠「目标桶内按 (conversationId, dir, text, ts) 去重」防重复。
- **一次性 CLI**：`ohmy-core.js channel migrate [projectRoot] [--dsh-home <dir>]` 用于未再启动 runner 的旧 checkout 批量迁移。
- **本仓库自迁移**：实现完成后对 helloharness 本身执行一次迁移（现状 17KB messages 文件 → 分桶至 `~/.dsh/channels/`），确认旧文件删除、`.git status` 干净。
- **channels.json 落位**：`git mv` 旧路径 `.dsh/channels.json` → `.dsh/channels/channels.json` 并提交（此前未跟踪，本次一并纳入版本库，符合设计文档 §4.2「引用配置随仓库提交」）。

## 7. 边界与失败模式

| 场景 | 行为 |
|---|---|
| 同名项目（不同父目录） | workspaces.json 注册表消歧：后者加 6 位路径哈希后缀 |
| 跨卷写入/rename 失败 | 迁移用 copy+verify+unlink（不依赖 rename 原子性）；写失败则保留旧文件并记日志 |
| dshHome 不可写 | store 抛错，被 runner 逐消息 try/catch 隔离，不影响轮询循环 |
| 会话 `/new` 轮换 | 历史留在旧会话桶文件，新消息进新会话桶；listMessages 合并展示，内容不丢 |
| 指令消息（无会话） | system 桶独立存放，不与会话历史混淆 |
| 旧 checkout 项目 | parseProjectRefs 旧路径读回退；runner 启动时自动迁移该 channel 数据 |
| 文件名超长 | workspaceKey 48 字符截断 + 哈希；最坏文件名 ≈120 字符，远低于 APFS 255 |

## 8. 验收标准

1. `node --test core/tests/` 全绿（含新增/重写用例）；
2. 任意 (channelId, projectRoot, dshHome) 组合，消息/会话只出现在 `~/.dsh/channels/` 下正确文件名；项目目录不再产生 messages/sessions 文件；
3. 预置旧格式文件 → store 构造/`channel migrate` → 旧文件消失、新桶按会话分好、sessions 合并一致、幂等（重跑不重复）；
4. macOS 面板：项目视图会话列表从全局 sessions.json 过滤当前项目正常显示；开关写 `.dsh/channels/channels.json`（已提交）；
5. `ohmy-core.js channel run`（mock token）实跑一条消息：落盘到全局分桶文件，项目目录零新增；
6. `.gitignore` 更新后 `git status` 干净：本仓库旧 messages 文件已迁走，`channels.json` 已提交；
7. 文档（设计/命令手册）与实现一致。