//
//  SkillInstaller.swift
//  oh-my-dsh
//
//  Built-in skill provisioning: installs oh-my-dsh's built-in agent skills
//  into the global dsh home at app startup, detects updates, and migrates
//  legacy skill names. Foundation-only so it compiles headless in tests.
//
//  Embedded SKILL.md copies are kept byte-identical to .dsh/skills/<dirName>/SKILL.md.
//

import Foundation

/// The built-in skills shipped by oh-my-dsh.
enum BuiltinSkill: CaseIterable {

    case webDevTools
    case repoKnowledge
    case taskTodo
    case requirementPool
    case workstreamPanel

    var dirName: String {
        switch self {
        case .webDevTools: return "web-dev-tools"
        case .repoKnowledge: return "repo-knowledge"
        case .taskTodo: return "task-todo"
        case .requirementPool: return "requirement-pool"
        case .workstreamPanel: return "workstream-panel"
        }
    }

    /// Pre-rename name this skill used to be installed under (startup migration).
    var legacyName: String? {
        switch self {
        case .webDevTools: return "shell-browser"
        case .repoKnowledge: return "repo-wiki"
        case .taskTodo: return nil
        case .requirementPool: return nil
        case .workstreamPanel: return nil
        }
    }

    var markdown: String {
        switch self {
        case .webDevTools: return Self.webDevToolsMarkdown
        case .repoKnowledge: return Self.repoKnowledgeMarkdown
        case .taskTodo: return Self.taskTodoMarkdown
        case .requirementPool: return Self.requirementPoolMarkdown
        case .workstreamPanel: return Self.workstreamPanelMarkdown
        }
    }

    static let webDevToolsMarkdown = """
    ---
    name: web-dev-tools
    description: 驱动 oh-my-dsh 壳层的「浏览器」面板排查网页问题（打开页面、读 console/网络日志、执行 JS、截图）。Drive the oh-my-dsh shell's Browser panel to troubleshoot web pages (open pages, read console/network logs, run JS, take screenshots).
    ---
    
    # web-dev-tools — 用 oh-my-dsh 浏览器面板排查网页问题
    
    oh-my-dsh 壳层内置一个**浏览器面板**（CEF 嵌入式 Chromium 内核），通过 **localhost REST API** 驱动，无需额外浏览器/驱动。面板与 dsh web 共用同一 App，Agent 驱动时面板会自动展开，用户实时可见。
    
    ## 端口发现（必做）
    
    API 服务随 App 启动常驻，默认端口 **3081**。按顺序取：
    
    ```bash
    PORT="$(cat "${DSH_HOME:-$HOME/.dsh}/oh-my-dsh/browser-api.port" 2>/dev/null || echo 3081)"
    ```
    
    （若设置了 `DSH_BROWSER_PORT` 环境变量则端口不同；port 文件由 App 写入。App 未运行时 API 不可用——先请用户打开 oh-my-dsh。）
    
    ## API 速查（`http://127.0.0.1:$PORT`）
    
    | 方法/路径 | 请求体 | 说明 |
    |---|---|---|
    | GET `/api/browser/status` | — | `{panelVisible, tabs:[{id,url,title,loading,canGoBack,canGoForward}], activeTabId}` |
    | POST `/api/browser/open` | `{"url":"…","tab":"active"\\|"new"\\|tabId}` | 打开/导航；自动展开面板（`"show":false` 可抑制） |
    | POST `/api/browser/tabs` | `{"action":"new"\\|"close"\\|"activate","tabId":N}` | 标签管理 |
    | POST `/api/browser/back` `/forward` `/reload` `/stop` | `{"tabId":N?}` | 导航控制 |
    | POST `/api/browser/eval` | `{"expression":"document.title"}` | JS 求值 → `{ok,result}` / `{ok:false,error}` |
    | GET `/api/browser/console` | `?level=error&limit=50` | console 日志（含 `network` 行） |
    | POST `/api/browser/console/clear` | — | 清空 |
    | GET `/api/browser/screenshot` | — | PNG 字节（`curl -o` 保存） |
    | POST `/api/browser/hide` | — | 收起面板 |
    
    ## 标准排查工作流
    
    1. **打开页面**：
       ```bash
       curl -s -X POST "http://127.0.0.1:$PORT/api/browser/open" -d '{"url":"https://example.com/page"}' -H 'Content-Type: application/json'
       ```
    2. **等待加载完成**（轮询 status 直到目标 tab `loading=false`，最多 ~30s；超时视为页面慢，继续读日志）：
       ```bash
       for i in $(seq 1 30); do
         S=$(curl -s "http://127.0.0.1:$PORT/api/browser/status")
         echo "$S" | grep -q '"loading":false' && break
         sleep 1
       done
       ```
    3. **读 console 日志（重点看 error/network 失败行）**：
       ```bash
       curl -s "http://127.0.0.1:$PORT/api/browser/console?level=error&limit=100"
       curl -s "http://127.0.0.1:$PORT/api/browser/console?limit=200" | python3 -c "import sys,json; [print(e['level'], e['text']) for e in json.load(sys.stdin)['entries'] if e['level'] in ('error','network')]"
       ```
    4. **JS 求值取证**（DOM 状态、接口返回值、渲染结果）：
       ```bash
       curl -s -X POST "http://127.0.0.1:$PORT/api/browser/eval" -d '{"expression":"document.title + \\" | \\" + document.readyState"}' -H 'Content-Type: application/json'
       curl -s -X POST "http://127.0.0.1:$PORT/api/browser/eval" -d '{"expression":"JSON.stringify(document.querySelectorAll(\\"img\\").length)"}' -H 'Content-Type: application/json'
       ```
    5. **截图取证**（存工作区，可读图/分享，预览面板可见）：
       ```bash
       curl -s "http://127.0.0.1:$PORT/api/browser/screenshot" -o "$(pwd)/browser-shot.png" && ls -la browser-shot.png
       ```
    6. **汇报**：URL、加载结果、console/网络错误（含状态码）、eval 关键值、截图路径与观察结论。
    
    ## 注意事项
    
    - **安全边界**：API 仅绑定 127.0.0.1、无鉴权（与 dsh web 同信任模型）；`eval` 可读任意页面内容——只对用户指定的页面操作；
    - **能力**：CDP 捕获 console/异常/全部网络请求（含图片/CSS/子框架，优于 WKWebView 注入）；完整 DevTools 由面板头部「DevTools」按钮在系统浏览器打开；
    - 面板隐藏时 status/open/eval/screenshot 全部可用（CEF 离屏渲染，截图无需展开面板）；
    - 多标签：open 默认在当前 tab 导航，`"tab":"new"` 新建；tab 上限 8。
    
    """

    static let repoKnowledgeMarkdown = """
    ---
    name: repo-knowledge
    description: 为当前仓库生成/维护 .dsh/wiki/ 知识库（初始生成、增量更新、重建 index、陈旧标记）。Generate / maintain the .dsh/wiki/ knowledge base for the current repository (initial generation, incremental update, index rebuild, staleness marking).
    user-invocable: false
    ---
    
    # repo-knowledge — 仓库知识库生成/维护
    
    为当前仓库维护 `<repoRoot>/.dsh/wiki/` 下的结构化 markdown 知识库。用户要求「生成/更新/维护知识库」时加载本 skill 执行。
    
    ## 执行方式（强制）
    - **在当前会话内直接执行，绝不新建顶层会话**（不得 session.create / fork，也不得建议用户另开会话）；确需并行探索时可使用 subagent（子会话，不影响顶层会话归属）；
    - **仓库根**：取当前会话的工作目录（`pwd`）；wiki 输出到 `<repoRoot>/.dsh/wiki/`，目录不存在则创建；
    - **模式选择**：`.dsh/wiki/index.md` 存在 → 增量更新；不存在 → 初始生成。
    
    ## 页面结构（初始生成 ≤ 20 页，单页 ≤ 200 行；单行/单段不得过长，长列表与长说明必须换行）
    - `index.md`：总索引（一句话简介 + 分节页链接 + 统计 + 最后生成时间）
    - `overview.md`：技术栈、目录布局、构建/运行/测试方式
    - `architecture.md`：分层、模块依赖、关键数据流、部署形态
    - `modules/<name>.md`：每个主要模块/包一页
    - `data-model.md`：核心数据模型/表结构/领域概念
    - `conventions.md`：工程约定（命名、提交规范、代码风格、工具链）
    - `tasks.md`：常见任务手册（如何加接口/发布/排查）
    
    ## 页面 frontmatter（每页必写）
    ```yaml
    ---
    title: <标题>
    tags: [a, b]
    updated: <本次实际 UTC ISO8601>
    sources: [<相对路径，列全依据文件或目录>]
    manual: false
    ---
    ```
    
    ## 事实基线（强制）
    1. **wiki 只收录当前分支可证实的内容**：工作树 + 当前分支（默认 `main`）的提交历史；
    2. 任何 tag / 远端分支 / 提交，写入前先用 `git merge-base --is-ancestor <commit> HEAD`（或 `git branch --contains <commit>`）确认**在当前分支可达**；**不可达的一律不写入 wiki**（不标注、不列举、不引用）；
    3. 版本信息：只有**当前分支可达**的 tag 才算本分支发布，「已发布」只认 GitHub Releases（`gh release list` 或 `https://api.github.com/repos/<owner>/<repo>/releases`，有 tag + 资产），只有 tag 时写「tag 存在」；**不得因远端存在某 tag 就写入**；
    4. 记录版本/release 的页面，`sources` 至少列 `CHANGELOG.md`、`scripts/version.sh`；
    5. 增量核查：`git status --short` + mtime 只发现**工作树**变更；tag/分支另按本节核查。

    ## 规则（强制）
    1. 只写可从代码/文档证实的事实；不确定处标注「待确认」；禁止编造；「已发布」按《事实基线》判定；
    2. **增量更新**：先读 `index.md` 了解已有结构；用 `git status --short` + mtime 定位变更文件，只重写 `sources` 命中变更的页面；未变页面保持**字节不变**；git 不可用时退化为 mtime 扫描；tag/分支变更按《事实基线》单独核查；
    3. **sources 质量**：`sources` 列全该页依据的文件/目录（目录即可覆盖其子树）——它决定陈旧检测与后续增量更新的准确性，遗漏会导致页面无法被判定过期；
    4. `manual: true` 的页面绝不改写；
    5. 脱敏：跳过 .env*/密钥/口令/个人数据，示例一律占位符；
    6. **不删除页面**：源码删除后在该页标注「已失效」而非删文件，留给用户审阅；
    7. 完成后更新 `index.md` 的统计与最后生成时间；**发现既有页面与当前仓库不符时一并修正，并在汇报中列出**；
    8. **提交（若仓库是 git）**：更新完成后执行 `git add .dsh/wiki` 并 `git commit`，**绝不 push**。commit message **由你概括本次实际变更**（如 `docs(wiki): 同步 v1.8.0 发布流程与 IssueRunner 面板文档`），不要用固定文案、不要带「自动提交」等过程标注；若没有任何变更（无 diff）则跳过提交；
    9. **汇报**：简短列出本次生成/更新的页面（含新增 / 失效 / 手动跳过 / 修正），不超过几行，不粘贴正文。
    """

    static let taskTodoMarkdown = """
    ---
    name: task-todo
    description: 把沟通好的需求/方案落成任务面板：默认追加到本会话已有的队列（没有才新建），可启动队列，也可对已完成队列发起交付；只有用户明确要求时才只建任务。Append to this session's existing queue by default (create one if none) on the oh-my-dsh tasks panel, start the queue on request, and deliver a finished queue when asked.
    ---
    
    # task-todo — 把沟通结论写进任务面板（任务 / 队列）
    
    oh-my-dsh 壳层的**任务面板**（Tasks）通过 **localhost REST API** 驱动。用户在会话里和你
    聊完需求与方案、并且**明确要求**时，用本技能把结论落进面板：
    
    - **默认：追加到本会话已有的队列** —— 带上 `session` 调 `/api/tasks/queue/append`；只有本会话
      还没有队列（`404 no-queue`）时，才新建「等待态队列 + 批量入队」（`queue/create`）。
      **同一个会话里默认沿用同一条泳道，不要每轮新建队列**；只有用户明确说「新建队列 / 另起一个」才新建。
    - **只建任务**（**仅当**用户明确说「只建任务 / 先别入队 / 不要队列」时）：批量创建
      「待处理、未入队」的手动任务，用户之后自己在面板挑队列。
    - **交付**（**仅当**用户明确说「交付 / 开 PR / 合并 / 推送这个队列」时）：对**已完成**的队列发起交付（按队列的 Git 工作流开 PR / 合并到基线 / 直接推送），由一条专门的交付会话执行，结果回写到队列卡片。
    - 追加到**已完成**的队列会让它回到**待启动**（要再 `queue/start` 才跑）；追加到**暂停**的队列保持暂停。
    
    ## 何时执行（硬规则）
    
    - **只在用户明确要求时执行**。用户没说「建任务 / 建队列 / 启动队列」，就**不要**建、不要
      启动；沟通还在进行、方案还没定，也不要抢跑。
    - 用户要求了 → 一次性建完（**一次请求多条**），不要一条一条调。
    - **默认沿用已有泳道**：本会话已经有队列时，把新任务**追加**进去（`queue/append`），不要新建队列；
      只有用户明确要求新建、或本会话确实还没有队列时，才用 `queue/create`。
    - **建任务 / 建队列 / 追加任务都不等于开始干活**：只有用户明确说「启动队列 / 开始处理队列」时
      才调 `/api/tasks/queue/start`，其余情况绝不替用户启动。
    - **交付也不等于启动，更不等于替用户收尾**：只有用户明确说「交付 / 开 PR / 合并 / 推送这个队列」
      时才调 `/api/tasks/queue/deliver`，且只对**已完成**队列；其余情况绝不主动交付。
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
    | GET `/api/tasks/task/list` | `?workspace=<路径>`（可选） | 面板现有的任务与队列：`{ok, workspace, tasks:[...], queues:[{id,name,state,...}]}` |
    | POST `/api/tasks/task/create` | `{"workspace":"…","focus":true,"tasks":[{"title":"…","body":"…"} 或 "标题"]}` | 只建任务（待处理、未入队）；返回 `{ok, created:[{id,title}], rejected:[…]}` |
    | POST `/api/tasks/queue/create` | `{"workspace":"…","session":"$DSH_SESSION_ID","focus":true,"name":"队列名","branch":"…","autoPR":true,"tasks":[…]}` | 建**等待态**队列 + 批量入队；不启动；返回 `{ok, queue:{id,name,state:"draft",…}, created:[…]}` |
    | POST `/api/tasks/queue/start` | `{"workspace":"…","session":"$DSH_SESSION_ID","queueId":"q-…"}`（`queueId` 也可换成 `name`） | 启动队列（draft/paused → active）；按 id / 名字定位，缺省时启动本会话创建的那个等待队列 |
    | POST `/api/tasks/queue/append` | `{"workspace":"…","session":"$DSH_SESSION_ID","queueId":"q-…"（或 "name":"队列名"）,"tasks":[…]}` | 向**已有**队列追加任务；不启动；返回 `{ok, queue:{id,name,state,…}, created:[…]}` |
    | POST `/api/tasks/queue/deliver` | `{workspace?, session?, queueId?（或 name?）}` | 对一条**已完成（done）**队列发起交付（PR / 合并 / 推送）；只发起、不等待，结果由交付会话回写卡片；返回 `{ok, delivering:[id]}` |
    
    - `workspace`：Agent 会话的工作目录（`pwd`）。传工作区根即可，面板按「最近祖先」解析
      （`pwd` 在子目录里也对）。不传则用面板当前工作区。
    - `focus`：默认 `true` —— 切到该工作区并展开任务面板。不想打扰就传 `false`。
    - `session`：**建队列时强烈建议带 `$DSH_SESSION_ID`**；完成回传就回到这里。
    - `branch`：缺省按队列名派生（`feature/<slug>`）；传 `""` = 完全不切分支。
    - `autoPR`：缺省按工作区能力（有 GitHub 远端才「完成后自动开 PR」）。
    - `tasks`：每条可写对象（`title` + `body`，**推荐**）或纯字符串。一次上限 50 条；空标题等
      进 `rejected`，不影响其它条目。
    - `queue/start` 可以按 `queueId` 或 `name` 启动；若本会话创建过多个等待队列又没说名字，先
      `task/list` 再点名（否则 409 `ambiguous-queue`）。
    - `queue/append` 的目标队列按 `queueId` → `name` → `session`（本会话创建的非关闭队列）解析；
      追加到 `.done` 队列会把它变回 **`draft`（待启动）**，要再 `queue/start` 才会跑。
    - `queue/deliver` 的目标队列同样按 `queueId` → `name` → `session` 解析（三者**必选其一**）；只接受 **`done`** 队列，
      工作流是「无」或还没有分支 / 远端时会被拒绝（错误码见下）。
    
    ## 工作流
    
    1. **先看面板有什么**（避免重复建）：
       ```bash
       curl -sG --data-urlencode "workspace=$(pwd)" "http://127.0.0.1:$PORT/api/tasks/task/list"
       ```
    2. **组织任务**：标题（一行，扫一眼就知道做什么）+ 描述（做什么 / 依据什么 / 怎么算完成）。
       只写沟通里已经确认的内容。
    3. **落进面板**（把 JSON 写成文件再 `--data-binary`，避免引号转义咬到中文）：
       - **默认：先追加到本会话的队列** —— `POST /api/tasks/queue/append`，带 `session`（知道 `queueId`/`name` 更好）：
         - 成功 → 追加完成；
         - `404 no-queue` → 本会话还没有队列 → 改用 `POST /api/tasks/queue/create`（带 `session`，
           队列名用户没给就按本轮主题起一个），并记下响应里的 `queue.id`；
         - `409 ambiguous-queue` → 本会话有多条队列：`GET /api/tasks/task/list` 看名字，按主题选一条再带 `queueId` 追加
           （真分不清就问用户一句）。
       - **仅当**用户明确说「只建任务 / 先别入队 / 不要队列」→ `/api/tasks/task/create`；
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
    5. **交付**（仅当用户明确要求，且队列**已完成**）：`POST /api/tasks/queue/deliver`，带 `session`（和必要的 `queueId` / `name`）；返回 `ok` 后告诉用户「已发起交付，结果会回写到队列卡片」。
    6. **核对与汇报**：几行以内 —— 建了什么（队列名 / 几条任务 / 是否待启动）、面板在哪、有没有
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
    | `404 no-queue` | 没有可启动的等待队列：先 `task/list` 确认 id，或它已经启动过 |
    | `400 no-queue-target` | 追加 / 交付没给目标队列：带 `queueId` / `name`，或用本会话定位 |
    | `400 queue-closed` | 目标队列已关闭（终态）：别翻它，明确新建一条队列 |
    | `400 not-deliverable` | 交付要求队列**已完成**（done）：还没跑完 / 已关闭都不能交付；先 `task/list` 看状态 |
    | `400 workflow-none` | 该队列的 Git 工作流是「无」：没有要交付的动作；让用户先去队列设置选一个工作流 |
    | `400 no-branch` / `no-remote` | 队列没有分支 / 工作区没有可推送远端：转述原因，请用户调整队列设置或工作区 |
    | `409 busy` | 已有一个交付会话在跑：等它结束再交付，不要重复发起 |
    | `rejected` 里有条目 | 逐条说明原因，把有效的部分如实汇报，不要谎报全部成功 |
    
    ## 不要做
    
    - 不直接改 `<workspace>/.dsh/tasks/*.json`（面板内存里有 board，外部改动会被覆盖，用户也
      看不到反馈）；
    - 不在用户没要求时建任务 / 建队列 / 启动队列 / 切分支 / 开 PR；
    - 不把本轮没确认的猜测写成任务。
    
    """

    static let requirementPoolMarkdown = """
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
    - **对话 / 收件 / 拆解阶段不改代码**：需求还在讨论、未落卡或拆解未确认之前，只讨论、只澄清、只落卡；**实施的唯一入口 = 已启动的任务队列**（工作区 `AGENTS.md` / 规范 R12）。
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
    
    """

    static let workstreamPanelMarkdown = """
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
    curl -sG --data-urlencode "session=$DSH_SESSION_ID" \\
      "http://127.0.0.1:$PORT/api/workstreams/bound"

    # 反查并聚焦：面板置前、高亮该事项卡
    curl -sG --data-urlencode "session=$DSH_SESSION_ID" --data-urlencode "focus=true" \\
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
     "text": "- 目标：…（WHAT）\\n- 边界：…\\n- 验收标准：AC1 …；AC2 …\\n- 阶段裁剪声明：不裁剪"}
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
    curl -s -X POST "http://127.0.0.1:$PORT/api/workstreams/queue/pause" -H 'Content-Type: application/json' \\
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

    """
}

/// Result of one skill's install/migration pass (for logs and tests).
struct SkillInstallResult {
    let skill: BuiltinSkill
    let action: String   // installed | updated | upToDate | skippedUserManaged | migrated | failed
    let path: String?
}

/// Installs built-in skills into the global dsh home at app startup.
enum SkillInstaller {

    /// Sidecar marker file identifying an app-managed install (protects user edits).
    static let managedMarker = ".ohmy-dsh-managed"

    /// Resolved global dsh home: $DSH_HOME or ~/.dsh.
    static func dshHomeDir() -> String {
        let env = ProcessInfo.processInfo.environment
        if let h = env["DSH_HOME"], !h.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (h as NSString).expandingTildeInPath
        }
        return (NSHomeDirectory() as NSString).appendingPathComponent(".dsh")
    }

    /// Names oh-my-dsh USED to ship and no longer does. The app-managed copy under
    /// $DSH_HOME/skills/ is deleted at startup; a copy the user edited (no managed
    /// marker) is THEIR file now — kept, and logged.
    ///
    /// `issue-resolve` retired with the 2026-09-27 alignment: the issue task and the
    /// manual task now share one prompt (TaskPrompts.requirements), so the skill had
    /// become a second, stale source of truth — it still told the agent to `git push`,
    /// which is the queue's 开 PR 会话 job now.
    static let retiredSkills = ["issue-resolve", "issue-fix"]

    /// Ensure every built-in skill is present under $DSH_HOME/skills,
    /// migrating legacy names first and retiring what we no longer ship.
    /// Never throws; failures are logged/skipped.
    @discardableResult
    static func installBuiltinSkills() -> [SkillInstallResult] {
        let home = dshHomeDir()
        migrateLegacyNames(home: home)
        removeRetiredSkills(home: home)
        var results: [SkillInstallResult] = []
        for skill in BuiltinSkill.allCases {
            results.append(ensure(skill: skill, home: home))
        }
        return results
    }

    /// Delete the app-managed copies of retired skills; leave user-managed ones alone.
    private static func removeRetiredSkills(home: String) {
        let fm = FileManager.default
        for name in retiredSkills {
            let dir = (home as NSString).appendingPathComponent("skills/" + name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { continue }
            let marker = (dir as NSString).appendingPathComponent(managedMarker)
            guard fm.fileExists(atPath: marker) else {
                AppLog.shared.log("skill retired: " + name + " kept (user-managed: no " + managedMarker + ")")
                continue
            }
            do {
                try fm.removeItem(atPath: dir)
                AppLog.shared.log("skill retired: removed " + dir)
            } catch {
                AppLog.shared.log("skill retire failed " + name + ": " + error.localizedDescription)
            }
        }
    }

    /// Rename legacy skill dirs (shell-browser/repo-wiki) to the new names when the
    /// target is absent. Only touches $DSH_HOME/skills. (issue-fix is NOT renamed any
    /// more: its skill is retired — see retiredSkills.)
    private static func migrateLegacyNames(home: String) {
        let skillsDir = (home as NSString).appendingPathComponent("skills")
        let fm = FileManager.default
        for skill in BuiltinSkill.allCases {
            guard let legacy = skill.legacyName else { continue }
            let newDir = (skillsDir as NSString).appendingPathComponent(skill.dirName)
            let oldDir = (skillsDir as NSString).appendingPathComponent(legacy)
            guard fm.fileExists(atPath: oldDir) else { continue }
            guard !fm.fileExists(atPath: newDir) else {
                AppLog.shared.log("skill migrate: " + skill.dirName + " already exists; legacy " + legacy + " left untouched")
                continue
            }
            do {
                try fm.createDirectory(atPath: skillsDir, withIntermediateDirectories: true)
                try fm.moveItem(atPath: oldDir, toPath: newDir)
                AppLog.shared.log("skill migrate: " + legacy + " -> " + skill.dirName)
                // Take ownership of the migrated copy: mark app-managed so ensure() refreshes it.
                writeManagedMarker((newDir as NSString).appendingPathComponent(managedMarker))
                _ = ensure(skill: skill, home: home)   // refresh content + marker
            } catch {
                AppLog.shared.log("skill migrate failed " + legacy + ": " + error.localizedDescription)
            }
        }
    }

    /// Install/update/skip one skill under <home>/skills/<dirName>.
    private static func ensure(skill: BuiltinSkill, home: String) -> SkillInstallResult {
        let dir = (home as NSString).appendingPathComponent("skills/" + skill.dirName)
        let path = (dir as NSString).appendingPathComponent("SKILL.md")
        let marker = (dir as NSString).appendingPathComponent(managedMarker)
        let fm = FileManager.default
        do {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: path) {
                let installed = try? String(contentsOfFile: path, encoding: .utf8)
                if installed == skill.markdown {
                    writeManagedMarker(marker)   // best-effort
                    return SkillInstallResult(skill: skill, action: "upToDate", path: path)
                }
                if fm.fileExists(atPath: marker) {
                    try skill.markdown.write(toFile: path, atomically: true, encoding: .utf8)
                    writeManagedMarker(marker)
                    AppLog.shared.log("skill updated: " + path)
                    return SkillInstallResult(skill: skill, action: "updated", path: path)
                }
                AppLog.shared.log("skill skipped (user-managed): " + path)
                return SkillInstallResult(skill: skill, action: "skippedUserManaged", path: path)
            }
            try skill.markdown.write(toFile: path, atomically: true, encoding: .utf8)
            writeManagedMarker(marker)
            AppLog.shared.log("skill installed: " + path)
            return SkillInstallResult(skill: skill, action: "installed", path: path)
        } catch {
            AppLog.shared.log("skill install failed " + skill.dirName + ": " + error.localizedDescription)
            return SkillInstallResult(skill: skill, action: "failed", path: path)
        }
    }

    private static func writeManagedMarker(_ marker: String) {
        let content = "Managed by oh-my-dsh. Removing this marker stops automatic updates.\n"
        try? content.write(toFile: marker, atomically: true, encoding: .utf8)
    }
}
