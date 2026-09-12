import AppKit

// MARK: - Review（审查）panel — READ-ONLY
//
// Shows what an agent changed in this workspace's dsh sessions as a tree:
//   会话 (session) → 对话 (turn) → 文件 (file) → 变更内容 (hunks)
// Every level expands/collapses. The audit itself is computed by the shared core
// (`core/lib/review-log.js`) because dsh session logs are Zstandard frames; this
// panel runs the core CLI and renders its JSON.
//
// Design + coverage notes: docs/review-panel-design.md

/// Content surface: the paper the tree is drawn on. Follows the system
/// appearance (white in light mode, a dark surface in dark mode) — the visual
/// language still matches the Channel panel's project view.
final class ReviewPaperView: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        ReviewInk.paper.setFill()
        dirtyRect.fill()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// A light/dark pair for the rounded blocks (RoundedBlockView picks by appearance).
struct ReviewFill {
    var light: NSColor
    var dark: NSColor
    static func adaptive(light: NSColor, dark: NSColor) -> ReviewFill { ReviewFill(light: light, dark: dark) }
}

/// Panel root: non-opaque self-drawn chrome background (same pattern as
/// `TerminalRootView`/`WikiRootView`/`ChannelRootView`). The content area is a
/// white paper view mounted on top of it.
final class ReviewRootView: NSView {
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let color = dark ? NSColor(calibratedWhite: 0.20, alpha: 1) : NSColor(calibratedWhite: 0.96, alpha: 1)
        color.setFill()
        dirtyRect.fill()
    }
}

/// Appearance-adaptive palette for the review tree.
///
/// Text/icons use AppKit's semantic colours (`labelColor` / `secondaryLabelColor` /
/// `tertiaryLabelColor`, `separatorColor`) so they re-resolve automatically when
/// the user switches theme; block fills are explicit light/dark pairs (the same
/// recipe the Channel panel uses) because the tree needs more contrast than the
/// stock control colours give.
private enum ReviewInk {
    static let paper: NSColor = .textBackgroundColor
    static let title: NSColor = .labelColor
    static let body: NSColor = .secondaryLabelColor
    static let muted: NSColor = .tertiaryLabelColor
    static let hairline = ReviewFill.adaptive(
        light: NSColor(calibratedWhite: 0.80, alpha: 1),
        dark: NSColor(calibratedWhite: 0.38, alpha: 0.7))
    static let sessionFill = ReviewFill.adaptive(
        light: NSColor(calibratedRed: 0.90, green: 0.93, blue: 0.99, alpha: 1),
        dark: NSColor(calibratedRed: 0.17, green: 0.21, blue: 0.30, alpha: 1))
    static let turnFill = ReviewFill.adaptive(
        light: NSColor(calibratedWhite: 0.955, alpha: 1),
        dark: NSColor(calibratedWhite: 0.235, alpha: 1))
    static let blockFill = ReviewFill.adaptive(
        light: NSColor.white,
        dark: NSColor(calibratedWhite: 0.185, alpha: 1))
    /// The session dsh web is showing: an accent-tinted block with accent ink.
    static let currentSessionFill = ReviewFill.adaptive(
        light: NSColor.controlAccentColor.withAlphaComponent(0.20),
        dark: NSColor.controlAccentColor.withAlphaComponent(0.40))
    static let currentSessionBorder = ReviewFill.adaptive(
        light: NSColor.controlAccentColor.withAlphaComponent(0.45),
        dark: NSColor.controlAccentColor.withAlphaComponent(0.55))
    static let currentSessionTitle = NSColor.controlAccentColor
    static let added: NSColor = .systemGreen
    static let removed: NSColor = .systemRed
}

final class ReviewPanelController: NSObject {

    var onRequestHide: (() -> Void)?
    /// The workspace whose sessions are listed (wired to main.swift).
    var workspacePath: (() -> String?)?
    /// dsh web's port, for reading session titles (wired to main.swift).
    var portProvider: (() -> Int)?
    /// QA hook: fires after each render (see main.swift's --ui-debug snapshot).
    var onDidRender: (() -> Void)?

    static let minWidth: CGFloat = 320

    let view = ReviewRootView()

    // Header / toolbar
    private let headerTitle = HeaderLabel()
    private let refreshButton = CustomIconButton(glyph: .symbol("arrow.clockwise"), tooltip: "")
    private let hideButton = CustomIconButton(glyph: .close, tooltip: "")
    private let expandAllButton = NSButton(title: "", target: nil, action: nil)
    private let collapseAllButton = NSButton(title: "", target: nil, action: nil)
    private let suspectToggle = NSButton(checkboxWithTitle: "", target: nil, action: nil)

    // Content
    private let contentContainer = ReviewPaperView()
    private let scroll = NSScrollView()
    private let list = FlippedStackView()

    // State (expansion is tracked with *collapse* sets for sessions/turns and an
    // expand set for files, so a freshly loaded audit opens on a useful default).
    private var sessions: [ReviewSessionSummary] = []
    /// Session id → the title dsh web shows (that is how the user recognizes a
    /// session). Sessions absent from the web list fall back to their short id.
    private var sessionTitles: [String: String] = [:]
    private var audits: [String: ReviewAudit] = [:]
    private var auditing: Set<String> = []
    private var failedAudits: Set<String> = []
    private var expandedSessions: Set<String> = []
    private var collapsedTurns: Set<String> = []
    private var expandedFiles: Set<String> = []
    private var expandedShells: Set<String> = []
    private var activeSessionId: String?
    private var workspace: String?
    private var suspectOnly = true
    private var hasLoaded = false
    private var isLoading = false
    private var pendingReload = false
    private var loadToken = 0
    /// Sessions whose tree already got its default expansion applied.
    private var preparedSessions: Set<String> = []

    private let maxDiffLinesPerEntry = 200
    private let maxSessions = 60

    override init() {
        super.init()
        buildUI()
        refreshButton.onAction = { [weak self] in self?.reload() }
        hideButton.onAction = { [weak self] in self?.onRequestHide?() }
        expandAllButton.target = self
        expandAllButton.action = #selector(expandAllTapped(_:))
        collapseAllButton.target = self
        collapseAllButton.action = #selector(collapseAllTapped(_:))
        suspectToggle.target = self
        suspectToggle.action = #selector(suspectToggled(_:))
        updateLabels()
    }

    // MARK: - Public entry points

    /// Load once when the panel is first shown.
    func ensureLoaded() {
        if !hasLoaded { reload() }
    }

    /// Warm the session listing before the panel is ever opened (called once the
    /// dsh web page is up). The listing costs a core-CLI round trip (~0.5–1.5s on
    /// this machine); doing it in the background makes the first open render
    /// immediately instead of showing an empty panel while node starts.
    func prewarm() {
        guard !hasLoaded, !isLoading else { return }
        reload()
    }

    /// dsh web is serving (page finished loading): (re)read the session titles so
    /// rows show the names the web UI shows instead of bare hashes.
    func webPageReady() {
        refreshSessionTitles()
    }

    /// Read `sessionId → title` from dsh web. Retries a few times: at launch the
    /// server may still be booting (the port/cookie are only valid once it serves),
    /// and a single failed fetch would leave every row shown as a short id.
    private func refreshSessionTitles(attempt: Int = 0) {
        let port = portProvider?() ?? 0
        guard port > 0 else { retrySessionTitles(after: attempt); return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let value = DshWebRPC.call(DshWebRPC.sessionList, [:], port: port, timeout: 6)
            let titles = value.map { ReviewLogModel.sessionTitles(fromSessionList: $0) } ?? [:]
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard !titles.isEmpty else {
                    self.retrySessionTitles(after: attempt)
                    return
                }
                let changed = titles != self.sessionTitles
                self.sessionTitles = titles
                AppLog.shared.log("review: titles \(titles.count) (attempt \(attempt), changed=\(changed))")
                if changed, !self.sessions.isEmpty { self.render() }
            }
        }
    }

    private func retrySessionTitles(after attempt: Int) {
        guard attempt < 6 else {
            AppLog.shared.log("review: titles unavailable after \(attempt) attempts (showing short ids)")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.refreshSessionTitles(attempt: attempt + 1)
        }
    }

    /// The workspace changed (session/project switch) — re-list, keep the audit
    /// cache (a session's audit does not depend on the current workspace).
    func workspaceChanged() {
        // Switching between sessions of the SAME workspace must not re-list: the
        // session list is unchanged, and re-listing was the flicker (and the
        // stale-list race) on every session switch.
        let resolved = workspacePath?()
        if let resolved = resolved, resolved == workspace { return }
        hasLoaded = false
        reload()
    }

    /// Follow the session dsh web is showing: expand it (auditing it if needed).
    /// Works even when that session belongs to another workspace — the session is
    /// resolved by id, never by the workspace list.
    func setActiveSession(_ sessionId: String?) {
        guard let sessionId = sessionId, !sessionId.isEmpty else { return }
        let changed = activeSessionId != sessionId
        activeSessionId = sessionId
        guard changed else { return }

        // The tree follows dsh web: the followed session is the ONLY expanded one
        // (switching sessions collapses whatever was open before), and its turns
        // reopen so the newest 对话 is visible immediately.
        expandedSessions = [sessionId]
        let prefix = "turn:\(sessionId)#"
        collapsedTurns = collapsedTurns.filter { !$0.hasPrefix(prefix) }
        let listed = sessions.contains { $0.id == sessionId }
        AppLog.shared.log("review: follow web session \(sessionId) (listed=\(listed))")
        ensureAudit(sessionId)

        if listed {
            render()
            return
        }
        // Not in the current list: another workspace, or older than the cap.
        // A listing already in flight will pick the current active id up when it
        // lands; otherwise re-list. Never paint the stale list here — that is
        // exactly what showed one workspace's sessions under another's session.
        if !isLoading { reload() }
    }

    /// Language change → refresh the visible strings.
    func refreshTooltips() {
        updateLabels()
        render()
    }

    private var isViewVisible: Bool { view.superview != nil }

    private func updateLabels() {
        headerTitle.text = L10n.tr("review.title")
        refreshButton.toolTip = L10n.tr("review.refresh")
        hideButton.toolTip = L10n.tr("preview.closePanel")
        expandAllButton.title = L10n.tr("review.expandAll")
        collapseAllButton.title = L10n.tr("review.collapseAll")
        suspectToggle.title = L10n.tr("review.suspectOnly")
    }

    // MARK: - Build

    private func buildUI() {
        headerTitle.translatesAutoresizingMaskIntoConstraints = false
        headerTitle.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let actions = NSStackView(views: [refreshButton, hideButton])
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
        ])

        // Toolbar: tree-wide expand/collapse + the shell-command filter.
        let toolbar = DynamicFillView()
        toolbar.kind = .window
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.wantsLayer = true
        toolbar.layer?.masksToBounds = true

        for button in [expandAllButton, collapseAllButton] {
            button.translatesAutoresizingMaskIntoConstraints = false
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = NSFont.systemFont(ofSize: 11)
        }
        suspectToggle.translatesAutoresizingMaskIntoConstraints = false
        suspectToggle.controlSize = .small
        suspectToggle.font = NSFont.systemFont(ofSize: 11)
        suspectToggle.state = suspectOnly ? .on : .off

        let toolbarSeparator = NSBox()
        toolbarSeparator.boxType = .separator
        toolbarSeparator.translatesAutoresizingMaskIntoConstraints = false

        toolbar.addSubview(expandAllButton)
        toolbar.addSubview(collapseAllButton)
        toolbar.addSubview(suspectToggle)
        toolbar.addSubview(toolbarSeparator)
        NSLayoutConstraint.activate([
            expandAllButton.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 10),
            expandAllButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            collapseAllButton.leadingAnchor.constraint(equalTo: expandAllButton.trailingAnchor, constant: 6),
            collapseAllButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            suspectToggle.leadingAnchor.constraint(greaterThanOrEqualTo: collapseAllButton.trailingAnchor, constant: 8),
            suspectToggle.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -10),
            suspectToggle.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            toolbarSeparator.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
            toolbarSeparator.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),
            toolbarSeparator.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor),
        ])

        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.wantsLayer = true
        contentContainer.layer?.masksToBounds = true

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        // Overlay scrollers: a legacy scroller takes ~16pt from the clip view, so
        // the rows would visibly narrow the moment clicking a session makes the
        // content taller than the viewport.
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

        contentContainer.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])

        // NOTE: the root view stays translatesAutoresizingMaskIntoConstraints = true
        // (the default) — NSSplitView sizes the pane by frame, and every other
        // panel's root view is left that way. Opting into Auto Layout here produced
        // a stale layout on the first mount (pane 620pt wide with its 505pt
        // header/content), which also left the content area empty.
        view.addSubview(header)
        view.addSubview(toolbar)
        view.addSubview(contentContainer)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 40),
            toolbar.topAnchor.constraint(equalTo: header.bottomAnchor),
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 28),
            contentContainer.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    // MARK: - Loading

    private func reload() {
        if isLoading {
            // Never drop a request: the follow-web-session path and the
            // workspace-change path both call reload(), and a dropped second
            // call is exactly how the panel used to show another session's data.
            pendingReload = true
            return
        }
        guard let workspace = workspacePath?(), !workspace.isEmpty else {
            showStatus(L10n.tr("review.noWorkspace"))
            return
        }
        isLoading = true
        loadToken += 1
        let token = loadToken
        let workspaceAtStart = workspace
        let activeAtStart = activeSessionId
        self.workspace = workspace
        // Keep whatever is already rendered (a refresh must not blank the panel);
        // only an empty panel falls back to the centred status text.
        if sessions.isEmpty { showStatus(L10n.tr("review.loading")) } else { render() }
        AppLog.shared.log("review: list sessions workspace=\(workspace) active=\(activeAtStart ?? "-")")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // One listing without a workspace filter: the panel partitions it
            // itself, so the session dsh web is showing is found even when it
            // belongs to another workspace (the old --workspace filter silently
            // dropped it, which is why the panel could show a different session).
            let listedJSON = CoreBridge.run(["review", "sessions", "--limit", "200"],
                                            timeout: 60, preferBundledNode: true)
            let listed = listedJSON.flatMap { ReviewLogModel.decodeSessions($0) }
            var sessions = listed?.sessions ?? []
            let total = listed?.total ?? sessions.count
            // STRICTLY the sessions of the workspace being shown (never pin the
            // followed session: a cross-workspace switch must not leave the
            // previous workspace's session above the new workspace's list).
            let scoped = ReviewLogModel.sessionsForWorkspace(sessions, workspace: workspaceAtStart,
                                                             limit: self?.maxSessions ?? 60)
            sessions = scoped.sessions
            let truncated = scoped.beyondLimit
            let diagnostics = listed?.diagnostics ?? []
            DispatchQueue.main.async {
                guard let self = self, self.loadToken == token else { return }
                self.isLoading = false
                self.hasLoaded = true
                self.sessions = sessions
                // Names come from dsh web and are fetched separately (below): at
                // launch the web server is not serving yet, so a fetch bundled into
                // the listing silently produced hashes for the first render.
                self.refreshSessionTitles()
                // Resolve the followed session against the CURRENT active id (it can
                // change while a listing is in flight — that is the cross-workspace
                // switch), never against the id captured when the listing started.
                let activeNow = self.activeSessionId
                if let followed = sessions.first(where: { $0.id == activeNow }) {
                    self.expandedSessions.insert(followed.id)
                } else if !sessions.contains(where: { self.expandedSessions.contains($0.id) }),
                          let first = sessions.first {
                    self.expandedSessions.insert(first.id)
                }
                AppLog.shared.log("review: listed \(sessions.count)/\(total) sessions workspace=\(workspaceAtStart) "
                    + "first=\(sessions.first?.id ?? "-") active=\(activeNow ?? "-") "
                    + "matched=\(sessions.contains { $0.id == activeNow }) "
                    + "expanded=\(self.expandedSessions.count) truncated=\(truncated) diagnostics=\(diagnostics.count)")
                if sessions.isEmpty {
                    self.showStatus(L10n.tr("review.noSessions"))
                } else {
                    self.render()
                    // Audit the sessions the user can actually see expanded.
                    for session in sessions where self.expandedSessions.contains(session.id) {
                        self.ensureAudit(session.id)
                    }
                }
                if self.pendingReload {
                    self.pendingReload = false
                    self.reload()
                }
            }
        }
    }

    /// Audit one session on demand (cached; never audits twice).
    private func ensureAudit(_ sessionId: String) {
        if audits[sessionId] != nil || auditing.contains(sessionId) { return }
        auditing.insert(sessionId)
        AppLog.shared.log("review: audit \(sessionId)")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // No --workspace: the id alone must resolve, wherever that session lives.
            let json = CoreBridge.run(["review", "audit", sessionId], timeout: 180, preferBundledNode: true)
            let audit = json.flatMap { ReviewLogModel.decodeAudit($0) }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.auditing.remove(sessionId)
                if let audit = audit, audit.session != nil {
                    self.audits[sessionId] = audit
                    let codes = (audit.diagnostics ?? []).map { $0.code }.joined(separator: ",")
                    AppLog.shared.log("review: audit \(sessionId) entries=\(audit.entries.count) "
                        + "files=\(audit.stats?.files ?? -1) turns=\(audit.turns?.count ?? 0) diagnostics=[\(codes)]")
                    if !self.preparedSessions.contains(sessionId), self.expandedSessions.contains(sessionId) {
                        // Default tree state: the newest 对话 open, older ones folded.
                        self.preparedSessions.insert(sessionId)
                        let groups = ReviewLogModel.turnGroups(audit, suspectShellsOnly: self.suspectOnly)
                        for group in groups.dropFirst() {
                            self.collapsedTurns.insert(self.expandKeyTurn(sessionId, group.turn))
                        }
                    }
                } else {
                    self.failedAudits.insert(sessionId)
                    AppLog.shared.log("review: audit FAILED for \(sessionId)")
                }
                self.render()
            }
        }
    }

    /// Status line rendered as a top-aligned card instead of a centred label:
    /// it paints immediately (no blank panel while the core CLI runs) and does
    /// not jump when the real rows arrive.
    private func showStatus(_ text: String) {
        let card = makeCard(text: text, fill: ReviewInk.turnFill, textColor: ReviewInk.body,
                            font: NSFont.systemFont(ofSize: 11), padding: 9)
        list.setViews([card], in: .top)
        card.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -20).isActive = true
    }

    // MARK: - Actions

    @objc private func suspectToggled(_ sender: Any?) {
        suspectOnly = (sender as? NSButton)?.state == .on
        render()
    }

    @objc private func expandAllTapped(_ sender: Any?) {
        for session in sessions {
            expandedSessions.insert(session.id)
            ensureAudit(session.id)
        }
        for (id, audit) in audits {
            for group in ReviewLogModel.turnGroups(audit, suspectShellsOnly: suspectOnly) {
                collapsedTurns.remove(expandKeyTurn(id, group.turn))
                for file in group.files { expandedFiles.insert(expandKeyFile(id, group.turn, file.path)) }
            }
        }
        render()
    }

    @objc private func collapseAllTapped(_ sender: Any?) {
        expandedSessions.removeAll()
        expandedFiles.removeAll()
        collapsedTurns.removeAll()
        render()
    }

    /// Expansion keys for the tree (one per level, scoped to its session).
    private func expandKeyTurn(_ sessionId: String, _ turn: Int?) -> String { "turn:\(sessionId)#\(turn.map(String.init) ?? "-")" }
    private func expandKeyFile(_ sessionId: String, _ turn: Int?, _ path: String) -> String { "file:\(expandKeyTurn(sessionId, turn))#\(path)" }
    private func expandKeyShell(_ sessionId: String, _ turn: Int?) -> String { "shell:\(expandKeyTurn(sessionId, turn))" }

    // MARK: - Rendering

    private func render() {
        // Click closures live in `headerActions` keyed by view identity; every
        // render rebuilds the tree, so stale entries must not accumulate.
        headerActions.removeAll()
        var rows: [NSView] = []
        rows.append(makeSummaryCard())
        for session in sessions {
            rows.append(makeSessionBlock(session))
        }
        list.setViews(rows, in: .top)
        // Full-width rows: a .leading-aligned stack sizes arranged views to their
        // fitting width, which would leave short rows hugging their content.
        for row in rows {
            row.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -20).isActive = true
        }
        onDidRender?()
    }

    /// Header summary over everything currently audited (never a half-filled line:
    /// every number is labelled, and the audited/total session count is explicit).
    private func makeSummaryCard() -> NSView {
        var sessionsCount = 0
        var turnsCount = 0
        var files = Set<String>()
        var added = 0, removed = 0, nested = 0, suspect = 0, shells = 0, failed = 0
        for (id, audit) in audits {
            guard let stats = audit.stats else { continue }
            sessionsCount += 1
            turnsCount += ReviewLogModel.turnGroups(audit, suspectShellsOnly: suspectOnly).count
            for group in ReviewLogModel.fileGroups(ReviewLogModel.mutations(audit.entries)) {
                files.insert("\(id)#\(group.path)")
            }
            added += stats.added
            removed += stats.removed
            nested += stats.nested
            suspect += stats.bashSuspect
            shells += stats.bashCalls
            failed += stats.failed
        }
        var parts: [String] = []
        if isLoading { parts.append(L10n.tr("review.reading")) }
        parts.append(contentsOf: [
            L10n.tr("review.summarySessions") + " \(sessionsCount)/\(sessions.count)",
            L10n.tr("review.summaryTurns") + " \(turnsCount)",
            L10n.tr("review.filesShort") + " \(files.count)",
            "+\(added) −\(removed)",
            L10n.tr("review.nested") + " \(nested)",
            L10n.tr("review.suspectShort") + " \(suspect)/\(shells)",
            L10n.tr("review.error") + " \(failed)",
        ])
        if let active = activeSessionId, !active.isEmpty,
           !sessions.contains(where: { $0.id == active }) {
            // The followed session is not part of this workspace's list (another
            // workspace, or older than the cap) — say so instead of showing it.
            parts.append(L10n.tr("review.activeElsewhere"))
        }
        return makeCard(text: parts.joined(separator: "  ·  "), fill: ReviewInk.turnFill,
                        textColor: ReviewInk.body, font: NSFont.systemFont(ofSize: 11), padding: 9)
    }

    private func makeSessionBlock(_ session: ReviewSessionSummary) -> NSView {
        let expanded = expandedSessions.contains(session.id)
        let audit = audits[session.id]
        var trailing = ""
        if auditing.contains(session.id) {
            trailing = L10n.tr("review.reading")
        } else if let stats = audit?.stats {
            trailing = "\(stats.files) " + L10n.tr("review.filesShort")
                + " ·  +\(stats.added) −\(stats.removed)"
                + (stats.nested > 0 ? " ·  " + L10n.tr("review.nested") + " \(stats.nested)" : "")
        } else if failedAudits.contains(session.id) {
            trailing = L10n.tr("review.loadFailed")
        } else if expanded {
            trailing = L10n.tr("review.reading")
        }
        let shortId = ReviewLogModel.shortId(session.id)
        // A titleless session is what dsh web itself renders as "New Session" /
        // "新会话" — match it instead of showing a bare hash.
        let displayName = ReviewLogModel.sessionDisplayName(id: session.id, titles: sessionTitles,
                                                            untitledPlaceholder: L10n.tr("review.untitled"))
        let webTitle = sessionTitles[session.id]
        var detail = shortId + " · " + ReviewLogModel.clockLabel(session.mtimeMs)
            + " · " + ReviewLogModel.byteLabel(session.sizeBytes)
        if session.isSubagent { detail += " · " + L10n.tr("review.subagent") }

        var children: [NSView] = []
        if expanded {
            if let audit = audit {
                let groups = ReviewLogModel.turnGroups(audit, suspectShellsOnly: suspectOnly)
                if groups.isEmpty {
                    children.append(makeNote(L10n.tr("review.empty")))
                } else {
                    for group in groups { children.append(makeTurnBlock(sessionId: session.id, group: group)) }
                }
                for diagnostic in audit.diagnostics ?? [] {
                    children.append(makeNote(diagnostic.message))
                }
            } else if failedAudits.contains(session.id) {
                children.append(makeNote(L10n.tr("review.loadFailed")))
            } else {
                children.append(makeNote(L10n.tr("review.reading")))
            }
        }
        // The session dsh web is showing is highlighted by fill + accent title
        // instead of a "current" text suffix.
        let isCurrent = session.id == activeSessionId
        return makeBlock(title: displayName, detail: detail, trailing: trailing,
                         symbol: "doc.text",
                         fill: isCurrent ? ReviewInk.currentSessionFill : ReviewInk.sessionFill,
                         border: isCurrent ? ReviewInk.currentSessionBorder : ReviewInk.hairline,
                         titleFont: NSFont.systemFont(ofSize: 13, weight: .semibold),
                         titleColor: isCurrent ? ReviewInk.currentSessionTitle : ReviewInk.title,
                         expanded: expanded,
                         onToggle: { [weak self] in
                             guard let self = self else { return }
                             if self.expandedSessions.contains(session.id) {
                                 self.expandedSessions.remove(session.id)
                             } else {
                                 self.expandedSessions.insert(session.id)
                                 self.ensureAudit(session.id)
                             }
                             self.render()
                         },
                         onOpen: nil,
                         titleTooltip: webTitle.map { "\($0)\n\(session.id)" } ?? session.id,
                         children: children)
    }

    private func makeTurnBlock(sessionId: String, group: ReviewLogModel.ReviewTurnGroup) -> NSView {
        let key = expandKeyTurn(sessionId, group.turn)
        let expanded = !collapsedTurns.contains(key)
        let title = group.turn.map { L10n.tr("review.turn") + " \($0)" } ?? L10n.tr("review.turnUnknown")
        var prompt: String? = group.prompt?.replacingOccurrences(of: "\n", with: " ")
        if let text = prompt, text.count > 240 { prompt = String(text.prefix(240)) + "…" }
        var parts = ["\(group.files.count) " + L10n.tr("review.filesShort"), "+\(group.added) −\(group.removed)"]
        if !group.shells.isEmpty { parts.append(L10n.tr("review.shell") + " \(group.shells.count)") }
        if !group.failures.isEmpty { parts.append(L10n.tr("review.error") + " \(group.failures.count)") }

        var children: [NSView] = []
        if expanded {
            for file in group.files { children.append(makeFileBlock(sessionId: sessionId, turn: group.turn, group: file)) }
            if !group.shells.isEmpty { children.append(makeShellBlock(sessionId: sessionId, turn: group.turn, entries: group.shells)) }
            if !group.failures.isEmpty { children.append(makeFailureBlock(entries: group.failures)) }
        }
        return makeBlock(title: title, detail: nil, subtitle: prompt, trailing: parts.joined(separator: " · "),
                         symbol: "bubble.left", fill: ReviewInk.turnFill, border: ReviewInk.hairline,
                         titleFont: NSFont.systemFont(ofSize: 12, weight: .semibold), titleColor: ReviewInk.title,
                         expanded: expanded,
                         onToggle: { [weak self] in
                             guard let self = self else { return }
                             if self.collapsedTurns.contains(key) { self.collapsedTurns.remove(key) } else { self.collapsedTurns.insert(key) }
                             self.render()
                         },
                         onOpen: nil,
                         children: children)
    }

    private func makeFileBlock(sessionId: String, turn: Int?, group: ReviewFileGroup) -> NSView {
        let key = expandKeyFile(sessionId, turn, group.path)
        let expanded = expandedFiles.contains(key)
        var badges: [String] = []
        if group.created { badges.append(L10n.tr("review.cat.create")) }
        if group.hasNested { badges.append(L10n.tr("review.nested")) }
        var parts = ["+\(group.added) −\(group.removed)"]
        parts.append(contentsOf: badges)

        var children: [NSView] = []
        if expanded {
            for entry in group.entries {
                children.append(makeEntryMetaRow(entry))
                let lines = ReviewLogModel.diffLines(entry.hunks)
                if !lines.isEmpty { children.append(makeDiffView(lines)) }
            }
        }
        return makeBlock(title: group.path, detail: nil, trailing: parts.joined(separator: " · "),
                         symbol: "doc.text", fill: ReviewInk.blockFill, border: ReviewInk.hairline,
                         titleFont: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold), titleColor: ReviewInk.body,
                         expanded: expanded,
                         onToggle: { [weak self] in
                             guard let self = self else { return }
                             if self.expandedFiles.contains(key) { self.expandedFiles.remove(key) } else { self.expandedFiles.insert(key) }
                             self.render()
                         },
                         onOpen: nil,
                         children: children)
    }

    private func makeShellBlock(sessionId: String, turn: Int?, entries: [ReviewEntry]) -> NSView {
        let key = expandKeyShell(sessionId, turn)
        let expanded = expandedShells.contains(key)
        var children: [NSView] = []
        if expanded {
            children.append(makeNote(L10n.tr("review.unstructuredNote")))
            for entry in entries.prefix(80) {
                children.append(makeCodeLine(entry.command ?? "", color: ReviewInk.body))
            }
            if entries.count > 80 {
                children.append(makeNote(String(format: L10n.tr("review.moreLines"), entries.count - 80)))
            }
        }
        return makeBlock(title: L10n.tr("review.bashHeader"), detail: nil, trailing: "\(entries.count)",
                         symbol: "terminal", fill: ReviewInk.blockFill, border: ReviewInk.hairline,
                         titleFont: NSFont.systemFont(ofSize: 11, weight: .semibold), titleColor: ReviewInk.body,
                         expanded: expanded,
                         onToggle: { [weak self] in
                             guard let self = self else { return }
                             if self.expandedShells.contains(key) { self.expandedShells.remove(key) } else { self.expandedShells.insert(key) }
                             self.render()
                         },
                         onOpen: nil,
                         children: children)
    }

    private func makeFailureBlock(entries: [ReviewEntry]) -> NSView {
        var children: [NSView] = []
        for entry in entries.prefix(40) {
            children.append(makeCodeLine("\(entry.tool) · \(entry.path ?? entry.command ?? "")", color: ReviewInk.removed))
        }
        return makeBlock(title: L10n.tr("review.failedHeader"), detail: nil, trailing: "\(entries.count)",
                         symbol: "exclamationmark.triangle", fill: ReviewInk.blockFill, border: ReviewInk.hairline,
                         titleFont: NSFont.systemFont(ofSize: 11, weight: .semibold), titleColor: ReviewInk.body,
                         expanded: true, onToggle: nil, onOpen: nil, children: children)
    }

    // MARK: - Block construction

    /// One disclosure block: a clickable title bar (chevron + symbol + title +
    /// detail + trailing summary) and an optional children stack — the same
    /// rounded-block language the Channel panel's project view uses.
    private func makeBlock(title: String, detail: String?, subtitle: String? = nil, trailing: String?, symbol: String,
                           fill: ReviewFill, border: ReviewFill, titleFont: NSFont, titleColor: NSColor,
                           expanded: Bool, onToggle: (() -> Void)?, onOpen: (() -> Void)?,
                           titleTooltip: String? = nil, children: [NSView]) -> NSView {
        let block = RoundedBlockView()
        block.translatesAutoresizingMaskIntoConstraints = false
        block.radius = 8
        block.lightFill = fill.light
        block.darkFill = fill.dark
        block.lightBorder = border.light
        block.darkBorder = border.dark

        let chevron = NSImageView()
        if let image = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil) {
            chevron.image = image
            chevron.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            chevron.contentTintColor = ReviewInk.muted
        }
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.widthAnchor.constraint(equalToConstant: 14).isActive = true
        chevron.heightAnchor.constraint(equalToConstant: 14).isActive = true

        let icon = NSImageView()
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            icon.image = image
            icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
            icon.contentTintColor = ReviewInk.muted
        }
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 15).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 15).isActive = true

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = titleFont
        titleLabel.textColor = titleColor
        titleLabel.lineBreakMode = .byTruncatingTail
        // The title is the block's identity ("对话 2", the session name): it keeps
        // its intrinsic width, and the flexible detail/subtitle gives way instead.
        // (With low resistance the prompt text used to squeeze the title away.)
        titleLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.toolTip = titleTooltip ?? title

        var headerViews: [NSView] = [chevron, icon, titleLabel]
        if let detail = detail, !detail.isEmpty {
            let detailLabel = NSTextField(labelWithString: detail)
            detailLabel.font = NSFont.systemFont(ofSize: 10)
            detailLabel.textColor = ReviewInk.muted
            detailLabel.lineBreakMode = .byTruncatingTail
            detailLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
            detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            detailLabel.translatesAutoresizingMaskIntoConstraints = false
            headerViews.append(detailLabel)
        }
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        headerViews.append(spacer)
        if let trailing = trailing, !trailing.isEmpty {
            let trailingLabel = NSTextField(labelWithString: trailing)
            trailingLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
            trailingLabel.textColor = ReviewInk.body
            trailingLabel.translatesAutoresizingMaskIntoConstraints = false
            trailingLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            headerViews.append(trailingLabel)
        }

        let headerRow = NSStackView(views: headerViews)
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 6
        headerRow.translatesAutoresizingMaskIntoConstraints = false

        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(headerRow)
        var headerBottom = headerRow.bottomAnchor
        var headerBottomInset: CGFloat = -7
        if let subtitle = subtitle, !subtitle.isEmpty {
            // Long content (a turn's prompt) goes on its own line instead of
            // fighting the title for horizontal space.
            let subtitleLabel = NSTextField(wrappingLabelWithString: subtitle)
            subtitleLabel.font = NSFont.systemFont(ofSize: 10)
            subtitleLabel.textColor = ReviewInk.muted
            subtitleLabel.maximumNumberOfLines = 2
            subtitleLabel.lineBreakMode = .byTruncatingTail
            subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(subtitleLabel)
            NSLayoutConstraint.activate([
                subtitleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 34),
                subtitleLabel.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -8),
                subtitleLabel.topAnchor.constraint(equalTo: headerRow.bottomAnchor, constant: 1),
            ])
            headerBottom = subtitleLabel.bottomAnchor
            headerBottomInset = -6
        }
        NSLayoutConstraint.activate([
            headerRow.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 8),
            headerRow.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -8),
            headerRow.topAnchor.constraint(equalTo: header.topAnchor, constant: 7),
            headerBottom.constraint(equalTo: header.bottomAnchor, constant: headerBottomInset),
        ])
        if onToggle != nil {
            let click = NSClickGestureRecognizer(target: self, action: #selector(blockTapped(_:)))
            header.addGestureRecognizer(click)
            headerActions[ObjectIdentifier(header)] = onToggle
        }

        let childrenStack = NSStackView()
        childrenStack.orientation = .vertical
        childrenStack.alignment = .leading
        childrenStack.spacing = 6
        childrenStack.translatesAutoresizingMaskIntoConstraints = false
        childrenStack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        for child in children {
            childrenStack.addArrangedSubview(child)
            child.widthAnchor.constraint(equalTo: childrenStack.widthAnchor).isActive = true
        }
        childrenStack.isHidden = !expanded

        block.addSubview(header)
        block.addSubview(childrenStack)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: block.topAnchor),
            header.leadingAnchor.constraint(equalTo: block.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: block.trailingAnchor),
        ])
        if expanded {
            NSLayoutConstraint.activate([
                childrenStack.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
                childrenStack.leadingAnchor.constraint(equalTo: block.leadingAnchor, constant: 12),
                childrenStack.trailingAnchor.constraint(equalTo: block.trailingAnchor, constant: -10),
                childrenStack.bottomAnchor.constraint(equalTo: block.bottomAnchor, constant: -8),
            ])
        } else {
            NSLayoutConstraint.activate([
                header.bottomAnchor.constraint(equalTo: block.bottomAnchor),
            ])
        }
        return block
    }

    /// Click routing for block headers (the header view is created inside
    /// `makeBlock`, so its target closure is kept here).
    private var headerActions: [ObjectIdentifier: () -> Void] = [:]

    @objc private func blockTapped(_ gesture: NSClickGestureRecognizer) {
        guard let view = gesture.view else { return }
        headerActions[ObjectIdentifier(view)]?()
    }

    // MARK: - Leaf views

    private func makeCard(text: String, fill: ReviewFill, textColor: NSColor, font: NSFont, padding: CGFloat) -> NSView {
        let card = RoundedBlockView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.radius = 8
        card.lightFill = fill.light
        card.darkFill = fill.dark
        card.lightBorder = ReviewInk.hairline.light
        card.darkBorder = ReviewInk.hairline.dark
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = font
        label.textColor = textColor
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: card.topAnchor, constant: padding),
            label.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -padding),
            label.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
        ])
        return card
    }

    private func makeNote(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = NSFont.systemFont(ofSize: 10)
        label.textColor = ReviewInk.muted
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func makeCodeLine(_ text: String, color: NSColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        label.textColor = color
        label.maximumNumberOfLines = 6
        label.lineBreakMode = .byCharWrapping
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func makeEntryMetaRow(_ entry: ReviewEntry) -> NSTextField {
        var parts: [String] = [entry.tool]
        if let turn = entry.turn, let step = entry.step { parts.append("T\(turn)/S\(step)") }
        switch entry.category {
        case "diff": parts.append(L10n.tr("review.cat.diff"))
        case "args": parts.append(L10n.tr("review.cat.args"))
        case "content": parts.append(L10n.tr("review.cat.content"))
        case "bash": parts.append(entry.suspicion == "write-like" ? L10n.tr("review.suspect") : L10n.tr("review.shell"))
        default: parts.append(L10n.tr("review.other"))
        }
        if entry.isNested { parts.append(L10n.tr("review.nestedCall")) }
        if entry.isError { parts.append(L10n.tr("review.error")) }
        let label = NSTextField(labelWithString: parts.joined(separator: " · "))
        label.font = NSFont.systemFont(ofSize: 10)
        label.textColor = ReviewInk.muted
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func makeDiffView(_ lines: [ReviewDiffLine]) -> NSTextField {
        let shown = Array(lines.prefix(maxDiffLinesPerEntry))
        let text = NSMutableAttributedString()
        let font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
        for line in shown {
            let prefix = line.kind == .removed ? "− " : "+ "
            text.append(NSAttributedString(string: prefix + line.text + "\n",
                                           attributes: [.font: font,
                                                        .foregroundColor: line.kind == .removed ? ReviewInk.removed : ReviewInk.added]))
        }
        if lines.count > shown.count {
            text.append(NSAttributedString(string: String(format: L10n.tr("review.moreLines"), lines.count - shown.count) + "\n",
                                           attributes: [.font: font, .foregroundColor: ReviewInk.muted]))
        }
        let field = NSTextField(labelWithAttributedString: text)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.isEditable = false
        field.isSelectable = true
        field.maximumNumberOfLines = 0
        field.lineBreakMode = .byCharWrapping
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // No own background: the field sits on the block surface, so it follows
        // the theme instead of pinning a white rectangle in dark mode.
        field.drawsBackground = false
        return field
    }
}
