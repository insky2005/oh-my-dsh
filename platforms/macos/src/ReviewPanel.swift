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

/// Content background: white, per the panel's document-style look (the visual
/// language follows the Channel panel's project view, which uses light rounded
/// blocks on a light surface).
final class ReviewPaperView: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        dirtyRect.fill()
    }
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

/// Palette for the white content surface (explicit colours so the tree stays
/// readable on the white paper regardless of the system appearance).
private enum ReviewInk {
    static let title = NSColor(calibratedWhite: 0.13, alpha: 1)
    static let body = NSColor(calibratedWhite: 0.30, alpha: 1)
    static let muted = NSColor(calibratedWhite: 0.52, alpha: 1)
    static let hairline = NSColor(calibratedWhite: 0.80, alpha: 1)
    static let sessionFill = NSColor(calibratedRed: 0.90, green: 0.93, blue: 0.99, alpha: 1)
    static let turnFill = NSColor(calibratedWhite: 0.955, alpha: 1)
    static let blockFill = NSColor.white
    static let added = NSColor(calibratedRed: 0.10, green: 0.48, blue: 0.20, alpha: 1)
    static let removed = NSColor(calibratedRed: 0.72, green: 0.16, blue: 0.16, alpha: 1)
}

final class ReviewPanelController: NSObject {

    var onRequestHide: (() -> Void)?
    /// The workspace whose sessions are listed (wired to main.swift).
    var workspacePath: (() -> String?)?
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
    private let statusLabel = NSTextField(wrappingLabelWithString: "")

    // State (expansion is tracked with *collapse* sets for sessions/turns and an
    // expand set for files, so a freshly loaded audit opens on a useful default).
    private var sessions: [ReviewSessionSummary] = []
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

    /// The workspace changed (session/project switch) — re-list, keep the audit
    /// cache (a session's audit does not depend on the current workspace).
    func workspaceChanged() {
        hasLoaded = false
        if isViewVisible { reload() }
    }

    /// Follow the session dsh web is showing: expand it (auditing it if needed).
    /// Works even when that session belongs to another workspace — the session is
    /// resolved by id, never by the workspace list.
    func setActiveSession(_ sessionId: String?) {
        guard let sessionId = sessionId, !sessionId.isEmpty else { return }
        let changed = activeSessionId != sessionId
        activeSessionId = sessionId
        if !sessions.contains(where: { $0.id == sessionId }) && !isLoading {
            // Not in the current list (older than the cap, or another workspace):
            // re-list before giving up, then expand whatever came back.
            reload()
        }
        if changed {
            expandedSessions.insert(sessionId)
            // Reopen every turn of that session (collapse state is keyed per turn).
            let prefix = "turn:\(sessionId)#"
            collapsedTurns = collapsedTurns.filter { !$0.hasPrefix(prefix) }
            AppLog.shared.log("review: follow web session \(sessionId) (listed=\(sessions.contains { $0.id == sessionId }))")
        }
        ensureAudit(sessionId)
        render()
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

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = ReviewInk.muted
        statusLabel.alignment = .center
        statusLabel.isHidden = true

        contentContainer.addSubview(scroll)
        contentContainer.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            statusLabel.centerXAnchor.constraint(equalTo: contentContainer.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: contentContainer.centerYAnchor),
            statusLabel.widthAnchor.constraint(lessThanOrEqualTo: contentContainer.widthAnchor, constant: -40),
        ])

        view.translatesAutoresizingMaskIntoConstraints = false
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
        showStatus(L10n.tr("review.loading"))
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
            let inWorkspace = sessions.filter { $0.cwd == workspaceAtStart }
            let active = activeAtStart.flatMap { id in sessions.first { $0.id == id } }
            sessions = inWorkspace
            if let active = active, !sessions.contains(where: { $0.id == active.id }) {
                sessions.insert(active, at: 0)
            }
            if sessions.count > self?.maxSessions ?? 60 {
                sessions = Array(sessions.prefix(self?.maxSessions ?? 60))
            }
            let diagnostics = listed?.diagnostics ?? []
            DispatchQueue.main.async {
                guard let self = self, self.loadToken == token else { return }
                self.isLoading = false
                self.hasLoaded = true
                self.sessions = sessions
                if let first = sessions.first(where: { $0.id == activeAtStart }) {
                    // The web session is in the list: open it (and only it).
                    self.expandedSessions.insert(first.id)
                } else if self.expandedSessions.isEmpty, let first = sessions.first {
                    self.expandedSessions.insert(first.id)
                }
                AppLog.shared.log("review: listed \(sessions.count)/\(total) sessions for workspace "
                    + "(active matched=\(sessions.contains { $0.id == activeAtStart })) diagnostics=\(diagnostics.count)")
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

    private func showStatus(_ text: String) {
        list.setViews([], in: .top)
        statusLabel.stringValue = text
        statusLabel.isHidden = false
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
        statusLabel.isHidden = true
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
        let parts = [
            L10n.tr("review.summarySessions") + " \(sessionsCount)/\(sessions.count)",
            L10n.tr("review.summaryTurns") + " \(turnsCount)",
            L10n.tr("review.filesShort") + " \(files.count)",
            "+\(added) −\(removed)",
            L10n.tr("review.nested") + " \(nested)",
            L10n.tr("review.suspectShort") + " \(suspect)/\(shells)",
            L10n.tr("review.error") + " \(failed)",
        ]
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
        var detail = ReviewLogModel.clockLabel(session.mtimeMs) + " · " + ReviewLogModel.byteLabel(session.sizeBytes)
        if session.isSubagent { detail += " · " + L10n.tr("review.subagent") }
        if session.id == activeSessionId { detail += " · " + L10n.tr("review.current") }

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
        return makeBlock(title: ReviewLogModel.shortId(session.id), detail: detail, trailing: trailing,
                         symbol: "doc.text", fill: ReviewInk.sessionFill, border: ReviewInk.hairline,
                         titleFont: NSFont.systemFont(ofSize: 13, weight: .semibold), titleColor: ReviewInk.title,
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
                         children: children)
    }

    private func makeTurnBlock(sessionId: String, group: ReviewLogModel.ReviewTurnGroup) -> NSView {
        let key = expandKeyTurn(sessionId, group.turn)
        let expanded = !collapsedTurns.contains(key)
        let title = group.turn.map { L10n.tr("review.turn") + " \($0)" } ?? L10n.tr("review.turnUnknown")
        var detail = group.prompt?.replacingOccurrences(of: "\n", with: " ") ?? ""
        if detail.count > 90 { detail = String(detail.prefix(90)) + "…" }
        var parts = ["\(group.files.count) " + L10n.tr("review.filesShort"), "+\(group.added) −\(group.removed)"]
        if !group.shells.isEmpty { parts.append(L10n.tr("review.shell") + " \(group.shells.count)") }
        if !group.failures.isEmpty { parts.append(L10n.tr("review.error") + " \(group.failures.count)") }

        var children: [NSView] = []
        if expanded {
            for file in group.files { children.append(makeFileBlock(sessionId: sessionId, turn: group.turn, group: file)) }
            if !group.shells.isEmpty { children.append(makeShellBlock(sessionId: sessionId, turn: group.turn, entries: group.shells)) }
            if !group.failures.isEmpty { children.append(makeFailureBlock(entries: group.failures)) }
        }
        return makeBlock(title: title, detail: detail.isEmpty ? nil : detail, trailing: parts.joined(separator: " · "),
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
    private func makeBlock(title: String, detail: String?, trailing: String?, symbol: String,
                           fill: NSColor, border: NSColor, titleFont: NSFont, titleColor: NSColor,
                           expanded: Bool, onToggle: (() -> Void)?, onOpen: (() -> Void)?,
                           children: [NSView]) -> NSView {
        let block = RoundedBlockView()
        block.translatesAutoresizingMaskIntoConstraints = false
        block.radius = 8
        block.lightFill = fill
        block.darkFill = fill
        block.lightBorder = border
        block.darkBorder = border

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
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.toolTip = title

        var headerViews: [NSView] = [chevron, icon, titleLabel]
        if let detail = detail, !detail.isEmpty {
            let detailLabel = NSTextField(labelWithString: detail)
            detailLabel.font = NSFont.systemFont(ofSize: 10)
            detailLabel.textColor = ReviewInk.muted
            detailLabel.lineBreakMode = .byTruncatingTail
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
        NSLayoutConstraint.activate([
            headerRow.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 8),
            headerRow.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -8),
            headerRow.topAnchor.constraint(equalTo: header.topAnchor, constant: 7),
            headerRow.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -7),
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

    private func makeCard(text: String, fill: NSColor, textColor: NSColor, font: NSFont, padding: CGFloat) -> NSView {
        let card = RoundedBlockView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.radius = 8
        card.lightFill = fill
        card.darkFill = fill
        card.lightBorder = ReviewInk.hairline
        card.darkBorder = ReviewInk.hairline
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
        field.drawsBackground = true
        field.backgroundColor = .white
        return field
    }
}
