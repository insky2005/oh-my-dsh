---
name: requirement-pool
description: 把对话里的想法落成需求卡片（需求池），并把一条需求拆解成 1..N 个事项提案、等人在面板确认。Capture ideas as requirement cards in the oh-my-dsh requirements pool, and propose a 1..N workstream breakdown for a requirement for human confirmation.
---

# requirement-pool — 想法收件箱 + 拆解器

oh-my-dsh 壳层的**需求池面板**（Requirements，⌥⌘I）通过 **localhost REST API** 驱动。
状态落在项目 `.dsh/requirements/REQ-*.md` 与 `.dsh/workstreams/WS-*.md`（随仓库提交）；
面板是写者，你只走 API。

## 何时执行（硬规则）

- **只在用户明确要求时执行**。用户没说「记个想法 / 落成需求 / 拆解 REQ-xxx」，就**不要**动；
  沟通还在进行、做法还没定，也不要抢跑。
- **只提案，不自签**：拆解方案只能调 `/api/requirements/breakdown/propose`；确认
  （`/api/requirements/breakdown/confirm`）是**人工确认门**，由需求池面板的「确认拆解」
  按钮完成，agent **绝不**调它。
- **不直接改** `.dsh/requirements/*.md` / `.dsh/workstreams/*.md`。
- App 没运行时停下来告诉用户「请先打开 oh-my-dsh」，**不要**绕过 API 写文件。

## 端口发现（必做）

```bash
PORT="${DSH_HOME:-$HOME/.dsh}/oh-my-dsh/shell-api.port"
[ -f "$PORT" ] || PORT="${DSH_HOME:-$HOME/.dsh}/oh-my-dsh/browser-api.port"
[ -f "$PORT" ] || PORT=3081
PORT="$(cat "$PORT" 2>/dev/null || echo 3081)"
```

## API 速查（http://127.0.0.1:$PORT）

| 方法/路径 | 请求体 | 说明 |
|---|---|---|
| GET `/api/requirements/list` | `?workspace=<路径>` | 需求 + 子事项 + 待确认提案 |
| POST `/api/requirements/create` | `{"workspace":"…","title":"…","body":"…","session":"$DSH_SESSION_ID","focus":true}` | 收件箱：新建需求卡（candidate）；带 `session` 以便日后「拆解」回到本会话 |
| POST `/api/requirements/state` | `{"id":"REQ-003","state":"evaluating","session":"$DSH_SESSION_ID"}` | 改人工状态（candidate/evaluating/suspended/discarded） |
| POST `/api/requirements/update` | `{"id":"REQ-003","title":"…","body":"…","session":"$DSH_SESSION_ID"}` | 改标题 + 诉求（只改这两处） |
| POST `/api/requirements/breakdown/propose` | `{"id":"REQ-003","items":[{"title":"…","boundary":"…","dependsOn":["…"]}],"session":"$DSH_SESSION_ID"}` | 拆解器：写**待确认**提案 |
| POST `/api/requirements/breakdown/confirm` / `reject` | `{"id":"REQ-003"}` | 人工确认 / 驳回 —— **confirm 不由 agent 调** |

- `workspace` 传 `$(pwd)`；不传则用面板当前工作区。
- **每个写操作都带上 `session`（`$DSH_SESSION_ID`）**：壳层把该需求绑定到本会话，之后面板上的「拆解 / 确认 / 驳回」都会回到这里——**同一需求的所有对话落在同一个会话**。
- `items` 每条：标题 + 边界 + 依赖（`dependsOn` 可空）。

## 工作流

### 收件（落需求）

1. 用户明确要求后，把诉求整理成一行**标题** + **诉求正文**（要解决什么 / 为什么）。
2. 提交（**带上本会话的 `$DSH_SESSION_ID`**，面板之后点「拆解」会优先回到这个会话）：
   ```bash
   cat > /tmp/requirement-pool.json <<'JSON'
   {"workspace": "<pwd 的输出>", "title": "标题", "body": "诉求正文", "session": "<$DSH_SESSION_ID 的值>", "focus": true}
   JSON
   curl -s -X POST "http://127.0.0.1:$PORT/api/requirements/create" -H 'Content-Type: application/json' --data-binary @/tmp/requirement-pool.json
   ```
3. 汇报新建的 `REQ-xxx`，不粘贴全文。

### 拆解（1 需求 → 1..N 事项提案）

1. 读 `.dsh/requirements/<id>.md` 与它的子事项（`WS.requirement == <id>`）；
2. 给出每个事项的**标题 / 边界 / 依赖顺序**；只拆不胀，范围外的新发现回池；
3. 提交提案：
   ```bash
   cat > /tmp/breakdown.json <<'JSON'
   {"id": "REQ-xxx", "session": "<$DSH_SESSION_ID 的值>", "items": [
     {"title": "事项 A", "boundary": "只做 A", "dependsOn": []},
     {"title": "事项 B", "boundary": "依赖 A", "dependsOn": ["事项 A"]}
   ]}
   JSON
   curl -s -X POST "http://127.0.0.1:$PORT/api/requirements/breakdown/propose" -H 'Content-Type: application/json' --data-binary @/tmp/breakdown.json
   ```
4. **停下**：告诉用户「已提交待确认拆解，请在需求池面板确认」。不要建卡、不要自签。

## 失败处理

| 现象 | 处理 |
|---|---|
| curl 连不上（Connection refused） | App 没运行：请用户打开 oh-my-dsh，不要直接改盘上文件 |
| `503 panel-unavailable` | 面板还没就绪：稍后重试一次；仍失败就请用户打开面板看一眼 |
| `400 no-workspace` | 面板还没有工作区：让用户先选好项目 |
| `404 unknown-requirement` | 没有该 REQ：先 `list` 确认 id |
| `409 no-proposal` | 没有待确认提案（confirm / reject 前必须已有提案） |
| `400 missing-title` | 收件缺标题：补一个一行标题 |

## 不要做

- 不调 `breakdown/confirm`（人工确认门）；
- 不直接改 `.dsh` 卡片文件；
- 不在用户没要求时建需求 / 提拆解。
