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

/// The three built-in skills shipped by oh-my-dsh.
enum BuiltinSkill: CaseIterable {

    case webDevTools
    case repoKnowledge
    case issueResolve

    var dirName: String {
        switch self {
        case .webDevTools: return "web-dev-tools"
        case .repoKnowledge: return "repo-knowledge"
        case .issueResolve: return "issue-resolve"
        }
    }

    /// Pre-rename name this skill used to be installed under (startup migration).
    var legacyName: String? {
        switch self {
        case .webDevTools: return "shell-browser"
        case .repoKnowledge: return "repo-wiki"
        case .issueResolve: return "issue-fix"
        }
    }

    var markdown: String {
        switch self {
        case .webDevTools: return Self.webDevToolsMarkdown
        case .repoKnowledge: return Self.repoKnowledgeMarkdown
        case .issueResolve: return Self.issueResolveMarkdown
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
    PORT="$(cat "$HOME/.dsh/browser-api.port" 2>/dev/null || echo 3081)"
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
    
    ## 页面结构（初始生成 ≤ 20 页，单页 ≤ 200 行）
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
    
    ## 规则（强制）
    1. 只写可从代码/文档证实的事实；不确定处标注「待确认」；禁止编造；
    2. **增量更新**：先读 `index.md` 了解已有结构；用 `git status --short` + mtime 定位变更文件，只重写 `sources` 命中变更的页面；未变页面保持**字节不变**；git 不可用时退化为 mtime 扫描；
    3. **sources 质量**：`sources` 列全该页依据的文件/目录（目录即可覆盖其子树）——它决定陈旧检测与后续增量更新的准确性，遗漏会导致页面无法被判定过期；
    4. `manual: true` 的页面绝不改写；
    5. 脱敏：跳过 .env*/密钥/口令/个人数据，示例一律占位符；
    6. **不删除页面**：源码删除后在该页标注「已失效」而非删文件，留给用户审阅；
    7. 完成后更新 `index.md` 的统计与最后生成时间；
    8. **提交（若仓库是 git）**：更新完成后执行 `git add .dsh/wiki` 并 `git commit`，**绝不 push**。commit message **由你概括本次实际变更**（如 `docs(wiki): 同步 v1.8.0 发布流程与 IssueRunner 面板文档`），不要用固定文案、不要带「自动提交」等过程标注；若没有任何变更（无 diff）则跳过提交；
    9. **汇报**：简短列出本次生成/更新的页面（含新增 / 失效 / 手动跳过），不超过几行，不粘贴正文。
    """

    static let issueResolveMarkdown = """
    ---
    name: issue-resolve
    description: 在当前会话中修复一个 GitHub issue（读 issue → 改代码 → 跑测试 → 提交推送 → 汇报）。Fix a GitHub issue in the current session (read issue → change code → run tests → commit & push → report).
    user-invocable: false
    ---
    
    # issue-resolve — 按 GitHub issue 完成修复并提交推送
    
    面板（IssueRunner）为某个 issue 创建独立会话并加载本 skill 时使用。会话 cwd 是**主项目工作区**，当前 git 分支由面板提前切好：feature 类 issue 为 `feature/issue-<N>`，bug/其他为 `fix/issue-<N>`（按统一分支规范 `docs/git-workflow.md`）。
    
    ## 执行方式（强制）
    - **在当前会话内直接执行，绝不新建顶层会话**（不得 session.create / fork）；确需并行探索时可使用 subagent（子会话，不影响顶层会话归属）；
    - **仓库根**：当前会话工作目录（`pwd`）；当前分支必须是 `feature/issue-<N>` 或 `fix/issue-<N>`（以面板会话提示为准）——若不是，先 `git status` 确认，异常则停下汇报；
    - 只改当前分支上的代码，**绝不触碰 main/其他分支**，不 `git checkout` 别的分支。
    
    ## 输入
    会话提示语会给出 issue 的：编号 `<N>`、标题、标签、正文/复现步骤（如有）、验收要求（如有）。
    
    ## 流程
    1. **理解 issue**：读给出的 issue 内容；不清楚的地方在代码里找依据，不臆测；
    2. **定位与修改**：找到相关代码，做**最小**修改解决 issue；遵守仓库 `.dsh/wiki/conventions.md` 的工程约定（L10n 中英、不改 dsh 上游源码、面板 UI 约定等）；需要时先读 `.dsh/wiki/` 了解模块结构；
    3. **本地验证**：按 issue 影响面跑相关测试：
       - 共享核心：`node --test core/tests/*.test.js`（node 用内置运行时：`Contents/Resources/runtime/node` 或 PATH 上的 node）；
       - macOS 壳：`tests/*/run.sh`（swiftc 可用时）；
       - 无法跑的（如缺工具链）明确说明，不假装通过；
    4. **提交**：`git add` 相关文件 → `git commit -m "fix(#<N>): <标题简短>"`；一个 issue 一个 commit（或逻辑相关的少量 commit）。若修复关联 PR，commit 正文可附加 `Closes #<N>`（GitHub 在 PR 合并时自动关闭对应 issue），但**不要**在 commit 里写无关内容；
    5. **推送**：先检测远端名（`git remote`；优先名为 `github`，其次 `origin`，否则第一个 remote），再 `git push -u <远端名> <当前分支名>`；
    6. **汇报**：简短列出改动文件、测试结果、commit 号；PR 由面板创建，你**不负责开 PR**。
    
    ## 规则（强制）
    1. 只做 issue 要求的最小改动；不顺手重构无关代码；
    2. 不提交无关文件（`git status` 里与本次修复无关的变更不要 add）；
    3. 不改动 `.env*`/密钥/口令相关文件，不提交敏感信息；
    4. 测试失败必须停下说明，不得静默跳过；
    5. 推送失败（无远端/权限）时停下汇报，不伪造成功；
    6. **GitHub 写操作需 token**：推送私有仓库 / 需要认证的调用时，从 `~/.dsh/tokens/<owner>-<repo>` 或 `~/.dsh/gh-token` 读取（`cat` 即得），**绝不打印/回显 token 内容，绝不在对话、汇报、日志、commit message 中泄露 token**；公开仓库推送通常无需 token；
    7. 汇报简短（几行），不粘贴大段正文。
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

    /// Ensure every built-in skill is present under $DSH_HOME/skills,
    /// migrating legacy names first. Never throws; failures are logged/skipped.
    @discardableResult
    static func installBuiltinSkills() -> [SkillInstallResult] {
        let home = dshHomeDir()
        migrateLegacyNames(home: home)
        var results: [SkillInstallResult] = []
        for skill in BuiltinSkill.allCases {
            results.append(ensure(skill: skill, home: home))
        }
        return results
    }

    /// Rename legacy skill dirs (shell-browser/repo-wiki/issue-fix) to the new
    /// names when the target is absent. Only touches $DSH_HOME/skills.
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
