# Channel 指令清单（已实现）

> 状态：✅ 与 `feature/channel-commands-v2` 当前实现同步（指令体系 v2）
> 维护：**新增/改动指令时，必须同步更新本文档**（见文末「维护说明」）
> 实现位置：`core/lib/channel-commands.js`（斜杠指令）、`core/lib/channel-runner.js`（快捷指令 + 路由 + 工作区/会话切换注入）、`core/lib/channel-workspaces.js`（代号/#tag）、`core/lib/channel-sessions.js`（会话映射）

本清单记录**已实现**的所有客户端内指令：命令格式、参数、响应内容格式。响应均为纯文本（发送前经 `toPlainText` 去 markdown 符号），示例中的路径以 `~` 开头、不暴露本机用户目录。

---

## 0. 判定规则

- 消息**整体以 `/` 开头**且首词匹配已知命令 → 当斜杠指令处理；否则按普通消息路由。
- 消息是**纯 `#` 代号**（`#wN` / `#sN`，无其他内容）→ 当快捷指令处理。
- 消息里同时含 `#` 代号 + 正文（如 `#w1 帮我看看`）→ 按 #tag 路由到对应项目会话，代号从发给会话的文本中剥离。
- 未知 `/xxx`（非路径）→ 回复「未知指令」。

---

## 1. 全局指令（无需绑定项目）

这些指令与项目/会话无关，未绑定项目也能用，**不会**出现「该会话未绑定任何项目」提示。

| 指令 | 参数 | 响应内容格式 | 示例 | 实现 |
|---|---|---|---|---|
| `/help` | — | `可用指令：\n` + 分组清单（全局 → 工作区 → 快捷） | 见下方「/help 输出示例」 | `channel-commands.js helpText()` |
| `/ping` | — | `pong (Nms)` | `pong (0ms)` | `case 'ping'` |
| `/status` | — | 4 行：`通道：`、`连接：`（已连接/未连接）、`当前工作区：#wN (名), ~/path`、`当前会话：#sN (id), 标题` | 见下方示例 | `case 'status'` + `getStatus()` |

### /help 输出示例
```
可用指令：
全局指令（无需绑定项目）：
  /help — 列出所有指令
  /ping — 连通性测试
  /status — 查看连接/项目/会话状态
工作区指令（需绑定 workspace / 先切好 workspace 上下文）：
  /workspaces、/wks [名称或代号] — 列出或切换工作区
  /sessions、/ses [会话id或代号] — 列出或切换会话（最近 5 条）
  /new [内容] — 创建新会话
快捷指令（# 开头，设置当前工作区 / 会话）：
  #w1、#w2… — 切换工作区（见 /workspaces）
  #s1、#s2… — 切换会话（见 /sessions）
```

### /status 输出示例
```
通道：weixin-clawbot-E68A6BA2
连接：已连接
当前工作区：#w1 (helloharness), ~/c/work.ai/deepseek-harness/helloharness
当前会话：#s1 (sess-abc), 会话甲
```
> 通道 = channelId；连接取 adapter 状态；当前工作区 = 通道级 lastWorkspace（代号/名称/~路径）；当前会话 = active 会话（代号/#id/标题）；两者都存于 `~/.dsh/channels/<channelId>.state.json`，重启可恢复。

---

## 2. 工作区指令（需绑定 workspace / 先切好 workspace 上下文）

### /workspaces、/wks —— 列出或切换工作区

| 模式 | 参数 | 响应内容格式 | 示例 | 实现 |
|---|---|---|---|---|
| 列出 | —（无内容） | `workspace 列表：\n#wN (名称): ~/路径\n…`；无可用时 `没有可用的 workspace` | 见下方示例 | `case 'workspaces'/'wks'`（无内容分支） |
| 切换 | `#wN` / `wN` / 工作区名 / 路径片段 | `已切换到工作区 #wN (名称), ~/路径\n当前会话：n/a\n最近会话（5）：…#sN (sessionId), 标题` | `/workspaces Alpha`、`/workspaces #w1` | `case 'workspaces'/'wks'` + `switchWorkspace()`（效果同 `#wN`） |

> **列出**只显示**已启用**该通道的 workspace（沿用项目开关门控）；**切换**要求目标工作区已启用该通道，否则回「该项目未启用该通道，请在面板「通道」项目视图开启后使用」；目标不存在回 `未找到工作区：<内容>（/wks 或 /workspaces 查看）`。切换后当前会话置为 n/a（须再显式选会话），并返回目标工作区最近 5 条会话便于选择。

### /wks 列出示例
```
workspace 列表：
#w1 (helloharness): ~/c/work.ai/deepseek-harness/helloharness
#w2 (repowikitest): ~/c/work.ai/deepseek-harness/repowikitest
```
> 名称 = dsh web 的 workspace `title`（缺省回退到路径 basename）；代号按 path 排序分配 `#w1/#w2…`；路径以 `~` 开头。

### /workspaces Alpha 切换示例
```
已切换到工作区 #w1 (Alpha), ~/repo/alpha
当前会话：n/a
最近会话（5）：
  #s1 (sess-6), 会话6
  #s2 (sess-5), 会话5
```

### /sessions、/ses —— 列出或切换会话

| 模式 | 参数 | 响应内容格式 | 示例 | 实现 |
|---|---|---|---|---|
| 列出 | —（无内容） | `工作区 #wN (名), ~/路径\n会话列表：\n#sN (sessionId), 标题…`（最近 5 条）；空时 `当前项目还没有会话（/new 新建）` | 见下方示例 | `case 'sessions'/'ses'`（无内容分支） |
| 切换 | `#sN` / sessionId / 会话名 / 序号 | `已切换到会话 #sN (sessionId), 标题`；找不到 `找不到会话：<内容>` | `/sessions #s2`、`/sessions 会话乙`、`/ses 2` | `case 'sessions'/'ses'` + `switchSession()`（效果同 `#sN`） |

> **切换**把该会话设为当前会话（写 conversation 映射 `sessions[conversationId]` + activeSession），下一条普通消息继续在该会话；当前工作区未启用该通道时被门控（回「该项目未启用该通道…」）。**列出**沿用现逻辑：首行 = 当前工作区（通道级 lastWorkspace），会话来自 dsh web 当前项目真实会话，按更新时间倒序取最近 5 条。

### /sessions 列出示例
```
工作区 #w1 (helloharness), ~/c/work.ai/deepseek-harness/helloharness
会话列表：
#s1 (s-1), 会话甲
#s2 (s-2), 会话乙
#s3 (s-3), 会话丙
#s4 (s-4), 会话丁
#s5 (s-5), 会话戊
```

### /new —— 创建新会话

| 模式 | 参数 | 响应内容格式 | 示例 | 实现 |
|---|---|---|---|---|
| 无内容 | — | `创建新会话 #sN (sessionId)\n请继续与我对话，我正在听...` | `/new` | `case 'new'` + `createSession()` |
| 有内容 | 会话内容 | `创建新会话 #sN (sessionId)`，随后 `sendTyping` 显示输入状态、后台生成并回推答案 | `/new 帮我看看项目` | 同上 + `dispatchGeneration` |

> **两模式行为一致**：统一先回复 `创建新会话 #sN (sessionId)`（N = 该会话在会话列表中的序号），并更新 activeSession、绑定到当前 conversation。
> - **无内容**：创建会话 + `rename` 为 `New Session`、标记 pending；回复后**等待用户下一条消息**——第一条普通消息激活该会话（以该消息内容 prompt + 设为标题）。
> - **有内容**：创建会话 + `rename` 为内容、发起会话（prompt = 指令后的内容）；回复后立即 `sendTyping(status=1)`（微信原生「正在输入…」），后台生成完成回推答案并 `sendTyping(status=2)`。
> - 目标工作区：内容可带 `#wN` / `#<workspace名>` 指定；未指定按「当前工作区（lastWorkspace）→ 第一个 workspace」回退。目标工作区未启用该通道 → 回「该项目未启用该通道…」、不建会话。忙门：同 conversation 在途生成时再来 `/new <内容>` → 回「请等待，前一条消息还在处理中」。
> - 创建方式对齐 dsh web 客户端 / Wiki / IssueRunner 面板：解析出目标 workspace 后传 `session.create { workspaceId }`（会话归到该工作区，而非 Ungrouped）。

---

## 3. 快捷指令（`#` 开头，纯代号）

用于快速设置「当前工作区 / 当前会话」；纯代号不当作提问发进会话。

| 指令 | 功能 | 响应内容格式 | 示例 | 实现 |
|---|---|---|---|---|
| `#w1` | 切换工作区 | `已切换到工作区 #wN (名称), ~/路径\n当前会话：n/a\n最近会话（5）：…#sN (sessionId), 标题`；不存在 `未找到工作区 #wN （/wks 或 /workspaces 查看）` | 见下方示例 | `channel-runner.js` quick 分支 |
| `#s1` | 切换会话 | `已切换到会话 #sN (sessionId), 会话标题`；不存在 `未找到会话 #sN （/ses 或 /sessions 查看）` | `已切换到会话 #s1 (sess-xxx), 会话甲` | 同上 |

> 判定：消息 trim 后匹配 `/^#([ws])(\d+)\s*$/i`。`#wN` 更新「最近 workspace」（lastWorkspace）并**把当前会话置为 n/a**（须再显式切会话），同时返回该工作区最近 5 条会话便于选择；`#sN` 把该会话设为当前会话（写 `sessions[conversationId]` + `activeSessionId`）。两者均受**项目开关门控**：目标/当前工作区未启用该通道 → 回「该项目未启用该通道…」。

### #w1 输出示例（切换后附带最近 5 条会话）
```
已切换到工作区 #w1 (Alpha), ~/repo/alpha
当前会话：n/a
最近会话（5）：
  #s1 (sess-6), 会话6
  #s2 (sess-5), 会话5
  #s3 (sess-4), 会话4
  #s4 (sess-3), 会话3
  #s5 (sess-2), 会话2
```

---

## 4. #tag 路由（代号 + 正文）

消息含 `#w1`（代号精确匹配）或 `#<workspace名/path片段>` → 路由到该项目会话；多个 tag 取第一个有效；`#tag` 本身从发往会话的文本中剥离。

- 未指定 tag 时回退：最近一次提到的 workspace → 第一个 workspace。
- 普通文本若**路由无匹配**（无引用该项目/未绑定）→ 回复：
  ```
  该会话未绑定任何项目（未匹配路由）。
  ```

---

## 5. 统一错误 / 兜底回复

| 场景 | 响应 |
|---|---|
| 未知 `/xxx` | `未知指令 /xxx（/help 查看）` |
| 无 workspace 可列 | `没有可用的 workspace` |
| 无会话可列 | `当前项目还没有会话（/new 新建）` |
| /workspaces 切换目标不存在 | `未找到工作区：<内容>（/wks 或 /workspaces 查看）` |
| /sessions 切换目标不存在 | `找不到会话：<内容>` |
| 切换目标/当前工作区未启用该通道 | `该项目未启用该通道，请在面板「通道」项目视图开启后使用` |
| 普通文本路由无匹配 | `该会话未绑定任何项目（未匹配路由）。` |

---

## 6. 维护说明（新增/改动指令时必做）

1. **改代码**：
   - 新增斜杠指令 → 在 `core/lib/channel-commands.js` 的 `KNOWN` 表登记（含 `group`：`global`/`workspace`、`title`、`desc`、别名 `aliases`），并在 `run()` 的 switch 里实现 handler；如需分组显示，更新 `GLOBAL_ORDER` / `WORKSPACE_ORDER`。
   - 新增快捷指令 → 在 `core/lib/channel-runner.js` 的 quick 分支扩展 `#w/#s` 处理。
   - 工作区/会话切换逻辑（`/workspaces`、`/sessions` 带内容，等同 `#wN`/`#sN`）→ 在 `core/lib/channel-runner.js` 注入的 `switchWorkspace` / `switchSession` / `bindSession` deps 里维护。
   - 改代号/名称/路径显示 → 在 `core/lib/channel-workspaces.js`（`assignCodes` / `normalizeWorkspace` / `toHomePath`）。
2. **改测试**：`core/tests/channel-commands.test.js`、`core/tests/channel-runner.test.js`、`core/tests/channel-workspaces.test.js`。
3. **更新本文档**：本表（§1–§5）与上文同步；若改了 `/help` 分组或文案，更新 §1 的 /help 输出示例。
4. **跑全量单测**：`node --test core/tests/`。
