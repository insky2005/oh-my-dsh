import AppKit

// MARK: - IssueRunner panel (issue-driven tasks)

/// Root view. Mirrors WikiRootView's compositing fix
/// (docs/fixes/terminal-header-fix.md): isOpaque=false so header/toolbar/content
/// composite correctly in the layer-backed window.
final class IssueRunnerRootView: NSView {
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        PanelSurface.color(for: effectiveAppearance).setFill()
        dirtyRect.fill()
    }
}

/// Keeps a dialog's default button in step with a text view: enabled only while
/// there is something to submit. The 评论并关闭 dialog used to accept an empty
/// comment, dismiss itself, and do nothing at all.
final class CommentFieldWatcher: NSObject, NSTextViewDelegate {
    weak var button: NSButton?

    func apply(_ view: NSTextView) {
        button?.isEnabled = !view.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func textDidChange(_ notification: Notification) {
        guard let view = notification.object as? NSTextView else { return }
        apply(view)
    }
}

/// Rows are the board's own model now (TasksCore.swift): the panel renders the
/// github half of it and hands every state change to TasksRunner. The card list
/// (step 6) renders manual tasks and queues from the same board.
typealias IssueRunnerTask = TaskItem

final class IssueRunnerPanelController: NSObject {

    var onRequestHide: (() -> Void)?
    /// Show this panel in the shell's right slot (set by AppDelegate). The tasks API
    /// uses it when an agent creates tasks: 用户刚要求建的任务，就该在眼前。
    var onShowPanel: (() -> Void)?
    /// The user picked another workspace that has a task running: the shell re-roots
    /// to it (the same primitive the Projects panel uses).
    var onSelectWorkspace: ((String) -> Void)?
    /// The task's session, handed to the shell: show it in dsh web / audit it.
    /// The shell has had these bridges all along (ChannelPanel uses the first).
    var onOpenSession: ((String) -> Void)?
    var onReviewSession: ((String) -> Void)?
    /// The runner started/stopped working: the shell shows that on the activity bar
    /// (a task panel that is closed has no other way to say "something is running").
    var onRunStateChanged: ((Bool) -> Void)?
    /// A task just finished — (workspace path, task title, did it succeed). The
    /// workspace is part of it: with several tracked at once, "a task finished"
    /// alone is not actionable.
    var onTaskFinished: ((String, String, Bool) -> Void)?
    /// Provides the dsh web port (set by AppDelegate, like other panels).
    var serverPortProvider: (() -> Int)?
    /// The main workspace directory (set by AppDelegate) — git/github root.
    var workspacePath: (() -> String?)?

    static let minWidth: CGFloat = 300

    let view = IssueRunnerRootView()

    /// Which tasks the list shows (the flat tabs in the toolbar). The RULES live in
    /// TasksUI (TaskSourceFilter: which tasks match, which lanes are worth showing) so
    /// the headless tests can pin them — the bug this replaces was a lane rule, not a
    /// tab index: 全部处理 builds AUTO queues for MANUAL tasks too, and the old rule
    /// decided lanes by `autoCreated`, so the Issue tab listed lanes named after manual
    /// tasks and the 手动 tab looked empty.
    typealias SourceFilter = TaskSourceFilter

    // UI
    private let headerTitle = HeaderLabel()
    private let configButton: CustomIconButton
    private let refreshButton: CustomIconButton
    private let runAllButton: CustomIconButton
    private let hideButton: CustomIconButton
    /// 使用说明 —— ALWAYS in the toolbar (user 2026-10-01). An empty board ALSO
    /// shows the same help inline in the content area (see render()).
    private let helpButton: CustomIconButton
    /// The two creation entries, flush right on the tabs row as ICON buttons:
    /// the labels live in their tooltips, so the row stays a strip of controls
    /// instead of a sentence.
    /// Shown only while ANOTHER workspace has a task running (see
    /// updateOtherWorkspaces): tracking work the user cannot see would just be a
    /// different way of hiding it.
    private let otherWorkspacesButton = CustomIconButton(glyph: .symbol("square.stack.3d.up.fill"),
                                                         tooltip: "", size: 24)
    private let newTaskRowButton = CustomIconButton(glyph: .plus, tooltip: "", size: 24)
    private let newQueueRowButton = CustomIconButton(glyph: .symbol("rectangle.stack.badge.plus"),
                                                     tooltip: "", size: 24)
    /// The header's second line: where this board lives (owner/repo, or the
    /// directory plus what it is not — 非 GitHub 仓库 / 非 Git 仓库). It fits its
    /// own text to the room it has (see FittingHeaderLabel).
    private let repoLabel = FittingHeaderLabel()
    /// The source filter as flat tabs — the skills panel's strip, so the whole
    /// shell keeps one tab体例 instead of one control style per panel.
    private let filterTabs = SkillTabStrip()
    private let listScroll = NSScrollView()
    private let listStack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let emptyIcon = BakedIconView(symbol: "checklist")
    private let emptyButton = NSButton(title: "", target: nil, action: nil)
    private let emptyView = NSStackView()
    /// The 使用说明 body shown inline while the board is empty.
    private let helpTextView = TasksHelpTextView()
    /// The bottom sheet a form slides up in, inside a clipping, click-through
    /// host that spans the panel's content area.
    private let formSheetHost = TaskFormSheetHostView()
    private let formSheet = TaskFormSheetView()
    private var formSheetTop: NSLayoutConstraint!
    /// The form on screen, for focus and for the slide-out animation.
    private weak var formSheetContent: NSView?
    private let statusBar = DynamicFillView()
    private let statusLabel = HeaderLabel()
    private let statusSpinner = NSProgressIndicator()

    // State
    /// Every workspace being tracked at once (TasksWorkspaces.swift). The board the
    /// panel SHOWS is the current workspace's; a workspace whose task is still
    /// running keeps its runner even after the user switches away, so the task is
    /// still stepped, still finishes and still opens its PR.
    private lazy var workspaces = TaskWorkspaceRegistry { [weak self] path, reconcile in
        self?.makeRunner(path: path, reconcile: reconcile)
    }
    /// The execution engine of the CURRENT workspace: the panel renders its board
    /// and calls into it.
    private var runner: TasksRunner? { workspaces.currentRunner }
    private var repo: (owner: String, repo: String)?
    private var repoRootPath: String?
    /// Whether the adopted workspace is a git repository at all. The runner does
    /// not need it (a branchless queue never touches git), but the FORMS do:
    /// a queue created in a non-git directory must not be handed a branch it
    /// can never check out (docs/design/panels/issue-runner-design.md §V2-7).
    private var workspaceIsGit = true
    /// Whether this workspace has ANY git remote to push to (merge/push publish).
    /// A local-only repo has none — the honest default there is 「无」.
    private var workspaceHasRemote = false
    /// The current workspace's own default branch (origin/HEAD → main → master →
    /// current → "main"): the base an issue task's queue is built on, and what the
    /// queue form prefills.
    private var workspaceDefaultBase = "main"
    /// The adopted workspace's repositories (multi-repo, P1b): the header counts
    /// them, the queue form picks among them, and the runner env hands each its own
    /// git. Empty until a workspace is adopted.
    private var workspaceRepoSet = WorkspaceRepoSet()
    /// Per-path repo-set cache: the registry factory detects it to build the env,
    /// and adoptWorkspace reuses the same answer for the header / forms instead of
    /// probing git twice on the main thread.
    private var repoSetByPath: [String: WorkspaceRepoSet] = [:]
    /// Workspaces other than the current one that have a task in flight (their
    /// runners are alive). The header offers a way to jump to them — tracking work
    /// the user cannot see would just be a different way of hiding it.
    private var otherBusyPaths: [(path: String, title: String)] = []
    /// The task currently expanded inline (shows detail + action buttons).
    private var expandedTaskID: String?
    /// id -> open? Defaults differ per kind: user queues start open (they hold
    /// the work), issue tasks' auto queues start as one compact line.
    private var queueToggle: [String: Bool] = [:]
    /// Queues whose 交付结果 is expanded to the full report (per queue, panel state).
    private var expandedQueueNotes: Set<String> = []
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
        helpButton = CustomIconButton(glyph: .symbol("questionmark.circle"), tooltip: "")
        super.init()
        buildUI()
        refreshButton.onAction = { [weak self] in self?.reloadIssues() }
        runAllButton.onAction = { [weak self] in self?.runAllTapped() }
        configButton.onAction = { [weak self] in self?.configTapped() }
        helpButton.onAction = { [weak self] in self?.helpTapped() }
        hideButton.onAction = { [weak self] in self?.onRequestHide?() }
        updateLabels()
    }

    deinit {
        stepTimer?.invalidate()
    }

    private func updateLabels() {
        headerTitle.text = L10n.tr("tasks.title")
        // configButton / refreshButton / runAllButton tooltips are set with their
        // enabled state below (they depend on the workspace).
        hideButton.toolTip = L10n.tr("preview.closePanel")
        helpButton.toolTip = L10n.tr("tasks.help.hint")
        newTaskRowButton.toolTip = L10n.tr("tasks.new.hint")
        newQueueRowButton.toolTip = L10n.tr("tasks.queue.newButton")
        // Where this board lives (header line 2) and what that means for the
        // three GitHub-only buttons. A non-git directory and a git repository
        // without a GitHub remote are different things and say so differently.
        let workspace = TaskWorkspaceModel.build(owner: repo?.owner, repo: repo?.repo,
                                                 workspacePath: repoRootPath,
                                                 isGitRepo: workspaceIsGit,
                                                 repoSet: workspaceRepoSet)
        repoLabel.fullText = workspace.title
        // Multi-repo: the compact line counts repositories, the tooltip names them
        // (the primary marked) — the count alone would hide which ones.
        repoLabel.toolTip = workspace.repoListTooltip
        // The gear opens 面板设置 (token + 工作流). The integration default applies
        // to every workspace, so the gear is NOT GitHub-gated any more.
        configButton.isEnabled = true
        refreshButton.isEnabled = workspace.githubAvailable
        // 处理 is NOT GitHub-only: it starts everything that is waiting, and manual
        // tasks work in any workspace (only the PR half needs a GitHub remote).
        updateRunAllButton(githubAvailable: workspace.githubAvailable)
        configButton.toolTip = L10n.tr("tasks.settings.hint")
        refreshButton.toolTip = workspace.githubAvailable ? L10n.tr("tasks.refreshHint") : workspace.disabledHint
        // The strip is built FROM the enum: title order, index and meaning come from one
        // place (TaskSourceFilter.allCases), so a tab can never label the wrong filter.
        filterTabs.setItems(TaskSourceFilter.allCases.map { L10n.tr($0.titleKey) },
                            selected: sourceFilter.rawValue)
        emptyButton.title = L10n.tr("tasks.new.title")
        // The toolbar labels above are replaced in place; everything the CONTENT
        // says (the 统计信息 card, every card badge, the empty state) carries an
        // L10n string baked in when it was built — so a language switch rebuilds
        // the list. Re-rendering never touches the board, only its rendering.
        if runner != nil { render() }
    }

    /// 语言切换后刷新头部按钮 tooltip（复用 updateLabels）。
    func refreshTooltips() {
        updateLabels()
    }

    /// The shell reporting something the panel asked for but could not finish — an
    /// 「打开会话」 click whose session is not in dsh web's sidebar, say. It goes HERE,
    /// in the panel the user is looking at: the failure used to land on the PROJECTS
    /// panel's status line, so clicking 打开会话 in the task list looked like nothing
    /// happened at all.
    func reportStatus(_ message: String) {
        setStatus(message, spin: false)
        autoHideStatus(after: 8)
    }

    private func buildUI() {
        // The header carries TWO lines: 任务, and where this board lives. The
        // workspace line used to own a 28pt band of its own — a whole row of the
        // panel for one short line (the review panel's band carries controls) —
        // so it moved up here beside the title it belongs to.
        headerTitle.translatesAutoresizingMaskIntoConstraints = false
        headerTitle.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        repoLabel.translatesAutoresizingMaskIntoConstraints = false
        // The workspace line gives way first: it truncates itself (see
        // FittingHeaderLabel) while the title and the buttons keep their size.
        repoLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        repoLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        otherWorkspacesButton.isHidden = true
        otherWorkspacesButton.onAction = { [weak self] in self?.otherWorkspacesTapped() }
        // 处理 first: it is the primary action of the whole panel (start the work),
        // and it is the one that works in any workspace.
        // 帮助在设置之后、关闭之前（用户 2026-10-01）。
        let actions = NSStackView(views: [otherWorkspacesButton, runAllButton, refreshButton,
                                         configButton, helpButton, hideButton])
        actions.orientation = .horizontal
        actions.spacing = 6
        actions.translatesAutoresizingMaskIntoConstraints = false

        let header = DynamicFillView()
        header.kind = .panel
        header.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(headerTitle)
        header.addSubview(repoLabel)
        header.addSubview(actions)
        NSLayoutConstraint.activate([
            headerTitle.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 10),
            headerTitle.topAnchor.constraint(equalTo: header.topAnchor, constant: 7),
            headerTitle.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -8),
            repoLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 10),
            repoLabel.topAnchor.constraint(equalTo: headerTitle.bottomAnchor, constant: 1),
            repoLabel.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -8),
            actions.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -8),
            actions.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            header.heightAnchor.constraint(equalToConstant: 46),
        ])
        // the source filter as flat tabs (全部 / Issue / 手动) — the row that used
        // to sit under the workspace band.
        filterTabs.translatesAutoresizingMaskIntoConstraints = false
        filterTabs.onSelect = { [weak self] index in
            guard let self = self else { return }
            self.sourceFilter = Self.SourceFilter(rawValue: index) ?? .all
            self.render()
        }
        let tabRow = DynamicFillView()
        tabRow.kind = .panel
        tabRow.translatesAutoresizingMaskIntoConstraints = false
        newTaskRowButton.onAction = { [weak self] in self?.newTaskTapped() }
        newQueueRowButton.onAction = { [weak self] in self?.newQueueTapped() }
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
        // 使用说明 inline, under the way in: an empty board teaches the panel.
        helpTextView.contentWidth = 300
        helpTextView.apply(TasksHelpModel.build())
        emptyView.addArrangedSubview(helpTextView)

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
        // (docs/fixes/terminal-header-fix.md), same as wiki/terminal panels.
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
        // Final resting place: 8pt below the top of the content area. The sheet
        // pulls DOWN from there (the bottom of the panel belongs to the list and
        // its status bar — a sheet resting there covers the form's own buttons on
        // a short panel).
        formSheetTop = formSheet.topAnchor.constraint(equalTo: formSheetHost.topAnchor,
                                                      constant: TaskFormSheetHostView.restingTop)
        // The sheet's height comes from the sheet itself (it follows its form by
        // constraint, see TaskFormSheetView.setContent); the panel only caps it, so
        // a form taller than the content area scrolls instead of overflowing. No
        // measurement anywhere: a form that grows from the inside grows the sheet in
        // the same layout pass.
        formSheetHost.onLayout = { [weak self] in
            // A resize changes the wrapping: the description editor re-measures.
            (self?.formSheetContent as? TaskComposerView)?.layoutEditor()
        }
        view.addSubview(header)
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

            tabRow.topAnchor.constraint(equalTo: header.bottomAnchor),
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
            helpTextView.widthAnchor.constraint(equalToConstant: 300),

            statusBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            formSheetHost.topAnchor.constraint(equalTo: toolbarUnderline.bottomAnchor),
            formSheetHost.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            formSheetHost.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            formSheetHost.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            formSheet.leadingAnchor.constraint(equalTo: formSheetHost.leadingAnchor, constant: 8),
            formSheet.trailingAnchor.constraint(equalTo: formSheetHost.trailingAnchor, constant: -8),
            // As tall as the form wants, but never taller than the content area:
            // past that the form SCROLLS inside the sheet rather than shrinking
            // itself (a squeezed description editor is not a text area).
            formSheet.heightAnchor.constraint(lessThanOrEqualTo: formSheetHost.heightAnchor,
                                              constant: -2 * TaskFormSheetHostView.restingTop),
            formSheetTop,
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

    /// The workspace the user is viewing changed (a dsh web session switch).
    ///
    /// Switching between sessions of the SAME workspace must NOT re-adopt it: every
    /// adopt spawns blocking `/usr/bin/git` probes (detectGitHubRemote / isGitRepo /
    /// detectDefaultBaseBranch) on the MAIN thread — the same thread the dsh web
    /// WKWebView renders on — so re-adopting on every switch froze the page while it
    /// loaded a session. A genuine switch still goes through resolveRepoAndReload; a
    /// workspace SHAPE change (a task ran `git init`) is re-detected by
    /// recheckWorkspaceShape on the step timer, which rebuilds through adoptWorkspace.
    func workspaceChanged() {
        guard TaskWorkspaceRegistry.needsReadopt(resolved: workspacePath?(),
                                                 adopted: workspaces.currentPath,
                                                 hasRunner: runner != nil) else { return }
        resolveRepoAndReload()
    }

    // MARK: - Local API (task-todo skill / curl)

    /// 本地 API 的工作区解析：请求里的路径 → 真正要写的 board 根。
    ///
    /// 候选 = 面板当前 board + 所有已跟踪的 board（不额外做一次 dsh RPC）：Agent
    /// 的 cwd 常常是工作区的**子目录**，靠 TasksAPIWorkspace.resolve 的「最近祖先」
    /// 规则落回真正的 board（设计见 docs/design/panels/task-todo-skill-design.md §2.2）。
    private func apiResolveWorkspace(_ requested: String?) -> String? {
        var candidates: [String] = []
        if let current = workspaces.currentPath { candidates.append(current) }
        candidates.append(contentsOf: workspaces.trackedPaths)
        return TasksAPIWorkspace.resolve(requested: requested, candidates: candidates)
            ?? workspaces.currentPath
    }

    /// 任务面板的 board 根：请求指定的、面板当前正在看的，或 nil（还没 adopt 任何
    /// 工作区 —— 早期启动或没有活动项目）。
    ///
    /// 必须在主线程调用（board 的读改写要与 step 定时器同一条线程；桥接层负责派发）。
    private func apiRunner(for workspace: String?) -> (path: String, runner: TasksRunner)? {
        guard let path = apiResolveWorkspace(workspace) else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        guard let runner = workspaces.runner(for: path) else { return nil }
        return (path, runner)
    }

    private static func apiNoWorkspace(_ workspace: String?) -> [String: Any] {
        var result: [String: Any] = [
            "ok": false,
            "error": "no-workspace",
            "hint": "the tasks panel has no workspace yet — open a project in oh-my-dsh, or pass \"workspace\"",
        ]
        if let workspace = workspace, !workspace.isEmpty { result["requested"] = workspace }
        return result
    }

    /// GET /api/tasks/task/list —— 面板里现在有什么（任务 + 队列）。
    func apiTaskList(workspace: String?) -> [String: Any] {
        guard let (path, runner) = apiRunner(for: workspace) else {
            return Self.apiNoWorkspace(workspace)
        }
        let board = runner.board
        let tasks = board.tasks.map { task in
            TasksAPIRouter.taskDictionary(task, queueName: task.queueId.flatMap { board.queue($0)?.name })
        }
        return [
            "ok": true,
            "workspace": path,
            "current": path == workspaces.currentPath,
            "counts": ["tasks": board.tasks.count, "queues": board.queues.count],
            "tasks": tasks,
            "queues": board.queues.map {
                TasksAPIRouter.queueDictionary($0, reportsToSession: board.local.queueSessions[$0.id] != nil)
            },
        ]
    }

    /// POST /api/tasks/task/create —— 批量创建手动任务。
    ///
    /// 与用户在面板里点「新建任务」走同一条路径（TasksRunner.createManualTask）：
    /// 落盘、日志、重绘都由它负责。任务一律是「待处理、未入队」——**建任务不启动
    /// 任何东西**；队列与运行仍由用户在面板上决定。
    func apiTaskCreate(workspace: String?, focus: Bool, drafts: [TaskCreateDraft]) -> [String: Any] {
        let requested = workspace
        guard let (path, runner) = apiRunner(for: requested) else {
            return Self.apiNoWorkspace(requested)
        }

        // focus：用户刚要求建的任务就该看得见 —— 切到那个 board 并展开面板。
        // 非 focus：只落盘，用户切过去时 board 已经在磁盘上（面板会读）。
        if focus {
            if path != workspaces.currentPath { adoptWorkspace(path) }
            onShowPanel?()
        }

        var created: [[String: Any]] = []
        var rejected: [[String: Any]] = []
        for draft in drafts {
            let taskDraft = TaskDraft(title: draft.title, body: draft.body ?? "")
            guard let task = runner.createManualTask(taskDraft) else {
                rejected.append(["title": draft.title, "error": "invalid"])
                continue
            }
            created.append(["id": task.id, "title": task.title])
        }

        if path == workspaces.currentPath {
            syncFromBoard()
            if !created.isEmpty {
                setStatus(L10n.tr("tasks.apiCreated", created.count), spin: false)
                autoHideStatus(after: 8)
            }
        }
        AppLog.shared.log("tasks api: created \(created.count)/\(drafts.count) task(s) at \(path)"
                          + (rejected.isEmpty ? "" : " (rejected \(rejected.count))"))

        return [
            "ok": !created.isEmpty,
            "workspace": path,
            "current": path == workspaces.currentPath,
            "shown": focus,
            "created": created,
            "rejected": rejected,
        ]
    }

    /// POST /api/tasks/queue/create —— 建一个「等待态」队列（.draft）并批量入队。
    ///
    /// 与面板内「新建队列」走同一条落盘路径（TasksRunner.createQueueWithTasks），但
    /// 任务直接入队且**不激活队列**：等用户 / 会话说「启动队列」。带 session 时记录
    /// 来源会话，队列跑到 .done 时把完成情况回传给它。
    func apiTaskQueueCreate(_ request: TaskQueueCreateRequest) -> [String: Any] {
        guard let (path, runner) = apiRunner(for: request.workspace) else {
            return Self.apiNoWorkspace(request.workspace)
        }
        if request.focus {
            if path != workspaces.currentPath { adoptWorkspace(path) }
            onShowPanel?()
        }
        let drafts = request.drafts.map { TaskDraft(title: $0.title, body: $0.body ?? "") }
        let result = runner.createQueueWithTasks(name: request.name,
                                                 branch: request.branch,
                                                 baseBranch: request.baseBranch,
                                                 autoPR: request.autoPR,
                                                 originSession: request.session,
                                                 drafts: drafts)
        if path == workspaces.currentPath {
            syncFromBoard()
            if !result.created.isEmpty {
                setStatus(L10n.tr("tasks.apiQueueCreated", result.queue.name, result.created.count), spin: false)
                autoHideStatus(after: 8)
            }
        }
        AppLog.shared.log("tasks api: created queue \(result.queue.id) with \(result.created.count) task(s) at \(path)"
                          + (request.session.map { " (reports to \($0))" } ?? ""))
        return [
            "ok": !result.created.isEmpty,
            "workspace": path,
            "current": path == workspaces.currentPath,
            "shown": request.focus,
            "queue": TasksAPIRouter.queueDictionary(result.queue, reportsToSession: request.session != nil),
            "created": result.created.map { ["id": $0.id, "title": $0.title, "state": $0.state.rawValue] },
            "rejected": [[String: Any]](),
        ]
    }

    /// POST /api/tasks/queue/start —— 启动等待态（或暂停）的队列。
    ///
    /// 有 queueId 就启动它；没有则用 session 找「本会话创建、仍在 .draft」的队列 ——
    /// 恰好一个才启动，多个返回 ambiguous-queue 让会话 / 用户点名。
    func apiTaskQueueStart(_ request: TaskQueueStartRequest) -> [String: Any] {
        guard let (path, runner) = apiRunner(for: request.workspace) else {
            return Self.apiNoWorkspace(request.workspace)
        }
        let board = runner.board
        if let queueId = request.queueId {
            guard let queue = board.queue(queueId) else {
                return ["ok": false, "error": "no-queue", "queueId": queueId]
            }
            guard queue.state == .draft || queue.state == .paused else {
                return ["ok": false, "error": "not-startable",
                        "queueId": queueId, "state": queue.state.rawValue]
            }
            _ = runner.startQueue(queueId)
            return ["ok": true, "workspace": path, "started": [queueId]]
        }
        // 按名字启动：比 session 更直接（同名多个时返回候选，让调用方消歧）。
        if let name = request.name, !name.isEmpty {
            let matches = board.queues.filter { $0.name == name }
            if matches.isEmpty { return ["ok": false, "error": "no-queue", "name": name] }
            if matches.count > 1 {
                return ["ok": false, "error": "ambiguous-queue",
                        "queues": matches.map {
                            TasksAPIRouter.queueDictionary($0, reportsToSession: board.local.queueSessions[$0.id] != nil)
                        }]
            }
            let queue = matches[0]
            guard queue.state == .draft || queue.state == .paused else {
                return ["ok": false, "error": "not-startable",
                        "queueId": queue.id, "state": queue.state.rawValue]
            }
            _ = runner.startQueue(queue.id)
            return ["ok": true, "workspace": path, "started": [queue.id]]
        }
        guard let session = request.session, !session.isEmpty else {
            return ["ok": false, "error": "need-session",
                    "hint": "pass queueId, name, or session to start the draft queue that session created"]
        }
        let candidates = board.queues.filter {
            $0.state == .draft && board.local.queueSessions[$0.id] == session
        }
        if candidates.isEmpty { return ["ok": false, "error": "no-queue"] }
        if candidates.count > 1 {
            return ["ok": false, "error": "ambiguous-queue",
                    "queues": candidates.map { TasksAPIRouter.queueDictionary($0, reportsToSession: true) }]
        }
        let queueId = candidates[0].id
        _ = runner.startQueue(queueId)
        return ["ok": true, "workspace": path, "started": [queueId]]
    }

    /// POST /api/tasks/queue/append —— 向**已有**队列追加任务（会话里「再补几条」）。
    /// 目标按 queueId → name → session（本会话创建的非关闭队列）解析；不启动。
    func apiTaskQueueAppend(_ request: TaskQueueAppendRequest) -> [String: Any] {
        guard let (path, runner) = apiRunner(for: request.workspace) else {
            return Self.apiNoWorkspace(request.workspace)
        }
        let board = runner.board
        let target: TaskQueue?
        if let queueId = request.queueId {
            target = board.queue(queueId)
        } else if let name = request.name {
            let matches = board.queues.filter { $0.name == name && $0.state != .closed }
            if matches.count > 1 {
                return ["ok": false, "error": "ambiguous-queue",
                        "queues": matches.map {
                            TasksAPIRouter.queueDictionary($0, reportsToSession: board.local.queueSessions[$0.id] != nil)
                        }]
            }
            target = matches.first
        } else if let session = request.session {
            let matches = board.queues.filter {
                $0.state != .closed && board.local.queueSessions[$0.id] == session
            }
            if matches.count > 1 {
                return ["ok": false, "error": "ambiguous-queue",
                        "queues": matches.map { TasksAPIRouter.queueDictionary($0, reportsToSession: true) }]
            }
            target = matches.first
        } else {
            target = nil
        }
        guard let queue = target else { return ["ok": false, "error": "no-queue"] }
        guard queue.state != .closed else {
            return ["ok": false, "error": "queue-closed", "queueId": queue.id]
        }
        let drafts = request.drafts.map { TaskDraft(title: $0.title, body: $0.body ?? "") }
        let created = runner.appendTasks(toQueueID: queue.id, drafts: drafts)
        if path == workspaces.currentPath {
            syncFromBoard()
            if !created.isEmpty {
                setStatus(L10n.tr("tasks.apiQueueAppended", queue.name, created.count), spin: false)
                autoHideStatus(after: 8)
            }
        }
        AppLog.shared.log("tasks api: appended \(created.count) task(s) to queue \(queue.id) at \(path)")
        return [
            "ok": !created.isEmpty,
            "workspace": path,
            "queue": TasksAPIRouter.queueDictionary(runner.board.queue(queue.id) ?? queue,
                                                    reportsToSession: board.local.queueSessions[queue.id] != nil),
            "created": created.map { ["id": $0.id, "title": $0.title, "state": $0.state.rawValue] },
            "rejected": [[String: Any]](),
        ]
    }

    /// POST /api/tasks/queue/deliver —— 发起一条**已完成**队列的交付。
    ///
    /// 与队列头的「交付」按钮走同一条路径（TasksRunner.startQueueIntegration）：按该
    /// 队列的 Git 工作流开 PR / 合并到基线 / 直接推送。只发起、不等待，结果由交付会话
    /// 回写到队列卡片。目标按 queueId → name → session（本会话的非关闭队列）解析；
    /// 只接受 .done（与按钮的可见条件一致），工作流「无」直接拒绝。
    func apiTaskQueueDeliver(_ request: TaskQueueDeliverRequest) -> [String: Any] {
        guard let (path, runner) = apiRunner(for: request.workspace) else {
            return Self.apiNoWorkspace(request.workspace)
        }
        let board = runner.board
        let target: TaskQueue?
        if let queueId = request.queueId {
            target = board.queue(queueId)
        } else if let name = request.name {
            let matches = board.queues.filter { $0.name == name && $0.state != .closed }
            if matches.count > 1 {
                return ["ok": false, "error": "ambiguous-queue",
                        "queues": matches.map {
                            TasksAPIRouter.queueDictionary($0, reportsToSession: board.local.queueSessions[$0.id] != nil)
                        }]
            }
            target = matches.first
        } else if let session = request.session {
            let matches = board.queues.filter {
                $0.state != .closed && board.local.queueSessions[$0.id] == session
            }
            if matches.count > 1 {
                return ["ok": false, "error": "ambiguous-queue",
                        "queues": matches.map { TasksAPIRouter.queueDictionary($0, reportsToSession: true) }]
            }
            target = matches.first
        } else {
            target = nil
        }
        guard let queue = target else { return ["ok": false, "error": "no-queue"] }
        guard queue.state == .done else {
            return ["ok": false, "error": "not-deliverable",
                    "queueId": queue.id, "state": queue.state.rawValue,
                    "hint": "only a finished (done) queue can be delivered"]
        }
        let mode = runner.resolvedIntegration(forQueue: queue.id)
        guard mode != QueueIntegration.none else {
            return ["ok": false, "error": "workflow-none", "queueId": queue.id,
                    "hint": "this queue's Git workflow is None — there is nothing to deliver"]
        }
        guard runner.startQueueIntegration(queue.id) else {
            // The runner recorded WHY on the queue (busy / no branch / no remote); a nil
            // reason here means 无, which the guard above already handled.
            let reason = runner.board.queue(queue.id)?.prError
            return ["ok": false, "error": Self.deliverErrorCode(reason),
                    "queueId": queue.id, "reason": reason ?? "",
                    "queue": TasksAPIRouter.queueDictionary(runner.board.queue(queue.id) ?? queue,
                                                            reportsToSession: board.local.queueSessions[queue.id] != nil)]
        }
        if path == workspaces.currentPath {
            syncFromBoard()
            setStatus(L10n.tr(Self.finalizeStatusKey(mode: mode), queue.name), spin: true)
        }
        AppLog.shared.log("tasks api: delivering queue \(queue.id) at \(path) (mode \(mode.rawValue))")
        return [
            "ok": true,
            "workspace": path,
            "current": path == workspaces.currentPath,
            "queue": TasksAPIRouter.queueDictionary(runner.board.queue(queue.id) ?? queue,
                                                    reportsToSession: board.local.queueSessions[queue.id] != nil),
            "delivering": [queue.id],
        ]
    }

    /// 把 runner 记录在队列上的拒绝对因（L10n 键）翻译成 API 的稳定错误码，让技能不用
    /// 认识面板的文案键也能转述原因。
    static func deliverErrorCode(_ reason: String?) -> String {
        switch reason {
        case "tasks.errPRBusy": return "busy"
        case "tasks.errPRNoBranch": return "no-branch"
        case "tasks.errPRNoRemote": return "no-remote"
        case "tasks.errPRSession": return "session-failed"
        default: return "deliver-failed"
        }
    }

    // MARK: - Board / runner wiring

    /// Build one workspace's runner (the registry's factory).
    ///
    /// `reconcile` is true only the FIRST time a workspace is loaded in this app
    /// run: then a task recorded as running cannot still be running (its session
    /// died with the app) and an active queue is paused, so NOTHING starts until
    /// the user says so. Re-adopting a workspace we have already seen in this run
    /// must NOT reconcile again — that is exactly the bug that made "switch away
    /// and come back" mark a running task as 失败.
    private func makeRunner(path: String, reconcile: Bool) -> TasksRunner? {
        var board = TasksStore.load(path)
        var recovered: (interrupted: [String], pausedQueues: [String]) = ([], [])
        if reconcile {
            recovered = board.reconcileAfterRestart(interruptedError: TaskFailure.interrupted.rawValue)
            TasksStore.saveLocalHalf(path, board)
        }
        // The repo SET is what this workspace is now (design §4.1): the header
        // counts it, the queue form picks among it, and the env hands each repo its
        // own git. Detection is blocking, so it happens here once — adoptWorkspace
        // reuses the cached answer for the header / forms.
        let repoSet = repoSetByPath[path] ?? Self.detectRepoSet(path)
        repoSetByPath[path] = repoSet
        // Issues still belong to ONE repo: the root's GitHub remote, else the
        // primary's (design §9 — 默认跟随主仓库).
        let detected = Self.issueRepo(root: path, repoSet: repoSet)
        let isGit = repoSet.gitAvailable
        let timeout = Self.taskTimeout()
        let runner = TasksRunner(board: board,
                                 env: makeEnv(repoRoot: path, repo: detected, isGit: isGit,
                                              repoSet: repoSet),
                                 timeout: timeout)
        let extra = recovered.interrupted.isEmpty ? "" : ", interrupted: " + recovered.interrupted.joined(separator: ",")
        AppLog.shared.log("tasks: board loaded at \(path) — \(board.tasks.count) tasks, \(board.queues.count) queues"
                          + (reconcile ? " (reconciled)" : "") + extra)
        // Say it out loud — but only for the workspace the user is looking at, and
        // only once per app run (see the reconcile note above).
        if reconcile, path == workspaces.currentPath,
           !recovered.interrupted.isEmpty || !recovered.pausedQueues.isEmpty {
            setStatus(L10n.tr("tasks.recovered", recovered.interrupted.count, recovered.pausedQueues.count),
                      spin: false)
            autoHideStatus(after: 10)
        }
        return runner
    }

    /// Everything the runner needs from the outside world: git in this repo, the
    /// dsh session RPC on this port, GitHub REST with this repo's token, and the
    /// four-file persistence under .dsh/tasks/.
    private func makeEnv(repoRoot: String, repo: (owner: String, repo: String)?,
                         isGit: Bool, repoSet: WorkspaceRepoSet = WorkspaceRepoSet()) -> TaskRunnerEnv {
        // The dsh web port is read AT CALL TIME, never frozen here.
        //
        // This env is built as soon as the panel adopts a workspace — which is
        // ~6s BEFORE `dsh web` is up (app.log: "workspace adopted" 00:51:37 vs
        // "dsh web is up on …:64679" 00:51:43). Until then `server.port` is still
        // the default 3080, so capturing it in a `let` pointed every session RPC
        // of that runner at a port nothing listens on: EVERY task failed with
        // tasks.errSession while the real server was perfectly reachable (the same
        // session/create answered fine over curl on 64679). The panel only rebuilds
        // the runner when the PATH changes, so the runner kept the dead port for the
        // rest of the app run.
        // `[weak self]` so the env does not retain the panel (the panel owns the
        // runner that owns this closure), and so a provider assigned later still
        // counts — the panel works before the shell has finished wiring itself up.
        let portOf: () -> Int = { [weak self] in self?.serverPortProvider?() ?? 3080 }
        // Per workspace, not per panel: two runners can be alive at once, each with
        // its own remote, token and PR policy.
        let token = repo.flatMap { loadToken(for: $0) }
        // The PRIMARY repo is the default git target (a legacy single-repo workspace
        // has the root as its primary; a plain directory has none and keeps repoRoot).
        // Per-repo handles live in gitFor below (design §5.1).
        let primaryPath = repoSet.primary?.absolutePath ?? repoRoot
        return TaskRunnerEnv(
            git: TaskGit(run: { args in
                              Self.runProcess("/usr/bin/git", ["-C", primaryPath] + args, cwd: primaryPath)
                          },
                          remoteName: { Self.pushRemoteName(path: primaryPath) }),
            repoRoot: repoRoot,
            createSession: { cwd in
                // Both the port and the workspaceId are resolved now, not when the
                // runner was built: the workspace may have been registered with dsh
                // after the board loaded (and `workspaceId` is read from the store
                // dsh persists, which the shell does not own).
                let port = portOf()
                return Self.createSession(port: port,
                                          workspaceId: Self.resolveMainWorkspaceId(port: port, path: repoRoot),
                                          cwd: cwd)
            },
            renameSession: { id, title in Self.renameSession(port: portOf(), sessionId: id, title: title) },
            promptSession: { id, text in Self.promptSession(port: portOf(), sessionId: id, text: text) },
            sessionState: { id in Self.sessionState(port: portOf(), sessionId: id) },
            defaultBaseBranch: Self.detectDefaultBaseBranch(path: repoRoot),
            // 队列没写自己的 integration 时用它（面板设置里可改；**按工作区**存）。
            defaultIntegration: Self.resolvedIntegration(forWorkspace: repoRoot, isGit: isGit,
                                                         hasGitHubRemote: repo != nil),
            // 交付成功后自动关闭队列（面板设置；**按工作区**存 —— 和其他设置项一样）。
            autoCloseOnPublish: Self.storedAutoCloseOnPublish(forWorkspace: repoRoot),
            canSwitchBranches: isGit,
            canOpenPR: { repo != nil },
            cancelSession: { id in Self.cancelSession(port: portOf(), sessionId: id) },
            // Only a LOOKUP: the PR itself is created by the queue 开 PR 会话 (the
            // runner startQueuePR), because its title and body have to summarize the
            // real diff rather than fill a template — and because pushing the branch
            // is that session job too.
            findExistingPR: { branch in
                guard let repo = repo else { return nil }
                return Self.findExistingPR(owner: repo.owner, repo: repo.repo, branch: branch, token: token)
            },
            promptText: { task, queue, brief in
                // 两种来源共用同一套要求（TaskPrompts.requirements），**只有头不同**
                // （issue 头 = 编号/标题/标签/正文；手动任务头 = 标题/描述）：2026-09-27
                // 对齐。此前 issue 走一段写死的 5 条、还要求加载 issue-resolve 技能，
                // 而那个技能停在「任务自己 push、PR 由面板开」的旧政策里 —— 同一个面板
                // 于是有两种行为，issue 任务还会 push（手动任务只 commit）。
                // An AUTO queue (an issue task's, or the one 全部处理 makes for a
                // single manual task) is not a shared lane: it will never hold
                // another task, so 「与其他任务共享同一分支与改动」 would be false.
                // A user-made lane always names itself, even while it holds one task.
                let sharedQueueName = queue.flatMap { $0.autoCreated ? nil : $0.name }
                // What this workspace IS, asked AGAIN here rather than taken from the
                // isGit/repo this env was built with: the workspace converts (git init,
                // git remote add …), and the task that does the converting may be the one
                // just before this one IN THE SAME QUEUE. A queue never goes idle between
                // its own tasks, so the panel's re-detection (recheckWorkspaceShape)
                // cannot rebuild the runner in time — the prompt is the one place that
                // can still tell the truth, and it is written on the runner's background
                // queue, so the probe costs the UI nothing.
                let shape = Self.repoShape(path: repoRoot)
                // Prompt targets follow the LIVE repo set (design §5): a workspace
                // can gain or lose repositories between tasks. P1's default target
                // is the primary; a queue-level target set arrives with delivery (P3).
                let liveSet = Self.detectRepoSet(repoRoot)
                let targets: [TaskPromptTarget]
                if let primary = liveSet.primary {
                    targets = [TaskPromptTarget(
                        repoID: primary.id,
                        shape: TaskRepoShape.detect(isGit: primary.isGit,
                                                    hasGitHubRemote: primary.github != nil),
                        defaultBase: primary.defaultBase)]
                } else {
                    targets = [TaskPromptTarget(repoID: ".", shape: shape)]
                }
                // 队列自己的「基于分支」；不在队列里的任务用工作区的默认分支 —— 两条
                // 分支 rail 都会点名它（「若无分支，须基于 X 新建」/「直接在主分支 X 上处理」）。
                let base = queue?.baseBranch ?? Self.detectDefaultBaseBranch(path: repoRoot)
                if task.source == .github {
                    return TaskPrompts.issue(number: task.number ?? 0, title: task.title,
                                             body: task.body, labels: task.labels,
                                             branch: queue?.branch, queueName: sharedQueueName,
                                             base: base,
                                             brief: brief,
                                             shape: shape,
                                             targets: targets)
                }
                return TaskPrompts.manual(title: task.title, body: task.body,
                                          branch: queue?.branch, queueName: sharedQueueName,
                                          base: base,
                                          brief: brief,
                                          shape: shape,
                                          targets: targets)
            },
            // The 交接简报: what the previous task in this queue last said. Read
            // through the shell's core bridge (the same session logs the audit panel
            // uses) — the runner calls it off the main thread.
            sessionReport: { sessionId in Self.sessionReport(sessionId: sessionId, workspace: repoRoot) },
            // 队列完成回传：把报告投给创建队列的那个会话（同样是 session.prompt，
            // mode=queue）—— 这就是「做完把完成情况发回 dsh 会话 X」的落点。
            notifySession: { sessionId, text in
                Self.promptSession(port: portOf(), sessionId: sessionId, text: text)
            },
            persist: { board in TasksStore.saveLocalHalf(repoRoot, board) },
            persistIssueTask: { task in TasksStore.saveIssueTask(repoRoot, task) },
            log: { message in AppLog.shared.log(message) },
            perform: { blocking, completion in
                DispatchQueue.global(qos: .userInitiated).async {
                    blocking()
                    DispatchQueue.main.async { completion() }
                }
            },
            // The workspace repo set and one git handle per repo (design §5.1) —
            // the per-repo pipeline (pre-flight / branch / brief) is P2; today the
            // legacy `git` field above already points at the primary.
            repos: repoSet.repos,
            gitFor: { repo in
                TaskGit(run: { args in
                             Self.runProcess("/usr/bin/git", ["-C", repo.absolutePath] + args,
                                             cwd: repo.absolutePath)
                         },
                         remoteName: { Self.pushRemoteName(path: repo.absolutePath) })
            }
        )
    }

    /// No workspace resolved: show the empty state. Any OTHER workspace whose task
    /// is running stays tracked (its board is not this panel's to drop) — only the
    /// current board goes away.
    private func clearBoard() {
        workspaces.clearCurrent()
        expandedTaskID = nil
        queueToggle.removeAll()
        expandedQueueNotes.removeAll()
        render()
        updateLabels()
        updateOtherWorkspaces()
    }

    /// Cheap fingerprint of everything the list renders, so the 3-second step
    /// timer does not rebuild the cards (and fight the user's scrolling, or drop
    /// an open menu) while nothing is moving.
    private var boardSignature = ""

    private func boardSignatureNow() -> String {
        guard let runner = runner else { return "" }
        let tasks = runner.board.tasks.map { $0.id + ":" + $0.state.rawValue + ":" + ($0.prUrl ?? "") }
        // The queue's own RESULT fields are part of what the card shows: a publish
        // that clears prError or writes integrationNote/prUrl changes only these, so
        // without them the 3s timer saw "nothing changed" and the card kept showing
        // the old error / no result (user 2026-10-01).
        let queues: [String] = runner.board.queues.map { queue -> String in
            let id = queue.id
            let state = queue.state.rawValue
            let count = String(queue.taskIds.count)
            let error = queue.prError ?? ""
            let url = queue.prUrl ?? ""
            let note = queue.integrationNote ?? ""
            return id + ":" + state + ":" + count + ":" + error + ":" + url + ":" + note
        }
        // The running task's clock is part of what the cards SHOW, so the 3s timer
        // has to redraw when its minute flips — otherwise "已运行 0:59" would sit
        // there forever (the board itself has not changed at all).
        let clock = runner.board.tasks.first { $0.state == .running }
            .flatMap { $0.startedAt.map { TaskCardModel.duration(from: $0, to: Date()) } } ?? "-"
        return (tasks + queues + [clock]).joined(separator: "|")
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

    /// One tick for EVERY tracked workspace: the visible one, and any other one
    /// whose task is still running (that is the whole point of tracking them at
    /// once — see TaskWorkspaceRegistry).
    private func stepRunner() {
        let wasBusy = workspaces.isBusy
        let currentWasBusy = runner?.isBusy ?? false
        Self.beginSessionPoll()          // one session list for all of them
        let finished = workspaces.step()
        for done in finished {
            // Tell the shell so it can get the user's attention when the app is in
            // the background. A cancel the user asked for is not news (the runner
            // filters those out), and the workspace is named so the message is
            // actionable.
            onTaskFinished?(done.path, done.title, done.ok)
            // …and say it HERE too: with several workspaces tracked at once, a task
            // that finishes while the user is looking at another one would otherwise
            // only exist in the log.
            if done.path != workspaces.currentPath {
                let name = (done.path as NSString).lastPathComponent
                setStatus(L10n.tr(done.ok ? "tasks.otherFinished" : "tasks.otherFailed", name, done.title),
                          spin: false)
                autoHideStatus(after: 8)
            }
        }
        // A task can change the SHAPE of the workspace it ran in: 「初始化 git 仓库」
        // is exactly that — the directory was not a repository when the panel adopted
        // it, and everything decided back then (the header's 非 Git 仓库, whether the
        // queue form may name a branch, whether 全部处理 asks for branches at all) is
        // wrong now. Check when a task finished here, and again when the workspace goes
        // idle: a queue starts its next task in the very tick its previous one finished.
        if !finished.isEmpty || (currentWasBusy && !workspaces.isBusy) {
            recheckWorkspaceShape()
        }
        syncFromBoardIfChanged()
        if wasBusy != workspaces.isBusy { onRunStateChanged?(workspaces.isBusy) }
        if let runner = runner, runner.isBusy {
            if let queueID = runner.openingPRQueueID {
                // No task is running: the serial slot belongs to the queue's finalize
                // session — say which workflow it is running.
                let name = runner.board.queue(queueID)?.name ?? ""
                let mode = runner.board.integration(forQueue: queueID, default: workspaceIntegration)
                setStatus(L10n.tr(Self.finalizeStatusKey(mode: mode), name), spin: true)
            } else {
                let number = runner.runningTaskID.flatMap { runner.board.task($0)?.number } ?? 0
                setStatus(L10n.tr("tasks.running", number), spin: true)
            }
        } else if currentWasBusy {
            hideStatus()
        }
        updateOtherWorkspaces()
    }
    /// Re-detect a workspace whose SHAPE a finished task may have changed.
    ///
    /// The panel decides everything about a workspace when it ADOPTS it (is it a git
    /// repository? which base branch? which remote?) and hands those same facts to the
    /// runner's env. A task can make all of that stale — the plainest example being a
    /// task whose whole point is `git init`. Nothing else in the app notices, so the
    /// user is left with a header that says 非 Git 仓库 in a directory that is one.
    private func recheckWorkspaceShape() {
        guard let path = workspaces.currentPath else { return }
        // Re-detect the whole repository set, not just「is the root a repo now」: a
        // container workspace can gain or lose a CHILD repository while its root is
        // not a repository at all (design §4.3). This runs after a task finished /
        // the workspace went idle — never on the steady-state tick.
        let repoSetNow = Self.detectRepoSet(path)
        let repoIDsNow = repoSetNow.repos.map { $0.id }
        let isGitNow = repoSetNow.gitAvailable
        let hasRemoteNow = repoSetNow.prAvailable
        guard let shape = TaskWorkspaceShape.change(wasRepoIDs: workspaceRepoSet.repos.map { $0.id },
                                                     repoIDsNow: repoIDsNow,
                                                     wasGit: workspaceIsGit,
                                                     hadRemote: repo != nil,
                                                     isGitNow: isGitNow,
                                                     hasRemoteNow: hasRemoteNow),
              let messageKey = shape.messageKey else { return }
        // The runner env captured the repo set when it was built, so the runner has
        // to be rebuilt — but only with NOTHING in flight in this workspace: two
        // runners on one board would step the same task twice. (The next finish, or
        // the go-idle call, tries again.)
        guard workspaces.trackedRunner(for: path)?.isBusy != true else { return }
        AppLog.shared.log("tasks: workspace re-detected at \(path)"
                          + " (repos=\(repoIDsNow.joined(separator: ",")), git=\(isGitNow ? "yes" : "no"), github=\(hasRemoteNow ? "yes" : "no"))"
                          + " — runner rebuilt for the new shape")
        workspaces.invalidate(path)
        adoptWorkspace(path)
        setStatus(L10n.tr(messageKey), spin: false)
        autoHideStatus(after: 8)
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
    /// repository (docs/design/panels/issue-runner-design.md §V2-7).
    private func adoptWorkspace(_ path: String) {
        // The repo SET is the workspace shape now (multi-repo, P1b): detect it once,
        // cache it for the runner env, and derive the legacy single-root facts from
        // the primary. Always fresh: recheckWorkspaceShape re-adopts precisely
        // because the set changed, so a cache hit here would hide the change.
        let repoSet = Self.detectRepoSet(path)
        repoSetByPath[path] = repoSet
        workspaceRepoSet = repoSet
        let detected = Self.issueRepo(root: path, repoSet: repoSet)
        let sameBoard = (workspaces.currentPath == path) && runner != nil
        repo = detected
        repoRootPath = path
        let github = detected.map { $0.owner + "/" + $0.repo } ?? "-"
        workspaceIsGit = repoSet.gitAvailable
        workspaceDefaultBase = repoSet.primary?.defaultBase ?? "main"
        // Any remote (not only GitHub) counts — push needs somewhere to push to.
        // Merge does not: it is a local operation.
        workspaceHasRemote = repoSet.repos.contains { $0.remoteName != nil }
        AppLog.shared.log("tasks: workspace adopted at \(path) (github=\(github) git=\(workspaceIsGit ? "yes" : "no") base=\(workspaceDefaultBase) repos=\(repoSet.repos.count))")
        updateLabels()
        if !sameBoard {
            // Switching workspaces does NOT stop tracking the one we leave: its
            // task keeps running (and keeps being stepped) until it is over. Only
            // the first load of a workspace reconciles its board (see makeRunner).
            workspaces.adopt(path)
            expandedTaskID = nil
            queueToggle.removeAll()
            expandedQueueNotes.removeAll()
            boardSignature = ""
            startStepTimer()
        }
        reloadIssues()
        syncFromBoard()
        updateOtherWorkspaces()
    }

    // MARK: - Other workspaces with work in flight

    /// Refresh the header's "other workspaces" entry: which ones are running
    /// something right now, and what. Hidden when the answer is "none", which is
    /// the normal case and must cost nothing on screen.
    private func updateOtherWorkspaces() {
        otherBusyPaths = workspaces.busyPaths()
            .filter { $0 != workspaces.currentPath }
            .map { path in
                let runner = workspaces.trackedRunner(for: path)
                let title = runner?.runningTaskID.flatMap { runner?.board.task($0)?.title } ?? ""
                return (path: path, title: title)
            }
        otherWorkspacesButton.isHidden = otherBusyPaths.isEmpty
        guard !otherBusyPaths.isEmpty else {
            otherWorkspacesButton.toolTip = ""
            return
        }
        otherWorkspacesButton.toolTip = L10n.tr("tasks.otherWorkspacesHint", otherBusyPaths.count) + "\n"
            + otherBusyPaths.map { entry in
                "• " + (entry.path as NSString).lastPathComponent
                    + (entry.title.isEmpty ? "" : " — " + entry.title)
            }.joined(separator: "\n")
    }

    /// The button drops a menu of those workspaces: picking one asks the shell to
    /// re-root there (the same path the Projects panel's quick entries take).
    @objc private func otherWorkspacesTapped() {
        guard !otherBusyPaths.isEmpty else { return }
        let menu = NSMenu(title: L10n.tr("tasks.otherWorkspaces", otherBusyPaths.count))
        for entry in otherBusyPaths {
            let title = (entry.path as NSString).lastPathComponent
                + (entry.title.isEmpty ? "" : " — " + entry.title)
            let item = NSMenuItem(title: title, action: #selector(otherWorkspaceChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.path
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -6), in: otherWorkspacesButton)
    }

    @objc private func otherWorkspaceChosen(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        onSelectWorkspace?(path)
    }

    /// The workspace's OWN default branch, asked of git (the decision chain lives
    /// in TaskBranch.defaultBaseBranch, which is what the tests pin):
    /// origin/HEAD → local main → local master → the checked-out branch → "main".
    ///
    /// Assuming "main" made a repo whose default branch is master/develop fail its
    /// very first issue task with 「切换分支失败」.
    static func detectDefaultBaseBranch(path: String) -> String {
        // The remote the runner pushes to (github > origin > first — the codebase's
        // own preference) is the one whose HEAD names the default branch. Asking for
        // "origin" specifically misses a repo whose only remote is called "github".
        let remote = pushRemoteName(path: path)
        let remoteHead = remote.flatMap { name in
            runProcess("/usr/bin/git", ["-C", path, "symbolic-ref", "--short",
                                        "refs/remotes/\(name)/HEAD"])
        }
        let current = runProcess("/usr/bin/git", ["-C", path, "rev-parse", "--abbrev-ref", "HEAD"])
        let hasMain = runProcess("/usr/bin/git",
                                 ["-C", path, "rev-parse", "--verify", "--quiet", "main"]) != nil
        let hasMaster = runProcess("/usr/bin/git",
                                   ["-C", path, "rev-parse", "--verify", "--quiet", "master"]) != nil
        return TaskBranch.defaultBaseBranch(symbolicRef: remoteHead, current: current,
                                           hasMain: hasMain, hasMaster: hasMaster)
    }

    /// How long a task may run. 60 minutes by default; a shell-config override
    /// ("tasksTimeoutMinutes", e.g. in ~/.dsh/shell/config.json or via
    /// `defaults write`) wins when it is a sane number. The running card SHOWS the
    /// limit, so it is never a surprise.
    // MARK: - 面板设置 (EVERYTHING PER WORKSPACE)

    /// **Every** 面板设置 item is **per workspace** (决策 2026-10-01): one panel serves
    /// very different directories at once (a GitHub repo wanting a PR, a scratch dir a
    /// direct push, a demo repo that must never auto-close), so a single shell-wide
    /// value cannot be right for all of them. Stored in ShellConfig as a path → value
    /// map (the shell's own config store, NOT inside the user's repository). The GitHub
    /// token is the one exception: it is per-REPO (see loadToken), because the same
    /// repo is the same credential.
    ///
    /// Standardized key, so a trailing slash / `..` does not create a second entry
    /// (the same normalization TaskWorkspaceRegistry.needsReadopt uses).
    static func workspaceSettingsKey(_ path: String) -> String {
        let standardized = (path as NSString).standardizingPath
        if standardized.count > 1, standardized.hasSuffix("/") {
            return String(standardized.dropLast())
        }
        return standardized
    }

    // MARK: - 工作流 default (PER WORKSPACE)

    /// The tasks-panel 工作流 default is **per workspace** (see the panel-settings note
    /// above): a GitHub repo usually wants a PR, a scratch directory a direct push, and
    /// one value for the whole shell cannot be both. A queue's own `integration` still
    /// overrides it. If a GLOBAL default is ever wanted, it belongs in the shell's
    /// settings, not in this panel.
    private static let integrationByWorkspaceKey = "tasksIntegrationByWorkspace"

    /// The mode saved for this workspace, or nil when it was never set.
    static func storedIntegration(forWorkspace path: String) -> QueueIntegration? {
        guard let map = ShellConfig.shared.object(forKey: integrationByWorkspaceKey) as? [String: Any],
              let raw = map[workspaceSettingsKey(path)] as? String else { return nil }
        return QueueIntegration(rawValue: raw)
    }

    static func setStoredIntegration(_ mode: QueueIntegration, forWorkspace path: String) {
        var map = (ShellConfig.shared.object(forKey: integrationByWorkspaceKey) as? [String: Any]) ?? [:]
        map[workspaceSettingsKey(path)] = mode.rawValue
        ShellConfig.shared.set(map, forKey: integrationByWorkspaceKey)
    }

    /// What a queue without its own override uses here: the saved value, else this
    /// workspace's RECOMMENDATION — so the panel is sensible before anyone sets it,
    /// and 首次打开设置时默认选中的就是这一档.
    static func resolvedIntegration(forWorkspace path: String, isGit: Bool,
                                    hasGitHubRemote: Bool) -> QueueIntegration {
        storedIntegration(forWorkspace: path)
            ?? QueueIntegration.recommended(isGit: isGit, hasGitHubRemote: hasGitHubRemote)
    }

    /// This workspace's resolved 工作流 default (设置抽屉 / 队列头的 fallback).
    private var workspaceIntegration: QueueIntegration {
        guard let path = repoRootPath else { return .pr }
        return Self.resolvedIntegration(forWorkspace: path, isGit: workspaceIsGit,
                                        hasGitHubRemote: repo != nil)
    }

    /// The repos a queue form may pick from: the whole set in multi-repo mode,
    /// none in the single-repo / plain shapes (the form then looks exactly like
    /// today — no selector at all, design §8).
    private var repoPickerRepos: [WorkspaceRepo] {
        workspaceRepoSet.isMultiRepo ? workspaceRepoSet.repos : []
    }

    // MARK: - 交付成功后自动关闭队列 (PER WORKSPACE)

    /// 交付成功后自动关闭队列 —— **per workspace**, like every other 面板设置 item
    /// (决策 2026-10-01: the user asked the whole settings drawer to be workspace-
    /// isolated). A path → Bool map; **off until THIS workspace is set**, so one
    /// workspace's choice never leaks into another. The runner env snapshots this value
    /// when the workspace is adopted, so a change here affects this workspace's next
    /// finalize only.
    private static let autoCloseByWorkspaceKey = "tasksAutoCloseOnPublishByWorkspace"

    static func storedAutoCloseOnPublish(forWorkspace path: String) -> Bool {
        guard let map = ShellConfig.shared.object(forKey: autoCloseByWorkspaceKey) as? [String: Any],
              let on = map[workspaceSettingsKey(path)] as? Bool else { return false }
        return on
    }

    static func setStoredAutoCloseOnPublish(_ on: Bool, forWorkspace path: String) {
        var map = (ShellConfig.shared.object(forKey: autoCloseByWorkspaceKey) as? [String: Any]) ?? [:]
        map[workspaceSettingsKey(path)] = on
        ShellConfig.shared.set(map, forKey: autoCloseByWorkspaceKey)
    }

    static func taskTimeout() -> TimeInterval {
        if let minutes = ShellConfig.shared.object(forKey: "tasksTimeoutMinutes") as? Int,
           minutes >= 5, minutes <= 24 * 60 {
            return TimeInterval(minutes * 60)
        }
        return TasksRunner.defaultTimeout
    }

    /// Detect a workspace's repository set (design §4.1). BLOCKING (git), so it
    /// runs where the existing adopt probes run. The user's
    /// `tasksPrimaryRepoByWorkspace` pick resolves the primary; a stale one falls
    /// back to the automatic rule (root → first GitHub → first git).
    static func detectRepoSet(_ path: String) -> WorkspaceRepoSet {
        let set = WorkspaceRepoSet.detect(root: path,
                                          primaryRepoID: storedPrimaryRepoID(forWorkspace: path))
        guard set.repos.isEmpty, isGitRepo(path) else { return set }
        // A workspace registered to a SUBDIRECTORY of a repository is inside a work
        // tree but is not its top level. detect() only takes the root when it IS the
        // top level, so fall back to the legacy single-repo view rather than calling
        // the directory plain and taking git away from it.
        let probe = WorkspaceRepoProbe.live
        let root = WorkspaceRepo(id: ".", absolutePath: path, isGit: true,
                                 defaultBase: probe.defaultBase(path),
                                 remoteName: probe.remoteName(path),
                                 github: probe.github(path),
                                 displayName: (path as NSString).lastPathComponent)
        return WorkspaceRepoSet(repos: [root], primary: root)
    }

    /// The user's explicit primary-repo pick for a workspace, or nil.
    static func storedPrimaryRepoID(forWorkspace path: String) -> String? {
        guard let map = ShellConfig.shared.object(forKey: "tasksPrimaryRepoByWorkspace") as? [String: Any],
              let id = map[workspaceSettingsKey(path)] as? String, !id.isEmpty else { return nil }
        return id
    }

    /// The repo ISSUES belong to: the root's GitHub remote, else the primary's
    /// (design §9: default to the primary, never silently to another one).
    static func issueRepo(root: String, repoSet: WorkspaceRepoSet) -> (owner: String, repo: String)? {
        if let root = detectGitHubRemote(root) { return root }
        guard let github = repoSet.primary?.github else { return nil }
        return (github.owner, github.name)
    }

    /// True when the directory is inside a git work tree.
    static func isGitRepo(_ path: String) -> Bool {
        Self.runProcess("/usr/bin/git", ["-C", path, "rev-parse", "--is-inside-work-tree"]) == "true"
    }

    /// What this workspace IS, in the three states a task prompt tells apart
    /// (TaskRepoShape) — the directory the prompt is written for, not the one the
    /// panel adopted hours ago: 非 git 目录 → git 仓库 → GitHub 仓库 are conversions a
    /// TASK performs (git init / git remote add origin <url>), and the task after it
    /// has to be told the new story. One git rev-parse, and a git remote -v only when
    /// there is a repository at all.
    static func repoShape(path: String) -> TaskRepoShape {
        guard Self.isGitRepo(path) else { return .plain }
        return Self.detectGitHubRemote(path) != nil ? .github : .git
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
        // Board order: the committed issue index is read first, so issues go by
        // number and the user's own tasks follow in creation order. The selection
        // lives in the model — the counts in the confirmation box come from it too.
        let pending = TasksRunAllModel.startable(in: runner.board)
        let model = TasksRunAllModel.build(runner.board, githubAvailable: repo != nil,
                                           gitAvailable: workspaceIsGit)
        guard model.enabled else {
            setStatus(L10n.tr("tasks.runAllNone"), spin: false)
            autoHideStatus(after: 4)
            return
        }
        if pending.count > 1 {
            // Every task is a real agent session (up to the queue's timeout each),
            // so a batch asks first — and says what it will do.
            let alert = NSAlert()
            alert.messageText = L10n.tr("tasks.runAllTitle", pending.count)
            alert.informativeText = model.confirmationText
            alert.addButton(withTitle: L10n.tr("tasks.runAllConfirm"))
            alert.addButton(withTitle: L10n.tr("btn.cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        var started = 0
        var firstQueueID: String?
        for task in pending {
            // Each task runs in its OWN single-task queue: one branch, one PR —
            // the same shape an issue task gets. Unrelated work never shares a
            // branch just because it was batched.
            let queueID = task.source == .github
                ? runner.startIssueTask(task.id)
                : runner.startManualTask(task.id)
            if let queueID = queueID {
                started += 1
                if firstQueueID == nil { firstQueueID = queueID }
            }
        }
        // …and work them in BOARD order: every creation resumed its own queue, so
        // without this the runner would start with whichever was created last.
        if let first = firstQueueID { runner.focus(onQueue: first) }
        AppLog.shared.log("tasks: 全部处理 started \(started) task(s) "
                          + "(issues \(model.issueCount), manual \(model.manualCount))")
        setStatus(L10n.tr("tasks.runAllStarted", started), spin: false)
        autoHideStatus(after: 5)
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
        report(runner.cancelRunning())
        syncFromBoard()
    }

    /// Say what 取消任务 did. It used to do nothing at all while the task was
    /// starting (git + session + prompt in flight) or finishing (push / PR), with
    /// no feedback whatsoever — the card even hid the status line, so a click read
    /// as a frozen panel.
    private func report(_ outcome: CancelOutcome) {
        switch outcome {
        case .cancelled, .idle:
            hideStatus()
        case .deferred:
            setStatus(L10n.tr("tasks.cancelDeferred"), spin: true)
            autoHideStatus(after: 6)
        case .finishing:
            setStatus(L10n.tr("tasks.cancelFinishing"), spin: false)
            autoHideStatus(after: 6)
        }
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

    /// Create the dsh session one task runs in.
    ///
    /// This used to be a private copy that sent `{workspaceId}` and stopped there:
    /// when the persisted workspace store was stale (a workspace dsh no longer
    /// knows — removed, archived, or written by another DSH_HOME), the server
    /// answered `workspace/not-found` and EVERY task failed with `tasks.errSession`
    /// — silently, because nothing logged the reason. The shared helper does the
    /// documented two-step (workspaceId, then a plain `cwd` create) and is exercised
    /// by tests/dsh-rpc + tests/projects-panel.
    static func createSession(port: Int, workspaceId: String?, cwd: String?) -> String? {
        guard let cwd = cwd, !cwd.isEmpty else { return nil }
        let session = DshWorkspaceOps.createSession(port: port, cwd: cwd, workspaceId: workspaceId)
        if session == nil {
            AppLog.shared.log("tasks: session/create failed (workspaceId=\(workspaceId ?? "-") cwd=\(cwd))"
                              + " — " + (DshWebRPC.lastFailure ?? "no reason reported"))
        } else if let workspaceId = workspaceId, !workspaceId.isEmpty {
            AppLog.shared.log("tasks: session \(session ?? "-") created for workspace \(workspaceId)")
        }
        return session
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

    /// The agent's LAST text message in a session — its final report — for the
    /// queue's 交接简报. Blocking (a subprocess over the session log), so the
    /// runner only asks inside its background step. nil when the session has no
    /// report (or could not be read) — the brief then says so.
    static func sessionReport(sessionId: String, workspace: String?) -> String? {
        var args = ["brief", "report", sessionId]
        if let workspace = workspace, !workspace.isEmpty {
            args.append(contentsOf: ["--workspace", workspace])
        }
        guard let json = CoreBridge.run(args, timeout: 30, preferBundledNode: true),
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let text = object["text"] as? String
        return (text?.isEmpty ?? true) ? nil : text
    }

    /// The session list of the current tick, shared by every tracked workspace.
    ///
    /// With more than one workspace running (see TaskWorkspaceRegistry) a per-tick
    /// per-runner fetch would ask dsh for the SAME list N times; the panel clears
    /// this at the start of each tick, so N runners cost one RPC.
    private static var sessionListSnapshot: (port: Int, items: [[String: Any]])?

    /// Called at the start of every step tick (main thread, like the runners).
    static func beginSessionPoll() { sessionListSnapshot = nil }

    /// What dsh says about a session — see SessionState. "The RPC failed" and "the
    /// session is not listed" are NOT "it finished": the first is unknown, the
    /// second is only believed after a while (the runner counts).
    static func sessionState(port: Int, sessionId: String) -> SessionState {
        let items: [[String: Any]]
        if let snapshot = sessionListSnapshot, snapshot.port == port {
            items = snapshot.items
        } else {
            guard let value = DshWebRPC.call(DshWebRPC.sessionList, [:], port: port),
                  let fetched = value["items"] as? [[String: Any]] else { return .unknown }
            sessionListSnapshot = (port: port, items: fetched)
            items = fetched
        }
        for item in items where (item["sessionId"] as? String) == sessionId {
            return ((item["running"] as? Bool) ?? false) ? .running : .idle
        }
        return .missing
    }

    static func cancelSession(port: Int, sessionId: String) -> Bool {
        return DshWebRPC.call(DshWebRPC.sessionCancel, ["sessionId": sessionId], port: port) != nil
    }

    // MARK: - PR lookup (GitHub REST)

    /// An OPEN pull request whose head is this branch, or nil. The runner asks before
    /// it writes a queue's PR URL down, so a PR the session opened but did not quote
    /// back is still found (every task in a queue shares one branch).
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
    /// BOTH the app shell and external tools/agents
    /// (`${DSH_HOME:-$HOME/.dsh}/oh-my-dsh/gh-token`).
    /// Resolved dsh home ($DSH_HOME or ~/.dsh) — dev builds use ~/.dsh-dev.
    private static let dshHomePath: String = { ShellPaths.home() }()
    private static let genericTokenFilePath = ShellPaths.ghTokenPath(home: dshHomePath)
    /// Per-repo token dir: `${DSH_HOME:-$HOME/.dsh}/oh-my-dsh/tokens/<owner>-<repo>`.
    private static let tokenDir = ShellPaths.tokensDir(home: dshHomePath)
    /// Pre-refactor locations, read-only fallback for one transition release
    /// (the startup migration normally already moved them).
    private static let legacyGenericTokenFilePath = dshHomePath + "/gh-token"
    private static let legacyTokenDir = dshHomePath + "/tokens"

    /// Per-repo token file path: .../oh-my-dsh/tokens/<owner>-<repo>.
    private static func tokenFilePath(for repo: (owner: String, repo: String)) -> String {
        (tokenDir as NSString).appendingPathComponent(repo.owner + "-" + repo.repo)
    }

    private static func legacyTokenFilePath(for repo: (owner: String, repo: String)) -> String {
        (legacyTokenDir as NSString).appendingPathComponent(repo.owner + "-" + repo.repo)
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
    ///   1. File  ~/.dsh/oh-my-dsh/tokens/<owner>-<repo>   (per-repo, written by the panel)
    ///   2. File  ~/.dsh/oh-my-dsh/gh-token                (generic, shared with agents)
    ///   3. Legacy ~/.dsh/tokens/… and ~/.dsh/gh-token      (read-only fallback)
    private func loadToken(for repo: (owner: String, repo: String)? = nil) -> String? {
        if let repo = repo {
            if let t = readTokenFile(Self.tokenFilePath(for: repo)) { return t }
            if let t = readTokenFile(Self.legacyTokenFilePath(for: repo)) { return t }
        }
        return readTokenFile(Self.genericTokenFilePath)
            ?? readTokenFile(Self.legacyGenericTokenFilePath)
    }

    /// Save a token scoped to the current repo — **writes only the file**
    /// (~/.dsh/oh-my-dsh/tokens/<owner>-<repo>, atomic + chmod 600), which is the very file
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

    /// 面板设置 — a DRAWER (the same formSheet as 新建任务 / 新建队列), not an NSAlert:
    /// the GitHub token and THIS workspace's 工作流 default share one surface.
    private func configTapped() {
        let model = TaskSettingsModel(
            token: loadToken(for: repo) ?? "",
            // 没保存过时它就是本工作区的推荐（见 resolvedIntegration），所以首次
            // 打开抽屉默认选中的正是推荐那一档。
            defaultIntegration: workspaceIntegration,
            recommendedIntegration: QueueIntegration.recommended(isGit: workspaceIsGit,
                                                                 hasGitHubRemote: repo != nil),
            prAvailable: repo != nil,
            gitAvailable: workspaceIsGit,
            remoteAvailable: workspaceHasRemote,
            autoCloseOnPublish: repoRootPath.map { Self.storedAutoCloseOnPublish(forWorkspace: $0) } ?? false)
        let form = TaskSettingsView(model: model)
        form.onSubmit = { [weak self] settings in self?.submitSettings(settings) }
        form.onCancel = { [weak self] in self?.dismissForm() }
        presentForm(form) { ($0 as? TaskSettingsView)?.focusToken() }
    }

    /// 使用说明 —— the toolbar button. The empty board shows the same content inline,
    /// so the button is hidden there (see render()).
    private func helpTapped() {
        let form = TasksHelpView(model: TasksHelpModel.build())
        form.onCancel = { [weak self] in self?.dismissForm() }
        presentForm(form) { _ in }
    }

    private func submitSettings(_ settings: TaskSettingsModel) {
        let value = settings.token.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty → delete the token file; otherwise write it (file only).
        saveToken(value, for: repo)
        // PER WORKSPACE (every 面板设置 item): save under this workspace's path, then
        // tell the live runner (its env was snapshotted at adopt time) so the next
        // finalize uses it. Other workspaces keep their own value.
        if let path = repoRootPath {
            Self.setStoredIntegration(settings.defaultIntegration, forWorkspace: path)
            runner?.setDefaultIntegration(settings.defaultIntegration)
            Self.setStoredAutoCloseOnPublish(settings.autoCloseOnPublish, forWorkspace: path)
            runner?.setAutoCloseOnPublish(settings.autoCloseOnPublish)
        }
        dismissForm()
        setStatus(L10n.tr("tasks.settings.saved"), spin: false)
        autoHideStatus(after: 4)
        reloadIssues()
        syncFromBoard()
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
        // The header's 处理 button answers a BOARD question (「有待办吗」), so every
        // board change re-derives it — creating a task used to leave it greyed out
        // until the next workspace switch, because only updateLabels() ever set it.
        updateRunAllButton(githubAvailable: repo != nil)
        render()
    }

    /// The 处理 button's enabled state and tooltip: what it would start RIGHT NOW,
    /// or why there is nothing to start. Its enablement is 「有待办」 — a fact of the
    /// board, not of the workspace — so it is derived wherever either can change:
    /// `updateLabels()` (the workspace: git / GitHub availability) and
    /// `syncFromBoard()` (the board: 新建 / 入队 / 开始 / 完成 / 删除).
    private func updateRunAllButton(githubAvailable: Bool) {
        let runAll = TasksRunAllModel.build(runner?.board ?? TaskBoard(),
                                            githubAvailable: githubAvailable,
                                            gitAvailable: workspaceIsGit)
        runAllButton.isEnabled = runAll.enabled
        runAllButton.toolTip = runAll.tooltip
    }

    private func render() {
        for subview in listStack.arrangedSubviews { subview.removeFromSuperview() }
        guard let runner = runner else {
            emptyView.isHidden = false
            return
        }
        let board = runner.board
        let githubRepo = repo != nil
        var sections = 0

        // 0. 统计信息 — the content's first row, exactly where the review panel
        //    puts its own summary (the counts are no longer toolbar pills). It is
        //    not a "section": the empty state below is about queues and tasks.
        addCard(TaskSummaryCardView(model: TasksSummaryModel.build(board, source: sourceFilter.source)))

        // 1. Queues. User queues first (they hold the user's own work), then the
        //    issue tasks' single-task queues, which count and render like any
        //    other queue but start as one compact line (决策 8).
        // Which lanes to draw, and what is inside them: the rule lives in
        // TaskSourceFilter (pure, headless-testable) — a lane shows while it HOLDS at
        // least one card this tab accepts. Order is the panel's: the user's own lanes
        // first, then the auto queues by issue number.
        // Newest user lane first: the queue just created is what the user looks for.
        let userQueues = TaskQueue.newestFirst(
            board.queues.filter { !$0.autoCreated && sourceFilter.shows($0, in: board) })
        let autoQueues = board.queues.filter { $0.autoCreated && sourceFilter.shows($0, in: board) }
            .sorted(by: { autoQueueNumber($0, board) < autoQueueNumber($1, board) })
        let queues = userQueues + autoQueues
        if !queues.isEmpty {
            addCard(TaskSectionHeaderView(text: L10n.tr("tasks.section.queues", queues.count)))
            for queue in queues {
                // A queue is ONE block: the lane surface holds its header AND its
                // cards, so the containment is geometric (review-panel体例)
                // instead of two parallel stacks that only happen to be adjacent.
                let cards = sourceFilter.cards(of: queue, in: board)
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
        // An empty board ALSO shows the help inline, in the content area; the
        // toolbar button is ALWAYS there (user 2026-10-01), so the same drawer can
        // be opened at any time.
        helpTextView.isHidden = !empty.showsHelp
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
        formSheet.setContent(content)
        formSheetContent = content
        // The panel is in "form mode": clicks stay with the form.
        formSheetHost.blocksClicksBelow = true
        // Resolve the height the form asked for (its constraint) before the slide:
        // the animation starts one host-height above, so no measurement is needed.
        view.layoutSubtreeIfNeeded()
        let wasVisible = !formSheet.isHidden
        view.layoutSubtreeIfNeeded()
        if wasVisible {
            // Already down (create → create again): swap the content in place.
            formSheetTop.constant = TaskFormSheetHostView.restingTop
            view.layoutSubtreeIfNeeded()
            formSheetHost.showScrim()
            formSheetHost.scrim.alphaValue = 1
        } else {
            // Start ABOVE the host's edge (clipped away by it) and drop down. The
            // offset is the host's own height, so nothing has to be measured.
            formSheetTop.constant = -(formSheetHost.bounds.height)
            view.layoutSubtreeIfNeeded()
            formSheet.isHidden = false
            // The frost comes in WITH the drawer, in the same animation group.
            formSheetHost.showScrim()
            formSheetHost.scrim.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                formSheetTop.animator().constant = TaskFormSheetHostView.restingTop
                formSheet.animator().alphaValue = 1
                formSheetHost.scrim.animator().alphaValue = 1
            }
        }
        // Take focus once the sheet has arrived (the fields must be on screen
        // before the caret lands in them).
        DispatchQueue.main.asyncAfter(deadline: .now() + (wasVisible ? 0 : 0.22)) { [weak self] in
            guard let self = self, let content = self.formSheetContent else { return }
            focus(content)
        }
    }

    /// Pull the sheet back up and drop its content.
    private func dismissForm() {
        guard !formSheet.isHidden else { return }
        let hidden = -formSheetHost.bounds.height
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.formSheetTop.animator().constant = hidden
            self.formSheet.animator().alphaValue = 0
            self.formSheetHost.scrim.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self = self else { return }
            self.formSheet.isHidden = true
            self.formSheetHost.hideScrim()
            self.formSheet.setContent(NSView())
            self.formSheetContent = nil
            // Back to a plain overlay: the list takes clicks again.
            self.formSheetHost.blocksClicksBelow = false
        })
    }

    private func showTaskForm(_ model: TaskComposerModel) {
        taskComposer = model
        let form = TaskComposerView(model: model)
        form.onSubmit = { [weak self] composer in self?.submitTaskComposer(composer) }
        form.onCancel = { [weak self] in self?.closeTaskComposer() }
        // The description editor growing (or the queue form's 高级设置 opening)
        // changes the form's height from the INSIDE — the panel's own layout does
        // not run for that, so the form tells the sheet to re-measure.
        // The sheet follows this form's height by constraint: growing from the
        // inside needs nothing from the panel.
        presentForm(form) { view in
            // The editor can only size itself to its text once it has its real
            // width: an edit must show the whole description, not its first line.
            guard let composer = view as? TaskComposerView else { return }
            composer.layoutEditor()
            composer.focusEditor()
        }
    }

    private func showQueueForm(_ model: QueueComposerModel) {
        queueComposer = model
        let form = QueueComposerView(model: model)
        form.onSubmit = { [weak self] composer in self?.submitQueueComposer(composer) }
        form.onCancel = { [weak self] in self?.closeQueueComposer() }
        // The sheet follows this form's height by constraint: growing from the
        // inside needs nothing from the panel.
        presentForm(form) { ($0 as? QueueComposerView)?.focusName() }
    }

    /// Issue numbers order the auto queues (they are per-repo and monotonic).
    private func autoQueueNumber(_ queue: TaskQueue, _ board: TaskBoard) -> Int {
        queue.taskIds.first.flatMap { board.task($0)?.number } ?? 0
    }

    /// Auto (issue) queues start collapsed: one line each, expanding on a click.
    /// Terminal lanes (已完成 / 已关闭) too — see TaskQueue.startsExpanded.
    private func isQueueExpanded(_ queue: TaskQueue) -> Bool {
        if let explicit = queueToggle[queue.id] { return explicit }
        return TaskQueue.startsExpanded(queue)
    }

    private func card(_ task: TaskItem, board: TaskBoard, githubRepo: Bool) -> NSView {
        let model = TaskCardModel.build(task, board: board,
                                        expanded: expandedTaskID == task.id,
                                        githubRepo: githubRepo,
                                        now: Date(),
                                        timeoutMinutes: runner?.timeoutMinutes ?? 60)
        let card = TaskCardView(model: model)
        let taskID = task.id
        card.onToggle = { [weak self] in self?.toggleTask(taskID) }
        card.onPrimary = { [weak self] in
            // A card with no primary never offers the button at all (finished manual
            // task) — the guard is what keeps that state from reaching the switch.
            guard let action = model.primaryAction else { return }
            self?.primaryAction(task, action: action)
        }
        card.onQueue = { [weak self] anchor in
            self?.presentQueuePicker(for: taskID, from: anchor)
        }
        card.onCommentClose = { [weak self] in self?.commentAndCloseTapped(number: task.number ?? 0) }
        card.onSkip = { [weak self] in
            // 跳过并继续: keep the failure's record, resume the queue, run the next
            // queued task (the runner knows how — the UI never could reach it before).
            _ = self?.runner?.skip(taskID: taskID)
            self?.syncFromBoard()
        }
        card.onOpenSession = { [weak self] in
            guard let session = task.sessionId else { return }
            // Say something the moment it is clicked: the shell's lookup walks dsh web's
            // sidebar (with a retry), so a second of silence is normal — and a click that
            // showed nothing at all is what «点了没反应» actually was. The shell reports a
            // real failure back through reportStatus(_:).
            self?.setStatus(L10n.tr("tasks.openingSession"), spin: true)
            self?.autoHideStatus(after: 8)
            self?.onOpenSession?(session)
        }
        card.onReview = { [weak self] in
            guard let session = task.sessionId else { return }
            self?.onReviewSession?(session)
        }
        card.onEdit = { [weak self] in self?.openTaskComposer(.edit(taskID: taskID)) }
        card.onDelete = { [weak self] in self?.confirmDelete(task) }
        return card
    }

    private func queueHeader(_ queue: TaskQueue, board: TaskBoard, cardCount: Int) -> TaskQueueHeaderView {
        // prAvailable: the queue's PR switch/toggle only exists where a PR can
        // exist (the same rule the queue form follows).
        // Only ONE queue is actually being worked on: several can be 活跃 (开始 on a
        // second one just re-points the runner), and the others must not claim to
        // be running anything.
        let isCurrent = board.activeQueue()?.id == queue.id
        let integration = board.integration(forQueue: queue.id, default: workspaceIntegration)
        let model = QueueHeaderModel.build(queue, board: board, collapsed: !isQueueExpanded(queue),
                                           prAvailable: repo != nil, isCurrent: isCurrent,
                                           integration: integration,
                                           hasRemote: workspaceHasRemote,
                                           noteExpanded: expandedQueueNotes.contains(queue.id))
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
        header.onOpenPR = { [weak self] in self?.publishPR(for: queue) }
        header.onOpenPRLink = { [weak self] in self?.openPRURL(queue) }
        header.onClose = { [weak self] in self?.confirmCloseQueue(queue) }
        // 重命名 / 改分支 / 基于分支 / PR 开关 are one inline form now.
        header.onSettings = { [weak self] in self?.openQueueComposer(.edit(queueID: queueID)) }
        header.onTogglePR = { [weak self] in
            _ = self?.runner?.updateQueue(queueID, autoPR: !queue.autoPR)
            self?.syncFromBoard()
        }
        header.onDelete = { [weak self] in self?.confirmDeleteQueue(queue, cardCount: cardCount) }
        header.onToggleNote = { [weak self] in
            guard let self = self else { return }
            if self.expandedQueueNotes.contains(queueID) {
                self.expandedQueueNotes.remove(queueID)
            } else {
                self.expandedQueueNotes.insert(queueID)
            }
            self.render()
        }
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

    /// The card's primary action, as the CARD MODEL decided it (TasksUI.swift).
    ///
    /// The panel used to switch on the task's state, which cannot tell the two
    /// cases apart: a failed task still in its queue is 重试, while a failed task
    /// whose queue was DELETED is 加入队列 (manual) / 处理 (issue) — 重试 there would
    /// only reset the card and ask again.
    private func primaryAction(_ task: TaskItem, action: TaskCardModel.PrimaryAction) {
        guard let runner = runner else { return }
        switch action {
        case .joinQueue:
            // The control is the 加入队列 DROPDOWN: the card routes the click to
            // onQueue (the queue picker), so this never fires for it.
            break
        case .processIssue:
            _ = runner.startIssueTask(task.id)
        case .dequeue:
            _ = runner.dequeue(taskID: task.id)
        case .cancel:
            report(runner.cancelRunning())

        case .openIssue:
            openIssue(number: task.number ?? 0)
        case .retry(let clearsBranch):
            if clearsBranch { dropQueueBranch(for: task) }
            _ = runner.retry(taskID: task.id)
        }
        syncFromBoard()
    }

    /// 不切分支并重试: the task failed with tasks.errNotGit — its queue asked for
    /// a branch in a directory that is not a git repository. Clearing the queue's
    /// branch IS the fix, and offering it here turns a dead end (重试 fails
    /// identically) into one click, instead of the three-step detour through
    /// 队列设置.
    private func dropQueueBranch(for task: TaskItem) {
        guard let runner = runner, let queueID = task.queueId else { return }
        let name = runner.board.queue(queueID)?.name ?? ""
        guard runner.updateQueue(queueID, branch: .some(nil)) else { return }
        AppLog.shared.log("tasks: queue " + queueID + " set to 不切分支 to recover " + task.id)
        setStatus(L10n.tr("tasks.queue.branchDropped", name), spin: false)
        autoHideStatus(after: 5)
    }

    private func openIssue(number: Int) {
        guard let repo = repo,
              let url = URL(string: "https://github.com/\(repo.owner)/\(repo.repo)/issues/\(number)") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Queue PR, from the header's 开 PR button. An existing PR simply opens;
    /// otherwise the runner starts this queue's PR SESSION (startQueuePR) — the one
    /// place that pushes the branch, summarizes the diff, opens the PR and reports the
    /// URL back onto the queue. The panel no longer talks to the GitHub API itself:
    /// pushing a branch needs credentials and judgement, which is exactly what a
    /// session has and a URLSession call does not.
    private func publishPR(for queue: TaskQueue) {
        guard let runner = runner else { return }
        guard runner.startQueueIntegration(queue.id) else {
            // Say WHY: the runner records the concrete reason on the queue (no branch /
            // no remote / another finalize session is already running). The generic
            // 「开不了 PR」 is only the fallback when there is nothing specific.
            let key = runner.board.queue(queue.id)?.prError ?? "tasks.errPRStart"
            setStatus(L10n.tr(key), spin: false)
            autoHideStatus(after: 8)
            // Re-render so the publish button's tooltip carries the same reason.
            syncFromBoard()
            return
        }
        // The status line says what THIS queue's workflow does — not always 「开 PR」.
        setStatus(L10n.tr(Self.finalizeStatusKey(mode: runner.board.integration(
            forQueue: queue.id, default: workspaceIntegration)), queue.name), spin: true)
        syncFromBoard()
    }

    /// The status line for a queue whose finalize session is (or is about to be)
    /// running — by the mode it will actually execute.
    static func finalizeStatusKey(mode: QueueIntegration) -> String {
        switch mode {
        case .merge: return "tasks.queue.merging"
        case .push: return "tasks.queue.pushing"
        case .pr, .none: return "tasks.prOpening"
        }
    }

    /// 打开已有 PR 的链接 —— 与「交付」分开：PR 已存在时仍要能再次交付去更新它。
    private func openPRURL(_ queue: TaskQueue) {
        guard let url = queue.prUrl, let link = URL(string: url) else { return }
        NSWorkspace.shared.open(link)
    }

    // MARK: - Queue picker (加入队列)

    /// 加入队列 ▾ — the same dropdown the files panel's 打开项目 button opens: the
    /// control is a menu button and the list drops just BELOW it (the menu used to
    /// be anchored at the card's top-left corner, so it covered the card it
    /// belonged to).
    ///
    /// 新建队列 comes FIRST: creating a lane is the step that most often comes
    /// next, and it must never sit under a long list of existing queues.
    private func presentQueuePicker(for taskID: String, from button: NSView) {
        guard let runner = runner else { return }
        let menu = NSMenu(title: L10n.tr("tasks.queue.add"))
        let items = QueuePickerItem.build(runner.queueChoices())
        for row in items {
            if row.isNewQueue {
                let item = NSMenuItem(title: row.title, action: #selector(newQueueForTask(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = taskID
                menu.addItem(item)
                // The 新建队列 row is always first; separate it from the queues.
                if items.count > 1 { menu.addItem(.separator()) }
            } else {
                let suffix = row.branch.map { "  " + $0 } ?? ""
                let item = NSMenuItem(title: row.title + suffix, action: #selector(queueChosen(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = [taskID, row.queueID ?? ""]
                menu.addItem(item)
            }
        }
        // Drop below the button: the anchor is the menu's TOP-LEFT corner in the
        // view's (non-flipped) coordinates (FilePanel.popBelow).
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -6), in: button)
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
            // The task may have started running while the form was open (the step
            // timer starts the next queued one): its session already holds the old
            // text, so the edit is refused. Reporting "已更新" anyway — which is
            // what this did — silently threw the typing away.
            guard runner.updateManualTask(taskID, title: draft.normalizedTitle,
                                          body: draft.normalizedBody) else {
                setStatus(L10n.tr("tasks.new.editRefused"), spin: false)
                autoHideStatus(after: 6)
                syncFromBoard()
                return                       // the form stays: the typing is the only copy
            }
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
            let base = taskID.map { QueueComposerModel.create(taskID: $0) } ?? QueueComposerModel.create()
            // The PR switch is only pre-armed where the repo can carry one, and
            // 不切分支 is decided by the workspace having no repo to switch in.
            var model = base.forWorkspace(git: workspaceIsGit, pr: repo != nil,
                                          hasRemote: workspaceHasRemote,
                                          defaultBase: workspaceDefaultBase,
                                          defaultIntegration: workspaceIntegration)
                .forRepos(repoPickerRepos, primary: workspaceRepoSet.primary)
            model.autoPR = false
            showQueueForm(model)
        case .edit(let queueID):
            guard let queue = runner.board.queue(queueID) else { return }
            // The repo selector is a multi-repo affordance: single-repo / plain
            // workspaces pass [] and keep today's form unchanged.
            showQueueForm(QueueComposerModel.edit(queue, prAvailable: repo != nil,
                                                  gitAvailable: workspaceIsGit,
                                                  hasRemote: workspaceHasRemote,
                                                  defaultBaseBranch: workspaceDefaultBase,
                                                  defaultIntegration: workspaceIntegration)
                .forRepos(repoPickerRepos, primary: workspaceRepoSet.primary))
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
                                           autoPR: composer.autoPR && repo != nil,
                                           integration: composer.integration)
            if let taskID = taskID { _ = runner.enqueue(taskID: taskID, into: queue.id) }
            setStatus(L10n.tr("tasks.queue.created", queue.name), spin: false)
            autoHideStatus(after: 4)
            // Show the new queue open: its card list is what the user just built.
            queueToggle[queue.id] = true
            queueComposer = nil
            dismissForm()
        case .edit(let queueID):
            guard runner.updateQueue(queueID,
                                     name: composer.normalizedName,
                                     branch: .some(composer.branchValue),
                                     baseBranch: composer.normalizedBaseBranch,
                                     autoPR: composer.autoPR && repo != nil,
                                     integration: .some(composer.integration)) else {
                // The queue is gone (workspace switched under the open form): say
                // so instead of reporting a save that never happened.
                setStatus(L10n.tr("tasks.queue.updateFailed"), spin: false)
                autoHideStatus(after: 6)
                syncFromBoard()
                return
            }
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
        guard runner?.deleteManualTask(task.id) == true else {
            // It started running while the dialog was up: the delete is refused.
            setStatus(L10n.tr("tasks.card.deleteRefused"), spin: false)
            autoHideStatus(after: 6)
            syncFromBoard()
            return
        }
        syncFromBoard()
    }

    private func confirmDeleteQueue(_ queue: TaskQueue, cardCount: Int) {
        let alert = NSAlert()
        alert.messageText = L10n.tr("tasks.deleteQueueTitle", queue.name)
        alert.informativeText = L10n.tr("tasks.deleteQueueInfo", cardCount)
        alert.addButton(withTitle: L10n.tr("tasks.queue.delete"))
        alert.addButton(withTitle: L10n.tr("btn.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard runner?.removeQueue(queue.id) == true else {
            // A task in it is running: the model refuses to delete the queue, and
            // the panel used to say nothing at all about it.
            setStatus(L10n.tr("tasks.queue.deleteRefused"), spin: false)
            autoHideStatus(after: 6)
            syncFromBoard()
            return
        }
        queueToggle[queue.id] = nil
        syncFromBoard()
    }

    private func confirmCloseQueue(_ queue: TaskQueue) {
        let alert = NSAlert()
        alert.messageText = L10n.tr("tasks.closeQueueTitle", queue.name)
        alert.informativeText = L10n.tr("tasks.closeQueueInfo")
        alert.addButton(withTitle: L10n.tr("tasks.queue.close"))
        alert.addButton(withTitle: L10n.tr("btn.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard runner?.closeQueue(queue.id) == true else {
            setStatus(L10n.tr("tasks.queue.closeRefused"), spin: false)
            autoHideStatus(after: 6)
            syncFromBoard()
            return
        }
        syncFromBoard()
    }

    /// User pressed "Comment & Close Issue": show a confirmation dialog with an
    /// editable comment (pre-filled with the PR reference), then act on GitHub.
    /// Explicitly user-initiated — never automatic.
    private func commentAndCloseTapped(number: Int) {
        guard let repo = repo,
              let task = runner?.board.tasks.first(where: { $0.number == number }),
              task.state == .done else { return }
        // A task with no PR (creation failed, or the queue never asked for one) is
        // still commentable: the template just leaves the PR line out.
        let template = task.prUrl.map { L10n.tr("tasks.commentTemplate", $0) }
            ?? L10n.tr("tasks.commentTemplateNoPR")

        let alert = NSAlert()
        alert.messageText = L10n.tr("tasks.commentCloseTitle", number)
        alert.informativeText = L10n.tr("tasks.commentCloseInfo")
        alert.addButton(withTitle: L10n.tr("btn.ok"))
        alert.addButton(withTitle: L10n.tr("btn.cancel"))
        let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 120))
        field.isEditable = true
        field.isSelectable = true
        field.string = template
        let scroll = NSScrollView(frame: field.bounds)
        scroll.documentView = field
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.frame = NSRect(x: 0, y: 0, width: 420, height: 120)
        alert.accessoryView = scroll
        alert.window.initialFirstResponder = field
        // The OK button is dead while the comment is empty: pressing it used to
        // dismiss the dialog and do nothing at all, with no explanation anywhere.
        let watcher = CommentFieldWatcher()
        watcher.button = alert.buttons.first
        field.delegate = watcher
        watcher.apply(field)

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let comment = field.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !comment.isEmpty else {
            // Belt and braces (a programmatic close can still land here).
            setStatus(L10n.tr("tasks.commentEmpty"), spin: false)
            autoHideStatus(after: 4)
            return
        }

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

