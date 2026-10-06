---
name: workstream-panel
description: 改事项（Workstream）卡片、按阶段建任务、启动事项/阶段队列、查看任务、按会话反查当前事项并把事项面板聚焦给用户，一律走事项面板 REST API /api/workstreams/*，不直接改 .dsh/workstreams/*.md。Edit workstream cards and stage tasks through the oh-my-dsh Workstreams panel API instead of writing .dsh files directly.
user-invocable: false
---

# workstream-panel — 通过 API 改事项卡与阶段任务

oh-my-dsh 壳层的**事项面板**（Workstreams，⌥⌘K）通过 **localhost REST API** 驱动。
事项卡片落在项目 `.dsh/workstreams/WS-*.md`（随仓库提交），执行队列与三级任务落在
项目 `.dsh/workstreams/queues.json`（ignored）；**面板是唯一写者**，
agent 改事项、建阶段任务、启动 / 暂停队列**一律走 `/api/workstreams/*`**，
**不直接改 .dsh 文件**。

## 何时执行（硬规则）

- **只在被要求时执行**：用户明确说「改 / 补 / 登记某个事项」「把这个事项拆成任务 /
  启动队列 / 看看任务」，或阶段交接提示词（`WorkstreamHandoff`）要求本步动作时，
  才调用本 API；其余情况不动。
- **只写门内可写的字段**：标题 / 需求指针 / 正文、`## 规划` 段、事项唯一队列映射
  （`queues`），以及**等待态**阶段任务（`task/create`）。
- **不自签人工确认门**：`stage/confirm`（确认推进）与 `stage/reject`（退回）是
  **人工确认门**，只能由人在事项面板点按完成，agent **绝不**调用；
  `stage`（低层显式改阶段口子）同理不由 agent 调。
- **拆分后先停**：`task/create` 只建**等待态**任务（= 任务拆分本身），建完**停下请人
  确认拆分合理**；**只有人确认后**（或用户明确要求启动）才 `queue/start` 启动实施，
  不在人未确认时自行起跑。
- **不直接改 `.dsh` 文件**：`.dsh/workstreams/*.md` 与 `.dsh/workstreams/queues.json`
  由面板写；绕过 API 改盘会让面板内存覆盖你的改动，用户也看不到反馈。
  `.dsh/requirements/*.md`、`.dsh/regression/*.md` 也不归本技能改。
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
| GET `/api/workstreams/bound` | `?session=$DSH_SESSION_ID` | **按会话反查**：本会话已绑定的事项（`workstreams[]`，`workstream` = 第一个）；未绑定返回空列表 |
| GET `/api/workstreams/task/list` | `?workspace=<路径>` | **查看任务**：该工作区的队列 + 三级任务（状态 / 会话 / 失败原因）；`workspace` 传 `$(pwd)` |
| POST `/api/workstreams/update` | `{"workspace":"…","id":"WS-000012","title":"…","requirement":"REQ-003","body":"…","session":"$DSH_SESSION_ID"}` | 改标题 / 需求指针 / 正文；缺省字段不改写，显式空串清除 |
| POST `/api/workstreams/plan` | `{"workspace":"…","id":"WS-000012","heading":"## 规划","text":"…","session":"$DSH_SESSION_ID"}` | 整段替换某一级标题段（默认 `## 规划`；heading 不带 `## ` 会由服务端补上） |
| POST `/api/workstreams/queues` | `{"workspace":"…","id":"WS-000012","queues":["q-3"],"session":"$DSH_SESSION_ID"}` | 登记该事项的**唯一**队列 id（一事项一队列，**0..1**）；空数组清空 |
| POST `/api/workstreams/task/create` | `{"workspace":"…","id":"WS-000012","stage":"task","titles":["…","…"],"session":"$DSH_SESSION_ID"}` | **按阶段创建任务**：建**等待态**阶段任务（**只建不启动**）；`stage` 缺省 = 卡片当前阶段；`titles` 每条由面板生成阶段交接提示词、追加到事项唯一队列（没有才建）；也可只传整段 `body` |
| POST `/api/workstreams/queue/start` | `{"workspace":"…","id":"WS-000012","stage":"task","session":"$DSH_SESSION_ID"}` | **启动事项 / 阶段队列**；带 `stage` = 只跑该阶段任务（跑完自动暂停队列）；不带 = 事项级（整条队列 FIFO）；仅在用户要求 / 人已确认拆分后 |
| POST `/api/workstreams/queue/pause` | `{"workspace":"…","id":"WS-000012","session":"$DSH_SESSION_ID"}` | 暂停队列（不影响已在跑的会话） |
| POST `/api/workstreams/covered` | `{"workspace":"…","id":"WS-000012","covered":{"paths":["docs/x.md"],"base":"<blob/tree>","head":"<blob/tree>"},"session":"$DSH_SESSION_ID"}` | **记录验收点记录**（事实；验收 / 交付阶段必选）；`covered: null` 清除；缺 `paths` / 空 `paths` 报错 |
| POST `/api/workstreams/delivery` | `{"workspace":"…","id":"WS-000012","delivery":{"pr":42,"url":"https://github.com/o/r/pull/42","state":"open"},"session":"$DSH_SESSION_ID"}` | **记录交付事实**（`pr` / `url`）；`delivery.outcome` 是**派生缓存**，服务端按 PR 观察（`state` / `merged` / `abandoned`）现算，**禁止手写** |
| POST `/api/workstreams/create` | `{"workspace":"…","title":"…","requirement":"REQ-003","stage":"planning","body":"…","session":"$DSH_SESSION_ID"}` | 新建事项卡（**仅当用户明确要求**；拆解确认由需求池面板建卡） |
| POST `/api/workstreams/stage` | `{"workspace":"…","id":"…","stage":"design"}` | 低层显式改阶段口子；**agent 不调**，阶段推进走人工确认门 |
| POST `/api/workstreams/stage/confirm` / `stage/reject` | `{"id":"…","note":"…"}` / `{"id":"…","reason":"…"}` | **人工确认 / 退回**，**agent 绝不调** |

- `workspace` 传 `$(pwd)`；不传则用面板当前工作区。
- **主场会话（`session` 绑定）**：写请求带 `session`（`$DSH_SESSION_ID`）时，面板把该事项的**主场会话**记成这次会话（`.dsh/workstreams/local.json` 的 `workstreamSessions`，ignored）。一个事项**只有一条**、**后写覆盖先写**（last-writer-wins）——这是运行时绑定，**不是「绑回来就永久有效」的契约**。面板「在会话中处理」会复用它；人在面板确认阶段后，面板把**下一阶段**交接提示词发回它（`bound` 反查的也是它）。因此**只有真正在推进该事项的对话才带 `session`**；阶段 runner / 子会话等**临时会话不要带**——它们写完就消失，带上会把主场会话覆盖成一条死会话（让人在面板「在会话中处理」重新绑定即可恢复）。
- **`focus`（对话 → 面板）**：任意路由可带 `focus: true`（写请求放 body，读请求放 `?focus=true`）；仅当请求成功（返回 200）时面板置前，并把目标卡高亮、滚动到可见。`create` 聚焦返回的新卡；`bound` 聚焦响应里**第一张**绑定卡；其余写路由聚焦请求的 `id`；其余读路由只置前（无 id）。**默认 `false`**，普通写卡不会抢用户的右栏。
- `stage` 取值：`planning` / `design` / `task` / `acceptance` / `delivery`。
- `update` 的 `requirement` 传空串清除指针；`queues` 是队列 id 字符串列表（**0..1**）。
- `task/create` 的 `titles` 与 `body` 至少给一个（只给 `body` 时取首行做标题）；`stage` 显式给空串是错误。
- `queue/start` 的 `stage` 缺省 = 事项级；给 `stage` = 阶段级（只跑该阶段任务）。
- 写成功返回 `{ok: true, …}`：`update` / `create` / `stage` / `plan` / `queues` 回 `workstream`；
  `task/create` 回 `queue` + `tasks`；`task/list` 回 `workspace` + `tasks` + `queues`；
  `queue/start` / `queue/pause` 回 `queue`（`start` 另带 `stage`）。
- `covered` / `delivery` 用上面的写路由记**事实**；`delivery.outcome` 是**派生缓存**（服务端按 PR 状态
  现算），**禁止手写**；`closed` / `split` 等派生字段同样不写。
- 交付阶段动作由面板执行（「交付」按钮收集 git / GitHub / token 事实并起交付会话）；agent 不要
  直接改盘上文件，也不要手写 `outcome`。

## 工作流

### 先看现状（避免重复建、确认 id）

```bash
curl -sG --data-urlencode "workspace=$(pwd)" "http://127.0.0.1:$PORT/api/workstreams/list"
```

### 反查本会话的事项（对话 → 面板）

不知道当前对话对应哪个事项时，用 `$DSH_SESSION_ID` 反查；要把用户的注意力带回事项面板时，
给任意请求加 `focus: true`（读请求用 `?focus=true`，默认关闭）：

```bash
# 反查：本会话绑定的事项（未绑定则 workstreams 为空）
curl -sG --data-urlencode "session=$DSH_SESSION_ID" \
  "http://127.0.0.1:$PORT/api/workstreams/bound"

# 反查并聚焦：面板置前、高亮该事项卡
curl -sG --data-urlencode "session=$DSH_SESSION_ID" --data-urlencode "focus=true" \
  "http://127.0.0.1:$PORT/api/workstreams/bound"
```

返回 `{ok, session, workstreams:[…], workstream?}`（`workstream` = 第一个，供单事项流程）。
无绑定时 `workstreams` 为空；需要全量就 `list`，要给用户看卡就带 `focus: true`。

### 查看任务 / 队列

```bash
curl -sG --data-urlencode "workspace=$(pwd)" "http://127.0.0.1:$PORT/api/workstreams/task/list"
```

返回 `tasks[]`（`id` / `title` / `state` / `stage` / `session` / `error` / `report`）与
`queues[]`（`id` / `name` / `workstreamId` / `state` / `taskIds`）。
`state` 取值：任务 `pending` / `queued` / `running` / `done` / `failed` / `needsReview` /
`cancelled`，队列 `draft` / `active` / `paused` / `done` / `closed`。
**只读**，用来确认事项已有的队列与任务，再决定建 / 启动。

### 补规划（规划阶段本步动作）

把目标 / 边界 / 验收标准（AC<n>）/ 阶段裁剪声明整理成 `## 规划` 段，整段提交：

```bash
cat > /tmp/ws-plan.json <<'JSON'
{"workspace": "<pwd 的输出>", "id": "WS-000012", "heading": "## 规划", "session": "<$DSH_SESSION_ID 的值>",
 "text": "- 目标：…（WHAT）\n- 边界：…\n- 验收标准：AC1 …；AC2 …\n- 阶段裁剪声明：不裁剪"}
JSON
curl -s -X POST "http://127.0.0.1:$PORT/api/workstreams/plan" -H 'Content-Type: application/json' --data-binary @/tmp/ws-plan.json
```

### 按阶段创建任务（执行阶段「拆分任务」本步动作）

为事项建**等待态**阶段任务——**只建不启动**，追加到该事项的唯一队列（没有才建）。
`stage` 缺省取卡片当前阶段；每条 `titles` 由面板生成阶段交接提示词：

```bash
cat > /tmp/ws-tasks.json <<'JSON'
{"workspace": "<pwd 的输出>", "id": "WS-000012", "stage": "task", "session": "<$DSH_SESSION_ID 的值>",
 "titles": ["实现模型层", "接线面板", "补测试"]}
JSON
curl -s -X POST "http://127.0.0.1:$PORT/api/workstreams/task/create" -H 'Content-Type: application/json' --data-binary @/tmp/ws-tasks.json
```

建完**停下请人确认拆分合理**；不要立刻启动。阶段 ↔ 队列映射由面板写回卡片 `queues`。

### 启动事项 / 阶段队列（人确认后）

- **启动阶段**（只跑该 `stage` 的任务，跑完自动暂停队列）：带 `stage`。
- **启动事项**（整条队列 FIFO）：不带 `stage`。

```bash
cat > /tmp/ws-start.json <<'JSON'
{"workspace": "<pwd 的输出>", "id": "WS-000012", "stage": "task", "session": "<$DSH_SESSION_ID 的值>"}
JSON
curl -s -X POST "http://127.0.0.1:$PORT/api/workstreams/queue/start" -H 'Content-Type: application/json' --data-binary @/tmp/ws-start.json
```

需要停下时暂停队列（不影响已在跑的会话）：

```bash
curl -s -X POST "http://127.0.0.1:$PORT/api/workstreams/queue/pause" -H 'Content-Type: application/json' \
  -d '{"workspace":"'$(pwd)'","id":"WS-000012","session":"'"$DSH_SESSION_ID"'"}'
```

### 登记事项队列

面板建队列后（或需要把已有队列绑到事项时），把队列 id 写回卡片：

```bash
cat > /tmp/ws-queues.json <<'JSON'
{"workspace": "<pwd 的输出>", "id": "WS-000012", "session": "<$DSH_SESSION_ID 的值>",
 "queues": ["q-3"]}
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

几行以内 —— 改了哪个 `WS-xxx`、建了哪几条任务 / 启动了哪个队列、面板在哪；不粘贴卡片全文。

## 失败处理

| 现象 | 处理 |
|---|---|
| curl 连不上（Connection refused） | App 没运行：请用户打开 oh-my-dsh，**不要**直接改盘上文件 |
| `503 panel-unavailable` | 面板还没就绪：稍后重试一次；仍失败就请用户打开事项面板 |
| `400 no-workspace` | 面板还没有工作区：让用户先选好项目 |
| `400 missing-session` | `bound` 反查少了 `session`：带上 `$DSH_SESSION_ID` |
| `400 missing-id` / `missing-title` | 请求缺 id / 标题：补全后再试 |
| `400 no-fields` | `update` 一个可改字段都没给：至少给 `title` / `requirement` / `body` 之一 |
| `400 missing-text` / `missing-queues` | `plan` / `queues` 少了必填字段：补齐后再试 |
| `400 missing-titles` | `task/create` 既没给 `titles` 也没给 `body`：至少给一个 |
| `400 invalid-titles` | `titles` 不是字符串列表：改成 `["…"]` |
| `400 missing-stage` | `task/create` / `queue/start` 的 `stage` 键给了但为空：去掉该键（缺省）或给合法值 |
| `400 invalid-stage` | `stage` 不是五个之一：改用 `planning` / `design` / `task` / `acceptance` / `delivery` |
| `400 invalid-queue` | `queues` 不是字符串列表 / 超过一条：按 `["q-…"]`（0..1）修正 |
| `400 missing-covered` / `invalid-covered` / `missing-covered-paths` | `covered` 没给 / 不是对象 / `paths` 为空：按 `{"paths":["…"]}` 修正 |
| `400 missing-delivery` / `invalid-delivery` | `delivery` 没给 / 不是对象 / `pr` 非整数：按 `{"pr":42,"url":"…"}` 修正 |
| `400 outcome-derived` | 手写了 `outcome`：它是派生缓存；只传 `pr` / `url`（+ 可选 `state` / `merged` / `abandoned` 观察） |
| `404 unknown-workstream` | 没有该 WS：先 `list` 确认 id |
| `404 no-queue` | 该事项还没有队列（或队列已关闭无法再建 / 启动）：先 `task/create` 建队列，或 `task/list` 看状态 |
| `409 evidence-missing` / `stage-changed` | 人工确认门未过 / 阶段已变：**不要**自行推进；请用户处理 |
| `500 write-failed` | 面板写盘失败：如实转述，稍后重试 |

## 不要做

- **不直接改 .dsh 文件**（`.dsh/workstreams/*.md` 与 `.dsh/workstreams/queues.json` 由面板写；
  也不碰 `.dsh/requirements/*.md`、`.dsh/regression/*.md`）；
- 不调 `stage/confirm` / `stage/reject`（人工确认门），也不调 `stage`（低层口子）；
- **人未确认拆分前不 `queue/start`**：`task/create` 只建等待态任务，启动实施等人确认或用户明说；
- 不手写派生字段（`closed` / `outcome` / `split`）；`covered` / `delivery` 只经写路由记事实，`outcome` 由服务端派生；
- 不在用户没要求时新建事项 / 改阶段 / 建队列 / 启动队列；
- 不在用户没要求时用 `focus: true` 抢面板（默认已关闭；只有确实要把卡给用户看时才开）；
- **阶段 runner / 临时会话不把本会话写进 `session`**：那会覆盖该事项的主场会话（后写覆盖先写），让「在会话中处理」和阶段推进找不到原来的对话。
