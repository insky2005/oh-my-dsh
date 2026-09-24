//
//  ProjectsPanel.swift — the Projects panel (right-side panel slot #9).
//
//  One card per workspace = one directory under the configured projects root.
//  A card answers the three questions the panel exists for:
//
//    * where is this workspace?        -> path line (tooltip = full path)
//    * does dsh know it?               -> badge: registered + session count, or not
//    * what can I do here right now?   -> 文件 / 终端 / 知识库 / 任务 / 通道 / 审查
//                                         quick entries, "新会话", reveal, copy path
//
//  Everything that is not UI lives elsewhere on purpose:
//    * root resolution / name rules / listing / registry merge -> ProjectsCore.swift
//    * dsh RPC (workspace/create, session/create)              -> DshWorkspaceOps
//    * re-rooting the other panels (ProjectDirectory)          -> main.swift closures
//  The controller only wires those three together, which is why it can be driven
//  headlessly (tests/projects-panel/).
//
//  Design: docs/projects-panel-design.md (§5).
//

import AppKit

/// A panel a workspace card can jump into. The raw values are the panel names
/// used by the QA sweep (DSH_PANEL_TEST); main.swift maps them onto RightPanel so
/// this file never depends on main.swift.
enum ProjectTargetPanel: String, CaseIterable {
    case files, terminal, wiki, tasks, channel, review

    /// SF Symbol — the same one the activity bar uses for that panel, so the
    /// button and the icon strip read as the same thing.
    var symbolName: String {
        switch self {
        case .files: return "doc.on.doc"
        case .terminal: return "terminal"
        case .wiki: return "book.closed"
        case .tasks: return "checkmark.circle"
        case .channel: return "dot.radiowaves.left.and.right"
        case .review: return "doc.text"
        }
    }

    /// Tooltip text key (reuses the activity bar's labels).
    var labelKey: String {
        switch self {
        case .files: return "bar.preview"
        case .terminal: return "bar.terminal"
        case .wiki: return "bar.wiki"
        case .tasks: return "bar.tasks"
        case .channel: return "bar.channel"
        case .review: return "bar.review"
        }
    }
}

/// Panel background — the shared panel surface token (see PanelSurface.swift).
final class ProjectsRootView: NSView {
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        PanelSurface.color(for: effectiveAppearance).setFill()
        bounds.intersection(dirtyRect).fill()
    }
}

/// One workspace card. Three lines: title + badge, path, action row.
///
/// The card itself is clickable (= "open in dsh": reuse the workspace's newest
/// session, create one when it has none); the icon buttons on the action row stop
/// the click naturally because AppKit hit-tests the deepest subview first.
final class ProjectCardView: NSView {

    var onOpen: (() -> Void)?
    var onPanel: ((ProjectTargetPanel) -> Void)?
    var onNewSession: (() -> Void)?
    /// "Create the dsh workspace for this folder" — offered only while the
    /// directory is NOT registered (see the badge).
    var onRegister: (() -> Void)?
    var onReveal: (() -> Void)?
    var onCopyPath: (() -> Void)?

    /// Internal (not private) so the headless panel tests can identify a card by
    /// its workspace and assert the "current workspace" flag.
    let workspace: ProjectWorkspace
    private(set) var isCurrentWorkspace: Bool

    private let badge = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")

    /// Whether this card's dsh actions ("open in dsh", "new session") apply: a
    /// directory dsh does not know cannot be linked to dsh web at all — the user
    /// creates the workspace first (the card's own button). Internal for tests.
    var canUseDshActions: Bool { workspace.registered }

    init(workspace: ProjectWorkspace, isCurrent: Bool) {
        self.workspace = workspace
        self.isCurrentWorkspace = isCurrent
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        // Card fill: one step up from the panel surface (the current workspace
        // keeps the highlight fill so it reads as "you are here").
        PanelControl.fill(dark: dark, highlighted: isCurrentWorkspace).setFill()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        path.fill()
        if isCurrentWorkspace {
            NSColor.controlAccentColor.withAlphaComponent(0.6).setStroke()
        } else {
            (dark ? NSColor(calibratedWhite: 0.38, alpha: 0.7) : NSColor(calibratedWhite: 0.82, alpha: 1)).setStroke()
        }
        path.lineWidth = 1
        path.stroke()
    }

    override func resetCursorRects() {
        // The whole card is the "open in dsh" target — but only while the folder
        // actually has a dsh workspace behind it.
        addCursorRect(bounds, cursor: canUseDshActions ? .pointingHand : .arrow)
    }

    override func mouseDown(with event: NSEvent) { onOpen?() }

    /// The whole card is the "open in dsh" target, but its own labels must not
    /// swallow the click (a label IS a hit-testable view). Anything that is not
    /// one of the action-row controls therefore counts as the card itself; the
    /// buttons keep working because AppKit hit-tests the deepest subview first.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if hit is NSButton || hit is CustomIconButton { return hit }
        return self
    }

    // MARK: - Layout

    private func build() {
        titleLabel.stringValue = workspace.name
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.toolTip = workspace.registered ? L10n.tr("projects.openInDsh") : L10n.tr("projects.needsWorkspace")
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // An unregistered folder is inert for dsh web (no sessions to open), so
        // it reads as secondary until the workspace has been created.
        titleLabel.textColor = workspace.registered ? .labelColor : .secondaryLabelColor

        badge.stringValue = workspace.registered
            ? L10n.tr("projects.registered") + " · " + L10n.tr("projects.sessions", workspace.sessionCount)
            : L10n.tr("projects.unregistered")
        badge.font = NSFont.systemFont(ofSize: 11)
        badge.textColor = workspace.registered ? .secondaryLabelColor : .tertiaryLabelColor
        badge.alignment = .right
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.setContentHuggingPriority(.required, for: .horizontal)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)

        pathLabel.stringValue = workspace.path
        pathLabel.font = NSFont.systemFont(ofSize: 11)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.toolTip = workspace.path
        pathLabel.translatesAutoresizingMaskIntoConstraints = false

        // The badge is followed by the ONE dsh action this card offers: "添加工作区"
        // (folder +) while the folder has no dsh workspace, "新会话" (+) once it has
        // one. Keeping it on the title row is what the user asked for — it reads as
        // "this workspace, do the obvious thing" instead of as another toolbar entry.
        let titleRow = NSStackView(views: [titleLabel, badge, dshActionButton()])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 8
        titleRow.distribution = .fill
        titleRow.translatesAutoresizingMaskIntoConstraints = false

        // The path line carries its own two utilities (show in Finder / copy path):
        // they belong to "where is this folder", not to the panel entries below —
        // and they sit IMMEDIATELY after the path text (not flushed right), which
        // is what the trailing spacer is for: the row is as wide as the card so a
        // long path can truncate, but only the spacer absorbs the slack.
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let pathRow = NSStackView(views: [pathLabel] + pathButtons() + [spacer])
        pathRow.orientation = .horizontal
        pathRow.alignment = .centerY
        pathRow.spacing = 6
        pathRow.distribution = .fill
        pathRow.translatesAutoresizingMaskIntoConstraints = false
        // The label hugs its text (so the buttons follow it) but gives way first
        // when the card gets narrow — that is where the truncation happens.
        pathLabel.setContentHuggingPriority(.required, for: .horizontal)
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let actions = NSStackView(views: actionButtons())
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 2
        actions.translatesAutoresizingMaskIntoConstraints = false

        let column = NSStackView(views: [titleRow, pathRow, actions])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 4
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            column.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            titleRow.widthAnchor.constraint(equalTo: column.widthAnchor),
            pathRow.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])
    }

    /// The one dsh action this card offers, mounted right after the badge:
    ///   * unregistered -> "添加工作区" (folder +), i.e. create the dsh workspace;
    ///   * registered   -> "新会话" (+), i.e. start a session in it.
    /// The two are mutually exclusive, so neither ever needs a disabled state.
    private func dshActionButton() -> CustomIconButton {
        if canUseDshActions {
            let button = CustomIconButton(glyph: .plus, tooltip: L10n.tr("projects.newSession"), size: 24)
            button.onAction = { [weak self] in self?.onNewSession?() }
            return button
        }
        let button = CustomIconButton(glyph: .folderPlus,
                                      tooltip: L10n.tr("projects.register"), size: 24)
        button.onAction = { [weak self] in self?.onRegister?() }
        return button
    }

    /// The folder-path utilities: show in Finder + copy path (they sit on the
    /// path line, right after the path itself).
    private func pathButtons() -> [NSView] {
        let reveal = CustomIconButton(glyph: .reveal, tooltip: L10n.tr("files.revealInFinder"), size: 22)
        reveal.onAction = { [weak self] in self?.onReveal?() }
        let copy = CustomIconButton(glyph: .symbol("link"), tooltip: L10n.tr("files.copyPath"), size: 22)
        copy.onAction = { [weak self] in self?.onCopyPath?() }
        return [reveal, copy]
    }

    /// The six panel quick entries — all local (they re-root the shell's own
    /// panels); the dsh action lives on the title row (see dshActionButton).
    private func actionButtons() -> [NSView] {
        var views: [NSView] = []
        for target in ProjectTargetPanel.allCases {
            let button = CustomIconButton(glyph: .symbol(target.symbolName),
                                          tooltip: L10n.tr(target.labelKey),
                                          size: 24)
            button.onAction = { [weak self] in self?.onPanel?(target) }
            views.append(button)
        }
        return views
    }


}

/// The Projects panel. Wired by main.swift; every side effect that touches the
/// rest of the shell goes through a closure so the controller stays testable.
final class ProjectsPanelController: NSObject, NSTextFieldDelegate {

    // MARK: - Wiring (set by main.swift)

    var onRequestHide: (() -> Void)?
    /// dsh web's port (for the registry read + workspace/create).
    var portProvider: (() -> Int)?
    /// The dsh data home (dev builds isolate to ~/.dsh-dev) — the default root
    /// lives under it.
    var dshHomeProvider: (() -> String)?
    /// The workspace the shell currently considers active (ProjectDirectory).
    var currentWorkspacePath: (() -> String?)?
    /// "open in dsh": reuse the workspace's newest session, or create one.
    var onEnterWorkspace: ((String) -> Void)?
    /// A quick entry: re-root the shell to this workspace and show that panel.
    var onOpenPanel: ((String, ProjectTargetPanel) -> Void)?
    /// Create a session in this workspace and switch dsh web to it.
    var onCreateSession: ((String) -> Void)?
    /// dsh just registered this folder as a workspace (idempotent, so this also
    /// covers "the folder was already a workspace"). dsh web needs no nudge for
    /// the ROW — the new workspace reaches every connected client through dsh's
    /// own workspace stream (measured: ~0.2 s) — but main.swift uses this to put
    /// the page ON that workspace, exactly like dsh's own "Add workspace" entry
    /// does (`WorkspacePickFlow.onPick` → `startSession`). The path is passed so
    /// the shell knows which workspace to open.
    var onWorkspaceRegistered: ((String) -> Void)?
    /// Make this folder the shell's current workspace (main.swift re-roots every
    /// panel through `adoptProjectDirectory`). Sent right after the panel creates
    /// or adopts a workspace: that folder is the one the user just asked for, so
    /// its card must come up highlighted — the highlight IS the current
    /// workspace, the panel deliberately has no second selection state.
    var onSelectWorkspace: ((String) -> Void)?
    var onOpenSettings: (() -> Void)?
    /// QA hook (--ui-debug): fires after each render.
    var onDidRender: (() -> Void)?

    static let minWidth: CGFloat = 320

    let view = ProjectsRootView()

    /// What the last load produced (also what the tests assert on).
    private(set) var workspaces: [ProjectWorkspace] = []
    /// The root in effect for the last load (display + create target).
    private(set) var rootPath: String = ""
    /// True while the empty state (no workspaces / missing root) is on screen —
    /// internal for the headless panel tests.
    var isEmptyStateVisible: Bool { !emptyView.isHidden }

    // MARK: - Views

    private let headerTitle = HeaderLabel()
    private let newButton = CustomIconButton(glyph: .folderPlus, tooltip: "")
    private let refreshButton = CustomIconButton(glyph: .symbol("arrow.clockwise"), tooltip: "")
    private let settingsButton = CustomIconButton(glyph: .symbol("gearshape"), tooltip: "")
    private let hideButton = CustomIconButton(glyph: .close, tooltip: "")

    private let rootLabel = NSTextField(labelWithString: "")
    private let changeRootButton = NSButton(title: "", target: nil, action: nil)

    private let scroll = NSScrollView()
    private let list = FlippedStackView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let emptyButton = NSButton(title: "", target: nil, action: nil)
    private let emptyView = NSStackView()

    private let statusLabel = NSTextField(labelWithString: "")

    // MARK: - State

    /// Bumped per load so a slow listing cannot overwrite a newer one.
    private var loadToken = 0
    private var statusClearTimer: Timer?
    private var hasRendered = false
    /// The open "new workspace" sheet (nil when none) — kept so the informative
    /// text can follow what the user types.
    private var promptAlert: NSAlert?
    /// Canonical path of a just-created workspace whose card must be scrolled into
    /// view on the next render that contains it (the list is sorted by name, so a
    /// new card can land far below the fold).
    private var pendingScrollPath: String?

    override init() {
        super.init()
        buildUI()
        newButton.onAction = { [weak self] in self?.promptForNewWorkspace() }
        refreshButton.onAction = { [weak self] in self?.reload() }
        settingsButton.onAction = { [weak self] in self?.onOpenSettings?() }
        hideButton.onAction = { [weak self] in self?.onRequestHide?() }
        updateLabels()
    }

    // MARK: - Public entry points

    /// Language switch: every static label and tooltip of this panel is set once,
    /// so re-apply them (and re-render, which rebuilds the cards' buttons).
    /// Called from AppDelegate.applyLanguage — same contract as the other panels'
    /// refreshTooltips().
    func refreshTooltips() {
        updateLabels()
        render()
    }

    /// Called every time the panel is mounted: always re-read (the root may have
    /// been changed from the settings window, workspaces may have appeared in
    /// Finder, dsh may have registered something meanwhile).
    func ensureLoaded() { reload() }

    /// The settings window changed the root.
    func workRootChanged() { reload() }

    /// The session dsh web is showing changed: the "current workspace" highlight
    /// (and the badges, which follow dsh's registry) may now be different.
    func workspaceChanged() {
        render()
        reload()
    }

    /// Language change / first mount: refresh every static label.
    func updateLabels() {
        headerTitle.text = L10n.tr("projects.title")
        // Same wording as dsh web's own "Add workspace" entry.
        newButton.toolTip = L10n.tr("projects.register")
        refreshButton.toolTip = L10n.tr("snapshot.action.refresh")
        settingsButton.toolTip = L10n.tr("settings.title")
        hideButton.toolTip = L10n.tr("preview.closePanel")
        changeRootButton.title = L10n.tr("projects.changeRoot")
        changeRootButton.toolTip = L10n.tr("projects.changeRootTooltip")
        emptyButton.title = L10n.tr("projects.register")
        updateRootLabel()
    }

    /// The panel's one-line result area (success messages fade, failures stay).
    func setStatus(_ text: String, isError: Bool) {
        statusLabel.stringValue = text
        statusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
        AppLog.shared.log("projects: " + text)
        statusClearTimer?.invalidate()
        statusClearTimer = nil
        guard !isError, !text.isEmpty else { return }
        let timer = Timer(timeInterval: 5, repeats: false) { [weak self] _ in
            self?.statusLabel.stringValue = ""
            self?.statusClearTimer = nil
        }
        RunLoop.main.add(timer, forMode: .common)
        statusClearTimer = timer
    }

    // MARK: - Creating a workspace

    /// Validate the typed name, create <root>/<name> and register it with dsh.
    /// `false` means nothing was created (the reason is shown in the panel).
    ///
    /// The `mkdir` runs synchronously: it is a single directory creation (unlike
    /// the listing and the registry read, which are slow and therefore run on a
    /// background queue), and its result decides what the caller must report.
    @discardableResult
    func createWorkspace(named raw: String) -> Bool {
        guard case .success(let name) = ProjectsCore.validateName(raw) else {
            if case .failure(let error) = ProjectsCore.validateName(raw) {
                presentError(Self.message(for: error))
            }
            return false
        }
        let root = effectiveRoot()
        let path = ProjectsCore.workspacePath(root: root, name: name)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: path, isDirectory: &isDir) {
            guard isDir.boolValue else {
                setStatus(L10n.tr("projects.createFailed", path), isError: true)
                return false
            }
            setStatus(L10n.tr("projects.nameExists"), isError: false)
        } else {
            do {
                try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
            } catch {
                setStatus(L10n.tr("projects.createFailed", error.localizedDescription), isError: true)
                return false
            }
            setStatus(L10n.tr("projects.created", name), isError: false)
        }
        // The workspace the user just made (or adopted) is the one they mean to
        // work in: select it now. The card highlight follows ProjectDirectory,
        // which only main.swift writes, so this goes through the caller.
        pendingScrollPath = DshWorkspaceStore.canonical(path)
        onSelectWorkspace?(path)
        registerInBackground(path: path)
        reload()
        return true
    }

    /// A dsh action was requested for a folder dsh does not know: say so instead
    /// of silently doing nothing (the buttons are disabled; this covers the card
    /// click and any future entry point).
    func warnNeedsWorkspace() {
        setStatus(L10n.tr("projects.needsWorkspace"), isError: true)
    }

    /// Create the dsh workspace for an existing folder (the card's own action when
    /// the badge says 未注册). Idempotent on dsh's side; on success the card flips
    /// to 已注册 and the dsh actions unlock — no page reload involved.
    func registerWorkspace(_ path: String) {
        guard let port = portProvider?(), port > 0 else {
            setStatus(L10n.tr("projects.registerFailed", "dsh web is not running"), isError: true)
            return
        }
        setStatus(L10n.tr("projects.registerPending"), isError: false)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let id = DshWorkspaceOps.register(port: port, path: path)
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard let id = id else {
                    self.setStatus(L10n.tr("projects.registerFailed", "workspace/create was rejected"), isError: true)
                    return
                }
                AppLog.shared.log("projects: registered " + path + " as " + id)
                self.setStatus(L10n.tr("projects.registerDone", (path as NSString).lastPathComponent), isError: false)
                self.onWorkspaceRegistered?(path)
                self.reload()
            }
        }
    }

    /// workspace/create is idempotent, so an existing directory is simply
    /// (re)registered. A server that cannot serve it leaves the directory in
    /// place and says so — nothing is rolled back.
    private func registerInBackground(path: String) {
        guard let port = portProvider?(), port > 0 else {
            setStatus(L10n.tr("projects.registerPending"), isError: false)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let id = DshWorkspaceOps.register(port: port, path: path)
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let id = id {
                    // The acceptance check ("did dsh register it?") reads this line.
                    AppLog.shared.log("projects: registered " + path + " as " + id)
                } else {
                    self.setStatus(L10n.tr("projects.registerPending"), isError: false)
                }
                self.reload()
                // Registration succeeded: let main.swift put dsh web on this
                // workspace (a folder dsh cannot register stays where it is).
                if id != nil { self.onWorkspaceRegistered?(path) }
            }
        }
    }

    static func message(for error: ProjectsCore.NameError) -> String {
        switch error {
        case .empty, .separator, .illegalCharacter, .dot, .hidden, .tooLong:
            return L10n.tr("projects.invalidName")
        }
    }

    private func effectiveRoot() -> String {
        if !rootPath.isEmpty { return rootPath }
        let dshHome = dshHomeProvider?() ?? (NSHomeDirectory() + "/.dsh")
        return ProjectsCore.resolvedRoot(configValue: ShellConfig.shared.string(forKey: ProjectsCore.configKey),
                                         dshHome: dshHome).path
    }

    // MARK: - Layout

    private func buildUI() {
        view.translatesAutoresizingMaskIntoConstraints = false

        // --- header: title + [+ 新建] [⟳] [⚙] [✕] ---
        headerTitle.translatesAutoresizingMaskIntoConstraints = false
        headerTitle.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = DynamicFillView()
        header.kind = .panel
        header.translatesAutoresizingMaskIntoConstraints = false
        let actions = NSStackView(views: [newButton, refreshButton, settingsButton, hideButton])
        actions.orientation = .horizontal
        actions.spacing = 6
        actions.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(headerTitle)
        header.addSubview(actions)
        NSLayoutConstraint.activate([
            headerTitle.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 10),
            headerTitle.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            headerTitle.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -8),
            actions.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -8),
            actions.centerYAnchor.constraint(equalTo: header.centerYAnchor),
        ])

        // --- root line: the effective projects root + 更改… ---
        let rootRow = DynamicFillView()
        rootRow.kind = .panel
        rootRow.translatesAutoresizingMaskIntoConstraints = false
        rootLabel.font = NSFont.systemFont(ofSize: 11)
        rootLabel.textColor = .secondaryLabelColor
        rootLabel.lineBreakMode = .byTruncatingMiddle
        rootLabel.translatesAutoresizingMaskIntoConstraints = false
        rootLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        changeRootButton.bezelStyle = .rounded
        changeRootButton.controlSize = .small
        changeRootButton.font = NSFont.systemFont(ofSize: 11)
        changeRootButton.target = self
        changeRootButton.action = #selector(changeRootTapped(_:))
        changeRootButton.translatesAutoresizingMaskIntoConstraints = false
        changeRootButton.setContentHuggingPriority(.required, for: .horizontal)
        rootRow.addSubview(rootLabel)
        rootRow.addSubview(changeRootButton)
        NSLayoutConstraint.activate([
            rootLabel.leadingAnchor.constraint(equalTo: rootRow.leadingAnchor, constant: 10),
            rootLabel.centerYAnchor.constraint(equalTo: rootRow.centerYAnchor),
            rootLabel.trailingAnchor.constraint(lessThanOrEqualTo: changeRootButton.leadingAnchor, constant: -8),
            changeRootButton.trailingAnchor.constraint(equalTo: rootRow.trailingAnchor, constant: -10),
            changeRootButton.centerYAnchor.constraint(equalTo: rootRow.centerYAnchor),
        ])

        // --- content: the workspace cards ---
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 8
        list.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 14, right: 10)
        list.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = list
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            list.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            list.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])

        // --- empty state (no workspaces yet / the root does not exist) ---
        emptyLabel.font = NSFont.systemFont(ofSize: 12)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.maximumNumberOfLines = 4
        emptyLabel.lineBreakMode = .byWordWrapping
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyButton.bezelStyle = .rounded
        emptyButton.controlSize = .regular
        emptyButton.target = self
        emptyButton.action = #selector(newWorkspaceTapped(_:))
        emptyButton.translatesAutoresizingMaskIntoConstraints = false
        emptyView.addArrangedSubview(emptyLabel)
        emptyView.addArrangedSubview(emptyButton)
        emptyView.orientation = .vertical
        emptyView.alignment = .centerX
        emptyView.spacing = 10
        emptyView.translatesAutoresizingMaskIntoConstraints = false

        // --- result line ---
        let statusRow = DynamicFillView()
        statusRow.kind = .panel
        statusRow.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusRow.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: statusRow.leadingAnchor, constant: 10),
            statusLabel.trailingAnchor.constraint(equalTo: statusRow.trailingAnchor, constant: -10),
            statusLabel.centerYAnchor.constraint(equalTo: statusRow.centerYAnchor),
        ])

        for sub in [header, rootRow, scroll, emptyView, statusRow] {
            view.addSubview(sub)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 44),

            rootRow.topAnchor.constraint(equalTo: header.bottomAnchor),
            rootRow.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            rootRow.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            rootRow.heightAnchor.constraint(equalToConstant: 28),

            scroll.topAnchor.constraint(equalTo: rootRow.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: statusRow.topAnchor),

            emptyView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            emptyView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),

            statusRow.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusRow.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusRow.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            statusRow.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    // MARK: - Actions

    @objc private func newWorkspaceTapped(_ sender: Any?) { promptForNewWorkspace() }

    /// Pick a different projects root (same setting the settings window edits).
    @objc func changeRootTapped(_ sender: Any?) { promptForRoot() }

    func promptForRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = L10n.tr("projects.changeRootTooltip")
        panel.prompt = L10n.tr("projects.settingsPick")
        if !rootPath.isEmpty { panel.directoryURL = URL(fileURLWithPath: rootPath) }
        guard let window = view.window else {
            AppLog.shared.log("projects: no window to pick a root folder in")
            return
        }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            ShellConfig.shared.set(url.path, forKey: ProjectsCore.configKey)
            self?.reload()
        }
    }

    // MARK: - Loading

    /// Re-read the root, the directory listing and dsh's workspace registry, then
    /// re-render. Everything slow runs on a background queue (the registry read can
    /// block up to 6 s on a busy or absent server).
    func reload() {
        loadToken += 1
        let token = loadToken
        let dshHome = dshHomeProvider?() ?? (NSHomeDirectory() + "/.dsh")
        let configValue = ShellConfig.shared.string(forKey: ProjectsCore.configKey)
        let resolution = ProjectsCore.resolvedRoot(configValue: configValue, dshHome: dshHome)
        rootPath = resolution.path
        updateRootLabel()
        if resolution.source == .invalidConfig {
            AppLog.shared.log("projects: the configured root is not an absolute path -> using " + resolution.path)
        }
        let port = portProvider?() ?? 0
        let usablePort: Int? = port > 0 ? port : nil

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let entries = ProjectsCore.listDirectories(root: resolution.path)
            let registry = DshWorkspaceStore.items(port: usablePort, dshHome: dshHome,
                                                   log: { AppLog.shared.log($0) })
            let merged = ProjectsCore.merge(entries: entries, registry: registry,
                                            canonical: DshWorkspaceStore.canonical)
            DispatchQueue.main.async {
                guard let self = self, self.loadToken == token else { return }
                self.workspaces = merged
                self.render()
            }
        }
    }

    private func updateRootLabel() {
        let text = rootPath.isEmpty ? effectiveRoot() : rootPath
        rootLabel.stringValue = L10n.tr("projects.rootLabel", text)
        rootLabel.toolTip = text
    }

    // MARK: - Rendering

    private func render() {
        for view in list.arrangedSubviews { view.removeFromSuperview() }
        let current = currentWorkspacePath?().map { DshWorkspaceStore.canonical($0) }
        for workspace in workspaces {
            let isCurrent = current.map { $0 == DshWorkspaceStore.canonical(workspace.path) } ?? false
            let card = ProjectCardView(workspace: workspace, isCurrent: isCurrent)
            let path = workspace.path
            // A folder without a dsh workspace cannot be linked to dsh web: those
            // two actions are refused here (the buttons are disabled too, so this
            // is the second line of defence — and the one the tests drive).
            let registered = workspace.registered
            card.onOpen = { [weak self] in
                guard registered else { self?.warnNeedsWorkspace(); return }
                self?.onEnterWorkspace?(path)
            }
            card.onPanel = { [weak self] target in self?.onOpenPanel?(path, target) }
            card.onNewSession = { [weak self] in
                guard registered else { self?.warnNeedsWorkspace(); return }
                self?.onCreateSession?(path)
            }
            card.onRegister = { [weak self] in self?.registerWorkspace(path) }
            card.onReveal = { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            card.onCopyPath = {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            }
            list.addArrangedSubview(card)
            // Stretch every card to the full content width (a stack's .leading
            // alignment only stretches the widest row). -20 = the list insets.
            card.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -20).isActive = true
        }

        let root = rootPath.isEmpty ? effectiveRoot() : rootPath
        let rootExists = FileManager.default.fileExists(atPath: root)
        emptyLabel.stringValue = rootExists ? L10n.tr("projects.empty")
                                            : L10n.tr("projects.rootMissing", root)
        emptyView.isHidden = !workspaces.isEmpty
        scroll.isHidden = workspaces.isEmpty

        scrollToNewWorkspaceIfNeeded()

        hasRendered = true
        onDidRender?()
    }

    /// Bring a just-created workspace's card on screen. The card is already
    /// highlighted (it is the current workspace now) — this makes sure the user
    /// can SEE that, instead of hunting for it in a long alphabetical list.
    private func scrollToNewWorkspaceIfNeeded() {
        guard let pending = pendingScrollPath,
              let card = list.arrangedSubviews.compactMap({ $0 as? ProjectCardView })
                  .first(where: { DshWorkspaceStore.canonical($0.workspace.path) == pending })
        else { return }
        pendingScrollPath = nil
        // The stack has just been rebuilt; scroll once it has laid out.
        DispatchQueue.main.async { [weak self] in
            guard let self = self, card.superview != nil else { return }
            self.view.layoutSubtreeIfNeeded()
            card.scrollToVisible(card.bounds.insetBy(dx: 0, dy: -10))
        }
    }

    // MARK: - The create sheet

    /// Ask for a workspace name (sheet over the window, modal when there is none)
    /// and create it. The informative text previews the path that will be created
    /// and follows what the user types.
    func promptForNewWorkspace() {
        let alert = NSAlert()
        // One name for the whole action, matching dsh web: "添加工作区 / Add workspace".
        alert.messageText = L10n.tr("projects.register")
        alert.informativeText = L10n.tr("projects.newWorkspaceLocation",
                                        ProjectsCore.workspacePath(root: effectiveRoot(), name: "..."))
        alert.addButton(withTitle: L10n.tr("files.create"))
        alert.addButton(withTitle: L10n.tr("btn.cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = L10n.tr("projects.namePlaceholder")
        field.delegate = self
        alert.accessoryView = field
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            self?.promptAlert = nil
            guard response == .alertFirstButtonReturn else { return }
            _ = self?.createWorkspace(named: field.stringValue)
        }
        guard let window = view.window else {
            AppLog.shared.log("projects: no window to prompt in")
            return
        }
        promptAlert = alert
        alert.beginSheetModal(for: window, completionHandler: finish)
        DispatchQueue.main.async { window.makeFirstResponder(field) }
    }

    /// Live "will be created at …" preview while the name is typed.
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, let alert = promptAlert else { return }
        let typed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        alert.informativeText = L10n.tr("projects.newWorkspaceLocation",
                                        ProjectsCore.workspacePath(root: effectiveRoot(),
                                                                   name: typed.isEmpty ? "..." : typed))
    }

    private func presentError(_ message: String) {
        AppLog.shared.log("projects error: " + message)
        setStatus(message, isError: true)
        // The sheet is only reachable from a mounted panel; a modal alert with no
        // window would block the app invisibly.
        guard let window = view.window, window.isVisible else { return }
        let alert = NSAlert()
        alert.messageText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.tr("btn.ok"))
        alert.beginSheetModal(for: window, completionHandler: nil)
    }
}
