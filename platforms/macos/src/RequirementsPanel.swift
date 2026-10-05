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

/// One requirement card, in the tasks panel's card grammar (TaskCardView.swift):
///   * a RAISED block (corner 8, ONE hairline) = the requirement container;
///   * workstreams + the pending proposal are RECESSED blocks inside it;
///   * state lives in a trailing badge (tone like the task cards), never on the
///     border — the one accent is the "active" state (evaluating / split).
final class RequirementCardView: NSView {

    var onSetState: ((String) -> Void)?
    var onBreakdown: (() -> Void)?
    var onConfirm: (() -> Void)?
    var onReject: (() -> Void)?
    var onOpenWorkstream: ((String) -> Void)?
    var onEdit: (() -> Void)?

    /// The rendered requirement (internal for symmetry with ProjectCardView).
    let item: PoolItem
    /// The card starts open when it has something to show inside.
    private(set) var isExpanded: Bool

    init(item: PoolItem) {
        self.item = item
        self.isExpanded = !item.children.isEmpty || !(item.proposal?.isEmpty ?? true)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        TaskInk.fill(dark: dark, recessed: false).setFill()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        path.fill()
        TaskInk.hairline(dark: dark).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    /// Only the disclosure chevron toggles: clicking inside the card (text, nested
    /// cards, proposal items) must never collapse it.
    func toggleExpanded() {
        isExpanded.toggle()
        for sub in subviews { sub.removeFromSuperview() }
        build()
    }

    // MARK: - Layout

    private func build() {
        let state = item.effectiveState
        let tone = requirementTone(state)

        // Row 1 — disclosure / kind glyph / title / badges / actions. The state
        // badge sits last before the actions (tasks grammar), never on the border.
        // The chevron is only an INDICATOR: the whole header row is the toggle
        // (TaskCardView's grammar), so it must not be a button.
        let chevron = taskRowGlyph(isExpanded ? "chevron.down" : "chevron.right",
                                   accessibility: isExpanded ? "requirements.collapse" : "requirements.expand")

        let glyph = taskRowGlyph("tray.full", accessibility: "requirements.glyph")

        let title = NSTextField(labelWithString: item.requirement.id + "  " + item.requirement.title)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = TaskBadgeView.bodyColor(tone)
        title.lineBreakMode = .byTruncatingTail
        title.toolTip = item.requirement.title
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let kindBadge = TaskBadgeView(text: L10n.tr("requirements.kind"), tone: .neutral)
        let stateBadge = TaskBadgeView(text: requirementStateLabel(state), tone: tone,
                                       filled: state == .evaluating)

        let breakdownButton = NSButton(title: L10n.tr("requirements.breakdown"), target: self, action: #selector(breakdownTapped(_:)))
        breakdownButton.bezelStyle = .rounded
        breakdownButton.controlSize = .small
        breakdownButton.font = .systemFont(ofSize: 11)
        breakdownButton.toolTip = L10n.tr("requirements.breakdown")
        breakdownButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stateButton = CustomIconButton(glyph: .symbol("circle.dashed"),
                                           tooltip: L10n.tr("requirements.set.state") + "：" + requirementManualStateLabel(item.requirement.state ?? "candidate"),
                                           size: 22)
        stateButton.onAction = { [weak self] in self?.showStateMenu(from: stateButton) }
        let editButton = CustomIconButton(glyph: .symbol("pencil"), tooltip: L10n.tr("requirements.edit"), size: 22)
        editButton.onAction = { [weak self] in self?.onEdit?() }

        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        var titleViews: [NSView] = [chevron, glyph, title, kindBadge]
        if !item.children.isEmpty {
            titleViews.append(TaskBadgeView(text: L10n.tr("requirements.children", item.children.count), tone: .neutral))
        }
        titleViews.append(contentsOf: [spacer, stateBadge, breakdownButton, stateButton, editButton])
        let titleRow = NSStackView(views: titleViews)
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 6

        // The header row owns the toggle; the body below it never does (a click on
        // the statement / nested cards must not collapse the requirement).
        let header = RequirementHeaderView(content: titleRow)
        header.onToggle = { [weak self] in self?.toggleExpanded() }
        var rows: [NSView] = [header]

        // 诉求 preview: always visible (an agent-captured card used to be title-only),
        // clamped to 3 lines when collapsed.
        if !item.requirement.statement.isEmpty {
            let statement = NSTextField(wrappingLabelWithString: item.requirement.statement)
            statement.font = .systemFont(ofSize: 11)
            statement.textColor = .secondaryLabelColor
            statement.maximumNumberOfLines = isExpanded ? 0 : 3
            statement.lineBreakMode = .byTruncatingTail
            statement.toolTip = item.requirement.statement
            rows.append(statement)
        }

        var meta: [String] = []
        if !item.requirement.source.isEmpty { meta.append(item.requirement.source) }
        if !item.requirement.updated.isEmpty { meta.append(item.requirement.updated) }
        if let proposal = item.proposal, !proposal.isEmpty {
            meta.append(L10n.tr("requirements.proposalMeta", proposal.count))
        }
        if !meta.isEmpty {
            let metaLabel = NSTextField(labelWithString: meta.joined(separator: "  ·  "))
            metaLabel.font = .systemFont(ofSize: 10)
            metaLabel.textColor = .tertiaryLabelColor
            metaLabel.lineBreakMode = .byTruncatingMiddle
            rows.append(metaLabel)
        }

        // The requirement's OWN collapse hides its body; each nested card then
        // collapses ITSELF (a workstream / a proposal item)。
        if isExpanded {
            if !item.children.isEmpty {
                rows.append(sectionTitle(L10n.tr("requirements.childrenSection"), count: item.children.count))
                for child in item.children { rows.append(workstreamCard(child)) }
            }
            if let proposal = item.proposal, !proposal.isEmpty {
                rows.append(proposalBlock(proposal))
            }
        }

        let column = NSStackView(views: rows)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            column.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
        ])
        for row in rows { row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
    }

    /// A quiet section caption inside the card ("已拆解事项 (N)").
    private func sectionTitle(_ text: String, count: Int) -> NSView {
        let label = NSTextField(labelWithString: text + " (" + String(count) + ")")
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    /// One workstream as a RECESSED mini card that collapses ITSELF: collapsed shows
    /// the header (id + title + stage + ↗), expanded adds 阶段 / 结果 / 路径.
    private func workstreamCard(_ child: WorkstreamSummary) -> NSView {
        let glyph = taskRowGlyph("doc.text", accessibility: "requirements.glyph.workstream")
        let id = NSTextField(labelWithString: child.id)
        id.font = .systemFont(ofSize: 12, weight: .semibold)
        let name = NSTextField(labelWithString: child.title)
        name.font = .systemFont(ofSize: 12)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stageBadge = TaskBadgeView(text: child.stage, tone: .neutral)
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let open = CustomIconButton(glyph: .symbol("arrow.up.forward.app"),
                                    tooltip: L10n.tr("requirements.openWorkstream"), size: 22)
        let path = child.path
        open.onAction = { [weak self] in self?.onOpenWorkstream?(path) }
        let row = NSStackView(views: [glyph, id, name, spacer, stageBadge, open])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        return RequirementNestedCardView(header: row, body: workstreamDetail(child),
                                         recessed: true, collapsible: true)
    }

    private func workstreamDetail(_ child: WorkstreamSummary) -> NSView {
        let rows: [NSView] = [detailLine("requirements.detail.stage", child.stage),
                              detailLine("requirements.detail.outcome", child.outcome ?? "—"),
                              detailLine("requirements.detail.path", child.path)]
        let column = NSStackView(views: rows)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        for row in rows { row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        return column
    }

    private func detailLine(_ key: String, _ value: String) -> NSView {
        let label = NSTextField(labelWithString: L10n.tr(key) + "：" + value)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.toolTip = value
        return label
    }

    /// The pending proposal + its human confirmation gate (R10): a RECESSED container
    /// whose header carries 确认 / 驳回, with one item card per proposed workstream.
    /// Each item card collapses ITSELF (collapsed = 标题 + 依赖; expanded adds 内容).
    private func proposalBlock(_ proposal: [BreakdownItem]) -> NSView {
        let glyph = taskRowGlyph("square.dashed", accessibility: "requirements.glyph.proposal")
        let header = NSTextField(labelWithString: L10n.tr("requirements.proposalSection"))
        header.font = .systemFont(ofSize: 12, weight: .semibold)
        let pending = TaskBadgeView(text: L10n.tr("requirements.pending", proposal.count), tone: .warning)
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let confirm = NSButton(title: L10n.tr("requirements.confirm"), target: self, action: #selector(confirmTapped(_:)))
        confirm.bezelStyle = .rounded
        confirm.controlSize = .small
        confirm.font = .systemFont(ofSize: 11)
        let reject = NSButton(title: L10n.tr("requirements.reject"), target: self, action: #selector(rejectTapped(_:)))
        reject.bezelStyle = .rounded
        reject.controlSize = .small
        reject.font = .systemFont(ofSize: 11)
        let headerRow = NSStackView(views: [glyph, header, pending, spacer, confirm, reject])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 6

        let items = proposal.map { proposalItemCard($0) }
        let column = NSStackView(views: items)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6
        for item in items { item.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        return RequirementNestedCardView(header: headerRow, body: column, recessed: true)
    }

    /// One proposal item: a RAISED mini card that collapses itself — collapsed shows
    /// 标题 + [依赖 N], expanded adds the 内容（边界）.
    private func proposalItemCard(_ entry: BreakdownItem) -> NSView {
        let glyph = taskRowGlyph("square.dashed", accessibility: "requirements.glyph.proposalItem")
        let title = NSTextField(labelWithString: entry.title)
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        var titleViews: [NSView] = [glyph, title, spacer]
        if !entry.dependsOn.isEmpty {
            titleViews.append(TaskBadgeView(text: L10n.tr("requirements.depends", entry.dependsOn.count), tone: .neutral))
        }
        let titleRow = NSStackView(views: titleViews)
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 6

        var body: NSView? = nil
        if !entry.boundary.isEmpty {
            let boundary = NSTextField(wrappingLabelWithString: entry.boundary)
            boundary.font = .systemFont(ofSize: 11)
            boundary.textColor = .secondaryLabelColor
            body = boundary
        }
        return RequirementNestedCardView(header: titleRow, body: body, recessed: false, collapsible: true)
    }

    // MARK: - Actions

    @objc private func showStateMenu(from view: NSView) {
        let menu = NSMenu()
        for state in RequirementsCore.manualStates {
            let entry = NSMenuItem(title: requirementManualStateLabel(state),
                                   action: #selector(statePicked(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = state
            menu.addItem(entry)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
    }

    @objc private func statePicked(_ sender: NSMenuItem) {
        guard let state = sender.representedObject as? String else { return }
        onSetState?(state)
    }

    @objc private func breakdownTapped(_ sender: Any?) { onBreakdown?() }
    @objc private func confirmTapped(_ sender: Any?) { onConfirm?() }
    @objc private func rejectTapped(_ sender: Any?) { onReject?() }
}

/// The requirement's header row — the lane-header equivalent. Clicking ANYWHERE in
/// this row (outside its controls) toggles the card, exactly like a task card; the
/// chevron is only an indicator. The body below the header never toggles.
final class RequirementHeaderView: NSView {
    var onToggle: (() -> Void)?
    private let content: NSView

    init(content: NSView) {
        self.content = content
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isOpaque: Bool { false }

    /// Labels are hit-testable but must not swallow the header click; controls keep
    /// working because AppKit hit-tests the deepest view first (TaskCardView's rule).
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if hit is NSButton || hit is TaskBadgeView || hit is NSTextView || hit is CustomIconButton {
            return hit
        }
        return self
    }

    override func mouseDown(with event: NSEvent) { onToggle?() }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// A nested card inside a requirement (a workstream or a proposal block): fill by
/// nesting level (recessed inside a container, raised inside a recessed block) +
/// ONE hairline, corner 8, content inset 8/7 — the task-card grammar.
final class RequirementNestedCardView: NSView {
    private let recessed: Bool
    private let headerContent: NSView
    private let bodyContent: NSView?
    /// A collapsible card toggles its OWN body (the requirement card is not involved).
    private let collapsible: Bool
    private(set) var isExpanded: Bool

    init(header: NSView, body: NSView?, recessed: Bool,
         collapsible: Bool = false, startsExpanded: Bool = false) {
        self.recessed = recessed
        self.headerContent = header
        self.bodyContent = body
        self.collapsible = collapsible && body != nil
        self.isExpanded = startsExpanded
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isOpaque: Bool { false }

    func toggle() {
        isExpanded.toggle()
        build()
    }

    private func build() {
        for sub in subviews { sub.removeFromSuperview() }
        // A collapsible card gets its own chevron + header-only click target.
        let header: NSView
        if collapsible {
            let chevron = taskRowGlyph(isExpanded ? "chevron.down" : "chevron.right",
                                       accessibility: isExpanded ? "requirements.collapse" : "requirements.expand")
            let row = NSStackView(views: [chevron, headerContent])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 6
            let clickable = RequirementHeaderView(content: row)
            clickable.onToggle = { [weak self] in self?.toggle() }
            header = clickable
        } else {
            header = headerContent
        }

        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6
        column.translatesAutoresizingMaskIntoConstraints = false
        column.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        if let body = bodyContent, !collapsible || isExpanded {
            body.translatesAutoresizingMaskIntoConstraints = false
            column.addArrangedSubview(body)
            body.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            column.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
        ])
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearanceBestMatch()
        TaskInk.fill(dark: dark, recessed: recessed).setFill()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        path.fill()
        TaskInk.hairline(dark: dark).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

private extension NSView {
    /// Small helper so the card draw code reads the same as the tasks panel's.
    func effectiveAppearanceBestMatch() -> Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

/// Effective pool state → the task-card tone ladder (TaskTone).
func requirementTone(_ state: ReqEffectiveState) -> TaskTone {
    switch state {
    case .candidate: return .neutral
    case .evaluating: return .running
    case .suspended: return .warning
    case .discarded: return .neutral
    case .split: return .running
    case .closed: return .positive
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
    /// Send the breakdown prompt into a conversation (main.swift): the card's
    /// source session when it has one, else the current one; nil falls back to
    /// copying the prompt to the clipboard.
    var onBreakdown: ((String, String?) -> Void)?
    /// The user pressed「创建并细化」; main.swift starts a refinement session for
    /// the new card and binds it to that session (id, title).
    var onRefineRequested: ((String, String) -> Void)?
    /// Human confirmed (true) / rejected (false) a proposal in the panel; the
    /// created workstream ids come along so main.swift can write the outcome back
    /// to the requirement's session.
    var onBreakdownResolved: ((String, Bool, [String]) -> Void)?
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
            card.onEdit = { [weak self] in self?.openComposer(id: id) }
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

    /// The idea inbox / editor: a drawer whose one box's first line is the title
    /// (the rest is the 诉求) — the same drawer the tasks panel's composer uses
    /// (TaskInlineForms.swift). Pass an id to edit that card.
    func openComposer(id: String? = nil) {
        guard let workspace = workspaceProvider?(), !workspace.isEmpty else {
            presentNeedsWorkspace()
            return
        }
        let model: RequirementComposerModel
        if let id = id {
            guard let item = snapshot.requirements.first(where: { $0.requirement.id == id }) else {
                setStatus(L10n.tr("requirements.error.notFound"), isError: true)
                return
            }
            model = RequirementComposerModel.edit(item.requirement)
        } else {
            model = RequirementComposerModel.build()
        }
        let form = RequirementComposerView(model: model)
        form.onSubmit = { [weak self] composer, refine in self?.submitComposer(composer, refine: refine) }
        form.onCancel = { [weak self] in self?.dismissForm() }
        presentForm(form) { ($0 as? RequirementComposerView)?.focusEditor() }
    }

    /// Save the edited title + 诉求 (only those two change).
    @discardableResult
    func updateRequirement(id: String, title: String, body: String) -> Bool {
        guard let workspace = workspaceProvider?(), !workspace.isEmpty else {
            presentNeedsWorkspace()
            return false
        }
        do {
            let card = try RequirementsCore.updateRequirement(workspace: workspace, id: id,
                                                              title: title, body: body,
                                                              today: RequirementsCore.today())
            setStatus(L10n.tr("requirements.updated", card.id), isError: false)
            reload()
            return true
        } catch let error as PoolError {
            setStatus(message(for: error), isError: true)
        } catch {
            setStatus(L10n.tr("requirements.error.generic", error.localizedDescription), isError: true)
        }
        return false
    }

    /// Submit the composer; on a refused write the drawer stays open so nothing
    /// typed is lost (the reason is in the status line).
    func submitComposer(_ composer: RequirementComposerModel, refine: Bool) {
        guard composer.canSubmit else { return }
        let saved: Bool
        switch composer.mode {
        case .create:
            if let card = createRequirement(title: composer.title, body: composer.body) {
                // Only「创建并细化」starts a session; plain「创建」just writes the card.
                if refine { onRefineRequested?(card.id, card.title) }
                saved = true
            } else {
                saved = false
            }
        case .edit(let id):
            saved = updateRequirement(id: id, title: composer.title, body: composer.body)
        }
        if saved { dismissForm() }
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
    func createRequirement(title: String, body: String) -> RequirementCard? {
        guard let workspace = workspaceProvider?(), !workspace.isEmpty else {
            presentNeedsWorkspace()
            return nil
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
            return card
        } catch let error as PoolError {
            setStatus(message(for: error), isError: true)
        } catch {
            setStatus(L10n.tr("requirements.error.generic", error.localizedDescription), isError: true)
        }
        return nil
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
            let source = snapshot.requirements.first { $0.requirement.id == id }?.requirement.session
            onBreakdown(id, source)
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
            onBreakdownResolved?(id, true, created.map { $0.id })
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
            onBreakdownResolved?(id, false, [])
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

    /// Keep the requirement bound to the session that acted on it, so every later
    /// panel action (and the confirm/reject write-back) stays in ONE conversation.
    private func bindSession(_ session: String?, workspace: String, id: String) {
        guard let session = session?.trimmingCharacters(in: .whitespacesAndNewlines), !session.isEmpty else { return }
        RequirementsCore.rememberSession(workspace: workspace, id: id, session: session)
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
                                                              today: RequirementsCore.today(),
                                                              session: request.session)
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
            bindSession(request.session, workspace: workspace, id: request.id)
            if workspace == (workspaceProvider?() ?? "") { reload() }
            return ["ok": true, "requirement": RequirementsAPIResponse.requirement(card)]
        } catch let error as PoolError {
            return error.apiResult
        } catch {
            return ["ok": false, "error": "write-failed", "message": error.localizedDescription]
        }
    }

    func apiRequirementsUpdate(_ request: RequirementsUpdateRequest) -> [String: Any] {
        guard let workspace = resolveWorkspace(request.workspace), !workspace.isEmpty else {
            return PoolError.noWorkspace.apiResult
        }
        do {
            let card = try RequirementsCore.updateRequirement(workspace: workspace, id: request.id,
                                                              title: request.title, body: request.body,
                                                              today: RequirementsCore.today())
            bindSession(request.session, workspace: workspace, id: request.id)
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
            bindSession(request.session, workspace: workspace, id: request.id)
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
            bindSession(request.session, workspace: workspace, id: request.id)
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
            bindSession(request.session, workspace: workspace, id: request.id)
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
        let actions = NSStackView(views: [refreshButton, helpButton, hideButton])
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

        // --- toolbar: 建需求 sits on its RIGHT (the row below the header,
        // mirroring the tasks panel's tab row) ---
        let toolbar = DynamicFillView()
        toolbar.kind = .panel
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        let toolbarSpacer = NSView()
        toolbarSpacer.translatesAutoresizingMaskIntoConstraints = false
        toolbarSpacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        toolbarSpacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let toolbarStack = NSStackView(views: [toolbarSpacer, newButton])
        toolbarStack.orientation = .horizontal
        toolbarStack.alignment = .centerY
        toolbarStack.spacing = 5
        toolbarStack.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(toolbarStack)
        NSLayoutConstraint.activate([
            toolbarStack.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 6),
            toolbarStack.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -8),
            toolbarStack.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 32),
        ])
        let toolbarUnderline = NSBox()
        toolbarUnderline.boxType = .separator
        toolbarUnderline.translatesAutoresizingMaskIntoConstraints = false

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

        for sub in [header, toolbar, toolbarUnderline, scroll, emptyView, statusRow, formSheetHost] { view.addSubview(sub) }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 44),

            toolbar.topAnchor.constraint(equalTo: header.bottomAnchor),
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            toolbarUnderline.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            toolbarUnderline.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbarUnderline.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            scroll.topAnchor.constraint(equalTo: toolbarUnderline.bottomAnchor),
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

            formSheetHost.topAnchor.constraint(equalTo: toolbarUnderline.bottomAnchor),
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
    /// (model, refine) — refine is true only for the「创建并细化」button.
    var onSubmit: ((RequirementComposerModel, Bool) -> Void)?
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
    /// 「创建并细化」— only shown in create mode (edit mode is just 保存).
    let refineButton: NSButton
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
        refineButton = TaskFormKit.button("", primary: false)
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
        refineButton.title = L10n.tr(model.refineKey)
        refineButton.isHidden = !model.showsRefineButton
        cancelButton.title = L10n.tr("btn.cancel")
        closeButton.toolTip = L10n.tr("btn.cancel")
        submitButton.isEnabled = model.canSubmit
        refineButton.isEnabled = model.canSubmit
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
        refineButton.target = self
        refineButton.action = #selector(refineTapped)
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)

        let headingRow = TaskFormKit.headingRow(title: heading, close: closeButton)
        let contentRow = TaskFormKit.row(contentCaption, editorBox)
        let buttons = TaskFormKit.buttonRow([submitButton, refineButton, cancelButton])
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

    @objc func submitTapped() { submit(refine: false) }

    /// 创建并细化：建卡后由 main 起一条细化会话。
    @objc func refineTapped() { submit(refine: true) }

    private func submit(refine: Bool) {
        let typed = currentDraft
        guard typed.canSubmit else {
            apply(typed.attemptedSubmit())
            return
        }
        onSubmit?(typed, refine)
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

