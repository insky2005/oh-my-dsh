---
name: workstream-panel
description: 改事项（Workstream）卡片一律走事项面板 REST API /api/workstreams/*，不直接改 .dsh/workstreams/*.md；补规划、改标题/需求指针/正文、登记阶段队列。Edit workstream cards through the oh-my-dsh Workstreams panel API instead of writing .dsh files directly.
user-invocable: false
---

# workstream-panel — 通过 API 改事项卡

oh-my-dsh 壳层的**事项面板**（Workstreams，⌥⌘K）通过 **localhost REST API** 驱动。
事项状态落在项目 `.dsh/workstreams/WS-*.md`（随仓库提交）；**面板是唯一写者**，
agent 改事项**一律走 `/api/workstreams/*`**，**不直接改 .dsh 文件**。

## 何时执行（硬规则）

- **只在被要求时执行**：用户明确说「改 / 补 / 登记某个事项」，或阶段交接提示词
  （`WorkstreamHandoff`）要求本步更新卡片时，才调用本 API；其余情况不动。
- **只写门内可写的字段**：标题 / 需求指针 / 正文、`## 规划` 段、`queues` 阶段队列映射。
- **不自签人工确认门**：`stage/confirm`（确认推进）与 `stage/reject`（退回）是
  **人工确认门**，只能由人在事项面板点按完成，agent **绝不**调用；
  `stage`（低层显式改阶段口子）同理不由 agent 调。
- **不直接改 `.dsh` 文件**：`.dsh/workstreams/*.md` 由面板写；绕过 API 改盘会让
  面板内存覆盖你的改动，用户也看不到反馈。`.dsh/requirements/*.md`、
  `.dsh/regression/*.md` 也不归本技能改。
- App 没运行时停下来告诉用户「请先打开 oh-my-dsh」，**不要**绕过 API 写文件。

## 端口发现（必做）

```bash
PORT="$(cat "${DSH_HOME:-$HOME/.dsh}/oh-my-dsh/shell-api.port" 2>/dev/null || cat "${DSH_HOME:-$HOME/.dsh}/oh-my-dsh/browser-api.port" 2>/dev/null || echo 3081)"
```

（首个可用者为准；App 没运行时一个都连不上，停下来请用户打开 App。）

## API 速查（http://127.0.0.1:$PORT）

| 方法/路径 | 请求体 | 说明 |
|---|---|---|
| GET `/api/workstreams/list` | `?workspace=<路径>` | 现有事项卡 + 解析失败项；`workspace` 传 `$(pwd)` |
| POST `/api/workstreams/update` | `{"workspace":"…","id":"WS-000012","title":"…","requirement":"REQ-003","body":"…","session":"$DSH_SESSION_ID"}` | 改标题 / 需求指针 / 正文；缺省字段不改写，显式空串清除 |
| POST `/api/workstreams/plan` | `{"workspace":"…","id":"WS-000012","heading":"## 规划","text":"…","session":"$DSH_SESSION_ID"}` | 整段替换某一级标题段（默认 `## 规划`；heading 不带 `## ` 会由服务端补上） |
| POST `/api/workstreams/queues` | `{"workspace":"…","id":"WS-000012","queues":[{"id":"q-3","stage":"task"}],"session":"$DSH_SESSION_ID"}` | 写阶段 ↔ 队列映射；空数组清空 |
| POST `/api/workstreams/create` | `{"workspace":"…","title":"…","requirement":"REQ-003","stage":"planning","body":"…","session":"$DSH_SESSION_ID"}` | 新建事项卡（**仅当用户明确要求**；拆解确认由需求池面板建卡） |
| POST `/api/workstreams/stage` | `{"workspace":"…","id":"…","stage":"design"}` | 低层显式改阶段口子；**agent 不调**，阶段推进走人工确认门 |
| POST `/api/workstreams/stage/confirm` / `stage/reject` | `{"id":"…","note":"…"}` / `{"id":"…","reason":"…"}` | **人工确认 / 退回**，**agent 绝不调** |

- `workspace` 传 `$(pwd)`；不传则用面板当前工作区。
- 每个写操作都带上本会话的 `session`（`$DSH_SESSION_ID`），面板据此把该事项绑定回本会话。
- `stage` 取值：`planning` / `design` / `task` / `acceptance` / `delivery`。
- `update` 的 `requirement` 传空串清除指针；`queues` 条目按 `[{id, stage?}]` 校验。
- 写成功返回 `{ok: true, workstream: …}`。
- `covered` / `delivery` 事实字段当前**没有**写路由（由验收 / 交付流程在面板侧记录）；
  **不要**为写它们绕过 API 改文件，也不要手写派生字段（`closed` / `outcome`）。

## 工作流

### 先看现状（避免重复建、确认 id）

```bash
curl -sG --data-urlencode "workspace=$(pwd)" "http://127.0.0.1:$PORT/api/workstreams/list"
```

### 补规划（规划阶段本步动作）

把目标 / 边界 / 验收标准（AC<n>）/ 阶段裁剪声明整理成 `## 规划` 段，整段提交：

```bash
cat > /tmp/ws-plan.json <<'JSON'
{"workspace": "<pwd 的输出>", "id": "WS-000012", "heading": "## 规划", "session": "<$DSH_SESSION_ID 的值>",
 "text": "- 目标：…（WHAT）\n- 边界：…\n- 验收标准：AC1 …；AC2 …\n- 阶段裁剪声明：不裁剪"}
JSON
curl -s -X POST "http://127.0.0.1:$PORT/api/workstreams/plan" -H 'Content-Type: application/json' --data-binary @/tmp/ws-plan.json
```

### 登记阶段队列

用 `/task-todo` 建好等待态队列后，把 `queueId` + 所属 `stage` 写回事项卡：

```bash
cat > /tmp/ws-queues.json <<'JSON'
{"workspace": "<pwd 的输出>", "id": "WS-000012", "session": "<$DSH_SESSION_ID 的值>",
 "queues": [{"id": "q-3", "stage": "task"}]}
JSON
curl -s -X POST "http://127.0.0.1:$PORT/api/workstreams/queues" -H 'Content-Type: application/json' --data-binary @/tmp/ws-queues.json
```

### 改标题 / 需求指针 / 正文

```bash
cat > /tmp/ws-update.json <<'JSON'
{"workspace": "<pwd 的输出>", "id": "WS-000012", "session": "<$DSH_SESSION_ID 的值>", "title": "新标题"}
JSON
curl -s -X POST "http://127.0.0.1:$PORT/api/workstreams/update" -H 'Content-Type: application/json' --data-binary @/tmp/ws-update.json
```

### 汇报

几行以内 —— 改了哪个 `WS-xxx`、改了哪几处、面板在哪；不粘贴卡片全文。

## 失败处理

| 现象 | 处理 |
|---|---|
| curl 连不上（Connection refused） | App 没运行：请用户打开 oh-my-dsh，**不要**直接改盘上文件 |
| `503 panel-unavailable` | 面板还没就绪：稍后重试一次；仍失败就请用户打开事项面板 |
| `400 no-workspace` | 面板还没有工作区：让用户先选好项目 |
| `400 missing-id` / `missing-title` | 请求缺 id / 标题：补全后再试 |
| `400 no-fields` | `update` 一个可改字段都没给：至少给 `title` / `requirement` / `body` 之一 |
| `400 missing-text` / `missing-queues` | `plan` / `queues` 少了必填字段：补齐后再试 |
| `400 invalid-stage` | `stage` 不是五个之一：改用 `planning` / `design` / `task` / `acceptance` / `delivery` |
| `400 invalid-queue` | `queues` 条目缺 id / 不是列表：按 `[{id, stage?}]` 修正 |
| `404 unknown-workstream` | 没有该 WS：先 `list` 确认 id |
| `409 evidence-missing` / `stage-changed` | 人工确认门未过 / 阶段已变：**不要**自行推进；请用户处理 |
| `500 write-failed` | 面板写盘失败：如实转述，稍后重试 |

## 不要做

- **不直接改 .dsh 文件**（`.dsh/workstreams/*.md` 由面板写；也不碰
  `.dsh/requirements/*.md`、`.dsh/regression/*.md`）；
- 不调 `stage/confirm` / `stage/reject`（人工确认门），也不调 `stage`（低层口子）；
- 不手写派生字段（`closed` / `outcome`）或 `covered` / `delivery` 事实（当前无写路由）；
- 不在用户没要求时新建事项 / 改阶段 / 建队列。
