import AppKit

// MARK: - IssueRunner panel (issue-driven tasks)

/// Root view. Mirrors WikiRootView's compositing fix
/// (docs/terminal-header-fix.md): isOpaque=false so header/toolbar/content
/// composite correctly in the layer-backed window.
final class IssueRunnerRootView: NSView {
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        PanelSurface.color(for: effectiveAppearance).setFill()
        dirtyRect.fill()
    }
}

/// Rows are the board's own model now (TasksCore.swift): the panel renders the
/// github half of it and hands every state change to TasksRunner. The card list
/// (step 6) renders manual tasks and queues from the same board.
typealias IssueRunnerTask = TaskItem

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
    /// Github-task VIEW of the runner's board (issue numbers are per repo, so a
    /// workspace switch drops the whole board). Manual tasks and queues are on
    /// the board too but not rendered until the card list lands (step 6).
    private var tasks: [TaskItem] = []
    /// The execution engine. Every state change goes through it; the panel only
    /// renders and calls in.
    private var runner: TasksRunner?
    private var repo: (owner: String, repo: String)?
    private var repoRootPath: String?
    /// The task currently expanded inline (shows detail + action buttons).
    private var expandedTaskID: String?
    /// Drives the runner: start the next queued task, advance the running one.
    private var stepTimer: Timer?

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
        stepTimer?.invalidate()
    }

    private func updateLabels() {
        headerTitle.text = L10n.tr("tasks.title")
        configButton.toolTip = L10n.tr("tasks.configHint")
        refreshButton.toolTip = L10n.tr("tasks.refreshHint")
        runAllButton.toolTip = L10n.tr("tasks.runAllHint")
        hideButton.toolTip = L10n.tr("preview.closePanel")
        repoLabel.text = repo.map { "\($0.owner)/\($0.repo)" } ?? L10n.tr("tasks.noRepo")
    }

    /// 语言切换后刷新头部按钮 tooltip（复用 updateLabels）。
    func refreshTooltips() {
        updateLabels()
    }

    private func buildUI() {
        headerTitle.translatesAutoresizingMaskIntoConstraints = false
        headerTitle.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let actions = NSStackView(views: [refreshButton, runAllButton, configButton, hideButton])
        actions.orientation = .horizontal
        actions.spacing = 6
        actions.translatesAutoresizingMaskIntoConstraints = false

        let header = DynamicFillView()
        header.kind = .panel
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
        toolbar.kind = .panel
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
        // 内容区 = 面板底色。NSTableView 默认画自己的 controlBackgroundColor
        // （浅色白 / 深色近黑），会盖住面板根视图的 PanelSurface。
        tableView.backgroundColor = PanelSurface.dynamic

        tableScroll.documentView = tableView
        tableScroll.hasVerticalScroller = true
        tableScroll.autohidesScrollers = true
        tableScroll.drawsBackground = false
        tableScroll.translatesAutoresizingMaskIntoConstraints = false

        // status bar
        statusBar.kind = .panel
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

    // MARK: - Board / runner wiring

    /// Load the board for this repo, hand it to the runner and bring it in line
    /// with reality after a restart: a task recorded as running cannot still be
    /// running (its session died with the app) and an active queue is paused, so
    /// NOTHING starts until the user says so.
    private func setupRunner(repoRoot: String) {
        var board = TasksStore.load(repoRoot)
        let recovered = board.reconcileAfterRestart(interruptedError: TaskFailure.interrupted.rawValue)
        TasksStore.saveLocalHalf(repoRoot, board)
        runner = TasksRunner(board: board, env: makeEnv(repoRoot: repoRoot))
        expandedTaskID = nil
        syncFromBoard()
        startStepTimer()
        let extra = recovered.interrupted.isEmpty ? "" : ", interrupted: " + recovered.interrupted.joined(separator: ",")
        AppLog.shared.log("tasks: board loaded at \(repoRoot) — \(board.tasks.count) tasks, \(board.queues.count) queues" + extra)
    }

    /// Everything the runner needs from the outside world: git in this repo, the
    /// dsh session RPC on this port, GitHub REST with this repo's token, and the
    /// four-file persistence under .dsh/tasks/.
    private func makeEnv(repoRoot: String) -> TaskRunnerEnv {
        let port = serverPortProvider?() ?? 3080
        let workspaceId = Self.resolveMainWorkspaceId(port: port, path: repoRoot)
        let repo = self.repo
        let token = repo.flatMap { loadToken(for: $0) }
        return TaskRunnerEnv(
            git: TaskGit(run: { args in
                              Self.runProcess("/usr/bin/git", ["-C", repoRoot] + args, cwd: repoRoot)
                          },
                          remoteName: { Self.pushRemoteName(path: repoRoot) }),
            repoRoot: repoRoot,
            createSession: { cwd in Self.createSession(port: port, workspaceId: workspaceId, cwd: cwd) },
            renameSession: { id, title in Self.renameSession(port: port, sessionId: id, title: title) },
            promptSession: { id, text in Self.promptSession(port: port, sessionId: id, text: text) },
            sessionRunning: { id in Self.sessionRunning(port: port, sessionId: id) },
            cancelSession: { id in Self.cancelSession(port: port, sessionId: id) },
            findExistingPR: { branch in
                guard let repo = repo else { return nil }
                return Self.findExistingPR(owner: repo.owner, repo: repo.repo, branch: branch, token: token)
            },
            createPR: { branch, base, title, body in
                guard let repo = repo else { return nil }
                return Self.createPR(owner: repo.owner, repo: repo.repo, title: title,
                                     head: branch, base: base, body: body, token: token)
            },
            prText: { task, _ in
                let number = task.number ?? 0
                return (title: L10n.tr("tasks.prTitle", number), body: L10n.tr("tasks.prBody", number))
            },
            promptText: { task, queue in
                if task.source == .github {
                    return TaskPrompts.issue(number: task.number ?? 0, title: task.title,
                                             branch: queue?.branch ?? task.branch ?? "")
                }
                return TaskPrompts.manual(title: task.title, body: task.body,
                                          branch: queue?.branch, queueName: queue?.name)
            },
            persist: { board in TasksStore.saveLocalHalf(repoRoot, board) },
            persistIssueTask: { task in TasksStore.saveIssueTask(repoRoot, task) },
            log: { message in AppLog.shared.log(message) },
            perform: { blocking, completion in
                DispatchQueue.global(qos: .userInitiated).async {
                    blocking()
                    DispatchQueue.main.async { completion() }
                }
            }
        )
    }

    /// No GitHub repo here: drop the board and stop stepping.
    private func clearBoard() {
        runner = nil
        tasks = []
        stepTimer?.invalidate()
        stepTimer = nil
        expandedTaskID = nil
        tableView.reloadData()
        updateLabels()
    }

    /// Copy the board's github tasks into the table's view list.
    private func syncFromBoard() {
        tasks = (runner?.board.tasks ?? [])
            .filter { $0.source == .github }
            .sorted { ($0.number ?? 0) < ($1.number ?? 0) }
        boardSignature = boardSignatureNow()
        tableView.reloadData()
    }

    /// Cheap fingerprint of everything the table renders, so the 3-second step
    /// timer does not rebuild the list (and fight the user's scrolling) while
    /// nothing is moving.
    private var boardSignature = ""

    private func boardSignatureNow() -> String {
        guard let runner = runner else { return "" }
        let tasks = runner.board.tasks.map { $0.id + ":" + $0.state.rawValue + ":" + ($0.prUrl ?? "") }
        let queues = runner.board.queues.map { $0.id + ":" + $0.state.rawValue + ":" + String($0.taskIds.count) }
        return (tasks + queues).joined(separator: "|")
    }

    /// Resync only when the board actually changed.
    private func syncFromBoardIfChanged() {
        guard boardSignatureNow() != boardSignature else { return }
        syncFromBoard()
    }

    private func startStepTimer() {
        stepTimer?.invalidate()
        let timer = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in self?.stepRunner() }
        RunLoop.main.add(timer, forMode: .common)
        stepTimer = timer
    }

    /// One runner step: advance the running task, start the next queued one.
    private func stepRunner() {
        guard let runner = runner else { return }
        let wasBusy = runner.isBusy
        _ = runner.step()
        syncFromBoardIfChanged()
        if runner.isBusy {
            let number = runner.runningTaskID.flatMap { runner.board.task($0)?.number } ?? 0
            setStatus(L10n.tr("tasks.running", number), spin: true)
        } else if wasBusy {
            hideStatus()
        }
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
                clearBoard()
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
            clearBoard()
        }
    }

    private func applyRepo(path: String) {
        guard let detected = Self.detectGitHubRemote(path) else {
            repo = nil
            clearBoard()
            return
        }
        // A DIFFERENT repo means a different board: issue numbers are per-repo,
        // so the previous tasks/queues must not leak into this one.
        let changedRepo = repo?.owner != detected.owner || repo?.repo != detected.repo
        repo = (detected.owner, detected.repo)
        repoRootPath = path
        AppLog.shared.log("tasks repo resolved: \(detected.owner)/\(detected.repo) at \(path)")
        updateLabels()
        if changedRepo || runner == nil {
            setupRunner(repoRoot: path)
        }
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

    /// Fetch the repo's open issues and merge them into the runner's board:
    ///   - a new issue becomes a pending github task (nothing is written to the
    ///     committed index until the task actually runs, exactly like v1);
    ///   - a known task gets its title/labels/body refreshed AND persisted, so
    ///     the content survives a restart even after the issue closes;
    ///   - a task whose issue is no longer open is marked closed, keeping its
    ///     record and adapting its buttons. In-flight tasks are never touched.
    /// Afterwards, closed issues with no stored body are back-filled from the
    /// single-issue endpoint (which also works for closed issues).
    private func reloadIssues() {
        guard let repo = repo, let runner = runner else { return }
        setStatus(L10n.tr("tasks.loading"), spin: true)
        let token = loadToken(for: repo)
        let root = repoRootPath ?? ""
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let issues = Self.fetchIssues(owner: repo.owner, repo: repo.repo, token: token)
            DispatchQueue.main.async {
                guard let self = self, let runner = self.runner else { return }
                self.hideStatus()
                guard let issues = issues else {
                    self.setStatus(L10n.tr("tasks.loadFailed"), spin: false)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.hideStatus() }
                    return
                }
                var indexUpdates: [(Int, [String: Any])] = []
                runner.updateBoard { board in
                    for issue in issues {
                        let id = TaskItem.githubID(issue.number)
                        if let idx = board.index(ofTask: id) {
                            // The issue was reopened: the task is actionable again.
                            if board.tasks[idx].state == .closed {
                                board.tasks[idx].state = .pending
                                indexUpdates.append((issue.number, ["state": "pending"]))
                            }
                            if board.tasks[idx].title != issue.title
                                || board.tasks[idx].labels != issue.labels
                                || board.tasks[idx].body != issue.body {
                                indexUpdates.append((issue.number, [
                                    "title": issue.title,
                                    "labels": issue.labels,
                                    "body": issue.body ?? NSNull(),
                                ]))
                            }
                            board.tasks[idx].title = issue.title
                            board.tasks[idx].labels = issue.labels
                            board.tasks[idx].body = issue.body
                        } else {
                            var task = TaskItem.github(number: issue.number, title: issue.title,
                                                       body: issue.body, labels: issue.labels)
                            task.state = .pending
                            board.tasks.append(task)
                        }
                    }
                    let openNumbers = Set(issues.map { $0.number })
                    for i in board.tasks.indices where board.tasks[i].source == .github {
                        let number = board.tasks[i].number ?? 0
                        guard !openNumbers.contains(number) else { continue }
                        guard board.tasks[i].state != .running, board.tasks[i].state != .queued else { continue }
                        if board.tasks[i].state != .closed {
                            board.tasks[i].state = .closed
                            indexUpdates.append((number, [
                                "state": "closed",
                                "closedAt": ISO8601DateFormatter().string(from: Date()),
                            ]))
                        }
                    }
                }
                for (issue, update) in indexUpdates {
                    TasksStore.mergeIssueTask(root, issue: issue, update: update)
                }
                self.syncFromBoard()
                self.backfillClosedIssues(openNumbers: Set(issues.map { $0.number }),
                                          repo: repo, token: token, root: root)
            }
        }
    }

    /// Closed issues never come back in the open-issues fetch, so a task with no
    /// stored body (restored from the index after a restart) would show nothing.
    /// Recover title/body/labels from the single-issue endpoint and persist them
    /// — a one-time cost per task (the index then carries a body key, even a
    /// null one, so the lookup is never repeated).
    private func backfillClosedIssues(openNumbers: Set<Int>,
                                      repo: (owner: String, repo: String),
                                      token: String?,
                                      root: String) {
        guard let runner = runner else { return }
        let missing = runner.board.tasks.filter { task in
            guard task.source == .github, let number = task.number,
                  !openNumbers.contains(number), task.body == nil else { return false }
            guard let entry = TasksStore.findIssueTask(root, issue: number) else { return true }
            return entry["body"] == nil
        }
        guard !missing.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var recovered: [Int: (title: String, body: String?, labels: [String])] = [:]
            for task in missing {
                guard let number = task.number else { continue }
                if let detail = Self.fetchIssueDetail(owner: repo.owner, repo: repo.repo,
                                                      number: number, token: token) {
                    recovered[number] = detail
                }
            }
            guard !recovered.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self = self, let runner = self.runner else { return }
                runner.updateBoard { board in
                    for (number, detail) in recovered {
                        guard let idx = board.index(ofTask: TaskItem.githubID(number)) else { continue }
                        board.tasks[idx].title = detail.title
                        board.tasks[idx].body = detail.body
                        board.tasks[idx].labels = detail.labels
                    }
                }
                for (number, detail) in recovered {
                    TasksStore.mergeIssueTask(root, issue: number, update: [
                        "title": detail.title,
                        "body": detail.body ?? NSNull(),
                        "labels": detail.labels,
                    ])
                }
                self.syncFromBoard()
            }
        }
    }

    /// Fetch a single issue (open OR closed) via GitHub REST. Returns
    /// title/body/labels; nil on network/auth error.
    static func fetchIssueDetail(owner: String, repo: String, number: Int, token: String?) -> (title: String, body: String?, labels: [String])? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(owner)/\(repo)/issues/\(number)")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "accept")
        request.setValue("oh-my-dsh", forHTTPHeaderField: "user-agent")
        if let token = token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        }
        let semaphore = DispatchSemaphore(value: 0)
        var result: (title: String, body: String?, labels: [String])?
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }
            guard let data = data,
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let title = json["title"] as? String else { return }
            let labels = (json["labels"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
            result = (title, json["body"] as? String, labels)
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 20)
        task.cancel()
        return result
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

    // MARK: - Task execution (through the runner)

    /// 全部处理: every pending issue task gets its OWN single-task queue (v1's
    /// one-issue-one-branch-one-PR rule, decision 5). The first one starts right
    /// away, the rest wait their turn — the runner is strictly serial.
    private func runAllTapped() {
        guard let runner = runner else { return }
        let pending = runner.board.tasks
            .filter { $0.source == .github && $0.state == .pending }
            .sorted { ($0.number ?? 0) < ($1.number ?? 0) }
        for task in pending { _ = runner.startIssueTask(task.id) }
        syncFromBoard()
    }

    /// 处理 one issue: create (or reuse) its single-task queue and run it.
    private func startIssueTask(_ taskID: String) {
        guard let runner = runner else { return }
        _ = runner.startIssueTask(taskID)
        syncFromBoard()
    }

    /// 取消 the running task. Its queue is paused and the branch/session are kept
    /// for traceability (v1 behaviour).
    func cancelRunningTask() {
        guard let runner = runner else { return }
        _ = runner.cancelRunning()
        syncFromBoard()
        hideStatus()
    }

    /// 重试 a failed/cancelled task (back into its queue, resuming it).
    private func retryTask(_ taskID: String) {
        guard let runner = runner else { return }
        _ = runner.retry(taskID: taskID)
        syncFromBoard()
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

    // MARK: - dsh session helpers

    /// All registered dsh workspace paths (for repo detection fallback).
    /// Live workspace.list when the server serves it (dsh <= 0.1.1), else the
    /// store dsh persists — dsh >= 0.1.2 dropped the RPC (DshWorkspaceStore).
    static func listWorkspacePaths(port: Int) -> [String] {
        DshWorkspaceStore.items(port: port, log: { AppLog.shared.log($0) }).compactMap { $0["path"] as? String }
    }

    static func resolveMainWorkspaceId(port: Int, path: String) -> String? {
        let std = (path as NSString).standardizingPath
        // find matching path (or prefix, symlink-resolved)
        for ws in DshWorkspaceStore.items(port: port, log: { AppLog.shared.log($0) }) {
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
        guard let value = DshWebRPC.call(DshWebRPC.sessionCreate, payload, port: port),
              let sid = value["sessionId"] as? String else { return nil }
        return sid
    }

    static func renameSession(port: Int, sessionId: String, title: String) -> Bool {
        return DshWebRPC.call(DshWebRPC.sessionRename,
                              ["sessionId": sessionId, "title": title], port: port) != nil
    }

    static func promptSession(port: Int, sessionId: String, text: String) -> Bool {
        let payload: [String: Any] = [
            "sessionId": sessionId,
            "mode": "queue",
            "content": [["type": "text", "text": text]],
        ]
        // dsh >= 0.1.2 requires a client request id for idempotent delivery.
        return DshWebRPC.call(DshWebRPC.sessionPrompt, payload, port: port,
                              modernExtras: ["requestId": UUID().uuidString]) != nil
    }

    static func sessionRunning(port: Int, sessionId: String) -> Bool {
        guard let value = DshWebRPC.call(DshWebRPC.sessionList, [:], port: port),
              let items = value["items"] as? [[String: Any]] else { return false }
        for item in items {
            guard (item["sessionId"] as? String) == sessionId else { continue }
            return (item["running"] as? Bool) ?? false
        }
        return false
    }

    static func cancelSession(port: Int, sessionId: String) -> Bool {
        return DshWebRPC.call(DshWebRPC.sessionCancel, ["sessionId": sessionId], port: port) != nil
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

    /// An OPEN pull request whose head is this branch, or nil. Queried before
    /// creating a queue PR so that a second task on the same branch reuses the
    /// existing one instead of hitting GitHub's "a pull request already exists"
    /// (422) — every task in a queue shares one branch.
    static func findExistingPR(owner: String, repo: String, branch: String, token: String?) -> String? {
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

    // MARK: - GitHub token (per-repo scoped, FILE ONLY)

    /// Shared generic token file: the single place a user can drop a token for
    /// BOTH the app shell and external tools/agents (`${DSH_HOME:-$HOME/.dsh}/gh-token`).
    /// Resolved dsh home ($DSH_HOME or ~/.dsh) — dev builds use ~/.dsh-dev.
    private static let dshHomePath: String = {
        if let h = ProcessInfo.processInfo.environment["DSH_HOME"],
           !h.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return h.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return NSHomeDirectory() + "/.dsh"
    }()
    private static let genericTokenFilePath = dshHomePath + "/gh-token"
    /// Per-repo token dir for file-based tokens: `${DSH_HOME:-$HOME/.dsh}/tokens/<owner>-<repo>`.
    private static let tokenDir = dshHomePath + "/tokens"

    /// Per-repo token file path: ~/.dsh/tokens/<owner>-<repo>.
    private static func tokenFilePath(for repo: (owner: String, repo: String)) -> String {
        tokenDir + "/" + repo.owner + "-" + repo.repo
    }

    private func readTokenFile(_ path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let token = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else { return nil }
        return token
    }

    /// Resolve the token for the CURRENT repo — **files only** (2026-09-24: the
    /// Keychain is no longer read; the panel writes the very files external
    /// tools/agents read, so there is exactly one place to look and no password
    /// prompt can ever appear):
    ///   1. File  ~/.dsh/tokens/<owner>-<repo>   (per-repo, written by the panel)
    ///   2. File  ~/.dsh/gh-token                (generic, shared with agents)
    private func loadToken(for repo: (owner: String, repo: String)? = nil) -> String? {
        if let repo = repo, let t = readTokenFile(Self.tokenFilePath(for: repo)) { return t }
        return readTokenFile(Self.genericTokenFilePath)
    }

    /// Save a token scoped to the current repo — **writes only the file**
    /// (~/.dsh/tokens/<owner>-<repo>, atomic + chmod 600), which is the very file
    /// external tools and agents read. With no repo resolved (the panel is open
    /// in a non-GitHub workspace) it writes the generic file instead.
    /// Clearing (empty string) deletes that file.
    private func saveToken(_ token: String, for repo: (owner: String, repo: String)? = nil) {
        let file = repo.map(Self.tokenFilePath(for:)) ?? Self.genericTokenFilePath
        let fm = FileManager.default
        if token.isEmpty {
            try? fm.removeItem(atPath: file)
            return
        }
        try? fm.createDirectory(atPath: (file as NSString).deletingLastPathComponent,
                                withIntermediateDirectories: true)
        try? token.data(using: .utf8)?.write(to: URL(fileURLWithPath: file), options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file)
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
            // Empty → delete the token file; otherwise write it (file only).
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
        let expanded = (task.id == expandedTaskID)
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
        cell.objectValue = task.id   // buttons read this to know which task
        let badge = task.state.badge
        var prefix = "#\(task.number ?? 0) \(badge)"
        if task.state == .running, task.sessionId != nil { prefix += " ⟳" }
        if let title = cell.viewWithTag(100) as? NSTextField {
            title.stringValue = "\(prefix) \(task.title)"
            switch task.state {
            case .failed: title.textColor = .systemRed
            case .closed, .cancelled: title.textColor = .secondaryLabelColor
            case .queued: title.textColor = .secondaryLabelColor
            default: title.textColor = .labelColor
            }
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
        case .queued: return L10n.tr("tasks.queue.remove")
        case .running: return L10n.tr("tasks.detailCancelTask")
        case .done: return L10n.tr("tasks.detailOpenPR")
        case .failed, .cancelled: return L10n.tr("tasks.detailRetry")
        case .closed: return L10n.tr("tasks.detailOpenIssue")
        }
    }

    /// 处理 is always available now: with a queue, starting a task while another
    /// one runs simply queues it (v1 disabled the button instead).
    private func primaryActionEnabled(for task: IssueRunnerTask) -> Bool {
        switch task.state {
        case .pending, .running, .queued, .closed: return true
        case .done: return task.prUrl != nil
        case .failed, .cancelled: return true
        }
    }

    private func secondaryActionTitle(for task: IssueRunnerTask) -> String {
        L10n.tr("tasks.detailClose")
    }

    private func secondaryActionEnabled(for task: IssueRunnerTask) -> Bool { true }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < tasks.count else { return 22 }
        return tasks[row].id == expandedTaskID ? 168 : 22
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0, row < tasks.count else { return }
        let taskID = tasks[row].id
        tableView.deselectAll(nil)
        // Clicking a row toggles the inline detail (expand / collapse).
        if expandedTaskID == taskID {
            expandedTaskID = nil
        } else {
            expandedTaskID = taskID
        }
        tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<tasks.count))
        tableView.reloadData()
    }

    /// Row button handler. The primary (tag 200), secondary (tag 201) and
    /// comment/close (tag 202) buttons live inside an expanded cell; the
    /// cell's objectValue carries the task ID. Actions are explicit — never
    /// implicit row clicks.
    @objc private func cellButtonTapped(_ sender: NSButton) {
        guard let cell = sender.superview as? NSTableCellView,
              let taskID = cell.objectValue as? String,
              let task = tasks.first(where: { $0.id == taskID }) else { return }
        let number = task.number ?? 0
        if sender.tag == 201 {   // secondary = close / collapse
            expandedTaskID = nil
            tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<tasks.count))
            tableView.reloadData()
            return
        }
        if sender.tag == 202 {   // comment & close (user-initiated)
            commentAndCloseTapped(number: number)
            return
        }
        // Primary action depends on state; every state change goes to the runner.
        switch task.state {
        case .pending:
            startIssueTask(taskID)
        case .queued:
            _ = runner?.dequeue(taskID: taskID)
            syncFromBoard()
        case .running:
            cancelRunningTask()
        case .done:
            if let url = task.prUrl, let u = URL(string: url) { NSWorkspace.shared.open(u) }
        case .closed:
            if let repo = repo,
               let u = URL(string: "https://github.com/\(repo.owner)/\(repo.repo)/issues/\(number)") {
                NSWorkspace.shared.open(u)
            }
        case .failed, .cancelled:
            retryTask(taskID)
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
                    // Mark the task with its actual state (issue now closed) on
                    // the board; the row stays in the list and its buttons adapt.
                    self.runner?.updateBoard { board in
                        guard let idx = board.index(ofTask: TaskItem.githubID(number)) else { return }
                        board.tasks[idx].state = .closed
                    }
                    if let path = self.repoRootPath ?? self.workspacePath?() {
                        TasksStore.mergeIssueTask(path, issue: number, update: [
                            "state": "closed",
                            "closedAt": ISO8601DateFormatter().string(from: Date()),
                        ])
                    }
                    self.syncFromBoard()
                    // Refresh issues so new/updated ones appear.
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
        case .queued: stateName = L10n.tr("tasks.state.queued")
        case .running: stateName = L10n.tr("tasks.state.running")
        case .done: stateName = L10n.tr("tasks.state.done")
        case .failed: stateName = L10n.tr("tasks.state.failed")
        case .cancelled: stateName = L10n.tr("tasks.state.cancelled")
        case .closed: stateName = L10n.tr("tasks.state.closed")
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
}
