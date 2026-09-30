---
name: task-todo
description: 把沟通好的需求/方案落成任务面板里的任务清单（批量创建手动任务，可一次多条）。Turn agreed requirements into a task list on the oh-my-dsh tasks panel (batch-create manual tasks).
---

# task-todo — 把沟通结论写进任务面板

oh-my-dsh 壳层的**任务面板**（Tasks）通过 **localhost REST API** 驱动。用户在会话里和你
聊完需求与方案、并且**明确要求**「把这些建成任务 / 生成任务清单 / 写进任务面板」时，
用本技能一次把任务建到面板上：面板会自动切到对应工作区并展开，「手动」页签下就能看到
这些任务（待处理、未入队），用户接下来照常挑队列、按「处理」运行。

## 何时执行（硬规则）

- **只在用户明确要求时执行**。用户没说「建任务 / 任务清单 / 写进任务面板」，就**不要**建；
  沟通还在进行、方案还没定，也不要抢跑。
- 用户要求了 → 一次性把任务建完（**一次请求多条**），不要一条一条调。
- 建任务**不等于开始干活**：不要替用户入队、建队列、切分支或启动运行。

## 端口发现（必做）

API 随 App 启动常驻，默认端口 **3081**，实际端口写在发现文件里：

```bash
PORT="$(cat "${DSH_HOME:-$HOME/.dsh}/oh-my-dsh/shell-api.port" 2>/dev/null \
     || cat "${DSH_HOME:-$HOME/.dsh}/oh-my-dsh/browser-api.port" 2>/dev/null \
     || echo 3081)"
```

（首个可用者为准，两者同时存在时是同一个端口。App 没运行时**一个都连不上** —— 那就
停下来告诉用户「请先打开 oh-my-dsh」，**不要**去改 `.dsh/tasks/*.json` 绕过面板。）

## API 速查（`http://127.0.0.1:$PORT`）

| 方法/路径 | 请求体 | 说明 |
|---|---|---|
| GET `/api/tasks/list` | `?workspace=<路径>`（可选） | 面板现有的任务与队列：`{ok, workspace, tasks:[{id,title,state,source,queueName}], queues:[...]}` |
| POST `/api/tasks/create` | `{"workspace":"…","focus":true,"tasks":[{"title":"…","body":"…"} \| "标题"]}` | 批量创建；返回 `{ok, workspace, shown, created:[{id,title}], rejected:[{title,error}]}` |

- `workspace`：Agent 会话的工作目录（`pwd`）。传到工作区根即可，面板按「最近祖先」
  解析（`pwd` 在子目录里也对）。不传则用面板当前的工作区。
- `focus`：默认 `true` —— 切到该工作区并展开任务面板（用户刚要求建的东西要看得见）；
  不想打扰就传 `false`。
- `tasks`：每条可写对象（`title` + `body`，**推荐**）或纯字符串（只有标题，描述回退为
  标题）。一次上限 50 条；空标题等会被放进 `rejected` 而不影响其它条目。
- 任务一律以「**待处理、未入队**」落盘：队列与运行仍由用户在面板上决定。

## 工作流

1. **先看面板有什么**（避免重复建：面板内新建任务不去重）：
   ```bash
   curl -sG --data-urlencode "workspace=$(pwd)" "http://127.0.0.1:$PORT/api/tasks/list"
   ```
2. **组织任务**：把本轮沟通的结论拆成独立、可执行的任务，每条写清
   - **标题**：一行，扫一眼就知道要做什么（不放编号前缀、不写「任务一」）；
   - **描述**（`body`）：给执行者的上下文 —— 做什么、依据是什么（文件/接口/文档）、
     怎么算完成（验收点）。**只写沟通里已经确认的内容**，不臆造需求、不加没谈过的
     范围。标题已能自明的短任务，描述可省略。
3. **一次提交**：把 JSON 写成文件再 `--data-binary`（避免 shell 引号转义咬到中文/引号）：
   ```bash
   cat > /tmp/task-todo.json <<'JSON'
   {
     "workspace": "<pwd 的输出>",
     "focus": true,
     "tasks": [
       {"title": "…", "body": "…"},
       {"title": "…", "body": "…"}
     ]
   }
   JSON
   curl -s -X POST "http://127.0.0.1:$PORT/api/tasks/create" \
     -H 'Content-Type: application/json' --data-binary @/tmp/task-todo.json
   ```
   （`workspace` 用真实的 `pwd` 值；路径含空格时 JSON 里照写，不用转义。）
4. **核对**：看响应里的 `created`（id + 标题）与 `rejected`；必要时再 list 一次确认。
   面板此时应已展开并显示这些卡片。
5. **汇报**：几行以内 —— 建了几条、标题清单、面板里在哪（哪个工作区/「手动」页签）；
   有 `rejected` 就说明原因。不粘贴任务正文全文。

## 失败处理

| 现象 | 处理 |
|---|---|
| curl 连不上（Connection refused） | App 没运行：请用户打开 oh-my-dsh，**不要**直接改盘上文件 |
| `503 panel-unavailable` | 壳层服务在，但任务面板还没就绪（刚启动）：稍后重试一次；仍失败就请用户打开任务面板看一眼 |
| `400 no-workspace` | 面板还没有工作区（或传的路径不存在）：让用户先在 oh-my-dsh 里选好项目 |
| `rejected` 里有条目 | 逐条说明原因（`empty-title` / `too-many` 等），把有效的部分如实汇报，不要谎报全部成功 |

## 不要做

- 不直接改 `<workspace>/.dsh/tasks/*.json`（面板内存里有 board，外部改动会被覆盖，
  用户也看不到反馈）；
- 不替用户建队列、入队、开跑、切分支、开 PR（那些是用户与面板的事）；
- 不在用户没要求时建任务，也不把本轮没确认的猜测写成任务。
