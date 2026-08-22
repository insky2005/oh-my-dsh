# Channel 指令清单（已实现）

> 状态：✅ 与 `feature/channel` 当前实现同步（2026-08-22）
> 维护：**新增/改动指令时，必须同步更新本文档**（见文末「维护说明」）
> 实现位置：`core/lib/channel-commands.js`（斜杠指令）、`core/lib/channel-runner.js`（快捷指令 + 路由）、`core/lib/channel-workspaces.js`（代号/#tag）、`core/lib/channel-sessions.js`（会话映射）

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
| `/help` | — | `可用指令：\n` + 分组清单（全局 → 项目 → 快捷） | 见下方「/help 输出示例」 | `channel-commands.js helpText()` |
| `/ping` | — | `pong (Nms)` | `pong (0ms)` | `case 'ping'` |
| `/status` | — | 4 行：`通道：`、`连接：`（已连接/未连接）、`当前工作区：#wN (名), ~/path`、`当前会话：#sN (id), 标题` | 见下方示例 | `case 'status'` + `getStatus()` |
| `/workspaces` | — | `workspace 列表：\n#wN (名称): ~/路径\n…`；无 workspace 时 `没有可用的 workspace` | 见下方示例 | `case 'workspaces'/'wks'` |
| `/wks` | — | 同 `/workspaces`（别名） | 同上 | 同上 |

### /help 输出示例
```
可用指令：
全局指令（无需绑定项目）：
  /help — 列出所有指令
  /ping — 连通性测试
  /status — 查看连接/项目/会话状态
  /workspaces — 列出 workspace 并分配代号 #w1/#w2…（别名 /wks）
  /wks — 列出 workspace 并分配代号 #w1/#w2…
项目指令（需绑定 workspace / 先切好 workspace 上下文）：
  /new [名称] — 新建一个独立会话
  /sessions — 列出当前项目的所有会话（别名 /ses）
  /ses — 列出当前项目的所有会话
  /switch <名称/编号/#sN> — 切换当前会话
快捷指令（# 开头，设置当前项目 / 会话）：
  #w1、#w2… — 设置当前项目（workspace，见 /wks）
  #s1、#s2… — 设置当前会话（见 /sessions，/switch #sN）
```

### /status 输出示例
```
通道：weixin-clawbot-E68A6BA2
连接：已连接
当前工作区：#w1 (helloharness), ~/c/work.ai/deepseek-harness/helloharness
当前会话：#s1 (sess-abc), 会话甲
```
> 通道 = channelId；连接取 adapter 状态；当前工作区 = 通道级 lastWorkspace（代号/名称/~路径）；当前会话 = active 会话（代号/#id/标题）；两者都存于 `~/.dsh/channels/<channelId>.state.json`，重启可恢复。

### /wks 输出示例
```
workspace 列表：
#w1 (helloharness): ~/c/work.ai/deepseek-harness/helloharness
#w2 (repowikitest): ~/c/work.ai/deepseek-harness/repowikitest
```
> 名称 = dsh web 的 workspace `title`（缺省回退到路径 basename）；代号按 path 排序分配 `#w1/#w2…`；路径以 `~` 开头。

---

## 2. 项目指令（需绑定 workspace / 先切好 workspace 上下文）

| 指令 | 参数 | 响应内容格式 | 示例 | 实现 |
|---|---|---|---|---|
| `/new [名称]` | 可选会话名 | `已新建会话：<名称>`；名称缺省 `已新建会话：unnamed` | `已新建会话：我的项目` | `case 'new'` + `createSession()` |
| `/sessions` | — | `会话列表：\n#sN  名称  ~/路径\n…`；空时 `当前项目还没有会话（/new 新建）` | 见下方示例 | `case 'sessions'/'ses'` |
| `/ses` | — | 同 `/sessions`（别名） | 同上 | 同上 |
| `/switch <名称/编号/#sN>` | 会话名 / 编号 / 代号 | 成功 `已切换到：<名称>`；缺参 `用法：/switch <会话名或编号，或 #sN>`；代号越界 `找不到会话 #sN`；失败 `切换失败：<原因>` | `已切换到：我的会话` | `case 'switch'` + `switchSession()` |

### /sessions 输出示例
```
会话列表：
#s1  会话甲  ~/c/work.ai/deepseek-harness/helloharness
#s2  会话乙  ~/c/work.ai/deepseek-harness/helloharness
```
> 代号 `#sN` 按会话列表顺序（更新时间倒序）分配；名称优先会话 name，其次 sessionId/id；路径 `~` 开头。

### /new 说明
- 新建独立 dsh 会话并更新当前会话映射。
- 参数可带 `#wN` / `#<workspace名>` 指定在哪个项目下新建；未指定按「最近一次 / 第一个 workspace」回退。
- 回复 `已新建会话：<名称>`（名称即传入参数，缺省 unnamed）。

---

## 3. 快捷指令（`#` 开头，纯代号）

用于快速设置「当前项目 / 当前会话」；纯代号不当作提问发进会话。

| `#w1` | 设置当前工作区 | `已切换到工作区 #wN (名称), ~/路径\n当前会话：n/a\n最近会话（5）：…#sN (sessionId), 标题`；代号不存在 `未找到代号 #wN（/wks 查看）` | 见下方示例 | `channel-runner.js` quick 分支 |
| `#s1` | 设置当前会话 | `已切换到会话 #sN (sessionId), 会话标题`；不存在 `未找到会话 #sN（/sessions 查看）` | `已切换到会话 #s1 (sess-xxx), 会话甲` | 同上 |

> 判定：消息 trim 后匹配 `/^#([ws])(\d+)\s*$/i`。`#wN` 更新「最近 workspace」（lastWorkspace）并**把当前会话置为 n/a**（须再显式切会话），同时返回该工作区最近 5 条会话便于选择；`#sN` 把该会话设为当前会话（写 `sessions[conversationId]` + `activeSessionId`）。

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
| /switch 缺参 | `用法：/switch <会话名或编号，或 #sN>` |
| 普通文本路由无匹配 | `该会话未绑定任何项目（未匹配路由）。` |

---

## 6. 维护说明（新增/改动指令时必做）

1. **改代码**：
   - 新增斜杠指令 → 在 `core/lib/channel-commands.js` 的 `KNOWN` 表登记（含 `group`：`global`/`project`、`title`、`desc`、别名 `aliases`），并在 `run()` 的 switch 里实现 handler；如需分组显示，更新 `GLOBAL_ORDER` / `PROJECT_ORDER`。
   - 新增快捷指令 → 在 `core/lib/channel-runner.js` 的 quick 分支扩展 `#w/#s` 处理。
   - 改代号/名称/路径显示 → 在 `core/lib/channel-workspaces.js`（`assignCodes` / `normalizeWorkspace` / `toHomePath`）。
2. **改测试**：`core/tests/channel-commands.test.js`、`core/tests/channel-runner.test.js`、`core/tests/channel-workspaces.test.js`。
3. **更新本文档**：本表（§1–§5）与上文同步；若改了 `/help` 分组或文案，更新 §1 的 /help 输出示例。
4. **跑全量单测**：`node --test core/tests/`。
