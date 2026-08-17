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
    var body: String?            // issue description (markdown)
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
    /// The issue currently expanded inline (shows detail + action buttons).
    private var expandedIssue: Int?
    private var pollTimer: Timer?
    private var runningNumber: Int?

    // MARK: - Init & UI

    override init() {
        configButton = CustomIconButton(glyph: .symbol("gearshape"), tooltip: "")
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
        // The shell's active project directory (follows the session the user
        // is viewing) is authoritative: if it IS a GitHub repo, show its
        // issues; if it is NOT (e.g. an Ungrouped / non-git session's cwd),
        // show the honest "not a GitHub repo" empty state — do NOT substitute
        // some other registered workspace.
        if let path = workspacePath?(), !path.isEmpty {
            if Self.detectGitHubRemote(path) != nil {
                applyRepo(path: path)
            } else {
                repo = nil
                tasks = []
                tableView.reloadData()
                updateLabels()
            }
            return
        }
        // ProjectDirectory not resolved yet (early launch): fall back to
        // scanning registered workspaces for the first GitHub repo.
        let port = serverPortProvider?() ?? 3080
        let workspaces = Self.listWorkspacePaths(port: port)
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
        // Workspace switched to a DIFFERENT repo → drop the previous repo's
        // task list (issue numbers are per-repo).
        if repo?.owner != detected.owner || repo?.repo != detected.repo {
            tasks = []
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
        let token = loadToken(for: repo)
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
                // Merge issues into the task list:
                //  - new issues: append as pending tasks
                //  - existing tasks (e.g. restored from the index): refresh
                //    title/labels so the real issue title is always shown
                //    (restored tasks start with a placeholder title).
                for issue in issues {
                    if let idx = self.tasks.firstIndex(where: { $0.number == issue.number }) {
                        self.tasks[idx].title = issue.title
                        self.tasks[idx].labels = issue.labels
                        self.tasks[idx].body = issue.body
                    } else {
                        var newTask = IssueRunnerTask(number: issue.number,
                                                      title: issue.title,
                                                      labels: issue.labels)
                        newTask.body = issue.body
                        self.tasks.append(newTask)
                    }
                }
                self.tasks.sort { $0.number < $1.number }
                self.tableView.reloadData()
            }
        }
    }

    /// Fetch open issues via GitHub REST. Returns nil on network/auth error.
    static func fetchIssues(owner: String, repo: String, token: String?) -> [(number: Int, title: String, body: String?, labels: [String])]? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(owner)/\(repo)/issues?state=open&per_page=50")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "accept")
        request.setValue("oh-my-dsh", forHTTPHeaderField: "user-agent")
        if let token = token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        }
        let semaphore = DispatchSemaphore(value: 0)
        var result: [(number: Int, title: String, body: String?, labels: [String])]?
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }
            guard let data = data,
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
            var out: [(number: Int, title: String, body: String?, labels: [String])] = []
            for item in json {
                // The issues API includes pull requests — filter them out.
                if item["pull_request"] != nil { continue }
                guard let number = item["number"] as? Int, let title = item["title"] as? String else { continue }
                let labels: [String] = (item["labels"] as? [[String: Any]])?
                    .compactMap { $0["name"] as? String } ?? []
                let body = item["body"] as? String
                out.append((number, title, body, labels))
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

    /// Branch name for an issue, following the unified branch convention
    /// (docs/git-workflow.md): feature-class issues → `feature/issue-N`,
    /// everything else (bug / unclassified) → `fix/issue-N`.
    /// Classification is by label: any label containing "feature",
    /// "enhancement" or "kind/feature" counts as a feature.
    private func branchForIssue(number: Int) -> String {
        guard let idx = tasks.firstIndex(where: { $0.number == number }) else {
            return "fix/issue-\(number)"
        }
        let labels = tasks[idx].labels.map { $0.lowercased() }
        let isFeature = labels.contains { $0.contains("feature") || $0.contains("enhancement") }
        return isFeature ? "feature/issue-\(number)" : "fix/issue-\(number)"
    }

    func startTask(number: Int) {
        guard runningNumber == nil else { return }   // strict serial
        guard let idx = tasks.firstIndex(where: { $0.number == number }),
              tasks[idx].state == .pending else { return }
        guard let repo = repo else { return }
        guard let path = repoRootPath ?? workspacePath?() else { return }

        let branch = branchForIssue(number: number)   // feature/issue-N or fix/issue-N
        tasks[idx].state = .running
        tasks[idx].startedAt = Date()
        tasks[idx].branch = branch
        runningNumber = number
        tableView.reloadData()
        setStatus(L10n.tr("tasks.running", number), spin: true)

        // Persist the association (issue → branch) in the committed index.
        TaskIndex.mergeTask(path, issue: number, update: [
            "branch": branch,
            "state": "running",
            "title": tasks[idx].title,
            "startedAt": ISO8601DateFormatter().string(from: Date()),
        ])

        let token = loadToken(for: repo)
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
            let prompt = Self.issueFixPrompt(number: number, title: issue?.title ?? "", branch: branch)
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
            let branch = self.branchForIssue(number: number)
            if Self.gitBranchPushed(path: path, branch: branch) {
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
        let branch = tasks[idx].branch ?? branchForIssue(number: number)
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

    // MARK: - GitHub token (per-repo scoped, Keychain primary + file fallback)

    /// Generic Keychain service (repo-agnostic fallback).
    private static let genericTokenService = "oh-my-dsh.issuerunner.github-token"
    /// Shared generic token file: the single place a user can drop a token for
    /// BOTH the app shell and external tools/agents (`~/.dsh/gh-token`).
    private static let genericTokenFilePath = NSHomeDirectory() + "/.dsh/gh-token"
    /// Per-repo token dir for file-based tokens: `~/.dsh/tokens/<owner>-<repo>`.
    private static let tokenDir = NSHomeDirectory() + "/.dsh/tokens"

    /// Keychain service for a specific repo (owner/repo scoped).
    private static func tokenService(for repo: (owner: String, repo: String)) -> String {
        "oh-my-dsh.issuerunner.github-token.\(repo.owner)/\(repo.repo)"
    }

    /// Per-repo token file path: ~/.dsh/tokens/<owner>-<repo>.
    private static func tokenFilePath(for repo: (owner: String, repo: String)) -> String {
        tokenDir + "/" + repo.owner + "-" + repo.repo
    }

    private func readKeychain(service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8), !token.isEmpty else { return nil }
        return token
    }

    private func readTokenFile(_ path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let token = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else { return nil }
        return token
    }

    /// Resolve the token for the CURRENT repo, with per-repo scoping so that
    /// multiple workspaces/projects each use their own token.
    /// File paths are read FIRST (no Keychain password prompt), Keychain is a
    /// fallback for entries created by older builds or the command line:
    ///   1. File      ~/.dsh/tokens/<owner>-<repo>
    ///   2. File      ~/.dsh/gh-token (generic, shared with agents)
    ///   3. Keychain  <owner>/<repo>
    ///   4. Keychain  generic (legacy single-token)
    private func loadToken(for repo: (owner: String, repo: String)? = nil) -> String? {
        if let repo = repo {
            if let t = readTokenFile(Self.tokenFilePath(for: repo)) { return t }
        }
        if let t = readTokenFile(Self.genericTokenFilePath) { return t }
        if let repo = repo {
            if let t = readKeychain(service: Self.tokenService(for: repo)) { return t }
        }
        return readKeychain(service: Self.genericTokenService)
    }

    /// Save a token scoped to the current repo. Writes BOTH the Keychain entry
    /// (primary, secure) AND the per-repo file (~/.dsh/tokens/<owner>-<repo>)
    /// so external tools/agents using the file see the same token. Clearing
    /// (empty token) removes both.
    private func saveToken(_ token: String, for repo: (owner: String, repo: String)? = nil) {
        let service = repo.map(Self.tokenService(for:)) ?? Self.genericTokenService
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)
        if token.isEmpty {
            // Clear the matching file too (per-repo or generic).
            let file = repo.map(Self.tokenFilePath(for:)) ?? Self.genericTokenFilePath
            try? FileManager.default.removeItem(atPath: file)
            return
        }
        var attrs = query
        attrs[kSecValueData as String] = token.data(using: .utf8) ?? Data()
        // Accessible after first unlock + no per-app ACL prompt: a token is a
        // low-sensitivity credential; prompting on every read is unacceptable
        // for a background shell. (File fallback is chmod 600.)
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attrs as CFDictionary, nil)
        // Mirror to the file so agents / external tools share the same token.
        if let repo = repo {
            let dir = Self.tokenDir
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let file = Self.tokenFilePath(for: repo)
            try? token.data(using: .utf8)?.write(to: URL(fileURLWithPath: file), options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file)
        }
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
        field.stringValue = loadToken(for: repo) ?? ""
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            // Empty → clear both Keychain and file; otherwise save both.
            saveToken(value, for: repo)
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
        let expanded = (task.number == expandedIssue)
        let id = NSUserInterfaceItemIdentifier(expanded ? "taskCellExpanded" : "taskCell")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = id
            buildCellContent(cell, expanded: expanded)
        }
        populateCell(cell, task: task, expanded: expanded)
        return cell
    }

    /// Build the cell's subviews once (collapsed: single line; expanded: title
    /// line + detail block + action buttons). Buttons get tags so the action
    /// closure can read which issue they belong to.
    private func buildCellContent(_ cell: NSTableCellView, expanded: Bool) {
        let title = NSTextField(labelWithString: "")
        title.translatesAutoresizingMaskIntoConstraints = false
        title.lineBreakMode = .byTruncatingTail
        title.tag = 100
        cell.addSubview(title)
        if cell.textField == nil { cell.textField = title }

        if expanded {
            // Detail area is a scrollable NSTextView inside an NSScrollView so
            // long issue bodies scroll instead of pushing the buttons away.
            let detail = NSTextView()
            detail.isEditable = false
            detail.isSelectable = true
            detail.drawsBackground = false
            detail.font = .systemFont(ofSize: 11)
            detail.textColor = .secondaryLabelColor
            detail.textContainerInset = NSSize(width: 0, height: 2)
            detail.isVerticallyResizable = true
            detail.isHorizontallyResizable = false
            detail.autoresizingMask = [.width]
            detail.textContainer?.widthTracksTextView = true
            detail.identifier = NSUserInterfaceItemIdentifier("taskDetail")

            let scroll = NSScrollView()
            scroll.translatesAutoresizingMaskIntoConstraints = false
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.drawsBackground = false
            scroll.borderType = .noBorder
            scroll.documentView = detail
            cell.addSubview(scroll)

            let process = NSButton(title: "", target: self, action: #selector(cellButtonTapped(_:)))
            process.tag = 200
            process.controlSize = .small
            process.bezelStyle = .rounded
            process.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(process)

            let secondary = NSButton(title: "", target: self, action: #selector(cellButtonTapped(_:)))
            secondary.tag = 201
            secondary.controlSize = .small
            secondary.bezelStyle = .rounded
            secondary.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(secondary)

            let commentClose = NSButton(title: "", target: self, action: #selector(cellButtonTapped(_:)))
            commentClose.tag = 202
            commentClose.controlSize = .small
            commentClose.bezelStyle = .rounded
            commentClose.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(commentClose)

            NSLayoutConstraint.activate([
                title.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                title.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                title.topAnchor.constraint(equalTo: cell.topAnchor, constant: 4),
                title.heightAnchor.constraint(equalToConstant: 16),

                // Scroll view: fills the middle (title → buttons).
                scroll.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                scroll.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
                scroll.bottomAnchor.constraint(equalTo: process.topAnchor, constant: -6),

                // Buttons pinned to the BOTTOM (never pushed out by content).
                process.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                process.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -6),
                process.heightAnchor.constraint(equalToConstant: 22),

                secondary.leadingAnchor.constraint(equalTo: process.trailingAnchor, constant: 8),
                secondary.centerYAnchor.constraint(equalTo: process.centerYAnchor),
                secondary.heightAnchor.constraint(equalToConstant: 22),

                commentClose.leadingAnchor.constraint(equalTo: secondary.trailingAnchor, constant: 8),
                commentClose.centerYAnchor.constraint(equalTo: process.centerYAnchor),
                commentClose.heightAnchor.constraint(equalToConstant: 22),
            ])
        } else {
            NSLayoutConstraint.activate([
                title.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                title.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                title.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
    }

    private func populateCell(_ cell: NSTableCellView, task: IssueRunnerTask, expanded: Bool) {
        cell.objectValue = task.number   // buttons read this to know the issue
        let badge = task.state.badge
        var prefix = "#\(task.number) \(badge)"
        if task.state == .running, task.sessionId != nil { prefix += " ⟳" }
        if let title = cell.viewWithTag(100) as? NSTextField {
            title.stringValue = "\(prefix) \(task.title)"
            title.textColor = task.state == .failed ? .systemRed : .labelColor
        }
        if expanded {
            // The detail NSTextView lives inside the cell's NSScrollView.
            if let scroll = cell.subviews.lazy.compactMap({ $0 as? NSScrollView }).first,
               let detail = scroll.documentView as? NSTextView {
                detail.string = Self.taskDetailText(task)
            }
            if let primary = cell.viewWithTag(200) as? NSButton {
                primary.title = primaryActionTitle(for: task)
                primary.isEnabled = primaryActionEnabled(for: task)
            }
            if let secondary = cell.viewWithTag(201) as? NSButton {
                secondary.title = secondaryActionTitle(for: task)
                secondary.isEnabled = secondaryActionEnabled(for: task)
            }
            if let commentClose = cell.viewWithTag(202) as? NSButton {
                // Only show "comment & close" for finished tasks with a PR.
                let visible = (task.state == .done && task.prUrl != nil)
                commentClose.isHidden = !visible
                if visible {
                    commentClose.title = L10n.tr("tasks.detailCommentClose")
                    commentClose.isEnabled = true
                }
            }
        }
    }

    private func primaryActionTitle(for task: IssueRunnerTask) -> String {
        switch task.state {
        case .pending: return L10n.tr("tasks.detailProcess")
        case .running: return L10n.tr("tasks.detailCancelTask")
        case .done: return L10n.tr("tasks.detailOpenPR")
        case .failed, .cancelled: return L10n.tr("tasks.detailRetry")
        }
    }

    private func primaryActionEnabled(for task: IssueRunnerTask) -> Bool {
        switch task.state {
        case .pending: return runningNumber == nil   // serial: disabled while another runs
        case .running: return true
        case .done: return task.prUrl != nil
        case .failed, .cancelled: return runningNumber == nil
        }
    }

    private func secondaryActionTitle(for task: IssueRunnerTask) -> String {
        L10n.tr("tasks.detailClose")
    }

    private func secondaryActionEnabled(for task: IssueRunnerTask) -> Bool { true }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < tasks.count else { return 22 }
        return tasks[row].number == expandedIssue ? 168 : 22
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0, row < tasks.count else { return }
        let number = tasks[row].number
        tableView.deselectAll(nil)
        // Clicking a row toggles the inline detail (expand / collapse).
        if expandedIssue == number {
            expandedIssue = nil
        } else {
            expandedIssue = number
        }
        tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<tasks.count))
        tableView.reloadData()
    }

    /// Row button handler. The primary (tag 200), secondary (tag 201) and
    /// comment/close (tag 202) buttons live inside an expanded cell; the
    /// cell's objectValue carries the issue number. Actions are explicit —
    /// never implicit row clicks.
    @objc private func cellButtonTapped(_ sender: NSButton) {
        guard let cell = sender.superview as? NSTableCellView,
              let number = cell.objectValue as? Int,
              let idx = tasks.firstIndex(where: { $0.number == number }) else { return }
        let task = tasks[idx]
        if sender.tag == 201 {   // secondary = close / collapse
            expandedIssue = nil
            tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<tasks.count))
            tableView.reloadData()
            return
        }
        if sender.tag == 202 {   // comment & close (user-initiated)
            commentAndCloseTapped(number: number)
            return
        }
        // Primary action depends on state.
        switch task.state {
        case .pending:
            if runningNumber == nil { startTask(number: number) }
        case .running:
            cancelRunningTask()
        case .done:
            if let url = task.prUrl, let u = URL(string: url) { NSWorkspace.shared.open(u) }
        case .failed:
            if let i = tasks.firstIndex(where: { $0.number == number }) {
                tasks[i].state = .pending
                tasks[i].error = nil
                if let path = repoRootPath {
                    TaskIndex.mergeTask(path, issue: number, update: ["state": "pending", "error": NSNull()])
                }
                tableView.reloadData()
            }
            startTask(number: number)
        case .cancelled:
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

    /// User pressed "Comment & Close Issue": show a confirmation dialog with an
    /// editable comment (pre-filled with the PR reference), then act on GitHub.
    /// Explicitly user-initiated — never automatic.
    private func commentAndCloseTapped(number: Int) {
        guard let idx = tasks.firstIndex(where: { $0.number == number }),
              let repo = repo,
              tasks[idx].state == .done else { return }
        let prRef = tasks[idx].prUrl ?? ""

        let alert = NSAlert()
        alert.messageText = L10n.tr("tasks.commentCloseTitle", number)
        alert.informativeText = L10n.tr("tasks.commentCloseInfo")
        alert.addButton(withTitle: L10n.tr("btn.ok"))
        alert.addButton(withTitle: L10n.tr("btn.cancel"))
        let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 120))
        field.isEditable = true
        field.isSelectable = true
        field.string = L10n.tr("tasks.commentTemplate", prRef)
        let scroll = NSScrollView(frame: field.bounds)
        scroll.documentView = field
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.frame = NSRect(x: 0, y: 0, width: 420, height: 120)
        alert.accessoryView = scroll
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let comment = field.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !comment.isEmpty else { return }

        guard let token = loadToken(for: repo) else {
            setStatus(L10n.tr("tasks.commentCloseFailed"), spin: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.hideStatus() }
            return
        }
        setStatus(L10n.tr("tasks.commentCloseTitle", number), spin: true)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ok = Self.commentAndCloseIssue(owner: repo.owner, repoName: repo.repo,
                                               number: number, comment: comment, token: token)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.hideStatus()
                if ok {
                    AppLog.shared.log("issue \(number) commented & closed")
                    // Refresh issues so the closed one disappears from the list.
                    self.reloadIssues()
                } else {
                    self.setStatus(L10n.tr("tasks.commentCloseFailed"), spin: false)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.hideStatus() }
                }
            }
        }
    }

    /// POST a comment on the issue, then PATCH state=closed. Returns success.
    static func commentAndCloseIssue(owner: String, repoName: String, number: Int,
                                     comment: String, token: String?) -> Bool {
        // 1) POST /repos/{o}/{r}/issues/{n}/comments
        let commentURL = URL(string: "https://api.github.com/repos/\(owner)/\(repoName)/issues/\(number)/comments")!
        var req = URLRequest(url: commentURL)
        req.httpMethod = "POST"
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "accept")
        req.setValue("oh-my-dsh", forHTTPHeaderField: "user-agent")
        if let token = token, !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        }
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["body": comment])
        let sem = DispatchSemaphore(value: 0)
        var commentOK = false
        let t1 = URLSession.shared.dataTask(with: req) { _, resp, _ in
            defer { sem.signal() }
            if let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) { commentOK = true }
        }
        t1.resume()
        _ = sem.wait(timeout: .now() + 20)
        t1.cancel()
        guard commentOK else { return false }

        // 2) PATCH /repos/{o}/{r}/issues/{n}  { state: "closed" }
        let closeURL = URL(string: "https://api.github.com/repos/\(owner)/\(repoName)/issues/\(number)")!
        var req2 = URLRequest(url: closeURL)
        req2.httpMethod = "PATCH"
        req2.setValue("application/vnd.github+json", forHTTPHeaderField: "accept")
        req2.setValue("oh-my-dsh", forHTTPHeaderField: "user-agent")
        if let token = token, !token.isEmpty {
            req2.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        }
        req2.setValue("application/json", forHTTPHeaderField: "content-type")
        req2.httpBody = try? JSONSerialization.data(withJSONObject: ["state": "closed"])
        let sem2 = DispatchSemaphore(value: 0)
        var closeOK = false
        let t2 = URLSession.shared.dataTask(with: req2) { _, resp, _ in
            defer { sem2.signal() }
            if let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) { closeOK = true }
        }
        t2.resume()
        _ = sem2.wait(timeout: .now() + 20)
        t2.cancel()
        return closeOK
    }

    /// Multi-line detail text shown in the expanded row's scrollable area:
    /// metadata first, then the issue's description (body). The scroll view
    /// handles long bodies, so no truncation is needed here.
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
        if let body = task.body, !body.isEmpty {
            let clean = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty {
                lines.append("")
                lines.append(clean)
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - issue-fix prompt

    static func issueFixPrompt(number: Int, title: String, branch: String) -> String {
        return """
        请加载 issue-fix skill 并完成以下 GitHub issue 的修复：

        ## Issue #\(number)
        标题：\(title)

        要求：
        1. 加载 `.dsh/skills/issue-fix/SKILL.md` 并严格按其流程执行（读 issue → 改代码 → 跑测试 → commit → push）；
        2. 当前分支应为 \(branch)，只在此分支上工作；
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
