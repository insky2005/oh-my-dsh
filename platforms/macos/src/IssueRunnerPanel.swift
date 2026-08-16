import AppKit

// MARK: - IssueRunner panel (issue-driven tasks)

/// Root view. Mirrors WikiRootView's compositing fix
/// (docs/terminal-header-fix.md): isOpaque=false so header/toolbar/content
/// composite correctly in the layer-backed window.
final class IssueRunnerRootView: NSView {
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let color = dark ? NSColor(calibratedWhite: 0.28, alpha: 1) : NSColor(calibratedWhite: 0.94, alpha: 1)
        color.setFill()
        dirtyRect.fill()
    }
}

/// One issue/task row shown in the list.
struct IssueRunnerTask {
    enum State: String {
        case pending, running, done, failed, cancelled
        var badge: String {
            switch self {
            case .pending: return "·"
            case .running: return "…"
            case .done: return "✓"
            case .failed: return "✗"
            case .cancelled: return "−"
            }
        }
    }
    var number: Int
    var title: String
    var labels: [String]
    var state: State = .pending
    var prUrl: String?
    var error: String?
    var branch: String?          // fix/issue-N
    var sessionId: String?       // dsh session created for this task
    var startedAt: Date?
}

final class IssueRunnerPanelController: NSObject, NSTableViewDataSource, NSTableViewDelegate {

    var onRequestHide: (() -> Void)?
    /// Provides the dsh web port (set by AppDelegate, like other panels).
    var serverPortProvider: (() -> Int)?
    /// The main workspace directory (set by AppDelegate) — git/github root.
    var workspacePath: (() -> String?)?

    static let minWidth: CGFloat = 300

    let view = IssueRunnerRootView()

    // UI
    private let headerTitle = HeaderLabel()
    private let configButton: CustomIconButton
    private let refreshButton: CustomIconButton
    private let runAllButton: CustomIconButton
    private let hideButton: CustomIconButton
    private let repoLabel = HeaderLabel()
    private let tableView = NSTableView()
    private let tableScroll = NSScrollView()
    private let statusBar = DynamicFillView()
    private let statusLabel = HeaderLabel()
    private let statusSpinner = NSProgressIndicator()

    // State
    private var tasks: [IssueRunnerTask] = []
    private var repo: (owner: String, repo: String)?
    private var repoRootPath: String?
    private var token: String?   // from Keychain; nil for public repos
    private var pollTimer: Timer?
    private var runningNumber: Int?

    // GitHub token keychain service (per-repo scoped later if needed).
    private static let tokenService = "oh-my-dsh.issuerunner.github-token"

    // MARK: - Init & UI

    override init() {
        configButton = CustomIconButton(glyph: .folder, tooltip: "")
        refreshButton = CustomIconButton(glyph: .symbol("arrow.clockwise"), tooltip: "")
        runAllButton = CustomIconButton(glyph: .play, tooltip: "")
        hideButton = CustomIconButton(glyph: .close, tooltip: "")
        super.init()
        buildUI()
        refreshButton.onAction = { [weak self] in self?.reloadIssues() }
        runAllButton.onAction = { [weak self] in self?.runAllTapped() }
        configButton.onAction = { [weak self] in self?.configTapped() }
        hideButton.onAction = { [weak self] in self?.onRequestHide?() }
        updateLabels()
    }

    deinit {
        pollTimer?.invalidate()
    }

    private func updateLabels() {
        headerTitle.text = L10n.tr("tasks.title")
        configButton.toolTip = L10n.tr("tasks.configHint")
        refreshButton.toolTip = L10n.tr("tasks.refreshHint")
        runAllButton.toolTip = L10n.tr("tasks.runAllHint")
        hideButton.toolTip = L10n.tr("preview.closePanel")
        repoLabel.text = repo.map { "\($0.owner)/\($0.repo)" } ?? L10n.tr("tasks.noRepo")
    }

    private func buildUI() {
        headerTitle.translatesAutoresizingMaskIntoConstraints = false
        headerTitle.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let actions = NSStackView(views: [refreshButton, runAllButton, configButton, hideButton])
        actions.orientation = .horizontal
        actions.spacing = 6
        actions.translatesAutoresizingMaskIntoConstraints = false

        let header = DynamicFillView()
        header.kind = .window
        header.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(headerTitle)
        header.addSubview(actions)
        NSLayoutConstraint.activate([
            headerTitle.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 10),
            headerTitle.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            headerTitle.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -8),
            actions.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -8),
            actions.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            header.heightAnchor.constraint(equalToConstant: 40),
        ])

        // toolbar: repo + status info
        repoLabel.translatesAutoresizingMaskIntoConstraints = false
        let toolbar = DynamicFillView()
        toolbar.kind = .window
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.wantsLayer = true
        toolbar.layer?.masksToBounds = true
        toolbar.addSubview(repoLabel)
        NSLayoutConstraint.activate([
            repoLabel.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 10),
            repoLabel.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            repoLabel.trailingAnchor.constraint(lessThanOrEqualTo: toolbar.trailingAnchor, constant: -8),
            toolbar.heightAnchor.constraint(equalToConstant: 28),
        ])

        let toolbarUnderline = NSBox()
        toolbarUnderline.boxType = .separator
        toolbarUnderline.translatesAutoresizingMaskIntoConstraints = false

        // task table
        tableView.headerView = nil
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("task"))
        tableView.addTableColumn(col)
        tableView.rowSizeStyle = .small
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsMultipleSelection = false

        tableScroll.documentView = tableView
        tableScroll.hasVerticalScroller = true
        tableScroll.autohidesScrollers = true
        tableScroll.drawsBackground = false
        tableScroll.translatesAutoresizingMaskIntoConstraints = false

        // status bar
        statusBar.kind = .control
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.text = ""
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusSpinner.style = .spinning
        statusSpinner.controlSize = .small
        statusSpinner.translatesAutoresizingMaskIntoConstraints = false
        statusBar.addSubview(statusSpinner)
        statusBar.addSubview(statusLabel)
        // Compositing trap: opaque bottom strip must be layer-isolated
        // (docs/terminal-header-fix.md), same as wiki/terminal panels.
        statusBar.wantsLayer = true
        statusBar.layer?.masksToBounds = true
        NSLayoutConstraint.activate([
            statusSpinner.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 10),
            statusSpinner.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            statusSpinner.widthAnchor.constraint(equalToConstant: 12),
            statusSpinner.heightAnchor.constraint(equalToConstant: 12),
            statusLabel.leadingAnchor.constraint(equalTo: statusSpinner.trailingAnchor, constant: 8),
            statusLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: statusBar.trailingAnchor, constant: -8),
            statusBar.heightAnchor.constraint(equalToConstant: 26),
        ])
        statusBar.isHidden = true

        view.addSubview(header)
        view.addSubview(toolbar)
        view.addSubview(toolbarUnderline)
        view.addSubview(tableScroll)
        view.addSubview(statusBar)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            toolbar.topAnchor.constraint(equalTo: header.bottomAnchor),
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            toolbarUnderline.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            toolbarUnderline.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbarUnderline.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            tableScroll.topAnchor.constraint(equalTo: toolbarUnderline.bottomAnchor),
            tableScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableScroll.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            statusBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    // MARK: - Public API (AppDelegate)

    /// Server became reachable: (re)detect the workspace repo and load issues.
    func serverReady(port: Int) {
        resolveRepoAndReload()
    }

    /// Panel shown: refresh issues if we already know the repo.
    func ensureLoaded() {
        if repo != nil {
            reloadIssues()
        } else {
            resolveRepoAndReload()
        }
    }

    /// The active workspace changed: re-detect the GitHub repo and reload.
    func workspaceChanged() {
        resolveRepoAndReload()
    }

    /// Restore task state from the `.dsh/tasks/` index (after an app restart):
    /// committed index gives issue → branch/PR/state; local overlay gives the
    /// session id on this machine. Merges into the in-memory list; the open
    /// issues fetch then fills in titles for anything still missing.
    func restoreFromIndex(repoRoot: String) {
        let indexTasks = TaskIndex.loadIndex(repoRoot)
        for entry in indexTasks {
            guard let issue = entry["issue"] as? Int else { continue }
            var task = IssueRunnerTask(number: issue,
                                       title: (entry["title"] as? String) ?? "issue #\(issue)",
                                       labels: [])
            task.branch = entry["branch"] as? String
            task.prUrl = entry["prUrl"] as? String
            task.error = entry["error"] as? String
            switch entry["state"] as? String {
            case "done": task.state = .done
            case "failed": task.state = .failed
            case "cancelled": task.state = .cancelled
            case "running": task.state = .running
            default: task.state = .pending
            }
            // Local overlay: re-attach the session id recorded on this machine.
            task.sessionId = TaskIndex.sessionForIssue(repoRoot, issue: issue)
            // Do not clobber a task already in memory with the same issue.
            if !tasks.contains(where: { $0.number == issue }) {
                tasks.append(task)
            }
        }
        tasks.sort { $0.number < $1.number }
        tableView.reloadData()
    }

    // MARK: - Repo detection & issue loading

    /// Number of deferred retries while waiting for the dsh workspace list to
    /// be ready right after server startup.
    private var repoResolveRetries = 0

    private func resolveRepoAndReload() {
        repoResolveRetries = 0
        resolveRepoOnce()
    }

    private func resolveRepoOnce() {
        // Preferred: the shell's active project directory (follows the session
        // the user is viewing). Fallback: resolve from the dsh workspace list.
        if let path = workspacePath?(), !path.isEmpty {
            applyRepo(path: path)
            return
        }
        let port = serverPortProvider?() ?? 3080
        let workspaces = Self.listWorkspacePaths(port: port)
        // Pick the first workspace that is a GitHub repo.
        for ws in workspaces {
            if Self.detectGitHubRemote(ws) != nil {
                applyRepo(path: ws)
                return
            }
        }
        // Server may not have the workspace list ready yet — retry briefly.
        if repoResolveRetries < 10 {
            repoResolveRetries += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.resolveRepoOnce()
            }
        } else {
            repo = nil
            tasks = []
            tableView.reloadData()
            updateLabels()
        }
    }

    private func applyRepo(path: String) {
        guard let detected = Self.detectGitHubRemote(path) else {
            repo = nil
            tasks = []
            tableView.reloadData()
            updateLabels()
            return
        }
        repo = (detected.owner, detected.repo)
        repoRootPath = path
        AppLog.shared.log("tasks repo resolved: \(detected.owner)/\(detected.repo) at \(path)")
        updateLabels()
        // Restore any previously recorded task associations (issue → branch/PR/session).
        restoreFromIndex(repoRoot: path)
        reloadIssues()
    }

    /// Parse `git remote -v` output for a github.com remote (prefers the
    /// remote literally named "github", else any github.com remote).
    static func detectGitHubRemote(_ path: String) -> (owner: String, repo: String)? {
        guard let out = Self.runProcess("/usr/bin/git", ["-C", path, "remote", "-v"]) else { return nil }
        var remotes: [String: String] = [:]
        for line in out.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2 else { continue }
            let name = String(parts[0])
            let url = String(parts[1])
            if remotes[name] == nil { remotes[name] = url }
        }
        let url = remotes["github"] ?? remotes.values.first { $0.contains("github.com") }
        guard let url = url else { return nil }
        // github.com/:owner/:repo(.git)  or  git@github.com::owner/:repo(.git)
        guard let range = url.range(of: "github.com[/:]", options: .regularExpression) else { return nil }
        let tail = String(url[range.upperBound...])
        let parts = tail.split(separator: "/")
        guard parts.count >= 2 else { return nil }
        let owner = String(parts[0])
        let repoName = String(parts[1]).replacingOccurrences(of: ".git", with: "")
        guard !owner.isEmpty, !repoName.isEmpty else { return nil }
        return (owner, repoName)
    }

    private func reloadIssues() {
        guard let repo = repo else { return }
        setStatus(L10n.tr("tasks.loading"), spin: true)
        let token = loadToken()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let issues = Self.fetchIssues(owner: repo.owner, repo: repo.repo, token: token)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.hideStatus()
                guard let issues = issues else {
                    self.setStatus(L10n.tr("tasks.loadFailed"), spin: false)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.hideStatus() }
                    return
                }
                // Keep any task that already has progress; merge new issues.
                let existingNumbers = Set(self.tasks.map { $0.number })
                for issue in issues where !existingNumbers.contains(issue.number) {
                    self.tasks.append(IssueRunnerTask(number: issue.number,
                                                      title: issue.title,
                                                      labels: issue.labels))
                }
                self.tasks.sort { $0.number < $1.number }
                self.tableView.reloadData()
            }
        }
    }

    /// Fetch open issues via GitHub REST. Returns nil on network/auth error.
    static func fetchIssues(owner: String, repo: String, token: String?) -> [(number: Int, title: String, labels: [String])]? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(owner)/\(repo)/issues?state=open&per_page=50")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "accept")
        request.setValue("oh-my-dsh", forHTTPHeaderField: "user-agent")
        if let token = token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        }
        let semaphore = DispatchSemaphore(value: 0)
        var result: [(number: Int, title: String, labels: [String])]?
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }
            guard let data = data,
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
            var out: [(number: Int, title: String, labels: [String])] = []
            for item in json {
                // The issues API includes pull requests — filter them out.
                if item["pull_request"] != nil { continue }
                guard let number = item["number"] as? Int, let title = item["title"] as? String else { continue }
                let labels: [String] = (item["labels"] as? [[String: Any]])?
                    .compactMap { $0["name"] as? String } ?? []
                out.append((number, title, labels))
            }
            result = out
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 20)
        task.cancel()
        return result
    }

    // MARK: - Task execution (serial queue)

    private func runAllTapped() {
        // Start the first pending task; subsequent ones auto-start when the
        // running one finishes (serial queue).
        if runningNumber != nil { return }
        if let next = tasks.first(where: { $0.state == .pending }) {
            startTask(number: next.number)
        }
    }

    func startTask(number: Int) {
        guard runningNumber == nil else { return }   // strict serial
        guard let idx = tasks.firstIndex(where: { $0.number == number }),
              tasks[idx].state == .pending else { return }
        guard let repo = repo else { return }
        guard let path = repoRootPath ?? workspacePath?() else { return }

        tasks[idx].state = .running
        tasks[idx].startedAt = Date()
        tasks[idx].branch = "fix/issue-\(number)"
        runningNumber = number
        tableView.reloadData()
        setStatus(L10n.tr("tasks.running", number), spin: true)

        // Persist the association (issue → branch) in the committed index.
        TaskIndex.mergeTask(path, issue: number, update: [
            "branch": "fix/issue-\(number)",
            "state": "running",
            "startedAt": ISO8601DateFormatter().string(from: Date()),
        ])

        let branch = "fix/issue-\(number)"
        let token = loadToken()
        let port = serverPortProvider?() ?? 3080
        let workspaceId = Self.resolveMainWorkspaceId(port: port, path: path)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // 1. checkout main → pull → new branch
            guard Self.gitCheckoutBranch(path: path, branch: branch) else {
                DispatchQueue.main.async { self?.taskFailed(number: number, error: L10n.tr("tasks.errBranch")) }
                return
            }
            // 2. create a dsh session in the main workspace (cwd auto-correct)
            guard let sessionId = Self.createSession(port: port, workspaceId: workspaceId, cwd: path) else {
                DispatchQueue.main.async { self?.taskFailed(number: number, error: L10n.tr("tasks.errSession")) }
                return
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let idx = self.tasks.firstIndex(where: { $0.number == number }) {
                    self.tasks[idx].sessionId = sessionId
                    self.tableView.reloadData()
                }
            }
            // Record the session in the LOCAL (machine-scoped) overlay so a
            // restart can re-attach issue → session on this machine.
            TaskIndex.rememberSession(path, issue: number, sessionId: sessionId)
            // 3. rename session for traceability
            _ = Self.renameSession(port: port, sessionId: sessionId, title: "fix(#\(number)): \(L10n.tr("tasks.sessionLabel"))")
            // 4. prompt the agent with the issue-fix skill + issue content
            let issue = self?.tasks.first { $0.number == number }
            let prompt = Self.issueFixPrompt(number: number, title: issue?.title ?? "")
            guard Self.promptSession(port: port, sessionId: sessionId, text: prompt) else {
                DispatchQueue.main.async { self?.taskFailed(number: number, error: L10n.tr("tasks.errPrompt")) }
                return
            }
            // 5. poll until the session finishes
            self?.pollSession(number: number, sessionId: sessionId, port: port, path: path, token: token)
        }
    }

    private func pollSession(number: Int, sessionId: String, port: Int, path: String, token: String?) {
        pollTimer?.invalidate()
        let start = Date()
        let timer = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let running = Self.sessionRunning(port: port, sessionId: sessionId)
            if running {
                if Date().timeIntervalSince(start) > 30 * 60 {  // 30min timeout
                    self.taskFailed(number: number, error: L10n.tr("tasks.errTimeout"))
                    _ = Self.cancelSession(port: port, sessionId: sessionId)
                    return
                }
                return
            }
            self.pollTimer?.invalidate()
            self.pollTimer = nil
            // Session ended: verify the branch was pushed, then open the PR.
            if Self.gitBranchPushed(path: path, branch: "fix/issue-\(number)") {
                self.openPR(number: number, token: token)
            } else {
                self.taskFailed(number: number, error: L10n.tr("tasks.errNoPush"))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func openPR(number: Int, token: String?) {
        guard let repo = repo else { return }
        guard let idx = tasks.firstIndex(where: { $0.number == number }) else { return }
        let branch = "fix/issue-\(number)"
        setStatus(L10n.tr("tasks.creatingPr", number), spin: true)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let pr = Self.createPR(owner: repo.owner, repo: repo.repo,
                                   title: L10n.tr("tasks.prTitle", number),
                                   head: branch, base: "main", body: L10n.tr("tasks.prBody", number),
                                   token: token)
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let pr = pr {
                    self.taskDone(number: number, prUrl: pr)
                } else {
                    self.taskFailed(number: number, error: L10n.tr("tasks.errPR"))
                }
            }
        }
    }

    private func taskDone(number: Int, prUrl: String) {
        guard let idx = tasks.firstIndex(where: { $0.number == number }) else { return }
        tasks[idx].state = .done
        tasks[idx].prUrl = prUrl
        // Persist done + PR association.
        if let path = workspacePath?() {
            TaskIndex.mergeTask(path, issue: number, update: [
                "state": "done",
                "prUrl": prUrl,
                "finishedAt": ISO8601DateFormatter().string(from: Date()),
            ])
        }
        finishCurrentTask(number: number)
    }

    private func taskFailed(number: Int, error: String) {
        guard let idx = tasks.firstIndex(where: { $0.number == number }) else { return }
        tasks[idx].state = .failed
        tasks[idx].error = error
        if let path = workspacePath?() {
            TaskIndex.mergeTask(path, issue: number, update: [
                "state": "failed",
                "error": error,
                "finishedAt": ISO8601DateFormatter().string(from: Date()),
            ])
        }
        AppLog.shared.log("issue task \(number) failed: \(error)")
        finishCurrentTask(number: number)
    }

    private func finishCurrentTask(number: Int) {
        runningNumber = nil
        pollTimer?.invalidate()
        pollTimer = nil
        tableView.reloadData()
        hideStatus()
        // Serial queue: auto-start the next pending task.
        if let next = tasks.first(where: { $0.state == .pending }) {
            startTask(number: next.number)
        }
    }

    func cancelRunningTask() {
        guard let number = runningNumber,
              let idx = tasks.firstIndex(where: { $0.number == number }),
              let sessionId = tasks[idx].sessionId else { return }
        let port = serverPortProvider?() ?? 3080
        _ = Self.cancelSession(port: port, sessionId: sessionId)
        tasks[idx].state = .cancelled
        finishCurrentTask(number: number)
        AppLog.shared.log("issue task \(number) cancelled")
    }

    // MARK: - git helpers (native Process)

    static func runProcess(_ launch: String, _ args: [String], cwd: String? = nil) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launch)
        proc.arguments = args
        if let cwd = cwd { proc.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do { try proc.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func gitCheckoutBranch(path: String, branch: String) -> Bool {
        // Make sure main is checked out & up to date, then create the branch.
        _ = runProcess("/usr/bin/git", ["-C", path, "checkout", "main"], cwd: path)
        _ = runProcess("/usr/bin/git", ["-C", path, "pull", "--ff-only"], cwd: path)
        // Branch may already exist locally (resume) — checkout it, else create.
        let existing = runProcess("/usr/bin/git", ["-C", path, "rev-parse", "--verify", "--quiet", branch], cwd: path)
        if existing != nil {
            return runProcess("/usr/bin/git", ["-C", path, "checkout", branch], cwd: path) != nil
        }
        return runProcess("/usr/bin/git", ["-C", path, "checkout", "-b", branch], cwd: path) != nil
    }

    /// The remote name used to push branches / check for pushes. Prefers the
    /// remote literally named "github", else "origin", else the first remote
    /// (mirrors detectGitHubRemote's preference).
    static func pushRemoteName(path: String) -> String? {
        guard let out = runProcess("/usr/bin/git", ["-C", path, "remote"], cwd: path) else { return nil }
        let names = out.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map(String.init)
        if names.contains("github") { return "github" }
        if names.contains("origin") { return "origin" }
        return names.first
    }

    /// True when the branch exists on the push remote (ls-remote heads).
    static func gitBranchPushed(path: String, branch: String) -> Bool {
        guard let remote = pushRemoteName(path: path) else { return false }
        let out = runProcess("/usr/bin/git", ["-C", path, "ls-remote", "--heads", remote, branch], cwd: path)
        return out?.contains(branch) == true
    }

    // MARK: - dsh session helpers

    /// All registered dsh workspace paths (for repo detection fallback).
    static func listWorkspacePaths(port: Int) -> [String] {
        let body = #"{"type":"client-request","rpcId":"ir-wslist","method":"workspace.list","payload":{}}"#
        guard let data = Self.rpcPost(port: port, path: "/api/workspace.list", body: body),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              (result["ok"] as? Bool) == true,
              let value = result["value"] as? [String: Any],
              let items = value["items"] as? [[String: Any]] else { return [] }
        return items.compactMap { $0["path"] as? String }
    }

    static func resolveMainWorkspaceId(port: Int, path: String) -> String? {
        let std = (path as NSString).standardizingPath
        // workspace.list → find matching path (or prefix, symlink-resolved)
        let body = #"{"type":"client-request","rpcId":"ir-ws","method":"workspace.list","payload":{}}"#
        guard let data = Self.rpcPost(port: port, path: "/api/workspace.list", body: body),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              (result["ok"] as? Bool) == true,
              let value = result["value"] as? [String: Any],
              let items = value["items"] as? [[String: Any]] else { return nil }
        for ws in items {
            guard let wsPath = ws["path"] as? String else { continue }
            if (wsPath as NSString).standardizingPath == std { return ws["workspaceId"] as? String }
        }
        return nil
    }

    static func createSession(port: Int, workspaceId: String?, cwd: String?) -> String? {
        let payload: [String: Any]
        if let workspaceId = workspaceId, !workspaceId.isEmpty {
            payload = ["workspaceId": workspaceId]   // cwd auto = workspace path
        } else if let cwd = cwd {
            payload = ["cwd": cwd]
        } else {
            return nil
        }
        let body = Self.rpcBody(method: "session.create", payload: payload, rpcId: "ir-create")
        guard let data = Self.rpcPost(port: port, path: "/api/session.create", body: body),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              (result["ok"] as? Bool) == true,
              let value = result["value"] as? [String: Any],
              let sid = value["sessionId"] as? String else { return nil }
        return sid
    }

    static func renameSession(port: Int, sessionId: String, title: String) -> Bool {
        let body = Self.rpcBody(method: "session.rename", payload: ["sessionId": sessionId, "title": title], rpcId: "ir-rename")
        guard let data = Self.rpcPost(port: port, path: "/api/session.rename", body: body),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              (result["ok"] as? Bool) == true else { return false }
        return true
    }

    static func promptSession(port: Int, sessionId: String, text: String) -> Bool {
        let payload: [String: Any] = [
            "sessionId": sessionId,
            "mode": "queue",
            "content": [["type": "text", "text": text]],
        ]
        let body = Self.rpcBody(method: "session.prompt", payload: payload, rpcId: "ir-prompt")
        guard let data = Self.rpcPost(port: port, path: "/api/session.prompt", body: body),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              (result["ok"] as? Bool) == true else { return false }
        return true
    }

    static func sessionRunning(port: Int, sessionId: String) -> Bool {
        let body = Self.rpcBody(method: "session.list", payload: [:], rpcId: "ir-poll")
        guard let data = Self.rpcPost(port: port, path: "/api/session.list", body: body),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              (result["ok"] as? Bool) == true,
              let value = result["value"] as? [String: Any],
              let items = value["items"] as? [[String: Any]] else { return false }
        for item in items {
            guard (item["sessionId"] as? String) == sessionId else { continue }
            return (item["running"] as? Bool) ?? false
        }
        return false
    }

    static func cancelSession(port: Int, sessionId: String) -> Bool {
        let body = Self.rpcBody(method: "session.cancel", payload: ["sessionId": sessionId], rpcId: "ir-cancel")
        guard let data = Self.rpcPost(port: port, path: "/api/session.cancel", body: body),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              (result["ok"] as? Bool) == true else { return false }
        return true
    }

    private static func rpcBody(method: String, payload: [String: Any], rpcId: String) -> String {
        let dict: [String: Any] = [
            "type": "client-request",
            "rpcId": rpcId,
            "method": method,
            "payload": payload,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: dict)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func rpcPost(port: Int, path: String, body: String, timeout: TimeInterval = 10) -> Data? {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = body.data(using: .utf8)
        let semaphore = DispatchSemaphore(value: 0)
        var result: Data?
        let task = URLSession.shared.dataTask(with: request) { data, _, _ in
            result = data
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + timeout + 1)
        task.cancel()
        return result
    }

    // MARK: - PR creation (GitHub REST)

    static func createPR(owner: String, repo: String, title: String, head: String, base: String, body: String, token: String?) -> String? {
        let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/pulls")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "accept")
        request.setValue("oh-my-dsh", forHTTPHeaderField: "user-agent")
        if let token = token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        }
        let payload: [String: Any] = ["title": title, "head": head, "base": base, "body": body]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        let semaphore = DispatchSemaphore(value: 0)
        var prUrl: String?
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }
            guard let data = data,
                  let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            prUrl = json["html_url"] as? String
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 20)
        task.cancel()
        return prUrl
    }

    // MARK: - Keychain token (never in UserDefaults/plaintext)

    private func loadToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.tokenService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8), !token.isEmpty else { return nil }
        return token
    }

    private func saveToken(_ token: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.tokenService,
        ]
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = token.data(using: .utf8) ?? Data()
        SecItemAdd(attrs as CFDictionary, nil)
    }

    // MARK: - Config

    private func configTapped() {
        let alert = NSAlert()
        alert.messageText = L10n.tr("tasks.configTitle")
        alert.informativeText = L10n.tr("tasks.configInfo")
        alert.addButton(withTitle: L10n.tr("btn.ok"))
        alert.addButton(withTitle: L10n.tr("btn.cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = L10n.tr("tasks.tokenPlaceholder")
        field.stringValue = loadToken() ?? ""
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty {
                SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                               kSecAttrService as String: Self.tokenService] as CFDictionary)
            } else {
                saveToken(value)
            }
            reloadIssues()
        }
    }

    // MARK: - Status

    private func setStatus(_ text: String, spin: Bool) {
        statusLabel.text = text
        statusSpinner.isHidden = !spin
        if spin { statusSpinner.startAnimation(nil) } else { statusSpinner.stopAnimation(nil) }
        statusBar.isHidden = false
    }

    private func hideStatus() {
        statusBar.isHidden = true
        statusSpinner.stopAnimation(nil)
    }

    // MARK: - NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int { tasks.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < tasks.count else { return nil }
        let task = tasks[row]
        let id = NSUserInterfaceItemIdentifier("taskCell")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = id
            let text = NSTextField(labelWithString: "")
            text.translatesAutoresizingMaskIntoConstraints = false
            text.lineBreakMode = .byTruncatingTail
            cell.addSubview(text)
            cell.textField = text
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        let badge = task.state.badge
        var prefix = "#\(task.number) \(badge)"
        if task.state == .running, let sid = task.sessionId, !sid.isEmpty {
            prefix += " ⟳"
        }
        cell.textField?.stringValue = "\(prefix) \(task.title)"
        cell.textField?.textColor = task.state == .failed ? .systemRed : .labelColor
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 22 }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0, row < tasks.count else { return }
        let number = tasks[row].number
        tableView.deselectAll(nil)
        // Clicking a row opens the DETAIL dialog — processing only starts when
        // the user presses the explicit "Process" button inside it.
        showTaskDetail(number: number)
    }

    /// Detail dialog for one task. Clicking the row shows this; actions
    /// (Process / Retry / Open PR / Cancel) are explicit buttons, never an
    /// implicit side effect of selecting the row.
    private func showTaskDetail(number: Int) {
        guard let idx = tasks.firstIndex(where: { $0.number == number }) else { return }
        let task = tasks[idx]

        let alert = NSAlert()
        alert.messageText = L10n.tr("tasks.detailTitle", number)
        alert.informativeText = Self.taskDetailText(task)
        alert.alertStyle = .informational

        // Primary action depends on state; the last button is always Close.
        switch task.state {
        case .pending:
            let process = alert.addButton(withTitle: L10n.tr("tasks.detailProcess"))
            process.keyEquivalent = "\r"   // Enter = process
            alert.addButton(withTitle: L10n.tr("tasks.detailClose"))
            let resp = alert.runModal()
            if resp == .alertFirstButtonReturn {
                startTask(number: number)
            }
        case .running:
            let cancel = alert.addButton(withTitle: L10n.tr("tasks.detailCancelTask"))
            cancel.keyEquivalent = "\r"
            alert.addButton(withTitle: L10n.tr("tasks.detailClose"))
            let resp = alert.runModal()
            if resp == .alertFirstButtonReturn {
                cancelRunningTask()
            }
        case .done:
            if let url = task.prUrl {
                let open = alert.addButton(withTitle: L10n.tr("tasks.detailOpenPR"))
                open.keyEquivalent = "\r"
            }
            alert.addButton(withTitle: L10n.tr("tasks.detailClose"))
            let resp = alert.runModal()
            if resp == .alertFirstButtonReturn, let url = task.prUrl, let u = URL(string: url) {
                NSWorkspace.shared.open(u)
            }
        case .failed:
            let retry = alert.addButton(withTitle: L10n.tr("tasks.detailRetry"))
            retry.keyEquivalent = "\r"
            alert.addButton(withTitle: L10n.tr("tasks.detailClose"))
            let resp = alert.runModal()
            if resp == .alertFirstButtonReturn {
                // Reset failed → pending, then process again.
                if let i = tasks.firstIndex(where: { $0.number == number }) {
                    tasks[i].state = .pending
                    tasks[i].error = nil
                    if let path = repoRootPath {
                        TaskIndex.mergeTask(path, issue: number, update: ["state": "pending", "error": NSNull()])
                    }
                    tableView.reloadData()
                }
                startTask(number: number)
            }
        case .cancelled:
            let retry = alert.addButton(withTitle: L10n.tr("tasks.detailRetry"))
            retry.keyEquivalent = "\r"
            alert.addButton(withTitle: L10n.tr("tasks.detailClose"))
            let resp = alert.runModal()
            if resp == .alertFirstButtonReturn {
                if let i = tasks.firstIndex(where: { $0.number == number }) {
                    tasks[i].state = .pending
                    if let path = repoRootPath {
                        TaskIndex.mergeTask(path, issue: number, update: ["state": "pending"])
                    }
                    tableView.reloadData()
                }
                startTask(number: number)
            }
        }
    }

    /// Multi-line detail text for the alert's informative area.
    private static func taskDetailText(_ task: IssueRunnerTask) -> String {
        let stateName: String
        switch task.state {
        case .pending: stateName = L10n.tr("tasks.state.pending")
        case .running: stateName = L10n.tr("tasks.state.running")
        case .done: stateName = L10n.tr("tasks.state.done")
        case .failed: stateName = L10n.tr("tasks.state.failed")
        case .cancelled: stateName = L10n.tr("tasks.state.cancelled")
        }
        var lines = [L10n.tr("tasks.detailState", stateName)]
        if !task.labels.isEmpty {
            lines.append(L10n.tr("tasks.detailLabels", task.labels.joined(separator: ", ")))
        }
        if let b = task.branch { lines.append(L10n.tr("tasks.detailBranch", b)) }
        if let pr = task.prUrl { lines.append(L10n.tr("tasks.detailPR", pr)) }
        if let err = task.error { lines.append(err) }
        lines.append("")
        lines.append(task.title)
        return lines.joined(separator: "\n")
    }

    // MARK: - issue-fix prompt

    static func issueFixPrompt(number: Int, title: String) -> String {
        return """
        请加载 issue-fix skill 并完成以下 GitHub issue 的修复：

        ## Issue #\(number)
        标题：\(title)

        要求：
        1. 加载 `.dsh/skills/issue-fix/SKILL.md` 并严格按其流程执行（读 issue → 改代码 → 跑测试 → commit → push）；
        2. 当前分支应为 fix/issue-\(number)，只在此分支上工作；
        3. 完成后简短汇报改动与测试结果。
        """
    }
}

// MARK: - Task association index (.dsh/tasks/)

/// Persists the issue ↔ branch ↔ PR ↔ session association under
/// `<repoRoot>/.dsh/tasks/`:
///   - index.json: repo-scoped, committed (issue → branch → prUrl → state)
///   - local.json: machine-scoped, gitignored (adds sessionId for THIS machine)
/// Mirrors core/lib/tasks.js so the shell and any future platform agree.
enum TaskIndex {

    static let indexFile = "index.json"
    static let localFile = "local.json"

    private static func tasksDir(_ repoRoot: String) -> String {
        let dir = (repoRoot as NSString).appendingPathComponent(".dsh/tasks")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func readJSON(_ path: String) -> [String: Any] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return obj
    }

    private static func writeJSON(_ path: String, _ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }

    /// Load the committed index (fresh when missing).
    static func loadIndex(_ repoRoot: String) -> [[String: Any]] {
        let obj = readJSON(tasksDir(repoRoot) + "/" + indexFile)
        return obj["tasks"] as? [[String: Any]] ?? []
    }

    /// Merge an update for one issue into the committed index (upsert).
    static func mergeTask(_ repoRoot: String, issue: Int, update: [String: Any]) {
        var tasks = loadIndex(repoRoot)
        var merged: [String: Any] = ["issue": issue]
        if let idx = tasks.firstIndex(where: { ($0["issue"] as? Int) == issue }) {
            merged = tasks[idx]
            merged["issue"] = issue
            tasks.remove(at: idx)
        }
        for (k, v) in update { merged[k] = v }
        tasks.append(merged)
        tasks.sort { (($0["issue"] as? Int) ?? 0) < (($1["issue"] as? Int) ?? 0) }
        writeJSON(tasksDir(repoRoot) + "/" + indexFile, ["version": 1, "tasks": tasks])
    }

    /// Find a committed task entry for an issue.
    static func findTask(_ repoRoot: String, issue: Int) -> [String: Any]? {
        loadIndex(repoRoot).first { ($0["issue"] as? Int) == issue }
    }

    /// Record the dsh session id for an issue in the LOCAL (gitignored) overlay.
    static func rememberSession(_ repoRoot: String, issue: Int, sessionId: String) {
        let file = tasksDir(repoRoot) + "/" + localFile
        var local = readJSON(file)
        var sessions = local["sessions"] as? [String: Any] ?? [:]
        sessions[String(issue)] = ["sessionId": sessionId, "updatedAt": ISO8601DateFormatter().string(from: Date())]
        local["sessions"] = sessions
        writeJSON(file, local)
    }

    /// The session id recorded for an issue on THIS machine.
    static func sessionForIssue(_ repoRoot: String, issue: Int) -> String? {
        let local = readJSON(tasksDir(repoRoot) + "/" + localFile)
        let sessions = local["sessions"] as? [String: Any] ?? [:]
        guard let entry = sessions[String(issue)] as? [String: Any] else { return nil }
        return entry["sessionId"] as? String
    }
}
