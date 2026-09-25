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

final class IssueRunnerPanelController: NSObject {

    var onRequestHide: (() -> Void)?
    /// Provides the dsh web port (set by AppDelegate, like other panels).
    var serverPortProvider: (() -> Int)?
    /// The main workspace directory (set by AppDelegate) — git/github root.
    var workspacePath: (() -> String?)?

    static let minWidth: CGFloat = 300

    let view = IssueRunnerRootView()

    /// Which tasks the list shows (the segmented control in the toolbar).
    enum SourceFilter: Int {
        case all = 0, issues = 1, manual = 2

        func matches(_ task: TaskItem) -> Bool {
            switch self {
            case .all: return true
            case .issues: return task.source == .github
            case .manual: return task.source == .manual
            }
        }

        /// User queues only ever hold manual tasks, so the queue section gains
        /// nothing from an issues filter; the auto queues are hidden for manual.
        var showsUserQueues: Bool { self != .issues }
        var showsAutoQueues: Bool { self != .manual }
    }

    // UI
    private let headerTitle = HeaderLabel()
    private let configButton: CustomIconButton
    private let refreshButton: CustomIconButton
    private let runAllButton: CustomIconButton
    private let hideButton: CustomIconButton
    /// The two creation entries, flush right on the tabs row (the user's ask:
    /// creating is a panel-level action, not a header icon).
    private let newTaskRowButton = NSButton(title: "", target: nil, action: nil)
    private let newQueueRowButton = NSButton(title: "", target: nil, action: nil)
    private let repoLabel = HeaderLabel()
    /// The four counters as small pills (队列 / 排队 / 运行 / 失败).
    private let chipStrip = NSStackView()
    /// The source filter as flat tabs — the skills panel's strip, so the whole
    /// shell keeps one tab体例 instead of one control style per panel.
    private let filterTabs = SkillTabStrip()
    private let listScroll = NSScrollView()
    private let listStack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let emptyIcon = BakedIconView(symbol: "checklist")
    private let emptyButton = NSButton(title: "", target: nil, action: nil)
    private let emptyView = NSStackView()
    /// The bottom sheet a form slides up in, inside a clipping, click-through
    /// host that spans the panel's content area.
    private let formSheetHost = TaskFormSheetHostView()
    private let formSheet = TaskFormSheetView()
    private var formSheetBottom: NSLayoutConstraint!
    /// The form on screen, for focus and for the slide-out animation.
    private weak var formSheetContent: NSView?
    private let statusBar = DynamicFillView()
    private let statusLabel = HeaderLabel()
    private let statusSpinner = NSProgressIndicator()

    // State
    /// The execution engine owns the board: the panel renders it and calls in.
    private var runner: TasksRunner?
    private var repo: (owner: String, repo: String)?
    private var repoRootPath: String?
    /// Which directory the current board was loaded from (a repo switch — or a
    /// switch to a non-GitHub workspace — must reload it).
    private var boardPath: String?
    /// The task currently expanded inline (shows detail + action buttons).
    private var expandedTaskID: String?
    /// id -> open? Defaults differ per kind: user queues start open (they hold
    /// the work), issue tasks' auto queues start as one compact line.
    private var queueToggle: [String: Bool] = [:]
    private var sourceFilter: SourceFilter = .all
    /// Which form the sheet is currently showing (nil = no form). Creating or
    /// editing a task never raises a dialog: the form slides up IN the panel.
    private var taskComposer: TaskComposerModel?
    private var queueComposer: QueueComposerModel?
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
        newTaskRowButton.title = L10n.tr("tasks.new.hint")
        newTaskRowButton.toolTip = L10n.tr("tasks.new.info")
        newQueueRowButton.title = L10n.tr("tasks.queue.newButton")
        newQueueRowButton.toolTip = L10n.tr("tasks.queue.newInfo")
        if let repo = repo {
            repoLabel.text = repo.owner + "/" + repo.repo
        } else if let path = repoRootPath {
            // A workspace without a GitHub remote still has a board: show where
            // we are instead of just "not a GitHub repo".
            repoLabel.text = (path as NSString).lastPathComponent + " · " + L10n.tr("tasks.noRepoShort")
        } else {
            repoLabel.text = L10n.tr("tasks.noRepo")
        }
        filterTabs.setItems([L10n.tr("tasks.filter.all"),
                             L10n.tr("tasks.filter.issues"),
                             L10n.tr("tasks.filter.manual")],
                            selected: sourceFilter.rawValue)
        emptyButton.title = L10n.tr("tasks.new.title")
        rebuildStats()
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

        // toolbar row 1: where this board lives, and the four counters as pills.
        repoLabel.translatesAutoresizingMaskIntoConstraints = false
        chipStrip.orientation = .horizontal
        chipStrip.alignment = .centerY
        chipStrip.spacing = 5
        chipStrip.translatesAutoresizingMaskIntoConstraints = false
        chipStrip.setContentHuggingPriority(.required, for: .horizontal)
        chipStrip.setContentCompressionResistancePriority(.required, for: .horizontal)
        let toolbar = DynamicFillView()
        toolbar.kind = .panel
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.wantsLayer = true
        toolbar.layer?.masksToBounds = true
        toolbar.addSubview(repoLabel)
        toolbar.addSubview(chipStrip)
        NSLayoutConstraint.activate([
            repoLabel.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 10),
            repoLabel.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            repoLabel.trailingAnchor.constraint(lessThanOrEqualTo: chipStrip.leadingAnchor, constant: -8),
            chipStrip.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -10),
            chipStrip.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 28),
        ])

        // toolbar row 2: the source filter as flat tabs (全部 / Issue / 手动).
        filterTabs.translatesAutoresizingMaskIntoConstraints = false
        filterTabs.onSelect = { [weak self] index in
            guard let self = self else { return }
            self.sourceFilter = Self.SourceFilter(rawValue: index) ?? .all
            self.render()
        }
        let tabRow = DynamicFillView()
        tabRow.kind = .panel
        tabRow.translatesAutoresizingMaskIntoConstraints = false
        for button in [newTaskRowButton, newQueueRowButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        newTaskRowButton.bezelColor = .controlAccentColor
        newTaskRowButton.target = self
        newTaskRowButton.action = #selector(newTaskTapped)
        newQueueRowButton.target = self
        newQueueRowButton.action = #selector(newQueueTapped)
        let tabSpacer = NSView()
        tabSpacer.translatesAutoresizingMaskIntoConstraints = false
        tabSpacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        tabSpacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        // The buttons keep their size; the tabs give way (a narrow panel must
        // never push the row past its own edge).
        filterTabs.setCompressible(true)
        let tabStrip = NSStackView(views: [filterTabs, tabSpacer, newTaskRowButton, newQueueRowButton])
        tabStrip.orientation = .horizontal
        tabStrip.alignment = .centerY
        tabStrip.spacing = 5
        tabStrip.translatesAutoresizingMaskIntoConstraints = false
        tabRow.addSubview(tabStrip)
        NSLayoutConstraint.activate([
            tabStrip.leadingAnchor.constraint(equalTo: tabRow.leadingAnchor, constant: 6),
            tabStrip.trailingAnchor.constraint(equalTo: tabRow.trailingAnchor, constant: -6),
            tabStrip.centerYAnchor.constraint(equalTo: tabRow.centerYAnchor),
            tabRow.heightAnchor.constraint(equalToConstant: 32),
        ])

        let toolbarUnderline = NSBox()
        toolbarUnderline.boxType = .separator
        toolbarUnderline.translatesAutoresizingMaskIntoConstraints = false

        // The list: a plain stack of cards inside a scroll view (the projects
        // panel's体例). The stack is re-built from the board on every change;
        // expansion state lives in the controller, never in the views.
        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 8
        listStack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 14, right: 10)
        listStack.translatesAutoresizingMaskIntoConstraints = false
        listStack.setHuggingPriority(.defaultLow, for: .horizontal)

        let listDocument = FlippedStackView()
        listDocument.translatesAutoresizingMaskIntoConstraints = false
        listDocument.orientation = .vertical
        listDocument.alignment = .leading
        listDocument.spacing = 0
        listDocument.addSubview(listStack)

        listScroll.documentView = listDocument
        listScroll.hasVerticalScroller = true
        listScroll.autohidesScrollers = true
        listScroll.drawsBackground = false
        listScroll.translatesAutoresizingMaskIntoConstraints = false

        // Empty state: an icon, the guidance line and the way in (the inline
        // 新建任务 form) — centred over the list, the projects panel's体例.
        emptyLabel.alignment = .center
        emptyLabel.maximumNumberOfLines = 3
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.lineBreakMode = .byWordWrapping
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyIcon.translatesAutoresizingMaskIntoConstraints = false
        emptyButton.bezelStyle = .rounded
        emptyButton.controlSize = .regular
        emptyButton.font = .systemFont(ofSize: 12)
        emptyButton.target = self
        emptyButton.action = #selector(newTaskTapped)
        emptyButton.translatesAutoresizingMaskIntoConstraints = false
        emptyView.orientation = .vertical
        emptyView.alignment = .centerX
        emptyView.spacing = 10
        emptyView.translatesAutoresizingMaskIntoConstraints = false
        emptyView.addArrangedSubview(emptyIcon)
        emptyView.addArrangedSubview(emptyLabel)
        emptyView.addArrangedSubview(emptyButton)

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

        // The document view must be pinned on every side (ChannelPanel /
        // ProjectsPanel体例): width alone lets the stack collapse into a corner.
        NSLayoutConstraint.activate([
            listStack.leadingAnchor.constraint(equalTo: listDocument.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: listDocument.trailingAnchor),
            listStack.topAnchor.constraint(equalTo: listDocument.topAnchor),
            listStack.bottomAnchor.constraint(equalTo: listDocument.bottomAnchor),
            listDocument.leadingAnchor.constraint(equalTo: listScroll.contentView.leadingAnchor),
            listDocument.topAnchor.constraint(equalTo: listScroll.contentView.topAnchor),
            listDocument.widthAnchor.constraint(equalTo: listScroll.contentView.widthAnchor),
        ])

        // The form sheet is added LAST (topmost) and starts hidden: it is pulled
        // up over the list, never laid out inside it.
        formSheetHost.translatesAutoresizingMaskIntoConstraints = false
        formSheetHost.wantsLayer = true
        formSheetHost.layer?.masksToBounds = true
        formSheet.translatesAutoresizingMaskIntoConstraints = false
        formSheet.isHidden = true
        formSheet.alphaValue = 0
        formSheetHost.addSubview(formSheet)
        // Final resting place: 8pt above the status bar (whose message must stay
        // readable while a form is open).
        formSheetBottom = formSheet.bottomAnchor.constraint(equalTo: formSheetHost.bottomAnchor,
                                                            constant: TaskFormSheetHostView.restingBottom)
        view.addSubview(header)
        view.addSubview(toolbar)
        view.addSubview(tabRow)
        view.addSubview(toolbarUnderline)
        view.addSubview(listScroll)
        view.addSubview(emptyView)
        view.addSubview(statusBar)
        view.addSubview(formSheetHost)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            toolbar.topAnchor.constraint(equalTo: header.bottomAnchor),
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            tabRow.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            tabRow.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabRow.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            toolbarUnderline.topAnchor.constraint(equalTo: tabRow.bottomAnchor),
            toolbarUnderline.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbarUnderline.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            listScroll.topAnchor.constraint(equalTo: toolbarUnderline.bottomAnchor),
            listScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            listScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            listScroll.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            emptyView.centerXAnchor.constraint(equalTo: listScroll.centerXAnchor),
            emptyView.centerYAnchor.constraint(equalTo: listScroll.centerYAnchor),
            emptyView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            emptyView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
            emptyIcon.widthAnchor.constraint(equalToConstant: 38),
            emptyIcon.heightAnchor.constraint(equalToConstant: 38),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 260),

            statusBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            formSheetHost.topAnchor.constraint(equalTo: toolbarUnderline.bottomAnchor),
            formSheetHost.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            formSheetHost.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            formSheetHost.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            formSheet.leadingAnchor.constraint(equalTo: formSheetHost.leadingAnchor, constant: 8),
            formSheet.trailingAnchor.constraint(equalTo: formSheetHost.trailingAnchor, constant: -8),
            formSheetBottom,
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
        boardPath = repoRoot
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
        boardPath = nil
        stepTimer?.invalidate()
        stepTimer = nil
        expandedTaskID = nil
        queueToggle.removeAll()
        render()
        updateLabels()
    }

    /// Cheap fingerprint of everything the list renders, so the 3-second step
    /// timer does not rebuild the cards (and fight the user's scrolling, or drop
    /// an open menu) while nothing is moving.
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
        // The shell's active project directory (follows the session the user is
        // viewing) is authoritative: it decides which board we show — do NOT
        // substitute some other registered workspace.
        if let path = workspacePath?(), !path.isEmpty {
            adoptWorkspace(path)
            return
        }
        // ProjectDirectory not resolved yet (early launch): fall back to the
        // registered workspaces, preferring one with a GitHub remote.
        let port = serverPortProvider?() ?? 3080
        let workspaces = Self.listWorkspacePaths(port: port)
        if let github = workspaces.first(where: { Self.detectGitHubRemote($0) != nil }) {
            adoptWorkspace(github)
            return
        }
        if let git = workspaces.first(where: { Self.isGitRepo($0) }) {
            adoptWorkspace(git)
            return
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
            AppLog.shared.log("tasks: no workspace adopted — activeWorkspacePath is empty and no registered workspace resolved")
        }
    }

    /// Adopt a workspace as the panel's board root.
    ///
    /// A GitHub remote only adds the ISSUE features (list / process / PR /
    /// comment & close). Manual tasks and queues work in ANY workspace: the
    /// board lives in that directory's .dsh/tasks/, and a queue that asks for a
    /// branch simply fails with tasks.errNotGit if the directory is not a git
    /// repository (docs/issue-runner-design.md §V2-7).
    private func adoptWorkspace(_ path: String) {
        let detected = Self.detectGitHubRemote(path)
        let sameBoard = (boardPath == path) && runner != nil
        repo = detected
        repoRootPath = path
        let github = detected.map { $0.owner + "/" + $0.repo } ?? "-"
        let git = Self.isGitRepo(path) ? "yes" : "no"
        AppLog.shared.log("tasks: workspace adopted at \(path) (github=\(github) git=\(git))")
        updateLabels()
        if !sameBoard { setupRunner(repoRoot: path) }
        reloadIssues()
        render()
    }

    /// True when the directory is inside a git work tree.
    static func isGitRepo(_ path: String) -> Bool {
        Self.runProcess("/usr/bin/git", ["-C", path, "rev-parse", "--is-inside-work-tree"]) == "true"
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

    // MARK: - Card list

    /// Rebuild the list from the board. Cards are created fresh on every change
    /// (the projects panel's体例): the state that must survive a rebuild — which
    /// task is expanded, which queues are open — lives in the controller.
    private func syncFromBoard() {
        boardSignature = boardSignatureNow()
        render()
    }

    private func render() {
        for subview in listStack.arrangedSubviews { subview.removeFromSuperview() }
        guard let runner = runner else {
            rebuildStats()
            emptyView.isHidden = false
            return
        }
        let board = runner.board
        let githubRepo = repo != nil
        var sections = 0

        // 1. Queues. User queues first (they hold the user's own work), then the
        //    issue tasks' single-task queues, which count and render like any
        //    other queue but start as one compact line (决策 8).
        let userQueues = sourceFilter.showsUserQueues ? board.queues.filter { !$0.autoCreated } : []
        let autoQueues = sourceFilter.showsAutoQueues
            ? board.queues.filter { $0.autoCreated }.sorted(by: { autoQueueNumber($0, board) < autoQueueNumber($1, board) })
            : []
        let queues = userQueues + autoQueues
        if !queues.isEmpty {
            addCard(TaskSectionHeaderView(text: L10n.tr("tasks.section.queues", queues.count)))
            for queue in queues {
                // A queue is ONE block: the lane surface holds its header AND its
                // cards, so the containment is geometric (review-panel体例)
                // instead of two parallel stacks that only happen to be adjacent.
                let cards = board.tasks(inQueue: queue.id).filter { sourceFilter.matches($0) }
                let header = queueHeader(queue, board: board, cardCount: cards.count)
                let expanded = isQueueExpanded(queue)
                let cardViews = expanded
                    ? cards.map { card($0, board: board, githubRepo: githubRepo) }
                    : []
                addCard(TaskQueueBlockView(header: header, cards: cardViews, collapsed: !expanded))
            }
            sections += 1
        }

        // 2. Tasks that are in no queue at all — the 未入队 area.
        let unqueued = board.tasks.filter { $0.queueId == nil && sourceFilter.matches($0) }
        if !unqueued.isEmpty {
            addCard(TaskSectionHeaderView(text: L10n.tr("tasks.section.unqueued", unqueued.count)))
            for task in unqueued { addCard(card(task, board: board, githubRepo: githubRepo)) }
            sections += 1
        }

        // 3. Empty state — the form sheet overlays the list, so it does not
        //    change what the list says about itself.
        let empty = TasksEmptyStateModel.build(filtered: sourceFilter != .all, githubRepo: repo != nil)
        emptyView.isHidden = sections > 0
        emptyLabel.stringValue = L10n.tr(empty.messageKey)
        emptyIcon.setSymbol(empty.symbol)
        emptyButton.isHidden = !empty.showsNewTask
        rebuildStats()
    }

    /// Cards fill the list width: the stack is leading-aligned, so without this
    /// every card would hug its own content instead (ProjectsPanel体例).
    private func addCard(_ view: NSView) {
        listStack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: listStack.widthAnchor, constant: -20).isActive = true
    }

    // MARK: - Form sheet

    /// Pull the form sheet up with this content (or swap its content while it is
    /// already up — a create-then-create-again round must not re-animate).
    private func presentForm(_ content: NSView, focus: @escaping (NSView) -> Void) {
        for subview in formSheet.subviews { subview.removeFromSuperview() }
        content.translatesAutoresizingMaskIntoConstraints = false
        formSheet.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: formSheet.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: formSheet.trailingAnchor),
            content.topAnchor.constraint(equalTo: formSheet.topAnchor),
            content.bottomAnchor.constraint(equalTo: formSheet.bottomAnchor),
        ])
        formSheetContent = content
        let wasVisible = !formSheet.isHidden
        view.layoutSubtreeIfNeeded()
        if wasVisible {
            // Already up (create → create again): swap the content in place.
            formSheetBottom.constant = TaskFormSheetHostView.restingBottom
            view.layoutSubtreeIfNeeded()
        } else {
            // Start BELOW the host's edge (clipped away by it) and slide up: the
            // sheet is exactly as tall as its content, which the layout pass
            // above has just resolved.
            formSheetBottom.constant = -formSheet.frame.height
            view.layoutSubtreeIfNeeded()
            formSheet.isHidden = false
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                formSheetBottom.animator().constant = TaskFormSheetHostView.restingBottom
                formSheet.animator().alphaValue = 1
            }
        }
        // Take focus once the sheet has arrived (the fields must be on screen
        // before the caret lands in them).
        DispatchQueue.main.asyncAfter(deadline: .now() + (wasVisible ? 0 : 0.22)) { [weak self] in
            guard let self = self, let content = self.formSheetContent else { return }
            focus(content)
        }
    }

    /// Slide the sheet back down and drop its content.
    private func dismissForm() {
        guard !formSheet.isHidden else { return }
        let hidden = -formSheet.frame.height
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.formSheetBottom.animator().constant = hidden
            self.formSheet.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self = self else { return }
            self.formSheet.isHidden = true
            for subview in self.formSheet.subviews { subview.removeFromSuperview() }
            self.formSheetContent = nil
        })
    }

    private func showTaskForm(_ model: TaskComposerModel) {
        taskComposer = model
        let form = TaskComposerView(model: model)
        form.onSubmit = { [weak self] composer in self?.submitTaskComposer(composer) }
        form.onCancel = { [weak self] in self?.closeTaskComposer() }
        presentForm(form) { ($0 as? TaskComposerView)?.focusTitle() }
    }

    private func showQueueForm(_ model: QueueComposerModel) {
        queueComposer = model
        let form = QueueComposerView(model: model)
        form.onSubmit = { [weak self] composer in self?.submitQueueComposer(composer) }
        form.onCancel = { [weak self] in self?.closeQueueComposer() }
        presentForm(form) { ($0 as? QueueComposerView)?.focusName() }
    }

    /// The four counters, right-aligned in the toolbar. Nothing to report (a
    /// brand-new board) leaves the strip empty instead of showing four zeros.
    private func rebuildStats() {
        for subview in chipStrip.arrangedSubviews { subview.removeFromSuperview() }
        guard let runner = runner else { return }
        let summary = TasksSummaryModel.build(runner.board)
        guard summary.queues + summary.queued + summary.running + summary.failed > 0 else { return }
        for chip in summary.chips {
            chipStrip.addArrangedSubview(TaskBadgeView(text: L10n.tr(chip.key) + " " + String(chip.count),
                                                       tone: chip.tone))
        }
    }

    /// Issue numbers order the auto queues (they are per-repo and monotonic).
    private func autoQueueNumber(_ queue: TaskQueue, _ board: TaskBoard) -> Int {
        queue.taskIds.first.flatMap { board.task($0)?.number } ?? 0
    }

    /// Auto (issue) queues start collapsed: one line each, expanding on a click.
    private func isQueueExpanded(_ queue: TaskQueue) -> Bool {
        if let explicit = queueToggle[queue.id] { return explicit }
        return !queue.autoCreated
    }

    private func card(_ task: TaskItem, board: TaskBoard, githubRepo: Bool) -> NSView {
        let model = TaskCardModel.build(task, board: board,
                                        expanded: expandedTaskID == task.id,
                                        githubRepo: githubRepo)
        let card = TaskCardView(model: model)
        let taskID = task.id
        card.onToggle = { [weak self] in self?.toggleTask(taskID) }
        card.onPrimary = { [weak self] in self?.primaryAction(task) }
        card.onQueue = { [weak self, weak card] in
            guard let card = card else { return }
            self?.presentQueuePicker(for: taskID, from: card)
        }
        card.onCommentClose = { [weak self] in self?.commentAndCloseTapped(number: task.number ?? 0) }
        card.onEdit = { [weak self] in self?.openTaskComposer(.edit(taskID: taskID)) }
        card.onDelete = { [weak self] in self?.confirmDelete(task) }
        return card
    }

    private func queueHeader(_ queue: TaskQueue, board: TaskBoard, cardCount: Int) -> TaskQueueHeaderView {
        let model = QueueHeaderModel.build(queue, board: board, collapsed: !isQueueExpanded(queue))
        let header = TaskQueueHeaderView(model: model)
        let queueID = queue.id
        header.onToggle = { [weak self] in self?.toggleQueue(queueID) }
        header.onStart = { [weak self] in
            _ = self?.runner?.startQueue(queueID)
            self?.syncFromBoard()
        }
        header.onPause = { [weak self] in
            _ = self?.runner?.pauseQueue(queueID)
            self?.syncFromBoard()
        }
        header.onOpenPR = { [weak self] in self?.openPR(for: queue) }
        // 重命名 / 改分支 / 基于分支 / PR 开关 are one inline form now.
        header.onSettings = { [weak self] in self?.openQueueComposer(.edit(queueID: queueID)) }
        header.onTogglePR = { [weak self] in
            _ = self?.runner?.updateQueue(queueID, autoPR: !queue.autoPR)
            self?.syncFromBoard()
        }
        header.onDelete = { [weak self] in self?.confirmDeleteQueue(queue, cardCount: cardCount) }
        return header
    }

    private func toggleTask(_ taskID: String) {
        expandedTaskID = (expandedTaskID == taskID) ? nil : taskID
        render()
    }

    private func toggleQueue(_ queueID: String) {
        guard let queue = runner?.board.queue(queueID) else { return }
        queueToggle[queueID] = !isQueueExpanded(queue)
        render()
    }

    // MARK: - Card actions (all state changes go through the runner)

    private func primaryAction(_ task: TaskItem) {
        guard let runner = runner else { return }
        switch task.state {
        case .pending:
            _ = runner.startIssueTask(task.id)
        case .queued:
            _ = runner.dequeue(taskID: task.id)
        case .running:
            _ = runner.cancelRunning()
            hideStatus()
        case .done:
            if let url = task.prUrl, let link = URL(string: url) { NSWorkspace.shared.open(link) }
        case .closed:
            openIssue(number: task.number ?? 0)
        case .failed, .cancelled:
            _ = runner.retry(taskID: task.id)
        }
        syncFromBoard()
    }

    private func openIssue(number: Int) {
        guard let repo = repo,
              let url = URL(string: "https://github.com/\(repo.owner)/\(repo.repo)/issues/\(number)") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Queue PR, opened from the header once the queue finished. Reuses the
    /// existing one when GitHub already has an open PR for the branch.
    private func openPR(for queue: TaskQueue) {
        if let url = queue.prUrl, let link = URL(string: url) { NSWorkspace.shared.open(link); return }
        guard let repo = repo, let branch = queue.branch else { return }
        setStatus(L10n.tr("tasks.queue.creatingPR", queue.name), spin: true)
        let token = loadToken(for: repo)
        let base = queue.baseBranch
        let title = L10n.tr("tasks.queue.prTitle", queue.name)
        let body = L10n.tr("tasks.queue.prBody", queue.name)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let existing = Self.findExistingPR(owner: repo.owner, repo: repo.repo, branch: branch, token: token)
            let url = existing ?? Self.createPR(owner: repo.owner, repo: repo.repo, title: title,
                                                head: branch, base: base, body: body, token: token)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.hideStatus()
                guard let url = url else {
                    self.setStatus(L10n.tr("tasks.errPR"), spin: false)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.hideStatus() }
                    return
                }
                _ = self.runner?.updateQueue(queue.id, prUrl: url)
                if let link = URL(string: url) { NSWorkspace.shared.open(link) }
                self.syncFromBoard()
            }
        }
    }

    // MARK: - Queue picker (加入队列)

    private func presentQueuePicker(for taskID: String, from view: NSView) {
        guard let runner = runner else { return }
        let menu = NSMenu()
        for choice in runner.queueChoices() {
            let suffix = choice.branch.map { "  " + $0 } ?? ""
            let item = NSMenuItem(title: choice.name + suffix, action: #selector(queueChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = [taskID, choice.id]
            menu.addItem(item)
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        let newItem = NSMenuItem(title: L10n.tr("tasks.queue.new"), action: #selector(newQueueForTask(_:)), keyEquivalent: "")
        newItem.target = self
        newItem.representedObject = taskID
        menu.addItem(newItem)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height), in: view)
    }

    @objc private func queueChosen(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? [String], payload.count == 2 else { return }
        _ = runner?.enqueue(taskID: payload[0], into: payload[1])
        syncFromBoard()
    }

    /// 新建队列 from a card's 加入队列 ▾ menu: the form opens inline, anchored
    /// under that card, and the task joins the queue once it is created.
    @objc private func newQueueForTask(_ sender: NSMenuItem) {
        guard let taskID = sender.representedObject as? String else { return }
        openQueueComposer(.create(taskID: taskID))
    }

    /// The tabs row's 新建任务 / 新建队列 buttons (empty state uses the same path).
    @objc private func newTaskTapped() { openTaskComposer(.create) }

    /// A queue created from the tabs row has no task to take: it starts empty and
    /// its cards get dragged in later from the cards' 加入队列 ▾.
    @objc private func newQueueTapped() { openQueueComposer(.create(taskID: nil)) }

    // MARK: - Inline forms (nothing here raises a dialog)

    /// 新建任务 / 编辑任务 — the form slides up from the bottom of the panel in
    /// the shared sheet; nothing here raises a dialog and nothing is laid out
    /// inside the list.
    private func openTaskComposer(_ mode: TaskComposerModel.Mode) {
        guard let runner = runner else {
            setStatus(L10n.tr("tasks.errNoWorkspace"), spin: false)
            autoHideStatus(after: 4)
            return
        }
        queueComposer = nil
        switch mode {
        case .create:
            showTaskForm(TaskComposerModel.build(mode: .create))
        case .edit(let taskID):
            // Prefilled from the board: the form must open on the task's own
            // title and description, not on an empty draft.
            guard let task = runner.board.task(taskID) else { return }
            showTaskForm(TaskComposerModel.edit(task))
        }
    }

    private func closeTaskComposer() {
        taskComposer = nil
        dismissForm()
    }

    /// Submit from the inline form. Creating keeps the form open with cleared
    /// fields so several tasks can be added in a row (完成 / Esc closes it);
    /// saving an edit closes it.
    private func submitTaskComposer(_ composer: TaskComposerModel) {
        guard let runner = runner else { return }
        let draft = composer.draft
        switch composer.mode {
        case .create:
            if let created = runner.createManualTask(draft) {
                setStatus(L10n.tr("tasks.new.created", created.title), spin: false)
                autoHideStatus(after: 4)
            }
            // Still open, cleared: 完成 / Esc closes it.
            showTaskForm(TaskComposerModel.build(mode: .create))
        case .edit(let taskID):
            _ = runner.updateManualTask(taskID, title: draft.normalizedTitle, body: draft.normalizedBody)
            setStatus(L10n.tr("tasks.new.updated", draft.normalizedTitle), spin: false)
            autoHideStatus(after: 4)
            taskComposer = nil
            dismissForm()
        }
        syncFromBoard()
    }

    private func autoHideStatus(after seconds: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.hideStatus() }
    }

    /// 新建队列 / 队列设置 — opened in the panel like the task form. A new queue
    /// can take the task that asked for it (加入队列 ▾ → 新建队列) or stand alone
    /// (the queues section header's 新建队列); the same form edits a queue's name,
    /// branch, base branch and PR switch in place under its header.
    private func openQueueComposer(_ mode: QueueComposerModel.Mode) {
        guard let runner = runner else {
            setStatus(L10n.tr("tasks.errNoWorkspace"), spin: false)
            autoHideStatus(after: 4)
            return
        }
        taskComposer = nil
        switch mode {
        case .create(let taskID):
            var model = taskID.map { QueueComposerModel.create(taskID: $0) } ?? QueueComposerModel.create()
            model.prAvailable = repo != nil
            // The PR switch is only pre-armed where the repo can carry one.
            model.autoPR = false
            showQueueForm(model)
        case .edit(let queueID):
            guard let queue = runner.board.queue(queueID) else { return }
            showQueueForm(QueueComposerModel.edit(queue, prAvailable: repo != nil))
        }
    }

    private func closeQueueComposer() {
        queueComposer = nil
        dismissForm()
    }

    private func submitQueueComposer(_ composer: QueueComposerModel) {
        guard let runner = runner else { return }
        switch composer.mode {
        case .create(let taskID):
            let queue = runner.createQueue(name: composer.normalizedName,
                                           branch: composer.branchValue,
                                           baseBranch: composer.normalizedBaseBranch,
                                           autoPR: composer.autoPR && repo != nil)
            if let taskID = taskID { _ = runner.enqueue(taskID: taskID, into: queue.id) }
            setStatus(L10n.tr("tasks.queue.created", queue.name), spin: false)
            autoHideStatus(after: 4)
            // Show the new queue open: its card list is what the user just built.
            queueToggle[queue.id] = true
            queueComposer = nil
            dismissForm()
        case .edit(let queueID):
            _ = runner.updateQueue(queueID,
                                   name: composer.normalizedName,
                                   branch: .some(composer.branchValue),
                                   baseBranch: composer.normalizedBaseBranch,
                                   autoPR: composer.autoPR && repo != nil)
            setStatus(L10n.tr("tasks.queue.updated", composer.normalizedName), spin: false)
            autoHideStatus(after: 4)
            queueComposer = nil
            dismissForm()
        }
        syncFromBoard()
    }

    private func confirmDelete(_ task: TaskItem) {
        let alert = NSAlert()
        alert.messageText = L10n.tr("tasks.deleteTaskTitle", task.title)
        alert.informativeText = L10n.tr("tasks.deleteTaskInfo")
        alert.addButton(withTitle: L10n.tr("tasks.card.delete"))
        alert.addButton(withTitle: L10n.tr("btn.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        _ = runner?.deleteManualTask(task.id)
        syncFromBoard()
    }

    private func confirmDeleteQueue(_ queue: TaskQueue, cardCount: Int) {
        let alert = NSAlert()
        alert.messageText = L10n.tr("tasks.deleteQueueTitle", queue.name)
        alert.informativeText = L10n.tr("tasks.deleteQueueInfo", cardCount)
        alert.addButton(withTitle: L10n.tr("tasks.queue.delete"))
        alert.addButton(withTitle: L10n.tr("btn.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        _ = runner?.removeQueue(queue.id)
        queueToggle[queue.id] = nil
        syncFromBoard()
    }

    /// User pressed "Comment & Close Issue": show a confirmation dialog with an
    /// editable comment (pre-filled with the PR reference), then act on GitHub.
    /// Explicitly user-initiated — never automatic.
    private func commentAndCloseTapped(number: Int) {
        guard let repo = repo,
              let task = runner?.board.tasks.first(where: { $0.number == number }),
              task.state == .done else { return }
        let prRef = task.prUrl ?? ""

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
}

