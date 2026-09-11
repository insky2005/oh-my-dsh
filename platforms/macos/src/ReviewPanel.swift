import AppKit

// MARK: - Review（变更审计）panel — READ-ONLY
//
// Shows what an agent changed in the dsh sessions of the current workspace:
// per-file groups with the applied hunks, the changes reconstructed from nested
// run_code dispatches, and the shell commands that may have written files
// outside any structured record. The audit itself is computed by the shared
// core (`core/lib/review-log.js`) because dsh session logs are Zstandard
// frames; this panel runs the core CLI and renders its JSON.
//
// Design + coverage notes: docs/review-panel-design.md

/// Panel root: non-opaque self-drawn background (same pattern as
/// `TerminalRootView`/`WikiRootView`/`ChannelRootView` — an opaque, layer-less
/// root composites over its siblings in this layer-backed window).
final class ReviewRootView: NSView {
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let color = dark ? NSColor(calibratedWhite: 0.20, alpha: 1) : NSColor(calibratedWhite: 0.96, alpha: 1)
        color.setFill()
        dirtyRect.fill()
    }
}

final class ReviewPanelController: NSObject {

    var onRequestHide: (() -> Void)?
    /// The workspace whose sessions are audited (wired to main.swift).
    var workspacePath: (() -> String?)?
    /// QA hook: fires after each render, so `--ui-debug` can snapshot the
    /// loaded panel (its mount-time snapshot only ever catches the load state).
    var onDidRender: (() -> Void)?

    static let minWidth: CGFloat = 320

    let view = ReviewRootView()

    // Header / toolbar
    private let headerTitle = HeaderLabel()
    private let refreshButton = CustomIconButton(glyph: .symbol("arrow.clockwise"), tooltip: "")
    private let hideButton = CustomIconButton(glyph: .close, tooltip: "")
    private let sessionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let suspectToggle = NSButton(checkboxWithTitle: "", target: nil, action: nil)

    // Content
    private let contentContainer = DynamicFillView()
    private let scroll = NSScrollView()
    private let list = FlippedStackView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")

    // State
    private var sessions: [ReviewSessionSummary] = []
    private var audit: ReviewAudit?
    private var selectedSessionId: String?
    /// The session dsh web is currently viewing — preferred when present.
    private var activeSessionId: String?
    private var suspectOnly = true
    private var hasLoaded = false
    private var isLoading = false
    private var loadToken = 0

    /// Cap on rendered diff lines per entry (a big create is summarized, not dumped).
    private let maxDiffLinesPerEntry = 200

    override init() {
        super.init()
        buildUI()
        refreshButton.onAction = { [weak self] in self?.reload() }
        hideButton.onAction = { [weak self] in self?.onRequestHide?() }
        sessionPopup.target = self
        sessionPopup.action = #selector(sessionChanged(_:))
        suspectToggle.target = self
        suspectToggle.action = #selector(suspectToggled(_:))
        updateLabels()
    }

    // MARK: - Public entry points

    /// Load once when the panel is first shown.
    func ensureLoaded() {
        if !hasLoaded { reload() }
    }

    /// The workspace changed (session/project switch) — start over.
    func workspaceChanged() {
        audit = nil
        sessions = []
        selectedSessionId = nil
        hasLoaded = false
        render()
        if isViewVisible { reload() }
    }

    /// Follow the session dsh web is showing (panel ↔ web link).
    func setActiveSession(_ sessionId: String?) {
        activeSessionId = sessionId
        guard let sessionId = sessionId, sessions.contains(where: { $0.id == sessionId }),
              selectedSessionId != sessionId else { return }
        selectedSessionId = sessionId
        syncPopupSelection()
        reload()
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

        // Toolbar: session picker + the suspect-only filter.
        let toolbar = DynamicFillView()
        toolbar.kind = .window
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.wantsLayer = true
        toolbar.layer?.masksToBounds = true

        sessionPopup.translatesAutoresizingMaskIntoConstraints = false
        sessionPopup.controlSize = .small
        sessionPopup.font = NSFont.systemFont(ofSize: 11)
        sessionPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        suspectToggle.translatesAutoresizingMaskIntoConstraints = false
        suspectToggle.controlSize = .small
        suspectToggle.font = NSFont.systemFont(ofSize: 11)
        suspectToggle.state = suspectOnly ? .on : .off

        let toolbarSeparator = NSBox()
        toolbarSeparator.boxType = .separator
        toolbarSeparator.translatesAutoresizingMaskIntoConstraints = false

        toolbar.addSubview(sessionPopup)
        toolbar.addSubview(suspectToggle)
        toolbar.addSubview(toolbarSeparator)
        NSLayoutConstraint.activate([
            sessionPopup.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 10),
            sessionPopup.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            sessionPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 150),
            suspectToggle.leadingAnchor.constraint(greaterThanOrEqualTo: sessionPopup.trailingAnchor, constant: 8),
            suspectToggle.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -10),
            suspectToggle.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            toolbarSeparator.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
            toolbarSeparator.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),
            toolbarSeparator.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor),
        ])

        contentContainer.kind = .control
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.wantsLayer = true
        contentContainer.layer?.masksToBounds = true

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 10
        list.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 12, right: 10)
        list.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = list

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.isHidden = true

        contentContainer.addSubview(scroll)
        contentContainer.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            list.widthAnchor.constraint(equalTo: scroll.widthAnchor),
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
        guard !isLoading else { return }
        guard let workspace = workspacePath?(), !workspace.isEmpty else {
            showStatus(L10n.tr("review.noWorkspace"))
            return
        }
        isLoading = true
        loadToken += 1
        let token = loadToken
        let preferred = selectedSessionId ?? activeSessionId
        let activeAtStart = activeSessionId
        showStatus(L10n.tr("review.loading"))
        AppLog.shared.log("review: reload workspace=\(workspace) preferredSession=\(preferred ?? "-")")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let listedJSON = CoreBridge.run(["review", "sessions", "--workspace", workspace, "--limit", "50"],
                                            timeout: 30, preferBundledNode: true)
            let listed = listedJSON.flatMap { ReviewLogModel.decodeSessions($0) }
            let sessions = listed?.sessions ?? []

            // Keep the current selection while it still exists; otherwise prefer
            // the session dsh web is showing, else the newest.
            var target: ReviewSessionSummary?
            if let preferred = preferred { target = sessions.first { $0.id == preferred } }
            if target == nil { target = sessions.first { $0.id == activeAtStart } }
            if target == nil { target = sessions.first }

            var auditJSON: String?
            if let target = target {
                auditJSON = CoreBridge.run(["review", "audit", target.id, "--workspace", workspace],
                                           timeout: 120, preferBundledNode: true)
            }
            let audit = auditJSON.flatMap { ReviewLogModel.decodeAudit($0) }
            DispatchQueue.main.async {
                guard let self = self, self.loadToken == token else { return }
                self.isLoading = false
                self.hasLoaded = true
                self.sessions = sessions
                self.selectedSessionId = target?.id
                self.audit = audit
                self.syncPopupSelection()
                if let audit = audit {
                    let codes = (audit.diagnostics ?? []).map { $0.code }.joined(separator: ",")
                    AppLog.shared.log("review: audit \(target?.id ?? "-") entries=\(audit.entries.count) "
                        + "files=\(audit.stats?.files ?? -1) diagnostics=[\(codes)]")
                } else {
                    AppLog.shared.log("review: audit FAILED for \(target?.id ?? "-") (sessions=\(sessions.count))")
                }
                if sessions.isEmpty {
                    self.showStatus(L10n.tr("review.noSessions"))
                } else if audit == nil {
                    self.showStatus(L10n.tr("review.loadFailed"))
                } else {
                    self.render()
                }
            }
        }
    }

    private func showStatus(_ text: String) {
        list.setViews([], in: .top)
        statusLabel.stringValue = text
        statusLabel.isHidden = false
    }

    // MARK: - Actions

    @objc private func sessionChanged(_ sender: Any?) {
        let index = sessionPopup.indexOfSelectedItem
        guard index >= 0, index < sessions.count else { return }
        let id = sessions[index].id
        guard id != selectedSessionId else { return }
        selectedSessionId = id
        reload()
    }

    @objc private func suspectToggled(_ sender: Any?) {
        suspectOnly = (sender as? NSButton)?.state == .on
        render()
    }

    private func syncPopupSelection() {
        sessionPopup.removeAllItems()
        for session in sessions {
            sessionPopup.addItem(withTitle: ReviewLogModel.sessionLabel(session))
        }
        if let selected = selectedSessionId, let index = sessions.firstIndex(where: { $0.id == selected }) {
            sessionPopup.selectItem(at: index)
        }
    }

    // MARK: - Rendering

    private func render() {
        guard let audit = audit else {
            if !isLoading { showStatus(sessions.isEmpty ? L10n.tr("review.noSessions") : L10n.tr("review.empty")) }
            return
        }
        statusLabel.isHidden = true
        var rows: [NSView] = []

        if let stats = audit.stats {
            rows.append(makeSummaryCard(stats, session: audit.session))
        }
        for diagnostic in audit.diagnostics ?? [] {
            rows.append(makeTextBlock(diagnostic.message, color: .secondaryLabelColor, size: 10, monospaced: false))
        }

        let groups = ReviewLogModel.fileGroups(audit.entries)
        if groups.isEmpty {
            rows.append(makeTextBlock(L10n.tr("review.empty"), color: .secondaryLabelColor, size: 11, monospaced: false))
        }
        for group in groups {
            rows.append(makeFileGroupView(group))
        }

        let failures = ReviewLogModel.failures(audit.entries)
        if !failures.isEmpty {
            rows.append(makeCallsSection(title: L10n.tr("review.failedHeader"), entries: failures, failed: true))
        }

        let bash = ReviewLogModel.bashEntries(audit.entries, suspectOnly: suspectOnly)
        if !bash.isEmpty {
            rows.append(makeCallsSection(title: L10n.tr("review.bashHeader"), entries: bash, failed: false))
        }

        list.setViews(rows, in: .top)
        onDidRender?()
    }

    private func makeSummaryCard(_ stats: ReviewStats, session: ReviewSessionInfo?) -> NSView {
        let card = DynamicFillView()
        card.kind = .control
        card.translatesAutoresizingMaskIntoConstraints = false
        card.wantsLayer = true
        card.layer?.cornerRadius = 6
        card.layer?.masksToBounds = true

        var parts = [String(format: L10n.tr("review.summaryFiles"), stats.files),
                     "+(stats.added) −(stats.removed)"]
        if stats.nested > 0 { parts.append(L10n.tr("review.nested") + " (stats.nested)") }
        if stats.bashSuspect > 0 { parts.append(L10n.tr("review.suspectShort") + " (stats.bashSuspect)") }
        if stats.failed > 0 { parts.append(L10n.tr("review.error") + " (stats.failed)") }
        var text = parts.joined(separator: "  ·  ")
        if let session = session, let created = session.createdAt {
            let stamp = DateFormatter.localizedString(from: Date(timeIntervalSince1970: created / 1000),
                                                      dateStyle: .short, timeStyle: .short)
            text += "\n" + ReviewLogModel.shortId(session.id) + " · " + stamp
        }
        let label = makeTextBlock(text, color: .labelColor, size: 11, monospaced: false)
        card.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: card.topAnchor, constant: 8),
            label.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            label.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8),
        ])
        return card
    }

    private func makeFileGroupView(_ group: ReviewFileGroup) -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 6
        container.translatesAutoresizingMaskIntoConstraints = false

        var headerParts = [group.path]
        if group.created { headerParts.append(L10n.tr("review.cat.create")) }
        if group.hasNested { headerParts.append(L10n.tr("review.nested")) }
        if group.hasAppliedHunks == false { headerParts.append(L10n.tr("review.cat.args")) }
        let header = NSTextField(labelWithString: headerParts.joined(separator: "  ·  "))
        header.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        header.lineBreakMode = .byTruncatingMiddle
        header.toolTip = group.path

        let totals = NSTextField(labelWithString: "+\(group.added) −\(group.removed)")
        totals.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        totals.textColor = .secondaryLabelColor

        let headerRow = NSStackView(views: [header, totals])
        headerRow.orientation = .horizontal
        headerRow.spacing = 8
        headerRow.alignment = .firstBaseline

        container.addArrangedSubview(headerRow)
        for entry in group.entries {
            let meta = makeEntryMetaRow(entry)
            container.addArrangedSubview(meta)
            let lines = ReviewLogModel.diffLines(entry.hunks)
            if !lines.isEmpty {
                container.addArrangedSubview(makeDiffView(lines))
            }
        }
        return container
    }

    private func makeEntryMetaRow(_ entry: ReviewEntry) -> NSView {
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
        label.textColor = .tertiaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    private func makeDiffView(_ lines: [ReviewDiffLine]) -> NSTextField {
        let shown = Array(lines.prefix(maxDiffLinesPerEntry))
        let text = NSMutableAttributedString()
        let font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
        for line in shown {
            let prefix = line.kind == .removed ? "− " : "+ "
            let color: NSColor = line.kind == .removed
                ? NSColor.systemRed.withAlphaComponent(0.85)
                : NSColor.systemGreen.withAlphaComponent(0.9)
            text.append(NSAttributedString(string: prefix + line.text + "\n",
                                           attributes: [.font: font, .foregroundColor: color]))
        }
        if lines.count > shown.count {
            text.append(NSAttributedString(string: String(format: L10n.tr("review.moreLines"), lines.count - shown.count) + "\n",
                                           attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
        }
        let field = NSTextField(labelWithAttributedString: text)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.isEditable = false
        field.isSelectable = true
        field.maximumNumberOfLines = 0
        field.lineBreakMode = .byCharWrapping
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    private func makeCallsSection(title: String, entries: [ReviewEntry], failed: Bool) -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 4
        container.translatesAutoresizingMaskIntoConstraints = false

        let heading = NSTextField(labelWithString: title)
        heading.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        container.addArrangedSubview(heading)
        if !failed {
            container.addArrangedSubview(makeTextBlock(L10n.tr("review.unstructuredNote"),
                                                       color: .tertiaryLabelColor, size: 10, monospaced: false))
        }
        for entry in entries.prefix(60) {
            let body = failed
                ? (entry.path ?? entry.command ?? entry.tool)
                : (entry.command ?? "")
            let line = NSTextField(wrappingLabelWithString: body)
            line.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
            line.textColor = failed ? NSColor.systemRed.withAlphaComponent(0.85) : .labelColor
            line.maximumNumberOfLines = 6
            line.lineBreakMode = .byCharWrapping
            line.translatesAutoresizingMaskIntoConstraints = false
            container.addArrangedSubview(line)
        }
        if entries.count > 60 {
            container.addArrangedSubview(makeTextBlock(String(format: L10n.tr("review.moreLines"), entries.count - 60) + " (" + title + ")",
                                                       color: .secondaryLabelColor, size: 10, monospaced: false))
        }
        return container
    }

    private func makeTextBlock(_ text: String, color: NSColor, size: CGFloat, monospaced: Bool) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = monospaced ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
                                : NSFont.systemFont(ofSize: size)
        label.textColor = color
        label.translatesAutoresizingMaskIntoConstraints = false
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        return label
    }
}
