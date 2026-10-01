---
name: task-todo
description: 把沟通好的需求/方案落成任务面板：默认追加到本会话已有的队列（没有才新建），并可启动队列；只有用户明确要求时才只建任务。Append to this session's existing queue by default (create one if none) on the oh-my-dsh tasks panel, and start the queue on request.
---

# task-todo — 把沟通结论写进任务面板（任务 / 队列）

oh-my-dsh 壳层的**任务面板**（Tasks）通过 **localhost REST API** 驱动。用户在会话里和你
聊完需求与方案、并且**明确要求**时，用本技能把结论落进面板：

- **默认：追加到本会话已有的队列** —— 带上 `session` 调 `/api/tasks/queue/append`；只有本会话
  还没有队列（`404 no-queue`）时，才新建「等待态队列 + 批量入队」（`queue/create`）。
  **同一个会话里默认沿用同一条泳道，不要每轮新建队列**；只有用户明确说「新建队列 / 另起一个」才新建。
- **只建任务**（**仅当**用户明确说「只建任务 / 先别入队 / 不要队列」时）：批量创建
  「待处理、未入队」的手动任务，用户之后自己在面板挑队列。
- 追加到**已完成**的队列会让它回到**待启动**（要再 `queue/start` 才跑）；追加到**暂停**的队列保持暂停。

## 何时执行（硬规则）

- **只在用户明确要求时执行**。用户没说「建任务 / 建队列 / 启动队列」，就**不要**建、不要
  启动；沟通还在进行、方案还没定，也不要抢跑。
- 用户要求了 → 一次性建完（**一次请求多条**），不要一条一条调。
- **默认沿用已有泳道**：本会话已经有队列时，把新任务**追加**进去（`queue/append`），不要新建队列；
  只有用户明确要求新建、或本会话确实还没有队列时，才用 `queue/create`。
- **建任务 / 建队列 / 追加任务都不等于开始干活**：只有用户明确说「启动队列 / 开始处理队列」时
  才调 `/api/tasks/queue/start`，其余情况绝不替用户启动。
- 建队列时带上本会话的 `$DSH_SESSION_ID`：队列跑完（进入 `done`）后，面板会把完成情况
  **回传本会话**；那一轮你只需简短确认（见下）。

## 端口发现（必做）

API 随 App 启动常驻，默认端口 **3081**，实际端口写在发现文件里：

```bash
PORT="$(cat "${DSH_HOME:-$HOME/.dsh}/oh-my-dsh/shell-api.port" 2>/dev/null || cat "${DSH_HOME:-$HOME/.dsh}/oh-my-dsh/browser-api.port" 2>/dev/null || echo 3081)"
```

（首个可用者为准，两者同时存在时是同一个端口。App 没运行时**一个都连不上** —— 那就
停下来告诉用户「请先打开 oh-my-dsh」，**不要**去改 `.dsh/tasks/*.json` 绕过面板。）

## API 速查（`http://127.0.0.1:$PORT`）

| 方法/路径 | 请求体 | 说明 |
|---|---|---|
| GET `/api/tasks/list` | `?workspace=<路径>`（可选） | 面板现有的任务与队列：`{ok, workspace, tasks:[...], queues:[{id,name,state,...}]}` |
| POST `/api/tasks/create` | `{"workspace":"…","focus":true,"tasks":[{"title":"…","body":"…"} 或 "标题"]}` | 只建任务（待处理、未入队）；返回 `{ok, created:[{id,title}], rejected:[…]}` |
| POST `/api/tasks/queue/create` | `{"workspace":"…","session":"$DSH_SESSION_ID","focus":true,"name":"队列名","branch":"…","autoPR":true,"tasks":[…]}` | 建**等待态**队列 + 批量入队；不启动；返回 `{ok, queue:{id,name,state:"draft",…}, created:[…]}` |
| POST `/api/tasks/queue/start` | `{"workspace":"…","session":"$DSH_SESSION_ID","queueId":"q-…"}`（`queueId` 也可换成 `name`） | 启动队列（draft/paused → active）；按 id / 名字定位，缺省时启动本会话创建的那个等待队列 |
| POST `/api/tasks/queue/append` | `{"workspace":"…","session":"$DSH_SESSION_ID","queueId":"q-…"（或 "name":"队列名"）,"tasks":[…]}` | 向**已有**队列追加任务；不启动；返回 `{ok, queue:{id,name,state,…}, created:[…]}` |

- `workspace`：Agent 会话的工作目录（`pwd`）。传工作区根即可，面板按「最近祖先」解析
  （`pwd` 在子目录里也对）。不传则用面板当前工作区。
- `focus`：默认 `true` —— 切到该工作区并展开任务面板。不想打扰就传 `false`。
- `session`：**建队列时强烈建议带 `$DSH_SESSION_ID`**；完成回传就回到这里。
- `branch`：缺省按队列名派生（`feature/<slug>`）；传 `""` = 完全不切分支。
- `autoPR`：缺省按工作区能力（有 GitHub 远端才「完成后自动开 PR」）。
- `tasks`：每条可写对象（`title` + `body`，**推荐**）或纯字符串。一次上限 50 条；空标题等
  进 `rejected`，不影响其它条目。
- `queue/start` 可以按 `queueId` 或 `name` 启动；若本会话创建过多个等待队列又没说名字，先
  `list` 再点名（否则 409 `ambiguous-queue`）。
- `queue/append` 的目标队列按 `queueId` → `name` → `session`（本会话创建的非关闭队列）解析；
  追加到 `.done` 队列会把它变回 **`draft`（待启动）**，要再 `queue/start` 才会跑。

## 工作流

1. **先看面板有什么**（避免重复建）：
   ```bash
   curl -sG --data-urlencode "workspace=$(pwd)" "http://127.0.0.1:$PORT/api/tasks/list"
   ```
2. **组织任务**：标题（一行，扫一眼就知道做什么）+ 描述（做什么 / 依据什么 / 怎么算完成）。
   只写沟通里已经确认的内容。
3. **落进面板**（把 JSON 写成文件再 `--data-binary`，避免引号转义咬到中文）：
   - **默认：先追加到本会话的队列** —— `POST /api/tasks/queue/append`，带 `session`（知道 `queueId`/`name` 更好）：
     - 成功 → 追加完成；
     - `404 no-queue` → 本会话还没有队列 → 改用 `POST /api/tasks/queue/create`（带 `session`，
       队列名用户没给就按本轮主题起一个），并记下响应里的 `queue.id`；
     - `409 ambiguous-queue` → 本会话有多条队列：`GET /list` 看名字，按主题选一条再带 `queueId` 追加
       （真分不清就问用户一句）。
   - **仅当**用户明确说「只建任务 / 先别入队 / 不要队列」→ `/api/tasks/create`；
   - **仅当**用户明确说「新建队列 / 另起一个队列」→ 直接 `queue/create`（即使已有队列也新建）。
   ```bash
   # 默认：追加到本会话已有的队列
   cat > /tmp/task-todo.json <<'JSON'
   {
     "workspace": "<pwd 的输出>",
     "session": "<$DSH_SESSION_ID 的值>",
     "tasks": [
       {"title": "深色模式适配", "body": "改主题令牌与面板底色；验收：深浅切换无残留"}
     ]
   }
   JSON
   curl -s -X POST "http://127.0.0.1:$PORT/api/tasks/queue/append" -H 'Content-Type: application/json' --data-binary @/tmp/task-todo.json
   # 若返回 404 no-queue：改用 /api/tasks/queue/create（可带 "name": "<本轮主题>"）
   ```
4. **启动**（仅当用户明确要求）：`POST /api/tasks/queue/start`，带 `session`（和必要的 `queueId`）。
5. **核对与汇报**：几行以内 —— 建了什么（队列名 / 几条任务 / 是否待启动）、面板在哪、有没有
   `rejected`。不粘贴任务正文全文。

## 等待队列完成后的回传

队列**进入 `done`**（队内任务都已结束）时，面板会向创建它的会话投一条完成通知（各任务结果、
失败原因、PR）。它会作为一条用户消息出现在本会话里：**只用一两句话确认收到，等待用户验收；
不要主动改代码、不要新建任务。** 失败 / 手动取消会让队列停在 `paused`，此时**不回传**。

在**已完成**的队列上追加任务（`queue/append`），它会回到「待启动」，并在下一次完成后**再次回传**
本会话——这正是「验收 → 再补几条 → 再跑」的循环。

## 失败处理

| 现象 | 处理 |
|---|---|
| curl 连不上（Connection refused） | App 没运行：请用户打开 oh-my-dsh，**不要**直接改盘上文件 |
| `503 panel-unavailable` | 壳层服务在，但任务面板还没就绪：稍后重试一次；仍失败就请用户打开面板看一眼 |
| `400 no-workspace` | 面板还没有工作区（或路径不存在）：让用户先选好项目 |
| `400 missing-name` | 建队列既没给 `name`、任务标题也兜不住：补一个队列名 |
| `409 ambiguous-queue` | 有多个同名 / 本会话的等待队列：从 `queues` 里挑一个，带 `queueId`（或更具体的 `name`）重试 |
| `404 no-queue` | 没有可启动的等待队列：先 `list` 确认 id，或它已经启动过 |
| `400 no-queue-target` | 追加没给目标队列：带 `queueId` / `name`，或用本会话定位 |
| `400 queue-closed` | 目标队列已关闭（终态）：别翻它，明确新建一条队列 |
| `rejected` 里有条目 | 逐条说明原因，把有效的部分如实汇报，不要谎报全部成功 |

## 不要做

- 不直接改 `<workspace>/.dsh/tasks/*.json`（面板内存里有 board，外部改动会被覆盖，用户也
  看不到反馈）；
- 不在用户没要求时建任务 / 建队列 / 启动队列 / 切分支 / 开 PR；
- 不把本轮没确认的猜测写成任务。
