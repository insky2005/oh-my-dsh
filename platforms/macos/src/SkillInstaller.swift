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

    var dirName: String {
        switch self {
        case .webDevTools: return "web-dev-tools"
        case .repoKnowledge: return "repo-knowledge"
        case .taskTodo: return "task-todo"
        }
    }

    /// Pre-rename name this skill used to be installed under (startup migration).
    var legacyName: String? {
        switch self {
        case .webDevTools: return "shell-browser"
        case .repoKnowledge: return "repo-wiki"
        case .taskTodo: return nil
        }
    }

    var markdown: String {
        switch self {
        case .webDevTools: return Self.webDevToolsMarkdown
        case .repoKnowledge: return Self.repoKnowledgeMarkdown
        case .taskTodo: return Self.taskTodoMarkdown
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
    description: 把沟通好的需求/方案落成任务面板：默认建「等待态队列 + 批量任务」并可启动队列；只有用户明确要求时才只建任务。Turn agreed requirements into a waiting queue with tasks by default (or bare tasks on request) on the oh-my-dsh tasks panel, and start the queue on request.
    ---
    
    # task-todo — 把沟通结论写进任务面板（任务 / 队列）
    
    oh-my-dsh 壳层的**任务面板**（Tasks）通过 **localhost REST API** 驱动。用户在会话里和你
    聊完需求与方案、并且**明确要求**时，用本技能把结论落进面板：
    
    - **默认：建「等待态队列 + 入队」** —— 建一个 `draft` 队列，把任务一次性批量入队；队列
      不会自己开跑，等用户（或会话）说「启动队列」；
    - **只建任务**（**仅当**用户明确说「只建任务 / 先别入队 / 不要队列」时）：批量创建
      「待处理、未入队」的手动任务，用户之后自己在面板挑队列；
    - **追加到已有队列**（用户说「加到队列 X / 再补几条 / 继续那个队列」时）：往该队列
      `/api/tasks/queue/append` 追加任务，**不新建队列**；追加到已完成的队列会让它回到**待启动**。
    
    ## 何时执行（硬规则）
    
    - **只在用户明确要求时执行**。用户没说「建任务 / 建队列 / 启动队列」，就**不要**建、不要
      启动；沟通还在进行、方案还没定，也不要抢跑。
    - 用户要求了 → 一次性建完（**一次请求多条**），不要一条一条调。
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
    3. **选端点**（把 JSON 写成文件再 `--data-binary`，避免引号转义咬到中文）：
       - **默认** → `/api/tasks/queue/create`（带上 `session`），并从响应里记下 `queue.id`；
         队列名用户没给就按本轮主题起一个（响应里会回 `queue.name`）；
       - **仅当**用户明确说「只建任务 / 先别入队 / 不要队列」→ `/api/tasks/create`；
       - **追加到已有队列**（「加到队列 X / 再补几条 / 继续那个队列」）→ `/api/tasks/queue/append`，
         带队列的 `queueId` 或 `name`（拿不准就先 `list` 找）。
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
