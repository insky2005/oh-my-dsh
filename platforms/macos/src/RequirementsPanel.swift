//
//  RequirementsPanel.swift — the Requirements Pool panel (right-side panel slot #10).
//
//  One card per requirement card in the current workspace's .dsh/requirements, plus
//  the two front-end tools of the AI-native workflow:
//
//    * 想法收件箱   -> the header "+" (and the requirement-pool skill / REST API)
//    * 需求池       -> the list, with the derived effective state and the children
//    * 拆解器       -> copy the breakdown handoff prompt; the agent proposes, the
//                      human confirms or dismisses the pending proposal in place
//
//  Everything that is not UI lives elsewhere on purpose:
//    * parsing / derivation / atomic writes -> RequirementsCore.swift
//    * localhost REST routing               -> RequirementsAPI.swift
//    * panel switching / opening files      -> main.swift closures
//  The controller only wires those together, so the model and the API stay testable
//  headlessly (tests/requirements-panel/).
//
//  Design: docs/design/panels/requirements-pool-panel-design.md (section 5).
//

import AppKit

/// Localized label for a derived pool state. Written as a switch (not
/// "requirements.state." + rawValue) so the L10n lint can see every key.
func requirementStateLabel(_ state: ReqEffectiveState) -> String {
    switch state {
    case .candidate: return L10n.tr("requirements.state.candidate")
    case .evaluating: return L10n.tr("requirements.state.evaluating")
    case .suspended: return L10n.tr("requirements.state.suspended")
    case .discarded: return L10n.tr("requirements.state.discarded")
    case .split: return L10n.tr("requirements.state.split")
    case .closed: return L10n.tr("requirements.state.closed")
    }
}

/// Localized label for a manual pool state string (the state menu / status line).
func requirementManualStateLabel(_ state: String) -> String {
    switch state {
    case "evaluating": return L10n.tr("requirements.state.evaluating")
    case "suspended": return L10n.tr("requirements.state.suspended")
    case "discarded": return L10n.tr("requirements.state.discarded")
    default: return L10n.tr("requirements.state.candidate")
    }
}

/// Panel background — the shared panel surface token (see PanelSurface.swift).
final class RequirementsRootView: NSView {
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        PanelSurface.color(for: effectiveAppearance).setFill()
        bounds.intersection(dirtyRect).fill()
    }
}

/// One requirement card: state badge + title, source line, children line, and the
/// pending breakdown proposal (with its human confirmation gate) when present.
final class RequirementCardView: NSView {

    var onSetState: ((String) -> Void)?
    var onBreakdown: (() -> Void)?
    var onConfirm: (() -> Void)?
    var onReject: (() -> Void)?
    var onOpenWorkstream: ((String) -> Void)?

    /// The rendered requirement (internal for symmetry with ProjectCardView).
    let item: PoolItem

    private let badge = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")

    init(item: PoolItem) {
        self.item = item
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        PanelControl.fill(dark: dark, highlighted: false).setFill()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        path.fill()
        (dark ? NSColor(calibratedWhite: 0.38, alpha: 0.7) : NSColor(calibratedWhite: 0.82, alpha: 1)).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    // MARK: - Layout

    private func build() {
        let state = item.effectiveState

        badge.stringValue = requirementStateLabel(state)
        badge.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        badge.textColor = state == .split ? .controlAccentColor : .secondaryLabelColor
        badge.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.stringValue = item.requirement.id + "  " + item.requirement.title
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var meta: [String] = []
        if !item.requirement.source.isEmpty { meta.append(item.requirement.source) }
        if !item.requirement.updated.isEmpty { meta.append(item.requirement.updated) }
        metaLabel.stringValue = meta.joined(separator: " · ")
        metaLabel.font = NSFont.systemFont(ofSize: 11)
        metaLabel.textColor = .tertiaryLabelColor
        metaLabel.lineBreakMode = .byTruncatingTail

        let stateButton = NSButton(title: L10n.tr("requirements.set.state"), target: self, action: #selector(showStateMenu(_:)))
        stateButton.bezelStyle = .rounded
        stateButton.controlSize = .small
        stateButton.font = NSFont.systemFont(ofSize: 11)
        stateButton.setContentHuggingPriority(.required, for: .horizontal)

        let breakdownButton = NSButton(title: L10n.tr("requirements.breakdown"), target: self, action: #selector(breakdownTapped(_:)))
        breakdownButton.bezelStyle = .rounded
        breakdownButton.controlSize = .small
        breakdownButton.font = NSFont.systemFont(ofSize: 11)
        breakdownButton.toolTip = L10n.tr("requirements.breakdown")
        breakdownButton.setContentHuggingPriority(.required, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let titleRow = NSStackView(views: [badge, titleLabel, spacer, stateButton, breakdownButton])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 8

        var rows: [NSView] = [titleRow, metaLabel, childrenRow()]
        if let proposal = item.proposal, !proposal.isEmpty {
            rows.append(proposalView(proposal))
        }

        let column = NSStackView(views: rows)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            column.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            titleRow.widthAnchor.constraint(equalTo: column.widthAnchor),
            metaLabel.widthAnchor.constraint(lessThanOrEqualTo: column.widthAnchor),
        ])
    }

    /// The children line: one small button per workstream ("WS-001 规划"), so a
    /// click can open the card in the file panel; "尚未拆解" when there are none.
    private func childrenRow() -> NSView {
        if item.children.isEmpty {
            let label = NSTextField(labelWithString: L10n.tr("requirements.noChildren"))
            label.font = NSFont.systemFont(ofSize: 11)
            label.textColor = .tertiaryLabelColor
            return label
        }
        var views: [NSView] = []
        for child in item.children {
            let button = NSButton(title: child.id + " " + child.stage, target: self, action: #selector(openWorkstream(_:)))
            button.bezelStyle = .inline
            button.controlSize = .small
            button.font = NSFont.systemFont(ofSize: 11)
            button.toolTip = L10n.tr("requirements.openWorkstream")
            button.identifier = NSUserInterfaceItemIdentifier(child.path)
            views.append(button)
        }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        return row
    }

    /// The pending breakdown proposal + its human confirmation gate (R10). The
    /// agent may only PROPOSE; confirm / dismiss belong to the human here.
    private func proposalView(_ proposal: [BreakdownItem]) -> NSView {
        let header = NSTextField(labelWithString: L10n.tr("requirements.proposal", proposal.count))
        header.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        header.textColor = .controlAccentColor

        var itemViews: [NSView] = [header]
        for entry in proposal {
            let text = entry.boundary.isEmpty ? "· " + entry.title : "· " + entry.title + " — " + entry.boundary
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = NSFont.systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            itemViews.append(label)
        }

        let confirm = NSButton(title: L10n.tr("requirements.confirm"), target: self, action: #selector(confirmTapped(_:)))
        confirm.bezelStyle = .rounded
        confirm.controlSize = .small
        confirm.font = NSFont.systemFont(ofSize: 11)
        let reject = NSButton(title: L10n.tr("requirements.reject"), target: self, action: #selector(rejectTapped(_:)))
        reject.bezelStyle = .rounded
        reject.controlSize = .small
        reject.font = NSFont.systemFont(ofSize: 11)
        let buttons = NSStackView(views: [confirm, reject])
        buttons.orientation = .horizontal
        buttons.spacing = 6
        itemViews.append(buttons)

        let stack = NSStackView(views: itemViews)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        return stack
    }

    // MARK: - Actions

    @objc private func showStateMenu(_ sender: NSButton) {
        let menu = NSMenu()
        for state in RequirementsCore.manualStates {
            let entry = NSMenuItem(title: requirementManualStateLabel(state),
                                   action: #selector(statePicked(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = state
            menu.addItem(entry)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func statePicked(_ sender: NSMenuItem) {
        guard let state = sender.representedObject as? String else { return }
        onSetState?(state)
    }

    @objc private func breakdownTapped(_ sender: Any?) { onBreakdown?() }
    @objc private func confirmTapped(_ sender: Any?) { onConfirm?() }
    @objc private func rejectTapped(_ sender: Any?) { onReject?() }

    @objc private func openWorkstream(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        onOpenWorkstream?(id)
    }
}

/// The Requirements Pool panel. Wired by main.swift; every side effect that touches
/// the rest of the shell goes through a closure so the model stays testable.
final class RequirementsPanelController: NSObject, RequirementsAPIDelegate {

    // MARK: - Wiring (set by main.swift)

    var onRequestHide: (() -> Void)?
    /// The workspace the shell currently considers active (ProjectDirectory).
    var workspaceProvider: (() -> String?)?
    /// Open a workstream card in the file panel.
    var onOpenWorkstream: ((String) -> Void)?
    /// Send the breakdown prompt into the current conversation (main.swift).
    /// nil falls back to copying it to the clipboard.
    var onBreakdown: ((String) -> Void)?
    /// Focus this workspace and show the requirements panel (REST focus=true).
    var onFocus: ((String) -> Void)?
    /// QA hook (--ui-debug): fires after each render.
    var onDidRender: (() -> Void)?

    static let minWidth: CGFloat = 320

    let view = RequirementsRootView()

    /// What the last load produced.
    private(set) var snapshot = PoolSnapshot(workspace: "", dshExists: false, requirements: [], workstreams: [], unparsed: [])

    // MARK: - Views

    private let headerTitle = HeaderLabel()
    private let newButton = CustomIconButton(glyph: .plus, tooltip: "")
    private let refreshButton = CustomIconButton(glyph: .symbol("arrow.clockwise"), tooltip: "")
    private let helpButton = CustomIconButton(glyph: .symbol("questionmark.circle"), tooltip: "")
    private let hideButton = CustomIconButton(glyph: .close, tooltip: "")

    private let scroll = NSScrollView()
    private let list = FlippedStackView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let emptyButton = NSButton(title: "", target: nil, action: nil)
    private let emptyView = NSStackView()
    private let helpTextView = TasksHelpTextView()

    private let statusLabel = NSTextField(labelWithString: "")

    // The shared form drawer (TaskInlineForms.swift): the composer and the help
    // view slide up in it, exactly like the tasks panel's forms.
    private let formSheetHost = TaskFormSheetHostView()
    private let formSheet = TaskFormSheetView()
    private var formSheetTop: NSLayoutConstraint!
    private weak var formSheetContent: NSView?

    // MARK: - State

    private var statusClearTimer: Timer?
    private var hasRendered = false
    private var pendingScrollId: String?

    override init() {
        super.init()
        buildUI()
        newButton.onAction = { [weak self] in self?.openComposer() }
        refreshButton.onAction = { [weak self] in self?.reload() }
        helpButton.onAction = { [weak self] in self?.helpTapped() }
        hideButton.onAction = { [weak self] in self?.onRequestHide?() }
        updateLabels()
    }

    // MARK: - Public entry points

    func refreshTooltips() {
        updateLabels()
        render()
    }

    func ensureLoaded() { reload() }

    /// The active workspace changed (main.swift adoptProjectDirectory).
    func workspaceChanged() { reload() }

    func updateLabels() {
        headerTitle.text = L10n.tr("requirements.title")
        newButton.toolTip = L10n.tr("requirements.new")
        refreshButton.toolTip = L10n.tr("snapshot.action.refresh")
        helpButton.toolTip = L10n.tr("requirements.help.hint")
        hideButton.toolTip = L10n.tr("preview.closePanel")
        emptyButton.title = L10n.tr("requirements.new")
        helpTextView.apply(helpModel())
    }

    /// The panel's one-line result area (success messages fade, failures stay).
    func setStatus(_ text: String, isError: Bool) {
        statusLabel.stringValue = text
        statusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
        AppLog.shared.log("requirements: " + text)
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

    // MARK: - Loading / rendering

    func reload() {
        let workspace = workspaceProvider?() ?? ""
        if workspace.isEmpty {
            snapshot = PoolSnapshot(workspace: "", dshExists: false, requirements: [], workstreams: [], unparsed: [])
        } else {
            snapshot = RequirementsCore.load(workspace: workspace)
        }
        render()
    }

    private func render() {
        for sub in list.arrangedSubviews { sub.removeFromSuperview() }

        for item in snapshot.requirements {
            let card = RequirementCardView(item: item)
            let id = item.requirement.id
            card.onSetState = { [weak self] state in self?.setState(id: id, state: state) }
            card.onBreakdown = { [weak self] in self?.breakdownRequested(id: id) }
            card.onConfirm = { [weak self] in self?.confirmBreakdown(id: id) }
            card.onReject = { [weak self] in self?.rejectBreakdown(id: id) }
            card.onOpenWorkstream = { [weak self] path in self?.onOpenWorkstream?(path) }
            list.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -20).isActive = true
        }

        let hasWorkspace = !(workspaceProvider?() ?? "").isEmpty
        emptyLabel.stringValue = hasWorkspace ? L10n.tr("requirements.empty") : L10n.tr("requirements.needsWorkspace")
        emptyButton.isHidden = !hasWorkspace
        helpTextView.isHidden = !snapshot.requirements.isEmpty
        emptyView.isHidden = !snapshot.requirements.isEmpty
        scroll.isHidden = snapshot.requirements.isEmpty

        scrollToPendingIfNeeded()
        hasRendered = true
        onDidRender?()
    }

    private func scrollToPendingIfNeeded() {
        guard let pending = pendingScrollId,
              let card = list.arrangedSubviews.compactMap({ $0 as? RequirementCardView })
                  .first(where: { $0.item.requirement.id == pending })
        else { return }
        pendingScrollId = nil
        DispatchQueue.main.async { [weak self] in
            guard let self = self, card.superview != nil else { return }
            self.view.layoutSubtreeIfNeeded()
            card.scrollToVisible(card.bounds.insetBy(dx: 0, dy: -10))
        }
    }

    // MARK: - Actions

    @objc private func newRequirementTapped(_ sender: Any?) { openComposer() }

    /// The idea inbox: a drawer whose one box's first line is the title (the rest
    /// is the 诉求), then an atomic REQ card write — the same drawer the tasks
    /// panel's composer uses (TaskInlineForms.swift).
    func openComposer() {
        guard let workspace = workspaceProvider?(), !workspace.isEmpty else {
            presentNeedsWorkspace()
            return
        }
        let form = RequirementComposerView(model: RequirementComposerModel.build())
        form.onSubmit = { [weak self] composer in self?.submitComposer(composer) }
        form.onCancel = { [weak self] in self?.dismissForm() }
        presentForm(form) { ($0 as? RequirementComposerView)?.focusEditor() }
    }

    /// Submit the composer; on a refused write the drawer stays open so nothing
    /// typed is lost (the reason is in the status line).
    func submitComposer(_ composer: RequirementComposerModel) {
        guard composer.canSubmit else { return }
        if createRequirement(title: composer.title, body: composer.body) {
            dismissForm()
        }
    }

    // MARK: - 使用说明 (help)

    private func helpModel() -> TasksHelpModel {
        let spec = RequirementsHelpSpec.build()
        return TasksHelpModel(titleKey: spec.titleKey,
                              introKey: spec.introKey,
                              sections: spec.sections.map {
                                  TasksHelpModel.Section(headingKey: $0.headingKey, lineKeys: $0.lineKeys)
                              })
    }

    /// The 使用说明 drawer (always available from the header's ? button; the same
    /// text is shown inline while the pool is empty).
    func helpTapped() {
        let help = TasksHelpView(model: helpModel())
        help.onCancel = { [weak self] in self?.dismissForm() }
        presentForm(help) { _ in }
    }

    // MARK: - Form drawer

    /// Pull the shared drawer up with this content, or swap its content while it is
    /// already up (a second create must not re-animate).
    private func presentForm(_ content: NSView, focus: @escaping (NSView) -> Void) {
        formSheet.setContent(content)
        formSheetContent = content
        formSheetHost.blocksClicksBelow = true
        view.layoutSubtreeIfNeeded()
        let wasVisible = !formSheet.isHidden
        view.layoutSubtreeIfNeeded()
        if wasVisible {
            formSheetTop.constant = TaskFormSheetHostView.restingTop
            view.layoutSubtreeIfNeeded()
            formSheetHost.showScrim()
            formSheetHost.scrim.alphaValue = 1
        } else {
            formSheetTop.constant = -(formSheetHost.bounds.height)
            view.layoutSubtreeIfNeeded()
            formSheet.isHidden = false
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
        DispatchQueue.main.asyncAfter(deadline: .now() + (wasVisible ? 0 : 0.22)) { [weak self] in
            guard let self = self, let content = self.formSheetContent else { return }
            focus(content)
        }
    }

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
            self.formSheetHost.blocksClicksBelow = false
        })
    }

    @discardableResult
    func createRequirement(title: String, body: String) -> Bool {
        guard let workspace = workspaceProvider?(), !workspace.isEmpty else {
            presentNeedsWorkspace()
            return false
        }
        do {
            let card = try RequirementsCore.createRequirement(workspace: workspace,
                                                              title: title,
                                                              body: body,
                                                              source: "panel",
                                                              today: RequirementsCore.today())
            setStatus(L10n.tr("requirements.created", card.id), isError: false)
            pendingScrollId = card.id
            reload()
            return true
        } catch let error as PoolError {
            setStatus(message(for: error), isError: true)
        } catch {
            setStatus(L10n.tr("requirements.error.generic", error.localizedDescription), isError: true)
        }
        return false
    }

    @discardableResult
    func setState(id: String, state: String) -> Bool {
        guard let workspace = workspaceProvider?(), !workspace.isEmpty else {
            presentNeedsWorkspace()
            return false
        }
        do {
            let card = try RequirementsCore.setState(workspace: workspace, id: id, state: state, today: RequirementsCore.today())
            setStatus(L10n.tr("requirements.stateChanged", id, requirementManualStateLabel(card.state ?? "candidate")), isError: false)
            reload()
            return true
        } catch let error as PoolError {
            setStatus(message(for: error), isError: true)
        } catch {
            setStatus(L10n.tr("requirements.error.generic", error.localizedDescription), isError: true)
        }
        return false
    }

    /// The 拆解 button: hand the prompt to the current conversation when main.swift
    /// wired a sender (it sends through session.prompt); otherwise copy it. The
    /// agent then proposes through the REST API and the human confirms below.
    @discardableResult
    func breakdownRequested(id: String) -> Bool {
        if let onBreakdown = onBreakdown {
            onBreakdown(id)
            return true
        }
        return copyBreakdownPrompt(id: id)
    }

    /// Copy the breakdown handoff prompt (fallback / manual path).
    @discardableResult
    func copyBreakdownPrompt(id: String) -> Bool {
        let prompt = RequirementsCore.breakdownPrompt(id)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)
        setStatus(L10n.tr("requirements.breakdownPromptCopied", id), isError: false)
        return true
    }

    @discardableResult
    func confirmBreakdown(id: String) -> Bool {
        guard let workspace = workspaceProvider?(), !workspace.isEmpty else {
            presentNeedsWorkspace()
            return false
        }
        do {
            let created = try RequirementsCore.confirm(workspace: workspace, id: id, today: RequirementsCore.today())
            setStatus(L10n.tr("requirements.confirmed", created.count), isError: false)
            reload()
            return true
        } catch let error as PoolError {
            setStatus(message(for: error), isError: true)
        } catch {
            setStatus(L10n.tr("requirements.error.generic", error.localizedDescription), isError: true)
        }
        return false
    }

    @discardableResult
    func rejectBreakdown(id: String) -> Bool {
        guard let workspace = workspaceProvider?(), !workspace.isEmpty else {
            presentNeedsWorkspace()
            return false
        }
        do {
            _ = try RequirementsCore.reject(workspace: workspace, id: id, today: RequirementsCore.today())
            setStatus(L10n.tr("requirements.rejected"), isError: false)
            reload()
            return true
        } catch let error as PoolError {
            setStatus(message(for: error), isError: true)
        } catch {
            setStatus(L10n.tr("requirements.error.generic", error.localizedDescription), isError: true)
        }
        return false
    }

    private func presentNeedsWorkspace() {
        setStatus(L10n.tr("requirements.needsWorkspace"), isError: true)
    }

    private func message(for error: PoolError) -> String {
        switch error {
        case .noWorkspace: return L10n.tr("requirements.needsWorkspace")
        case .unknownRequirement: return L10n.tr("requirements.error.notFound")
        case .noProposal: return L10n.tr("requirements.error.noProposal")
        case .unknownState: return L10n.tr("requirements.error.unknownState")
        default: return L10n.tr("requirements.error.generic", error.message)
        }
    }
}

// MARK: - REST API (BrowserAPIBridge forwards /api/requirements/* here)

extension RequirementsPanelController {

    private func resolveWorkspace(_ requested: String?) -> String? {
        let current = workspaceProvider?()
        let trimmed = requested?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let requested = trimmed, !requested.isEmpty else {
            if let current = current, !current.isEmpty { return current }
            return nil
        }
        if let current = current, !current.isEmpty,
           requested == current || requested.hasPrefix(current + "/") {
            return current
        }
        return requested
    }

    private func listDictionary(_ workspace: String?) -> [String: Any] {
        guard let workspace = workspace, !workspace.isEmpty else {
            return ["ok": false, "error": "no-workspace", "message": "select a workspace first"]
        }
        let loaded = workspace == (workspaceProvider?() ?? "") ? self.snapshot : RequirementsCore.load(workspace: workspace)
        return ["ok": true,
                "workspace": workspace,
                "dshExists": loaded.dshExists,
                "requirements": loaded.requirements.map(RequirementsAPIResponse.item),
                "workstreams": loaded.workstreams.map(RequirementsAPIResponse.workstream)]
    }

    func apiRequirementsList(workspace: String?) -> [String: Any] {
        let resolved = resolveWorkspace(workspace)
        if let resolved = resolved, resolved == (workspaceProvider?() ?? "") {
            reload()
        }
        return listDictionary(resolved)
    }

    func apiRequirementsCreate(_ request: RequirementsCreateRequest) -> [String: Any] {
        guard let workspace = resolveWorkspace(request.workspace), !workspace.isEmpty else {
            return PoolError.noWorkspace.apiResult
        }
        do {
            let card = try RequirementsCore.createRequirement(workspace: workspace,
                                                              title: request.title,
                                                              body: request.body,
                                                              source: request.source ?? "api",
                                                              today: RequirementsCore.today())
            if request.focus { onFocus?(workspace) }
            if workspace == (workspaceProvider?() ?? "") { reload() }
            return ["ok": true, "requirement": RequirementsAPIResponse.requirement(card)]
        } catch let error as PoolError {
            return error.apiResult
        } catch {
            return ["ok": false, "error": "write-failed", "message": error.localizedDescription]
        }
    }

    func apiRequirementsSetState(_ request: RequirementsStateRequest) -> [String: Any] {
        guard let workspace = resolveWorkspace(request.workspace), !workspace.isEmpty else {
            return PoolError.noWorkspace.apiResult
        }
        do {
            let card = try RequirementsCore.setState(workspace: workspace, id: request.id, state: request.state, today: RequirementsCore.today())
            if workspace == (workspaceProvider?() ?? "") { reload() }
            return ["ok": true, "requirement": RequirementsAPIResponse.requirement(card)]
        } catch let error as PoolError {
            return error.apiResult
        } catch {
            return ["ok": false, "error": "write-failed", "message": error.localizedDescription]
        }
    }

    func apiRequirementsPropose(_ request: RequirementsBreakdownRequest) -> [String: Any] {
        guard let workspace = resolveWorkspace(request.workspace), !workspace.isEmpty else {
            return PoolError.noWorkspace.apiResult
        }
        do {
            _ = try RequirementsCore.propose(workspace: workspace, id: request.id, items: request.items, today: RequirementsCore.today())
            if workspace == (workspaceProvider?() ?? "") { reload() }
            return ["ok": true, "id": request.id, "count": request.items.count]
        } catch let error as PoolError {
            return error.apiResult
        } catch {
            return ["ok": false, "error": "write-failed", "message": error.localizedDescription]
        }
    }

    func apiRequirementsConfirm(_ request: RequirementsTargetRequest) -> [String: Any] {
        guard let workspace = resolveWorkspace(request.workspace), !workspace.isEmpty else {
            return PoolError.noWorkspace.apiResult
        }
        do {
            let created = try RequirementsCore.confirm(workspace: workspace, id: request.id, today: RequirementsCore.today())
            if workspace == (workspaceProvider?() ?? "") { reload() }
            return ["ok": true, "created": created.map(RequirementsAPIResponse.workstream)]
        } catch let error as PoolError {
            return error.apiResult
        } catch {
            return ["ok": false, "error": "write-failed", "message": error.localizedDescription]
        }
    }

    func apiRequirementsReject(_ request: RequirementsTargetRequest) -> [String: Any] {
        guard let workspace = resolveWorkspace(request.workspace), !workspace.isEmpty else {
            return PoolError.noWorkspace.apiResult
        }
        do {
            _ = try RequirementsCore.reject(workspace: workspace, id: request.id, today: RequirementsCore.today())
            if workspace == (workspaceProvider?() ?? "") { reload() }
            return ["ok": true, "id": request.id]
        } catch let error as PoolError {
            return error.apiResult
        } catch {
            return ["ok": false, "error": "write-failed", "message": error.localizedDescription]
        }
    }
}

// MARK: - Layout

extension RequirementsPanelController {

    private func buildUI() {
        // The panel root must stay frame-based (autoresizing translated): it is
        // mounted directly as an NSSplitView pane (same rule as ProjectsPanel).

        headerTitle.translatesAutoresizingMaskIntoConstraints = false
        headerTitle.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = DynamicFillView()
        header.kind = .panel
        header.translatesAutoresizingMaskIntoConstraints = false
        let actions = NSStackView(views: [newButton, refreshButton, helpButton, hideButton])
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

        emptyLabel.font = NSFont.systemFont(ofSize: 12)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.maximumNumberOfLines = 4
        emptyLabel.lineBreakMode = .byWordWrapping
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyButton.bezelStyle = .rounded
        emptyButton.controlSize = .regular
        emptyButton.target = self
        emptyButton.action = #selector(newRequirementTapped(_:))
        emptyButton.translatesAutoresizingMaskIntoConstraints = false
        helpTextView.contentWidth = 300
        helpTextView.translatesAutoresizingMaskIntoConstraints = false
        emptyView.addArrangedSubview(emptyLabel)
        emptyView.addArrangedSubview(emptyButton)
        emptyView.addArrangedSubview(helpTextView)
        emptyView.orientation = .vertical
        emptyView.alignment = .centerX
        emptyView.spacing = 10
        emptyView.translatesAutoresizingMaskIntoConstraints = false

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

        // --- form drawer (composer / 使用说明) ---
        formSheetHost.translatesAutoresizingMaskIntoConstraints = false
        formSheetHost.wantsLayer = true
        formSheetHost.layer?.masksToBounds = true
        formSheet.translatesAutoresizingMaskIntoConstraints = false
        formSheet.isHidden = true
        formSheet.alphaValue = 0
        formSheetHost.addSubview(formSheet)
        formSheetHost.onLayout = { [weak self] in
            (self?.formSheetContent as? RequirementComposerView)?.layoutEditor()
        }
        formSheetTop = formSheet.topAnchor.constraint(equalTo: formSheetHost.topAnchor,
                                                      constant: TaskFormSheetHostView.restingTop)

        for sub in [header, scroll, emptyView, statusRow, formSheetHost] { view.addSubview(sub) }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 44),

            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: statusRow.topAnchor),

            emptyView.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyView.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            emptyView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            emptyView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
            helpTextView.widthAnchor.constraint(equalToConstant: 300),

            statusRow.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusRow.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusRow.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            statusRow.heightAnchor.constraint(equalToConstant: 24),

            formSheetHost.topAnchor.constraint(equalTo: header.bottomAnchor),
            formSheetHost.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            formSheetHost.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            formSheetHost.bottomAnchor.constraint(equalTo: statusRow.topAnchor),

            formSheet.leadingAnchor.constraint(equalTo: formSheetHost.leadingAnchor, constant: 8),
            formSheet.trailingAnchor.constraint(equalTo: formSheetHost.trailingAnchor, constant: -8),
            formSheet.heightAnchor.constraint(lessThanOrEqualTo: formSheetHost.heightAnchor,
                                              constant: -2 * TaskFormSheetHostView.restingTop),
            formSheetTop,
        ])
    }
}

// MARK: - The requirements composer drawer

/// The inline requirements composer: ONE box whose first line is the requirement's
/// title and whose remaining lines are its 诉求 (a single line is both), plus
/// 创建 / 取消. Mirrors the tasks panel's TaskComposerView.
final class RequirementComposerView: TaskFormCardView, NSTextViewDelegate {

    private(set) var model: RequirementComposerModel
    var onSubmit: ((RequirementComposerModel) -> Void)?
    var onCancel: (() -> Void)?

    private let heading = NSTextField(labelWithString: "")
    private let info = NSTextField(wrappingLabelWithString: "")
    private let contentCaption = TaskFormKit.caption()
    private let closeButton = CustomIconButton(glyph: .close, tooltip: "", size: 22)
    let editor: NSTextView
    let editorBox: TaskFieldBox
    let editorPlaceholder: NSTextField
    private var editorBoxHeight: NSLayoutConstraint!
    private var editorTextHeight: NSLayoutConstraint!
    let hint: NSTextField
    let submitButton: NSButton
    let cancelButton: NSButton

    init(model: RequirementComposerModel) {
        self.model = model
        let content = TaskFormKit.textArea(model.content)
        editorBox = content.box
        editor = content.text
        editorPlaceholder = content.placeholder
        editorBoxHeight = content.boxHeight
        editorTextHeight = content.textHeight
        hint = TaskFormKit.hintLabel()
        submitButton = TaskFormKit.button("", primary: true)
        cancelButton = TaskFormKit.button("", primary: false)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        editor.delegate = self
        build()
        apply(model)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func focusEditor() { window?.makeFirstResponder(editor) }

    func apply(_ model: RequirementComposerModel) {
        self.model = model
        heading.stringValue = L10n.tr(model.headingKey)
        info.stringValue = L10n.tr(model.infoKey)
        contentCaption.stringValue = L10n.tr(model.contentCaptionKey)
        editorPlaceholder.stringValue = L10n.tr(model.placeholderKey)
        editorPlaceholder.isHidden = !editor.string.isEmpty
        submitButton.title = L10n.tr(model.submitKey)
        cancelButton.title = L10n.tr("btn.cancel")
        closeButton.toolTip = L10n.tr("btn.cancel")
        submitButton.isEnabled = model.canSubmit
        TaskFormKit.setHint(hint, key: model.problemKey)
    }

    private func build() {
        info.font = TaskFormKit.captionFont
        info.textColor = .secondaryLabelColor
        info.maximumNumberOfLines = 2
        info.lineBreakMode = .byTruncatingTail
        info.translatesAutoresizingMaskIntoConstraints = false
        _ = TaskFormKit.requiredHeight(info)
        closeButton.onAction = { [weak self] in self?.onCancel?() }
        submitButton.target = self
        submitButton.action = #selector(submitTapped)
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)

        let headingRow = TaskFormKit.headingRow(title: heading, close: closeButton)
        let contentRow = TaskFormKit.row(contentCaption, editorBox)
        let buttons = TaskFormKit.buttonRow([submitButton, cancelButton])
        let column = NSStackView(views: [headingRow, info, contentRow, hint, buttons])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false
        _ = TaskFormKit.requiredHeight(column)
        addSubview(column)
        TaskFormKit.stretch([headingRow, info, contentRow, hint], to: column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            column.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
        ])
    }

    private var currentDraft: RequirementComposerModel {
        model.typed(content: editor.string)
    }

    /// The editor grows with what is typed (the box never shrinks below its
    /// comfortable default; past the maximum it scrolls under the caret).
    private func updateEditorHeight() {
        let width = editorBox.bounds.width
        guard width > 1 else { return }
        let needed = TaskFormKit.textHeight(editor.string, width: width)
        let box = min(TaskFormKit.editorMaxHeight, max(TaskFormKit.editorHeight, needed))
        if abs(editorBoxHeight.constant - box) > 0.5 { editorBoxHeight.constant = box }
        let text = max(box - 8, needed)
        if abs(editorTextHeight.constant - text) > 0.5 { editorTextHeight.constant = text }
    }

    func layoutEditor() { updateEditorHeight() }

    @objc func submitTapped() {
        let typed = currentDraft
        guard typed.canSubmit else {
            apply(typed.attemptedSubmit())
            return
        }
        onSubmit?(typed)
    }

    @objc private func cancelTapped() { onCancel?() }

    // MARK: NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        updateEditorHeight()
        apply(currentDraft)
    }
    func textDidBeginEditing(_ notification: Notification) { apply(currentDraft) }
    func textDidEndEditing(_ notification: Notification) { apply(currentDraft) }

    /// A plain Enter stays a NEWLINE (the first line is the title, the rest is the
    /// statement); ⌘↩ submits, Esc closes.
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            onCancel?()
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)),
           NSApp.currentEvent?.modifierFlags.contains(.command) == true {
            submitTapped()
            return true
        }
        return false
    }
}

