import Foundation

// MARK: - 事项交付（git 流水线 / GitHub PR / token 文件读取，design A10）
//
// 按裁决 A10，从任务面板的 git 探测（`TasksCore.WorkspaceRepoProbe`）与
// GitHub PR / token 读取（`IssueRunnerPanel`）「复制 + 重命名 + 改造」为事项面板
// 自有模块。clean-room（A1）：不 import / 不调用任务面板任何代码；不碰
// `.dsh/tasks/*`（D8）；纯 Foundation，可在 headless 测试里驱动。
//
// 按「事项 / 阶段」语义改造的适配点：
//   1. 交付是**事项的「交付」阶段动作**，不是队列动作：只有 `stage == .delivery`
//      的卡才准入（`WSDeliveryBlocker.notDeliveryStage`）；
//   2. 失败一律给出**明确原因**（`WSDeliveryBlocker`）：非 git 仓库 / 无分支 /
//      无远端 / 远端不是 GitHub / 无 token——无一沉默；
//   3. PR 状态 → `delivery.outcome` 派生缓存（store design §5：事实可写、outcome
//      由交付追踪派生，禁止手写；取值与 `.dsh/tools/derive-status.mjs` 对齐）；
//   4. `covered`（点记录）与事项标题进交付提示词，交付结果回填 WS 卡的 `delivery` 块。
//
// token 文件布局（与 AGENTS.md / ShellPaths 同一套约定，默认目录 ~/.dsh）：
//   1. $DSH_HOME/oh-my-dsh/tokens/<owner>-<repo>   逐仓库（面板写入）
//   2. $DSH_HOME/oh-my-dsh/gh-token                通用兜底（与 agent 共用）
//   3. $DSH_HOME/tokens/<owner>-<repo>、$DSH_HOME/gh-token   旧布局只读回退

// MARK: - GitHub remote

/// 一个 GitHub 远端拆成 API 需要的 owner / repo（复制自 TasksCore.GitHubRepo）。
struct WSGitHubRepo: Equatable {
    var owner: String
    var name: String

    var slug: String { owner + "/" + name }
}

// MARK: - git 探测（可注入）

/// 交付需要的 git 事实。每条命令都走注入的 `run` 闭包，测试无需真实仓库；
/// 解析类（remote / github / base）保持纯函数以便单独断言。
struct WSGitProbe {
    /// git 在 `path` 里跑这些参数后的 stdout；命令失败或无法启动时 nil。
    var run: (_ path: String, _ args: [String]) -> String?

    // MARK: 事实

    func isGitRepo(_ path: String) -> Bool {
        run(path, ["rev-parse", "--is-inside-work-tree"]) == "true"
    }

    func currentBranch(_ path: String) -> String? {
        run(path, ["rev-parse", "--abbrev-ref", "HEAD"])
    }

    /// `git remote` 的名字，按 git 输出顺序。
    func remoteNames(_ path: String) -> [String] {
        guard let out = run(path, ["remote"]) else { return [] }
        return out.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map(String.init)
    }

    /// `git remote -v` → 每个远端一条 (name, url)，同名第一行胜出。
    func remotes(_ path: String) -> [(name: String, url: String)] {
        guard let out = run(path, ["remote", "-v"]) else { return [] }
        return WSGitProbe.parseGitRemotes(out)
    }

    /// 推送用远端：github > origin > 第一个；无远端时 nil。
    func pushRemoteName(_ path: String) -> String? {
        WSGitProbe.pushRemoteName(remoteNames(path))
    }

    /// github.com 远端，优先字面名 "github"。
    func githubRepo(_ path: String) -> WSGitHubRepo? {
        WSGitProbe.githubRepo(fromRemotes: remotes(path))
    }

    /// 仓库自己的默认基线分支（origin/HEAD → main → master → 当前 → "main"）。
    func defaultBaseBranch(_ path: String) -> String {
        let remote = pushRemoteName(path)
        let symbolic = remote.flatMap { run(path, ["symbolic-ref", "--short", "refs/remotes/\($0)/HEAD"]) }
        let current = currentBranch(path)
        let hasMain = run(path, ["rev-parse", "--verify", "--quiet", "main"]) != nil
        let hasMaster = run(path, ["rev-parse", "--verify", "--quiet", "master"]) != nil
        return WSGitProbe.defaultBaseBranch(symbolicRef: symbolic, current: current,
                                            hasMain: hasMain, hasMaster: hasMaster)
    }

    func branchExists(_ path: String, _ branch: String) -> Bool {
        run(path, ["rev-parse", "--verify", "--quiet", branch]) != nil
    }

    /// 分支相对基线的提交（"abc123 subject"）；git 答不上来时 nil。
    func commits(_ path: String, base: String, branch: String) -> [String]? {
        guard let out = run(path, ["log", "--oneline", "--no-decorate", base + ".." + branch]) else { return nil }
        return out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: 纯解析

    /// `git remote -v` → 每个远端一条 (name, url)，同名第一行胜出。
    static func parseGitRemotes(_ output: String) -> [(name: String, url: String)] {
        var seen: Set<String> = []
        var remotes: [(name: String, url: String)] = []
        for line in output.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2 else { continue }
            let name = String(parts[0])
            guard !seen.contains(name) else { continue }
            seen.insert(name)
            remotes.append((name, String(parts[1])))
        }
        return remotes
    }

    /// github.com 远端，优先字面名 "github"（复制自 WorkspaceRepoProbe.githubRepo）。
    static func githubRepo(fromRemotes remotes: [(name: String, url: String)]) -> WSGitHubRepo? {
        let url = remotes.first { $0.name == "github" && $0.url.contains("github.com") }?.url
            ?? remotes.first { $0.url.contains("github.com") }?.url
        guard let url = url,
              let range = url.range(of: "github.com[/:]", options: .regularExpression) else { return nil }
        let tail = String(url[range.upperBound...])
        let parts = tail.split(separator: "/")
        guard parts.count >= 2 else { return nil }
        let owner = String(parts[0])
        let name = String(parts[1]).replacingOccurrences(of: ".git", with: "")
        guard !owner.isEmpty, !name.isEmpty else { return nil }
        return WSGitHubRepo(owner: owner, name: name)
    }

    /// 推送远端优先级：github > origin > 第一个。
    static func pushRemoteName(_ names: [String]) -> String? {
        if names.contains("github") { return "github" }
        if names.contains("origin") { return "origin" }
        return names.first
    }

    /// 基线分支决策链（复制自 TaskBranch.defaultBaseBranch）：远端 HEAD → main →
    /// master → 当前分支 → "main"。"origin/HEAD" 是未解析的悬空 symref，不算答案。
    static func defaultBaseBranch(symbolicRef: String?, current: String?,
                                  hasMain: Bool, hasMaster: Bool) -> String {
        if let ref = symbolicRef?.trimmingCharacters(in: .whitespacesAndNewlines), !ref.isEmpty {
            if let slash = ref.lastIndex(of: "/") {
                let tail = String(ref[ref.index(after: slash)...])
                if !tail.isEmpty, tail != "HEAD" { return tail }
            } else if ref != "HEAD" {
                return ref
            }
        }
        if hasMain { return "main" }
        if hasMaster { return "master" }
        if let current = current?.trimmingCharacters(in: .whitespacesAndNewlines),
           !current.isEmpty, current != "HEAD" {
            return current
        }
        return "main"
    }

    /// 真实 git（/usr/bin/git）。阻塞：调用方在后台线程跑。
    static func runGit(_ path: String, _ args: [String]) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = ["-C", path] + args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do { try proc.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let live = WSGitProbe(run: { path, args in WSGitProbe.runGit(path, args) })
}

// MARK: - GitHub token（文件读取，逐仓库作用域）

/// token 文件的唯一读写点：面板写的就是外部工具 / agent 读的那些文件，因此只有
/// 一处要找，也不会弹钥匙串密码框（2026-09-24 起不再读 Keychain）。
struct WSTokenStore {
    /// dsh 数据目录（$DSH_HOME 或 ~/.dsh）。
    var home: String
    /// 读文件；默认真实 FileManager。
    var read: (_ path: String) -> String?
    /// 写文件（父目录已建）；默认真实 FileManager，原子 + chmod 600。
    var write: (_ path: String, _ contents: String) -> Void
    /// 删文件（清空 token 时）。
    var remove: (_ path: String) -> Void

    init(home: String = WSTokenStore.defaultHome,
         read: @escaping (String) -> String? = WSTokenStore.readFile,
         write: @escaping (String, String) -> Void = WSTokenStore.writeFile,
         remove: @escaping (String) -> Void = WSTokenStore.removeFile) {
        self.home = home
        self.read = read
        self.write = write
        self.remove = remove
    }

    /// $DSH_HOME（去空白），否则 ~/.dsh —— 与 ShellPaths.home() 同一约定。
    static var defaultHome: String {
        if let h = ProcessInfo.processInfo.environment["DSH_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !h.isEmpty {
            return h
        }
        return (NSHomeDirectory() as NSString).appendingPathComponent(".dsh")
    }

    // MARK: 路径

    static func tokensDir(home: String) -> String {
        ((home as NSString).appendingPathComponent("oh-my-dsh") as NSString).appendingPathComponent("tokens")
    }

    static func genericPath(home: String) -> String {
        ((home as NSString).appendingPathComponent("oh-my-dsh") as NSString).appendingPathComponent("gh-token")
    }

    static func perRepoPath(home: String, owner: String, repo: String) -> String {
        (tokensDir(home: home) as NSString).appendingPathComponent(owner + "-" + repo)
    }

    static func legacyPerRepoPath(home: String, owner: String, repo: String) -> String {
        ((home as NSString).appendingPathComponent("tokens") as NSString).appendingPathComponent(owner + "-" + repo)
    }

    static func legacyGenericPath(home: String) -> String {
        (home as NSString).appendingPathComponent("gh-token")
    }

    /// 查找顺序：逐仓库新 → 逐仓库旧 → 通用新 → 通用旧（与任务面板逐字一致）。
    func candidatePaths(owner: String?, repo: String?) -> [String] {
        var paths: [String] = []
        if let owner = owner, let repo = repo, !owner.isEmpty, !repo.isEmpty {
            paths.append(WSTokenStore.perRepoPath(home: home, owner: owner, repo: repo))
            paths.append(WSTokenStore.legacyPerRepoPath(home: home, owner: owner, repo: repo))
        }
        paths.append(WSTokenStore.genericPath(home: home))
        paths.append(WSTokenStore.legacyGenericPath(home: home))
        return paths
    }

    /// 第一个非空（去空白后）token；都没有时 nil。
    func load(owner: String? = nil, repo: String? = nil) -> String? {
        for path in candidatePaths(owner: owner, repo: repo) {
            if let token = read(path)?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
                return token
            }
        }
        return nil
    }

    /// 命中 token 的**文件路径**（绝不返回 token 内容），供日志 / 面板显示"从哪读的"。
    func source(owner: String? = nil, repo: String? = nil) -> String? {
        for path in candidatePaths(owner: owner, repo: repo) {
            if let token = read(path)?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
                return path
            }
        }
        return nil
    }

    /// 写逐仓库 token（空串=删除该文件）；无 owner/repo 时写通用文件。
    func save(_ token: String, owner: String? = nil, repo: String? = nil) {
        let path: String
        if let owner = owner, let repo = repo, !owner.isEmpty, !repo.isEmpty {
            path = WSTokenStore.perRepoPath(home: home, owner: owner, repo: repo)
        } else {
            path = WSTokenStore.genericPath(home: home)
        }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            remove(path)
            return
        }
        write(path, trimmed)
    }

    // MARK: 真实文件实现

    static func readFile(_ path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func writeFile(_ path: String, _ contents: String) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                withIntermediateDirectories: true)
        try? contents.data(using: .utf8)?.write(to: URL(fileURLWithPath: path), options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    static func removeFile(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }
}

// MARK: - GitHub PR（REST 查询）

/// 已有 PR 的查询（复制自 IssueRunnerPanel.findExistingPR）：交付前先找 head 是本
/// 分支的 OPEN PR——会话开过但没把链接报回来的，也能找得到（同一分支复用）。
struct WSGitHubPR {
    var find: (_ owner: String, _ repo: String, _ branch: String, _ token: String?) -> String?

    static let live = WSGitHubPR(find: WSGitHubPR.liveFind)

    /// 尽力而为：网络 / 权限 / 无 token 一律返回 nil，不阻塞交付。
    static func liveFind(owner: String, repo: String, branch: String, token: String?) -> String? {
        let escaped = branch.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? branch
        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/pulls?state=open&head=\(owner):\(escaped)") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "accept")
        request.setValue("oh-my-dsh", forHTTPHeaderField: "user-agent")
        if let token = token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        }
        let semaphore = DispatchSemaphore(value: 0)
        var prUrl: String?
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }
            guard let data = data,
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
            prUrl = items.first?["html_url"] as? String
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 20)
        task.cancel()
        return prUrl
    }
}

// MARK: - PR 文本解析

/// 从会话汇报 / URL 里读 PR 事实（复制自 TaskPrompts.prURL）。
enum WSPRText {
    /// 汇报里的第一个 github.com/<owner>/<repo>/pull/<n> 链接。
    static func url(in report: String?) -> String? {
        guard let report = report else { return nil }
        guard let range = report.range(of: "https?://[^\\s]*github\\.com/[^\\s]*/pull/[0-9]+",
                                       options: .regularExpression) else { return nil }
        return String(report[range])
    }

    /// PR 链接里的编号；解析不出时 nil。
    static func number(in url: String?) -> Int? {
        guard let url = url,
              let range = url.range(of: "/pull/[0-9]+", options: .regularExpression) else { return nil }
        return Int(url[range].replacingOccurrences(of: "/pull/", with: ""))
    }
}

// MARK: - 交付结果（派生缓存）

/// `delivery.outcome` 的取值。事实（pr / url）写卡片，outcome 只由 PR 状态派生
/// （store design §5）；终态集合与 RequirementsCore.terminalOutcomes 一致。
enum WSDeliveryOutcome: String, Equatable {
    case merged
    case closed
    case abandoned
    case open
    case unknown

    var isTerminal: Bool {
        switch self {
        case .merged, .closed, .abandoned: return true
        case .open, .unknown: return false
        }
    }

    /// 由 GitHub PR 状态派生（对齐 .dsh/tools/derive-status.mjs 的 prStatus）：
    /// merged → merged；open → open；closed(未合) → closed；显式放弃 → abandoned。
    static func derive(merged: Bool, state: String?, abandoned: Bool = false) -> WSDeliveryOutcome {
        if abandoned { return .abandoned }
        if merged { return .merged }
        switch (state ?? "").lowercased() {
        case "open": return .open
        case "closed": return .closed
        default: return .unknown
        }
    }

    /// Parse a stored cache value (case-insensitive); unknown / empty -> nil.
    /// The (lowercased) canonical spelling is what serialize writes back.
    static func parse(_ raw: String?) -> WSDeliveryOutcome? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return WSDeliveryOutcome(rawValue: raw.lowercased())
    }
}

// MARK: - 交付准入 / 失败原因

/// 事项交付卡在哪一步——每个失败都有明确原因，绝不沉默。
enum WSDeliveryBlocker: Equatable {
    /// 阶段不对：交付是操作，前置是最后的验收阶段（后续任务改为 accepted）。
    case notDeliveryStage(WorkstreamStage)
    /// 工作区不是 git 仓库。
    case notGitRepo
    /// 没有可交付的分支（交付需要一个实现分支）。
    case noBranch
    /// 仓库没有远端，推不出去。
    case noRemote
    /// 远端不是 GitHub，开不了 PR。
    case noGitHubRemote
    /// 没有 GitHub token。
    case noToken

    /// 稳定的机读码（API / 日志 / 测试）。
    var code: String {
        switch self {
        case .notDeliveryStage: return "not-delivery-stage"
        case .notGitRepo: return "not-git-repo"
        case .noBranch: return "no-branch"
        case .noRemote: return "no-remote"
        case .noGitHubRemote: return "no-github-remote"
        case .noToken: return "no-token"
        }
    }

    /// 面板渲染用的 L10n 键（本模块不依赖 L10n.table，键由 UI 层补齐）。
    var messageKey: String { "workstreams.deliver." + code }

    /// 中文原因（日志 / 提示词 / 汇报）。
    var message: String {
        switch self {
        case .notDeliveryStage(let stage):
            return "事项尚未到达验收阶段（当前阶段：" + stage.rawValue + "）"
        case .notGitRepo:
            return "工作区不是 git 仓库"
        case .noBranch:
            return "没有可交付的分支（交付需要一个实现分支）"
        case .noRemote:
            return "仓库没有远端，无法推送 / 开 PR"
        case .noGitHubRemote:
            return "远端不是 GitHub 仓库，无法开 PR"
        case .noToken:
            return "没有 GitHub token（$DSH_HOME/oh-my-dsh/tokens/<owner>-<repo> 或 $DSH_HOME/oh-my-dsh/gh-token）"
        }
    }
}

// MARK: - 交付计划 / 结论

/// 一条待交付事项收集到的全部事实（不含任何提示词渲染）。
struct WSDeliveryPlan: Equatable {
    var workstreamID: String
    var title: String
    var stage: WorkstreamStage
    var repoID: String
    var repoPath: String
    var remote: String
    var owner: String
    var repo: String
    var branch: String
    var base: String
    var commits: [String]
    /// 交付会用到的 token。仅用于 API 调用，**绝不进日志 / 汇报 / 提示词**。
    var token: String?
    /// 已存在的 OPEN PR（GitHub 查询优先，回落卡片里已记的 url）。
    var existingPR: String?
    /// 验收留存的点记录（进交付提示词）。
    var covered: CoveredRecord?

    var slug: String { owner + "/" + repo }
}

/// 交付准入的结论：可交付的计划，或有明确原因的阻塞。
enum WSDeliveryResolution: Equatable {
    case ready(WSDeliveryPlan)
    case blocked(WSDeliveryBlocker)

    var plan: WSDeliveryPlan? {
        if case .ready(let plan) = self { return plan }
        return nil
    }

    var blocker: WSDeliveryBlocker? {
        if case .blocked(let blocker) = self { return blocker }
        return nil
    }

    var isReady: Bool { plan != nil }
}

// MARK: - 交付流水线

/// 事项交付：准入 → 收集 git / GitHub / token 事实 → 生成计划 / 明确原因。
enum WorkstreamsDelivery {

    /// 交付准入与事实收集（纯逻辑，全部外部访问走注入）。
    ///
    /// 顺序即失败优先级：阶段 → git 仓库 → 分支 → 远端 → GitHub → token。
    /// 前一步不成立就直接给出该步的原因，不继续猜后面的。
    static func resolve(card: WorkstreamCard,
                        branch: String?,
                        repoRoot: String,
                        repoID: String = ".",
                        base: String? = nil,
                        git: WSGitProbe = .live,
                        tokens: WSTokenStore = WSTokenStore(),
                        findExistingPR: (_ owner: String, _ repo: String, _ branch: String,
                                         _ token: String?) -> String? = WSGitHubPR.liveFind) -> WSDeliveryResolution {
        // 交付是操作（design A17），不是阶段；准入先卡「最后一个阶段」验收。
        // 后续任务会把前置收紧为 accepted（验收已确认）。
        guard card.stage == .acceptance else {
            return .blocked(.notDeliveryStage(card.stage))
        }
        guard git.isGitRepo(repoRoot) else {
            return .blocked(.notGitRepo)
        }
        guard let branch = branch?.trimmingCharacters(in: .whitespacesAndNewlines), !branch.isEmpty else {
            return .blocked(.noBranch)
        }
        guard let remote = git.pushRemoteName(repoRoot) else {
            return .blocked(.noRemote)
        }
        guard let github = git.githubRepo(repoRoot) else {
            return .blocked(.noGitHubRemote)
        }
        let baseBranch: String
        if let base = base?.trimmingCharacters(in: .whitespacesAndNewlines), !base.isEmpty {
            baseBranch = base
        } else {
            baseBranch = git.defaultBaseBranch(repoRoot)
        }
        guard let token = tokens.load(owner: github.owner, repo: github.name) else {
            return .blocked(.noToken)
        }
        let commits = git.commits(repoRoot, base: baseBranch, branch: branch) ?? []
        // GitHub 上先找 head 是本分支的 OPEN PR；找不到就回落到卡片里已记的 url。
        let existing = findExistingPR(github.owner, github.name, branch, token) ?? card.delivery?.url
        let plan = WSDeliveryPlan(workstreamID: card.id,
                                  title: card.title,
                                  stage: card.stage,
                                  repoID: repoID,
                                  repoPath: repoRoot,
                                  remote: remote,
                                  owner: github.owner,
                                  repo: github.name,
                                  branch: branch,
                                  base: baseBranch,
                                  commits: commits,
                                  token: token,
                                  existingPR: existing,
                                  covered: card.covered)
        return .ready(plan)
    }

    /// 交付提示词（事项 / 阶段语义；复制 + 改造自 TaskPrompts.pullRequest）。
    ///
    /// 只包含指针与事实：事项 ID / 标题、分支与基线、覆盖路径、已有 PR、token 的
    /// **读取位置**（绝非 token 本身）；PR 标题正文由会话按实际改动写。
    static func prompt(plan: WSDeliveryPlan) -> String {
        var lines: [String] = []
        lines.append("事项「" + plan.workstreamID + " " + plan.title + "」已验收，请执行交付：推送分支 "
                     + plan.branch + " 并发起 pull request：")
        lines.append("")
        lines.append("## 事项信息")
        lines.append("事项：" + plan.workstreamID + "（" + plan.title + "）")
        lines.append("仓库：" + plan.slug + "（远端 " + plan.remote
                     + (plan.repoID == "." ? "，工作区根" : "，子目录 " + plan.repoID) + "）")
        lines.append("分支：" + plan.branch + "（基于 " + plan.base + "）")
        if let covered = plan.covered, !covered.paths.isEmpty {
            lines.append("本次覆盖路径（covered）：")
            for path in covered.paths { lines.append("  - " + path) }
            if let head = covered.head { lines.append("  变更锚点 head：" + head) }
        }
        if let existing = plan.existingPR, !existing.isEmpty {
            lines.append("已存在的 PR（复用，不要重复创建）：" + existing)
        }
        if !plan.commits.isEmpty {
            lines.append("分支上已有的提交：")
            for commit in plan.commits { lines.append("  " + commit) }
        }
        lines.append("")
        lines.append("要求：")
        lines.append("1. 先看清这个分支到底改了什么（git log " + plan.base + ".." + plan.branch
                     + "、git diff " + plan.base + "..." + plan.branch + "），不要凭事项名字猜；")
        lines.append("2. 把分支 push 到远端（远端名 " + plan.remote + "；分支还没推送过就 -u 推送）；")
        lines.append("3. 用 GitHub token 开 PR：token 在 $DSH_HOME/oh-my-dsh/tokens/<owner>-<repo> 或 "
                     + "$DSH_HOME/oh-my-dsh/gh-token（默认目录 ~/.dsh；cat 读取即可，绝不在对话/汇报中回显）；"
                     + "base = " + plan.base + "，head = " + plan.branch + "；已有同一 head 的 PR 就复用；")
        lines.append("4. PR 标题与正文由你按实际改动写：标题一句话说清这次合并做了什么，正文分条列出改动要点、"
                     + "怎么验证的、需要注意的地方；不要只写事项名，也不要套模板；")
        lines.append("5. 这个会话不要改任何代码：只做交付；")
        lines.append("6. 必须在最后一行给出 PR 的完整链接（https://github.com/<owner>/<repo>/pull/<编号>）；"
                     + "真开不出来就说清楚卡在哪一步（权限 / 网络 / token / 分支状态），不要沉默结束；")
        lines.append("7. 交付结果（delivery.outcome）由 PR 状态派生，不要手写 outcome；")
        lines.append("8. 交付完成后用 POST /api/workstreams/delivery 记录 delivery.pr / delivery.url 两个事实"
                     + "（带 PR 状态观察 state / merged），不要直接改 .dsh 文件；outcome 由面板派生。")
        return lines.joined(separator: "\n")
    }

    /// 把交付事实 + PR 观察合成 delivery 块。**outcome 是派生缓存**：这里由观察
    /// （merged / state / abandoned）现算，调用方无从手写（store design §5）。没有任何
    /// 事实（pr 与 url 都空）时返回 nil——清除整个块。
    static func record(pr: Int?,
                       url: String?,
                       state: String? = nil,
                       merged: Bool = false,
                       abandoned: Bool = false) -> DeliveryInfo? {
        let cleanURL = url?.trimmingCharacters(in: .whitespacesAndNewlines)
        if pr == nil, cleanURL?.isEmpty ?? true { return nil }
        let outcome = WSDeliveryOutcome.derive(merged: merged, state: state, abandoned: abandoned)
        return DeliveryInfo(pr: pr,
                            url: (cleanURL?.isEmpty ?? true) ? nil : cleanURL,
                            outcome: outcome.rawValue)
    }

    /// 面板侧唯一的交付事实写入口：合成 delivery 并落卡（outcome 只作派生缓存）。
    @discardableResult
    static func writeBack(workspace: String,
                          id: String,
                          pr: Int?,
                          url: String?,
                          state: String? = nil,
                          merged: Bool = false,
                          abandoned: Bool = false,
                          today: String,
                          fileManager: FileManager = .default) throws -> WorkstreamCard {
        let delivery = record(pr: pr, url: url, state: state, merged: merged, abandoned: abandoned)
        return try WorkstreamsCore.setDelivery(workspace: workspace, id: id,
                                               delivery: delivery, today: today,
                                               fileManager: fileManager)
    }

    /// 交付会话汇报里最能代表结果的短句（面板显示用）：PR 链接优先，否则第一行。
    static func summary(fromReport report: String?) -> String? {
        if let url = WSPRText.url(in: report) { return url }
        guard let text = report?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text.split(separator: "\n").first.map(String.init)
    }
}
