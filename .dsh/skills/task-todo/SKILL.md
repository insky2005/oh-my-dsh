---
name: task-todo
description: 把沟通好的需求/方案落成任务面板里的任务清单；要一起跑就建「等待态队列 + 批量任务」，并可按用户指令启动队列。Turn agreed requirements into tasks or a waiting queue on the oh-my-dsh tasks panel (batch), and start the queue on request.
---

# task-todo — 把沟通结论写进任务面板（任务 / 队列）

oh-my-dsh 壳层的**任务面板**（Tasks）通过 **localhost REST API** 驱动。用户在会话里和你
聊完需求与方案、并且**明确要求**时，用本技能把结论落进面板。两种落法，按用户的话选：

- **只建任务**（默认）：批量创建「待处理、未入队」的手动任务，用户之后自己在面板挑队列；
- **建队列 + 入队**：建一个**等待态**队列（`draft`），把任务一次性批量入队；队列不会自己
  开跑，等用户（或会话）说「启动队列」。

## 何时执行（硬规则）

- **只在用户明确要求时执行**。用户没说「建任务 / 建队列 / 启动队列」，就**不要**建、不要
  启动；沟通还在进行、方案还没定，也不要抢跑。
- 用户要求了 → 一次性建完（**一次请求多条**），不要一条一条调。
- **建任务 / 建队列都不等于开始干活**：只有用户明确说「启动队列 / 开始处理队列」时才调
  `/api/tasks/queue/start`，其余情况绝不替用户启动。
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
| POST `/api/tasks/queue/start` | `{"workspace":"…","session":"$DSH_SESSION_ID","queueId":"q-…（可选）"}` | 启动队列（draft/paused → active）；`queueId` 缺省时启动本会话创建的那个等待队列 |

- `workspace`：Agent 会话的工作目录（`pwd`）。传工作区根即可，面板按「最近祖先」解析
  （`pwd` 在子目录里也对）。不传则用面板当前工作区。
- `focus`：默认 `true` —— 切到该工作区并展开任务面板。不想打扰就传 `false`。
- `session`：**建队列时强烈建议带 `$DSH_SESSION_ID`**；完成回传就回到这里。
- `branch`：缺省按队列名派生（`feature/<slug>`）；传 `""` = 完全不切分支。
- `autoPR`：缺省按工作区能力（有 GitHub 远端才「完成后自动开 PR」）。
- `tasks`：每条可写对象（`title` + `body`，**推荐**）或纯字符串。一次上限 50 条；空标题等
  进 `rejected`，不影响其它条目。
- `queue/start` 的 `queueId`：若本会话创建过多个等待队列，先 `list` 看名字，再补 `queueId`
  消歧（否则 409 `ambiguous-queue`）。

## 工作流

1. **先看面板有什么**（避免重复建）：
   ```bash
   curl -sG --data-urlencode "workspace=$(pwd)" "http://127.0.0.1:$PORT/api/tasks/list"
   ```
2. **组织任务**：标题（一行，扫一眼就知道做什么）+ 描述（做什么 / 依据什么 / 怎么算完成）。
   只写沟通里已经确认的内容。
3. **按用户的话选端点**（把 JSON 写成文件再 `--data-binary`，避免引号转义咬到中文）：
   - 只说「建任务 / 任务清单」→ `/api/tasks/create`；
   - 说「建个队列 / 拆成队列 / 一起跑」→ `/api/tasks/queue/create`（带上 `session`），
     并从响应里记下 `queue.id`。
   ```bash
   cat > /tmp/task-todo.json <<'JSON'
   {
     "workspace": "<pwd 的输出>",
     "session": "<$DSH_SESSION_ID 的值>",
     "focus": true,
     "name": "外观切换",
     "tasks": [
       {"title": "深色模式适配", "body": "改主题令牌与面板底色；验收：深浅切换无残留"},
       {"title": "跟随系统", "body": "监听系统外观变化"}
     ]
   }
   JSON
   curl -s -X POST "http://127.0.0.1:$PORT/api/tasks/queue/create" -H 'Content-Type: application/json' --data-binary @/tmp/task-todo.json
   ```
4. **启动**（仅当用户明确要求）：`POST /api/tasks/queue/start`，带 `session`（和必要的 `queueId`）。
5. **核对与汇报**：几行以内 —— 建了什么（队列名 / 几条任务 / 是否待启动）、面板在哪、有没有
   `rejected`。不粘贴任务正文全文。

## 等待队列完成后的回传

队列**进入 `done`**（队内任务都已结束）时，面板会向创建它的会话投一条完成通知（各任务结果、
失败原因、PR）。它会作为一条用户消息出现在本会话里：**只用一两句话确认收到，等待用户验收；
不要主动改代码、不要新建任务。** 失败 / 手动取消会让队列停在 `paused`，此时**不回传**。

## 失败处理

| 现象 | 处理 |
|---|---|
| curl 连不上（Connection refused） | App 没运行：请用户打开 oh-my-dsh，**不要**直接改盘上文件 |
| `503 panel-unavailable` | 壳层服务在，但任务面板还没就绪：稍后重试一次；仍失败就请用户打开面板看一眼 |
| `400 no-workspace` | 面板还没有工作区（或路径不存在）：让用户先选好项目 |
| `400 missing-name` | 建队列既没给 `name`、任务标题也兜不住：补一个队列名 |
| `409 ambiguous-queue` | 本会话有多个等待队列：从 `queues` 里挑一个，带 `queueId` 重试 |
| `404 no-queue` | 没有可启动的等待队列：先 `list` 确认 id，或它已经启动过 |
| `rejected` 里有条目 | 逐条说明原因，把有效的部分如实汇报，不要谎报全部成功 |

## 不要做

- 不直接改 `<workspace>/.dsh/tasks/*.json`（面板内存里有 board，外部改动会被覆盖，用户也
  看不到反馈）；
- 不在用户没要求时建任务 / 建队列 / 启动队列 / 切分支 / 开 PR；
- 不把本轮没确认的猜测写成任务。
