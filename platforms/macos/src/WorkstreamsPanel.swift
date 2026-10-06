//
//  WorkstreamsPanel.swift — the Workstreams panel (right-side panel slot #11).
//
//  The panel is the current workspace's 事项中心: one primary card per
//  .dsh/workstreams/WS-*.md card, five stage (secondary) cards inside it, and the
//  stage queue's tasks (tertiary) below that. The top strip switches between the
//  stage views (全部 / 规划 / 设计 / 执行 / 验收 / 交付).
//
//  Everything that is not UI lives elsewhere on purpose:
//    * parsing / writes            -> WorkstreamsCore.swift
//    * localhost REST routing      -> WorkstreamsAPI.swift
//    * card / filter / empty model -> WorkstreamsUI.swift (pure, unit-tested)
//    * panel switching / opening   -> main.swift closures (wired by the next task)
//  The controller only wires those together, so the model stays testable
//  headlessly (tests/workstreams-panel/ui-tests.swift).
//
//  Design: docs/design/panels/workstream-panel-design.md (A2 / §3.1 / §4).
//  Colour: PanelSurface / PanelControl only — no new token
//  (docs/design/shell/ui-color-scheme.md).
//

import AppKit

// MARK: - Tone → color

/// A badge / label tone mapped onto the shell's existing palette. The views keep
/// no colour of their own, so a new tone is one switch case and nothing else.
func wsTierColor(_ tone: WSTone) -> NSColor {
    switch tone {
    case .neutral: return .secondaryLabelColor
    case .running: return .controlAccentColor
    case .positive: return .systemGreen
    case .warning: return .systemOrange
    case .negative: return .systemRed
    }
}

/// The body text colour for a tone (a warning / error line reads in its tone).
func wsTierBodyColor(_ tone: WSTone) -> NSColor {
    switch tone {
    case .negative: return .systemRed
    case .warning: return .systemOrange
    default: return .labelColor
    }
}

/// A row-kind marker: a quiet SF Symbol before a stage / task name. A symbol the
/// running macOS does not have degrades to a zero-width view (no hole, no crash).
func wsTierGlyph(_ symbol: String, accessibility: String) -> NSView {
    guard let image = NSImage(systemSymbolName: symbol,
                              accessibilityDescription: L10n.tr(accessibility)) else {
        let empty = NSView()
        empty.translatesAutoresizingMaskIntoConstraints = false
        return empty
    }
    let view = NSImageView(image: image)
    view.identifier = NSUserInterfaceItemIdentifier("wsTierGlyph:" + symbol)
    view.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
    view.contentTintColor = .tertiaryLabelColor
    view.translatesAutoresizingMaskIntoConstraints = false
    view.widthAnchor.constraint(equalToConstant: 13).isActive = true
    view.heightAnchor.constraint(equalToConstant: 13).isActive = true
    view.setContentHuggingPriority(.required, for: .horizontal)
    view.setContentCompressionResistancePriority(.required, for: .horizontal)
    return view
}

// MARK: - Badge

/// A pill-shaped badge. Its colour comes from the model's tone — the card never
/// decides semantics itself.
final class WSTierBadgeView: NSView {

    let text: String
    private let label = NSTextField(labelWithString: "")
    private var tone: WSTone = .neutral
    private var filled = false

    init(text: String, tone: WSTone, filled: Bool = false) {
        self.text = text
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.masksToBounds = true
        label.stringValue = text
        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
        self.tone = tone
        self.filled = filled
        applyTone()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTone()
    }

    override var intrinsicContentSize: NSSize {
        let size = label.intrinsicContentSize
        return NSSize(width: size.width + 12, height: size.height + 4)
    }

    private func applyTone() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let color = wsTierColor(tone)
        layer?.backgroundColor = filled
            ? color.cgColor
            : color.withAlphaComponent(dark ? 0.24 : 0.14).cgColor
        label.textColor = filled ? .white : color
    }
}

// MARK: - Collapsible tier grammar

/// The header of a nested tier block. Clicking ANYWHERE in the row (outside its
/// controls) toggles the block; the chevron is only an indicator, exactly like
/// the requirement / task cards.
final class WSTierHeaderView: NSView {
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

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if hit is NSButton || hit is WSTierBadgeView || hit is NSTextView
            || hit is CustomIconButton {
            return hit
        }
        return self
    }

    override func mouseDown(with event: NSEvent) { onToggle?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// A nested tier block: fill by nesting level (recessed inside a container,
/// raised inside a recessed block) + ONE hairline, corner 8, content inset 8/7 —
/// the card grammar. A collapsible block toggles its OWN body.
final class WSNestedTierView: NSView {
    private let recessed: Bool
    private let headerContent: NSView
    private let bodyContent: NSView?
    private let collapsible: Bool
    private(set) var isExpanded: Bool

    init(header: NSView, body: NSView?, recessed: Bool,
         collapsible: Bool = false, startsExpanded: Bool = false) {
        self.recessed = recessed
        self.headerContent = header
        self.bodyContent = body
        self.collapsible = collapsible && body != nil
        self.isExpanded = startsExpanded || !collapsible
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
        let header: NSView
        if collapsible {
            let chevron = wsTierGlyph(isExpanded ? "chevron.down" : "chevron.right",
                                      accessibility: isExpanded ? "workstreams.collapse" : "workstreams.expand")
            let row = NSStackView(views: [chevron, headerContent])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 6
            let clickable = WSTierHeaderView(content: row)
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
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        // Reuse the card family's shared ink (WSInk, the review panel's grammar):
        // no new colour token is introduced by this panel.
        WSInk.fill(dark: dark, recessed: recessed).setFill()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        path.fill()
        WSInk.hairline(dark: dark).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

// MARK: - Primary card

/// One workstream card: the raised container. Its header carries the identity
/// (id / title / requirement / current stage), its body the five stage cards.
final class WSPrimaryCardView: NSView {

    let model: WSCardModel
    /// The focus channel: the card the user jumped to is ringed with the accent
    /// border (WSInk.accentBorder) so it is unmistakable in a long board.
    var isFocused: Bool = false {
        didSet { if isFocused != oldValue { needsDisplay = true } }
    }
    var onOpen: (() -> Void)?
    /// Human gate actions for the current stage (R10).
    var onConfirmStage: (() -> Void)?
    var onRejectStage: (() -> Void)?
    /// 「在会话中处理」(design §6): reuse the workstream's bound dsh session, or
    /// start (and bind) a new one.
    var onHandleInSession: (() -> Void)?
    /// 事项级启动 (design A3).
    var onStartWorkstream: (() -> Void)?
    /// 阶段二级卡的「＋创建任务」/「启动阶段」(design A3 / A14).
    var onCreateStageTask: ((WorkstreamStage) -> Void)?
    var onStartStage: ((WorkstreamStage) -> Void)?
    /// 阶段二级卡的「交付」(design A10): only offered on the delivery stage card.
    var onDeliverStage: (() -> Void)?
    private(set) var isExpanded: Bool

    init(model: WSCardModel) {
        self.model = model
        self.isExpanded = model.isExpanded
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isOpaque: Bool { false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    func toggle() {
        isExpanded.toggle()
        build()
    }

    private func build() {
        for sub in subviews { sub.removeFromSuperview() }

        let chevron = wsTierGlyph(isExpanded ? "chevron.down" : "chevron.right",
                                  accessibility: isExpanded ? "workstreams.collapse" : "workstreams.expand")
        let glyph = wsTierGlyph("list.bullet.rectangle", accessibility: "workstreams.glyph")

        let idLabel = NSTextField(labelWithString: model.id)
        idLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        idLabel.textColor = .secondaryLabelColor
        idLabel.setContentHuggingPriority(.required, for: .horizontal)

        let title = NSTextField(labelWithString: model.title)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = wsTierBodyColor(model.tone)
        title.lineBreakMode = .byTruncatingTail
        title.toolTip = model.title
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        var titleViews: [NSView] = [chevron, glyph, idLabel, title]
        if let requirement = model.requirement, !requirement.isEmpty {
            titleViews.append(WSTierBadgeView(text: requirement, tone: .neutral))
        }
        titleViews.append(spacer)
        titleViews.append(WSTierBadgeView(text: L10n.tr(model.stageLabelKey), tone: model.tone,
                                          filled: model.stage == .task))
        // Derived workstream run state (A13): the roll-up of the five stages.
        titleViews.append(WSTierBadgeView(text: L10n.tr(model.runStateKey), tone: model.runStateTone))
        titleViews.append(handleInSessionButton())
        let start = CustomIconButton(glyph: .play,
                                     tooltip: L10n.tr("workstreams.start.item"), size: 22)
        start.onAction = { [weak self] in self?.onStartWorkstream?() }
        titleViews.append(start)
        let open = CustomIconButton(glyph: .symbol("arrow.up.forward.app"),
                                    tooltip: L10n.tr("workstreams.openCard"), size: 22)
        open.onAction = { [weak self] in self?.onOpen?() }
        titleViews.append(open)

        let titleRow = NSStackView(views: titleViews)
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 6

        let header = WSTierHeaderView(content: titleRow)
        header.onToggle = { [weak self] in self?.toggle() }

        var rows: [NSView] = [header]
        if !model.meta.isEmpty {
            let meta = NSTextField(labelWithString: model.meta.map { L10n.tr($0.labelKey) + "：" + $0.value }
                .joined(separator: "  ·  "))
            meta.font = .systemFont(ofSize: 10)
            meta.textColor = .tertiaryLabelColor
            meta.lineBreakMode = .byTruncatingMiddle
            meta.toolTip = model.meta.map { $0.value }.joined(separator: "\n")
            rows.append(meta)
        }
        if isExpanded {
            if !model.detail.isEmpty {
                let detail = NSTextField(wrappingLabelWithString: model.detail)
                detail.font = .systemFont(ofSize: 11)
                detail.textColor = .secondaryLabelColor
                detail.maximumNumberOfLines = 0
                rows.append(detail)
            }
            rows.append(contentsOf: model.stages.map { stageCard($0) })
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

    /// 「在会话中处理」(design §6): the main card and every stage card share this
    /// ONE button — reuse the workstream's bound session, or start (and bind) a
    /// new one. The action is per-workstream, so both levels call the same
    /// controller handler.
    private func handleInSessionButton() -> CustomIconButton {
        let handle = CustomIconButton(glyph: .symbol("bubble.left.and.bubble.right"),
                                      tooltip: L10n.tr("workstreams.handleInSession"), size: 22)
        handle.onAction = { [weak self] in self?.onHandleInSession?() }
        return handle
    }

    /// One 阶段二级卡 (recessed inside the primary card). Empty stages are a
    /// header only (no disclosure; nothing to show yet).
    private func stageCard(_ stage: WSStageCardModel) -> NSView {
        let glyph = wsTierGlyph("square.stack.3d.up", accessibility: "workstreams.glyph.stage")
        let label = NSTextField(labelWithString: L10n.tr(stage.labelKey))
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        var headerViews: [NSView] = [glyph, label]
        if stage.isCurrent {
            headerViews.append(WSTierBadgeView(text: L10n.tr("workstreams.stage.current"), tone: stage.tone,
                                               filled: stage.stage == .task))
        }
        // Derived stage run state (A13): task states -> run state. It does not
        // move the authoritative stage; the gate buttons below still do (R10).
        headerViews.append(WSTierBadgeView(text: L10n.tr(stage.runStateKey), tone: stage.runStateTone))
        headerViews.append(spacer)
        if !stage.queueIDs.isEmpty {
            headerViews.append(WSTierBadgeView(text: stage.queueIDs.joined(separator: ", "), tone: .neutral))
        }
        if stage.awaitingConfirmation {
            let confirm = CustomIconButton(glyph: .symbol("checkmark"),
                                           tooltip: L10n.tr("workstreams.gate.confirm"), size: 22)
            confirm.onAction = { [weak self] in self?.onConfirmStage?() }
            let reject = CustomIconButton(glyph: .symbol("arrow.uturn.left"),
                                          tooltip: L10n.tr("workstreams.gate.reject"), size: 22)
            reject.onAction = { [weak self] in self?.onRejectStage?() }
            headerViews.append(confirm)
            headerViews.append(reject)
        }
        // 「在会话中处理」(design §6): the same per-workstream action as the main
        // card, offered on every stage card so the conversation is one click away
        // from the stage the user is reading.
        headerViews.append(handleInSessionButton())
        // 阶段级动作 (design A3 / A14): create waiting-state stage tasks, or run
        // only this stage's tasks.
        let createTask = CustomIconButton(glyph: .symbol("plus"),
                                          tooltip: L10n.tr("workstreams.stage.createTask"), size: 22)
        createTask.onAction = { [weak self] in self?.onCreateStageTask?(stage.stage) }
        headerViews.append(createTask)
        let startStage = CustomIconButton(glyph: .play,
                                          tooltip: L10n.tr("workstreams.stage.start"), size: 22)
        startStage.onAction = { [weak self] in self?.onStartStage?(stage.stage) }
        headerViews.append(startStage)
        // 交付阶段动作 (design A10): resolve the git / PR / token plan and start a
        // delivery session. Only the delivery stage card carries it.
        if stage.stage == .delivery {
            let deliver = CustomIconButton(glyph: .symbol("paperplane"),
                                           tooltip: L10n.tr("workstreams.stage.deliver"), size: 22)
            deliver.onAction = { [weak self] in self?.onDeliverStage?() }
            headerViews.append(deliver)
        }
        let headerRow = NSStackView(views: headerViews)
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 6

        var bodyRows: [NSView] = []
        for line in stage.evidence { bodyRows.append(detailLine(line)) }
        if stage.evidenceMissing {
            let missing = stage.missingEvidenceKeys.map { L10n.tr($0) }.joined(separator: "、")
            let blocked = NSTextField(labelWithString: L10n.tr("workstreams.gate.evidenceMissing") + "：" + missing)
            blocked.font = .systemFont(ofSize: 11)
            blocked.textColor = .systemOrange
            blocked.lineBreakMode = .byTruncatingTail
            blocked.toolTip = missing
            bodyRows.append(blocked)
        }
        if !stage.hasQueue && stage.tasks.isEmpty {
            let none = NSTextField(labelWithString: L10n.tr("workstreams.stage.noQueue"))
            none.font = .systemFont(ofSize: 11)
            none.textColor = .tertiaryLabelColor
            bodyRows.append(none)
        }
        for task in stage.tasks { bodyRows.append(taskCard(task)) }

        var body: NSView? = nil
        if !bodyRows.isEmpty {
            let column = NSStackView(views: bodyRows)
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 4
            for row in bodyRows { row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
            body = column
        }
        return WSNestedTierView(header: headerRow, body: body, recessed: true,
                                collapsible: body != nil, startsExpanded: stage.isExpanded)
    }

    /// One 任务三级卡 (raised inside the recessed stage card).
    private func taskCard(_ task: WSTaskCardModel) -> NSView {
        let glyph = wsTierGlyph("checklist", accessibility: "workstreams.glyph.task")
        let title = NSTextField(labelWithString: task.id + "  " + task.title)
        title.font = .systemFont(ofSize: 12)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        var headerViews: [NSView] = [glyph, title, spacer]
        if let stateKey = task.stateKey {
            headerViews.append(WSTierBadgeView(text: L10n.tr(stateKey), tone: task.tone))
        }
        let headerRow = NSStackView(views: headerViews)
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 6

        var bodyRows: [NSView] = []
        if let errorKey = task.errorKey, !errorKey.isEmpty {
            let error = NSTextField(labelWithString: L10n.tr(errorKey))
            error.font = .systemFont(ofSize: 11)
            error.textColor = wsTierColor(task.tone)
            error.lineBreakMode = .byTruncatingTail
            bodyRows.append(error)
        }
        if let session = task.sessionId, !session.isEmpty {
            let sessionLabel = NSTextField(labelWithString: L10n.tr("workstreams.task.session") + "：" + session)
            sessionLabel.font = .systemFont(ofSize: 10)
            sessionLabel.textColor = .tertiaryLabelColor
            sessionLabel.lineBreakMode = .byTruncatingMiddle
            sessionLabel.toolTip = session
            bodyRows.append(sessionLabel)
        }
        if !task.detail.isEmpty {
            let detail = NSTextField(wrappingLabelWithString: task.detail)
            detail.font = .systemFont(ofSize: 11)
            detail.textColor = .secondaryLabelColor
            detail.maximumNumberOfLines = 0
            bodyRows.append(detail)
        }
        var body: NSView? = nil
        if !bodyRows.isEmpty {
            let column = NSStackView(views: bodyRows)
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 3
            for row in bodyRows { row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
            body = column
        }
        return WSNestedTierView(header: headerRow, body: body, recessed: false,
                                collapsible: body != nil, startsExpanded: task.isExpanded)
    }

    private func detailLine(_ line: WSLine) -> NSView {
        let label = NSTextField(labelWithString: L10n.tr(line.labelKey) + "：" + line.value)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.toolTip = line.value
        return label
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        WSInk.fill(dark: dark, recessed: false).setFill()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        path.fill()
        // The focused card keeps the accent ring; everything else the hairline.
        if isFocused {
            WSInk.accentBorder(dark: dark).setStroke()
            path.lineWidth = 2
        } else {
            WSInk.hairline(dark: dark).setStroke()
            path.lineWidth = 1
        }
        path.stroke()
    }
}

// MARK: - Stage filter strip

/// One flat tab of the stage filter: label + accent underline when selected
/// (no bezel, no dropdown look).
final class WSFilterTabItemView: NSView {

    var onTap: (() -> Void)?
    private(set) var title: String
    var isSelected = false { didSet { needsDisplay = true } }
    private var isHovered = false
    private var trackingArea: NSTrackingArea?

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setTitle(_ value: String) {
        title = value
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize {
        let size = (title as NSString).size(withAttributes: [.font: Self.font])
        return NSSize(width: ceil(size.width) + 18, height: 24)
    }

    static let font = NSFont.systemFont(ofSize: 11, weight: .medium)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        let ta = NSTrackingArea(rect: .zero,
                                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                owner: self, userInfo: nil)
        addTrackingArea(ta)
        trackingArea = ta
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { onTap?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        PanelControl.fill(dark: dark, highlighted: isSelected || isHovered).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 2), xRadius: 5, yRadius: 5).fill()
        let color: NSColor = isSelected
            ? .controlAccentColor
            : (dark ? NSColor(calibratedWhite: 0.78, alpha: 1) : NSColor(calibratedWhite: 0.35, alpha: 1))
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: color]
        let size = (title as NSString).size(withAttributes: attrs)
        (title as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                                             y: (bounds.height - size.height) / 2 + 1),
                                 withAttributes: attrs)
        if isSelected {
            NSColor.controlAccentColor.setFill()
            NSBezierPath(rect: NSRect(x: 4, y: 0, width: max(0, bounds.width - 8), height: 2)).fill()
        }
    }
}

/// The flat stage-filter strip (全部 / 规划 / 设计 / 执行 / 验收 / 交付). Replaces a
/// dropdown so every stage view is visible at once.
final class WSStageFilterStrip: NSView {

    var onSelect: ((Int) -> Void)?
    private(set) var selectedIndex = 0
    private var items: [WSFilterTabItemView] = []
    private let row = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 2
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setItems(_ titles: [String], selected: Int) {
        for view in row.arrangedSubviews { view.removeFromSuperview() }
        items = []
        for (index, title) in titles.enumerated() {
            let item = WSFilterTabItemView(title: title)
            item.onTap = { [weak self] in self?.select(index) }
            row.addArrangedSubview(item)
            items.append(item)
        }
        selectedIndex = max(0, min(selected, max(0, titles.count - 1)))
        applySelection()
    }

    func select(_ index: Int, notify: Bool = true) {
        guard index >= 0, index < items.count else { return }
        selectedIndex = index
        applySelection()
        if notify { onSelect?(index) }
    }

    private func applySelection() {
        for (index, item) in items.enumerated() { item.isSelected = index == selectedIndex }
    }
}

// MARK: - Panel root

/// Panel background — the shared panel surface token (PanelSurface.swift).
final class WSBoardRootView: NSView {
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        PanelSurface.color(for: effectiveAppearance).setFill()
        bounds.intersection(dirtyRect).fill()
    }
}

// MARK: - Controller

/// The Workstreams panel. Wired by main.swift (the next task); every side effect
/// that touches the rest of the shell goes through a closure.
final class WorkstreamsPanelController: NSObject {

    // MARK: Wiring (set by main.swift)

    var onRequestHide: (() -> Void)?
    /// The workspace the shell currently considers active (ProjectDirectory).
    var workspaceProvider: (() -> String?)?
    /// Open a workstream card in the file panel.
    var onOpenCard: ((String) -> Void)?
    /// The focus channel (design A11 / D6): bring the workstreams panel forward
    /// (setRightPanel) for a request carrying focus. The id highlight is applied
    /// by `focus(onWorkstream:)`; this closure only lights the panel.
    var onFocus: ((String) -> Void)?
    /// 「在会话中处理」(design §6): main.swift reuses the workstream's bound
    /// session when it is alive, otherwise starts (and binds) a new one; the
    /// third argument is the bound session read from local.json (nil = none).
    var onHandleInSession: ((String, String, String?) -> Void)?
    /// 对话内阶段推进（design §5 + §6）：人在面板确认某阶段、stage 真的前移后触发；
    /// main.swift 复用 `WorkstreamHandoff` 把下一阶段交接提示词发给该事项绑定的主场
    /// 会话（无绑定会话则不发）。形状对齐需求池的 `onBreakdownResolved`：面板只报
    /// 事实，主程序负责会话选择与发送。
    var onStageConfirmed: ((WorkstreamCard, WorkstreamStage) -> Void)?
    /// QA hook (--ui-debug): fires after each render.
    var onDidRender: (() -> Void)?
    /// dsh web port, supplied by main.swift (read at call time, never frozen).
    var serverPortProvider: (() -> Int)?
    /// Fires when the visible workspace runner goes busy / idle.
    var onRunStateChanged: ((Bool) -> Void)?

    static let minWidth: CGFloat = 320

    let view = WSBoardRootView()

    /// What the last load produced.
    private(set) var snapshot = WorkstreamsSnapshot(workspace: "", dshExists: false,
                                                    workstreams: [], unparsed: [])
    /// The active top stage view.
    private(set) var selectedFilter: WSStageFilter = .all
    /// The focus channel current target: the workstream the panel highlights
    /// and scrolls to (nil = no focus). Set by focus(onWorkstream:).
    private(set) var focusTarget: String?
    /// The last rendered board (cards + filter + empty state).
    private(set) var board = WSBoardModel(cards: [], filter: .all, hasWorkspace: false, totalCount: 0)

    // MARK: Views

    private let headerTitle = HeaderLabel()
    private let refreshButton = CustomIconButton(glyph: .symbol("arrow.clockwise"), tooltip: "")
    private let hideButton = CustomIconButton(glyph: .close, tooltip: "")
    private let filterStrip = WSStageFilterStrip()
    private let countLabel = NSTextField(labelWithString: "")
    private let scroll = NSScrollView()
    private let list = FlippedStackView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let emptyView = NSStackView()
    private let statusLabel = NSTextField(labelWithString: "")

    private var statusClearTimer: Timer?

    // MARK: Queue engine (WorkstreamsRunner, design A3 / A10 / A14)

    /// One runner per workspace. The board the panel SHOWS is the current
    /// workspace's; a workspace whose task is running keeps its runner so the
    /// task still finishes after the user switches away.
    private var runners: [String: WorkstreamsRunner] = [:]
    /// Workspaces reconciled once in this app run: re-adopting must NOT reconcile
    /// again (that would mark a live task interrupted).
    private var reconciledWorkspaces: Set<String> = []
    /// Drives every runner: start the next queued task, advance the running one.
    private var stepTimer: Timer?

    override init() {
        super.init()
        buildUI()
        refreshButton.onAction = { [weak self] in self?.reload() }
        hideButton.onAction = { [weak self] in self?.onRequestHide?() }
        filterStrip.onSelect = { [weak self] index in
            guard let self = self else { return }
            let filters = WSStageFilter.allCases
            guard index >= 0, index < filters.count else { return }
            self.selectedFilter = filters[index]
            self.render()
        }
        updateLabels()
    }

    deinit {
        stepTimer?.invalidate()
    }

    // MARK: Public entry points

    func refreshTooltips() {
        updateLabels()
        render()
    }

    func ensureLoaded() { reload() }

    /// The active workspace changed (main.swift adoptProjectDirectory).
    func workspaceChanged() {
        focusTarget = nil
        reload()
    }

    func selectFilter(_ filter: WSStageFilter) {
        selectedFilter = filter
        updateLabels()
        render()
    }

    /// The focus channel: highlight one workstream and scroll it into view. When
    /// the active stage filter hides the card the filter falls back to the all
    /// view so the highlight is never invisible. A blank / unknown id is a no-op.
    func focus(onWorkstream id: String?) {
        guard let id = wsFocusedID(id) else { return }
        focusTarget = id
        reload()
    }

    func updateLabels() {
        headerTitle.text = L10n.tr("workstreams.title")
        refreshButton.toolTip = L10n.tr("snapshot.action.refresh")
        hideButton.toolTip = L10n.tr("preview.closePanel")
        let filters = WSStageFilter.allCases
        filterStrip.setItems(filters.map { L10n.tr($0.labelKey) },
                             selected: filters.firstIndex(of: selectedFilter) ?? 0)
    }

    /// The panel's one-line result area (success messages fade, failures stay).
    func setStatus(_ text: String, isError: Bool) {
        statusLabel.stringValue = text
        statusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
        AppLog.shared.log("workstreams: " + text)
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

    // MARK: Loading / rendering

    func reload() {
        let workspace = workspaceProvider?() ?? ""
        // The queue engine is the authoritative in-memory board; load it before
        // rendering so gates and task cards read live state, not a stale file.
        _ = ensureRunner(workspace)
        if workspace.isEmpty {
            snapshot = WorkstreamsSnapshot(workspace: "", dshExists: false, workstreams: [], unparsed: [])
        } else {
            snapshot = WorkstreamsCore.load(workspace: workspace)
        }
        render()
    }

    private func render() {
        let workspace = workspaceProvider?() ?? snapshot.workspace
        // Focus channel: a target hidden by the active stage filter switches the
        // filter back to 全部 so the ring is never off-screen (design A11 / D6).
        if let target = WSFocusTarget.resolve(focusTarget, snapshot: snapshot, filter: selectedFilter),
           target.filter != selectedFilter {
            selectedFilter = target.filter
            updateLabels()
        }
        let wsBoard = loadBoard(workspace)
        board = WSBoardModel.build(snapshot: snapshot, filter: selectedFilter,
                                   gates: stageGates(for: snapshot, workspace: workspace),
                                   board: wsBoard)
        for sub in list.arrangedSubviews { sub.removeFromSuperview() }
        var focusedCard: WSPrimaryCardView?
        for model in board.cards {
            let card = WSPrimaryCardView(model: model)
            card.isFocused = (model.id == focusTarget)
            if card.isFocused { focusedCard = card }
            card.onOpen = { [weak self] in self?.onOpenCard?(model.path) }
            card.onConfirmStage = { [weak self] in self?.confirmCurrentStage(model.id) }
            card.onRejectStage = { [weak self] in self?.rejectCurrentStage(model.id) }
            card.onHandleInSession = { [weak self] in self?.handleInSession(model.id) }
            card.onStartWorkstream = { [weak self] in self?.startWorkstream(model.id) }
            card.onCreateStageTask = { [weak self] stage in self?.createStageTask(model.id, stage: stage) }
            card.onStartStage = { [weak self] stage in self?.startStage(model.id, stage: stage) }
            card.onDeliverStage = { [weak self] in self?.deliverWorkstream(model.id) }
            list.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -20).isActive = true
        }
        countLabel.stringValue = L10n.tr("workstreams.count", board.totalCount)
        let empty = board.emptyState
        emptyLabel.stringValue = empty.map { L10n.tr($0.messageKey) } ?? ""
        emptyView.isHidden = empty == nil
        scroll.isHidden = board.cards.isEmpty
        scrollToFocused(focusedCard)
        onDidRender?()
    }

    /// Scroll the focused card into view once the rebuilt list has laid out (the
    /// same deferred pattern as the requirements pool pending-card scroll).
    private func scrollToFocused(_ card: WSPrimaryCardView?) {
        guard let card = card else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, card.superview != nil else { return }
            self.view.layoutSubtreeIfNeeded()
            card.scrollToVisible(card.bounds.insetBy(dx: 0, dy: -10))
        }
    }

    // MARK: Stage gate

    /// The queue board for a workspace. The current workspace's live runner board
    /// wins (task state changes there before it hits disk); otherwise read the file,
    /// and never create .dsh/workstreams just to read.
    func loadBoard(_ workspace: String) -> WSBoard {
        if let runner = runners[workspace] { return runner.board }
        guard !workspace.isEmpty else { return WSBoard() }
        let queuesPath = (workspace as NSString).appendingPathComponent(".dsh/workstreams/queues.json")
        return FileManager.default.fileExists(atPath: queuesPath) ? WSStore.load(workspace) : WSBoard()
    }

    // MARK: Queue engine (WorkstreamsRunner wiring, design A3 / A10 / A14)

    private var currentWorkspace: String { workspaceProvider?() ?? "" }
    private var currentRunner: WorkstreamsRunner? { runners[currentWorkspace] }

    /// The workspace runner, built on first use. The FIRST load of a workspace
    /// reconciles its board (a task recorded running cannot still be running — its
    /// session died with the app); re-adopting an already-seen workspace must not
    /// reconcile again, or switching away and back would mark a live task failed.
    @discardableResult
    private func ensureRunner(_ workspace: String) -> WorkstreamsRunner? {
        guard !workspace.isEmpty else { return nil }
        if let existing = runners[workspace] { return existing }
        var board = WSStore.load(workspace)
        var recovered: (interrupted: [String], pausedQueues: [String]) = ([], [])
        if !reconciledWorkspaces.contains(workspace) {
            recovered = board.reconcileAfterRestart(interruptedError: WSFailure.interrupted.rawValue)
            WSStore.save(workspace, board)
            reconciledWorkspaces.insert(workspace)
        }
        let runner = WorkstreamsRunner(board: board, env: makeEnv(repoRoot: workspace))
        runners[workspace] = runner
        startStepTimer()
        AppLog.shared.log("workstreams: board loaded at \(workspace) — "
                          + "\(board.tasks.count) tasks, \(board.queues.count) queues")
        if workspace == currentWorkspace,
           !recovered.interrupted.isEmpty || !recovered.pausedQueues.isEmpty {
            setStatus(L10n.tr("workstreams.recovered", recovered.interrupted.count,
                              recovered.pausedQueues.count), isError: false)
        }
        return runner
    }

    /// Everything the engine needs from the outside world: dsh session RPC on this
    /// port, the agent report, and .dsh/workstreams/ persistence. The port is read
    /// at call time, never frozen here (dsh web comes up after the panel is built).
    private func makeEnv(repoRoot: String) -> WSRunnerEnv {
        let portOf: () -> Int = { [weak self] in self?.serverPortProvider?() ?? 3080 }
        return WSRunnerEnv(
            repoRoot: repoRoot,
            createSession: { cwd in
                let port = portOf()
                let workspaceId = DshWorkspaceStore.workspaceId(forPath: repoRoot, port: port,
                                                                log: { AppLog.shared.log($0) })
                return DshWorkspaceOps.createSession(port: port, cwd: cwd, workspaceId: workspaceId)
            },
            renameSession: { id, title in DshSessionOps.rename(port: portOf(), sessionId: id, title: title) },
            promptSession: { id, text in DshSessionOps.sendPrompt(port: portOf(), sessionId: id, text: text) },
            sessionState: { id in Self.sessionState(port: portOf(), sessionId: id) },
            cancelSession: { id in
                DshWebRPC.call(DshWebRPC.sessionCancel, ["sessionId": id], port: portOf()) != nil
            },
            sessionReport: { id in Self.sessionReport(sessionId: id, workspace: repoRoot) },
            requireCompletionMarker: true,
            persist: { board in WSStore.save(repoRoot, board) },
            log: { message in AppLog.shared.log(message) },
            perform: { blocking, completion in
                DispatchQueue.global(qos: .userInitiated).async {
                    blocking()
                    DispatchQueue.main.async { completion() }
                }
            })
    }

    private func startStepTimer() {
        stepTimer?.invalidate()
        let timer = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in self?.stepRunner() }
        RunLoop.main.add(timer, forMode: .common)
        stepTimer = timer
    }

    /// One tick for every tracked workspace: advance the running task, start the
    /// next queued one. The visible board is re-rendered only when it changed, so
    /// the timer never fights scrolling or an open menu.
    private func stepRunner() {
        guard !runners.isEmpty else { return }
        let visible = currentWorkspace
        let currentWasBusy = currentRunner?.isBusy ?? false
        let all = runners
        for (path, runner) in all {
            let before = boardSignature(runner.board)
            _ = runner.step()
            if path == visible && boardSignature(runner.board) != before {
                reload()
            }
        }
        let busy = currentRunner?.isBusy ?? false
        if busy != currentWasBusy { onRunStateChanged?(busy) }
    }

    /// Cheap fingerprint of everything the cards render, so the 3s timer does not
    /// rebuild the list while nothing is moving.
    private func boardSignature(_ board: WSBoard) -> String {
        let tasks = board.tasks.map { $0.id + ":" + $0.state.rawValue + ":" + ($0.sessionId ?? "") }
        let queues = board.queues.map { $0.id + ":" + $0.state.rawValue + ":" + String($0.taskIds.count) }
        return (tasks + queues).joined(separator: "|")
    }

    /// What dsh says about a session. "The RPC failed" and "not listed" are NOT
    /// "it finished": the first is unknown, the second is only believed after the
    /// runner counts consecutive misses.
    private static func sessionState(port: Int, sessionId: String) -> WSSessionState {
        guard let value = DshWebRPC.call(DshWebRPC.sessionList, [:], port: port),
              let items = value["items"] as? [[String: Any]] else { return .unknown }
        for item in items where (item["sessionId"] as? String) == sessionId {
            return ((item["running"] as? Bool) ?? false) ? .running : .idle
        }
        return .missing
    }

    /// The agent's last text message in a session, for the task card / next task.
    /// Blocking (a subprocess over the session log); the runner only asks inside its
    /// background step.
    private static func sessionReport(sessionId: String, workspace: String) -> String? {
        var args = ["brief", "report", sessionId]
        if !workspace.isEmpty { args.append(contentsOf: ["--workspace", workspace]) }
        guard let json = CoreBridge.run(args, timeout: 30, preferBundledNode: true),
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let text = object["text"] as? String
        return (text?.isEmpty ?? true) ? nil : text
    }

    // MARK: Queue actions (panel buttons)

    /// 主卡「在会话中处理」(design §6): hand the workstream + its bound session to
    /// main.swift, which reuses that conversation or starts (and binds) a new one.
    @discardableResult
    func handleInSession(_ cardID: String) -> Bool {
        guard let onHandleInSession = onHandleInSession else { return false }
        guard let workspace = workspaceProvider?(), !workspace.isEmpty,
              let card = snapshot.workstreams.first(where: { $0.id == cardID }) else { return false }
        let bound = WSStore.loadLocal(workspace).workstreamSessions[card.id]
        onHandleInSession(card.id, card.title, bound)
        return true
    }

    /// 主卡「启动事项」：事项级启动 = 跑该事项队列（design A3）。
    func startWorkstream(_ cardID: String) {
        startWorkstream(cardID, stage: nil)
    }

    /// 阶段二级卡「启动阶段」：只跑该阶段任务（design A3 / D18）。
    func startStage(_ cardID: String, stage: WorkstreamStage) {
        startWorkstream(cardID, stage: stage)
    }

    private func startWorkstream(_ cardID: String, stage: WorkstreamStage?) {
        guard let workspace = workspaceProvider?(), !workspace.isEmpty,
              let runner = ensureRunner(workspace),
              let card = snapshot.workstreams.first(where: { $0.id == cardID }) else { return }
        guard runner.startWorkstream(card, stage: stage) else {
            setStatus(L10n.tr("workstreams.start.noQueue"), isError: true)
            return
        }
        if let stage = stage {
            setStatus(L10n.tr("workstreams.stage.started", L10n.tr(wsStageLabelKey(stage))), isError: false)
        } else {
            setStatus(L10n.tr("workstreams.start.started"), isError: false)
        }
        reload()
    }

    /// 阶段二级卡「交付」(design A10)：先按交付模块收集 git / GitHub / token 事实。
    /// 准入失败给出明确原因（WSDeliveryBlocker）；成功则把交付提示词作为一条 delivery
    /// 阶段任务追加并只启动该阶段。会话用 POST /api/workstreams/delivery 回填 PR 事实，
    /// 面板派生 outcome 并写卡（store §5：事实可写、outcome 只作派生缓存）。
    func deliverWorkstream(_ cardID: String) {
        guard let workspace = workspaceProvider?(), !workspace.isEmpty,
              let runner = ensureRunner(workspace),
              let card = snapshot.workstreams.first(where: { $0.id == cardID }) else { return }
        guard card.stage == .delivery else {
            setStatus(L10n.tr("workstreams.deliver.not-delivery-stage"), isError: true)
            return
        }
        let branch = WSGitProbe.live.currentBranch(workspace)
        let resolution = WorkstreamsDelivery.resolve(card: card,
                                                     branch: branch,
                                                     repoRoot: workspace,
                                                     git: .live,
                                                     tokens: WSTokenStore(),
                                                     findExistingPR: WSGitHubPR.liveFind)
        guard let plan = resolution.plan else {
            let key = resolution.blocker?.messageKey ?? "workstreams.deliver.blocked"
            setStatus(L10n.tr(key), isError: true)
            return
        }
        let built = runner.enqueueDelivery(card: card, prompt: WorkstreamsDelivery.prompt(plan: plan))
        guard !built.created.isEmpty else {
            setStatus(L10n.tr("workstreams.deliver.no-queue"), isError: true)
            return
        }
        writeBackQueueMapping(card: card, queueID: built.queue.id, workspace: workspace)
        guard runner.startWorkstream(card, stage: .delivery) else {
            setStatus(L10n.tr("workstreams.deliver.start-failed"), isError: true)
            return
        }
        setStatus(L10n.tr("workstreams.deliver.started", cardID), isError: false)
        reload()
    }

    /// 阶段二级卡「＋创建任务」：按阶段默认动作生成交接提示词、建等待态任务（A14）。
    func createStageTask(_ cardID: String, stage: WorkstreamStage) {
        guard let workspace = workspaceProvider?(), !workspace.isEmpty,
              let runner = ensureRunner(workspace),
              let card = snapshot.workstreams.first(where: { $0.id == cardID }) else { return }
        let alert = NSAlert()
        alert.messageText = L10n.tr("workstreams.task.create.title")
        alert.informativeText = L10n.tr("workstreams.task.create.message")
        alert.addButton(withTitle: L10n.tr("btn.save"))
        alert.addButton(withTitle: L10n.tr("btn.cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = L10n.tr("workstreams.task.create.placeholder")
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let title = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            setStatus(L10n.tr("workstreams.task.create.empty"), isError: true)
            return
        }
        let built = runner.createStageQueue(card: card, stage: stage, workspace: workspace, titles: [title])
        guard !built.created.isEmpty else {
            setStatus(L10n.tr("workstreams.task.create.failed"), isError: true)
            return
        }
        writeBackQueueMapping(card: card, queueID: built.queue.id, workspace: workspace)
        setStatus(L10n.tr("workstreams.task.created", built.created.count), isError: false)
        reload()
    }

    /// The panel is the only writer of WS-*.md (design A5): record the engine
    /// queue id on the card mapping (0..1) when it is not there yet.
    private func writeBackQueueMapping(card: WorkstreamCard, queueID: String, workspace: String) {
        guard !card.queues.contains(queueID) else { return }
        do {
            _ = try WorkstreamsCore.setQueues(workspace: workspace, id: card.id,
                                              queues: [queueID], today: WorkstreamsCore.today())
        } catch let error as WorkstreamError {
            setStatus(L10n.tr("workstreams.task.create.failed") + "：" + error.message, isError: true)
        } catch {
            setStatus(L10n.tr("workstreams.task.create.failed"), isError: true)
        }
    }

    /// A task title from a body-only create request: its first non-blank line.
    private func taskTitle(from body: String?) -> String {
        var title = (body ?? "").components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        while title.hasPrefix("#") || title.hasPrefix("-") || title.hasPrefix("*") {
            title = String(title.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        if title.count > 60 { title = String(title.prefix(60)) }
        return title.isEmpty ? "阶段任务" : title
    }

    // MARK: Task / queue JSON (shared by the API delegate)

    private func taskJSON(_ task: WSTaskItem) -> [String: Any] {
        WorkstreamsAPIResponse.task(task.id, title: task.title, state: task.state.rawValue,
                                    workstreamId: task.workstreamId, stage: task.stage,
                                    sessionId: task.sessionId, error: task.error, report: task.report)
    }

    private func queueJSON(_ queue: WSQueue) -> [String: Any] {
        WorkstreamsAPIResponse.queue(queue.id, name: queue.name, workstreamId: queue.workstreamId,
                                     state: queue.state.rawValue, taskIds: queue.taskIds)
    }

    /// Evaluate every card's stage gate (design A4 / D3) for the visible board.
    func stageGates(for snapshot: WorkstreamsSnapshot, workspace: String) -> [String: WSStageGate] {
        guard !workspace.isEmpty else { return [:] }
        let wsBoard = loadBoard(workspace)
        var out: [String: WSStageGate] = [:]
        for card in snapshot.workstreams {
            out[card.id] = WorkstreamsStageGate.evaluate(card,
                                                         carrier: stageCarrier(for: card, board: wsBoard),
                                                         workspace: workspace)
        }
        return out
    }

    /// The panel's confirmation button (the human side of R10).
    func confirmCurrentStage(_ cardID: String) {
        guard let workspace = workspaceProvider?(), !workspace.isEmpty,
              let card = snapshot.workstreams.first(where: { $0.id == cardID }) else { return }
        do {
            let updated = try WorkstreamsCore.confirmStage(workspace: workspace, id: cardID,
                                                 expectedStage: card.stage,
                                                 carrier: stageCarrier(for: card, board: loadBoard(workspace)),
                                                 note: nil, today: WorkstreamsCore.today())
            setStatus(L10n.tr("workstreams.gate.confirmed"), isError: false)
            continueToNextStage(after: card, updated: updated)
        } catch let error as WorkstreamError {
            setStatus(L10n.tr("workstreams.gate.failed") + "：" + error.message, isError: true)
        } catch {
            setStatus(L10n.tr("workstreams.gate.failed"), isError: true)
        }
        reload()
    }

    /// 对话内阶段推进（design §5 + §6 / 队列第 24 项）：确认成功且 stage 真的前移时，
    /// 把下一阶段交接提示词交给 main.swift。交付是终态、stage 不前移，或提示词生成
    /// 返回 nil 时静默跳过——人工确认本身已经完成推进，续发只是「让对话跟到下一阶段」。
    private func continueToNextStage(after old: WorkstreamCard, updated: WorkstreamCard) {
        guard updated.stage != old.stage,
              let handoff = WorkstreamHandoff.nextStagePrompt(card: updated,
                                                              workspace: workspaceProvider?() ?? "") else { return }
        onStageConfirmed?(updated, handoff.stage)
    }

    /// The panel's back-edge button: ask for a reason, then record it (R2 / R10).
    func rejectCurrentStage(_ cardID: String) {
        guard let workspace = workspaceProvider?(), !workspace.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = L10n.tr("workstreams.gate.rejectTitle")
        alert.informativeText = L10n.tr("workstreams.gate.rejectMessage")
        alert.addButton(withTitle: L10n.tr("workstreams.gate.reject"))
        alert.addButton(withTitle: L10n.tr("btn.cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = L10n.tr("workstreams.gate.rejectPlaceholder")
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let reason = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reason.isEmpty else {
            setStatus(L10n.tr("workstreams.gate.rejectNeedsReason"), isError: true)
            return
        }
        do {
            _ = try WorkstreamsCore.rejectStage(workspace: workspace, id: cardID, reason: reason,
                                                target: nil, today: WorkstreamsCore.today())
            setStatus(L10n.tr("workstreams.gate.rejected"), isError: false)
        } catch let error as WorkstreamError {
            setStatus(L10n.tr("workstreams.gate.failed") + "：" + error.message, isError: true)
        } catch {
            setStatus(L10n.tr("workstreams.gate.failed"), isError: true)
        }
        reload()
    }
}

// MARK: - Layout

extension WorkstreamsPanelController {

    private func buildUI() {
        // The panel root stays frame-based (autoresizing translated): it is
        // mounted directly as an NSSplitView pane (same rule as RequirementsPanel).

        headerTitle.translatesAutoresizingMaskIntoConstraints = false
        headerTitle.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = DynamicFillView()
        header.kind = .panel
        header.translatesAutoresizingMaskIntoConstraints = false
        let actions = NSStackView(views: [refreshButton, hideButton])
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

        // --- toolbar: the stage view / filter, with the total count on the right ---
        let toolbar = DynamicFillView()
        toolbar.kind = .panel
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        countLabel.font = NSFont.systemFont(ofSize: 10)
        countLabel.textColor = .tertiaryLabelColor
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        filterStrip.translatesAutoresizingMaskIntoConstraints = false
        filterStrip.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let toolbarStack = NSStackView(views: [filterStrip, countLabel])
        toolbarStack.orientation = .horizontal
        toolbarStack.alignment = .centerY
        toolbarStack.spacing = 8
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
        emptyView.addArrangedSubview(emptyLabel)
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

        for sub in [header, toolbar, toolbarUnderline, scroll, emptyView, statusRow] {
            view.addSubview(sub)
        }
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

            statusRow.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusRow.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusRow.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            statusRow.heightAnchor.constraint(equalToConstant: 24),
        ])
    }
}

// MARK: - Localhost API landing (/api/workstreams/*)

/// Same shape as the requirements pool panel: HTTP runs on its own queue and the
/// bridge marshals every call onto the main thread (single writer), so these
/// methods only touch the model and reload the visible board. The panel is the
/// only writer of WS-*.md (design A5), so the agent writes through here instead
/// of editing .dsh/workstreams/* directly.
extension WorkstreamsPanelController: WorkstreamsAPIDelegate {

    /// Prefer the requested workspace when it sits inside the active one (an
    /// agent may pass a subdirectory); otherwise fall back to the active
    /// workspace, then to the requested path itself. Mirrors the requirements
    /// panel's resolveWorkspace.
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
            return WorkstreamError.noWorkspace.apiResult
        }
        // Reuse the freshly rendered snapshot when it is the visible workspace;
        // otherwise load the requested one (the list is read-only either way).
        let loaded = workspace == (workspaceProvider?() ?? "") ? snapshot : WorkstreamsCore.load(workspace: workspace)
        // list carries the machine-scoped session bindings (design §6).
        return WorkstreamsAPIResponse.snapshot(loaded, sessions: WSStore.workstreamSessions(workspace))
    }

    /// One write result shape for every route: the re-parsed card on success,
    /// the model error code / message on failure (the router maps the status).
    private func writeResult(_ body: () throws -> WorkstreamCard,
                             workspace: String,
                             session: String? = nil) -> [String: Any] {
        do {
            let card = try body()
            // Remember the session that acted on this card (design §6): every later
            // panel action can then resume the same conversation.
            bindSession(session, workspace: workspace, id: card.id)
            if workspace == (workspaceProvider?() ?? "") { reload() }
            return ["ok": true, "workstream": WorkstreamsAPIResponse.card(card, session: session)]
        } catch let error as WorkstreamError {
            return error.apiResult
        } catch {
            return WorkstreamError.writeFailed(error.localizedDescription).apiResult
        }
    }

    /// Keep the workstream bound to the session that acted on it (design §6).
    /// Best-effort: a missing binding only means "fall back to the current session".
    private func bindSession(_ session: String?, workspace: String, id: String) {
        guard let session = session?.trimmingCharacters(in: .whitespacesAndNewlines),
              !session.isEmpty else { return }
        WSStore.rememberWorkstreamSession(workspace, id: id, session: session)
    }

    func apiWorkstreamsList(workspace: String?) -> [String: Any] {
        let resolved = resolveWorkspace(workspace)
        if let resolved = resolved, resolved == (workspaceProvider?() ?? "") {
            reload()
        }
        return listDictionary(resolved)
    }

    /// The focus channel (design A11 / D6): light the panel (onFocus, wired by
    /// main.swift to setRightPanel) and, when the request names a workstream,
    /// highlight + scroll to it. Called by the router for any route carrying
    /// focus:true (the write itself has already landed).
    func apiWorkstreamsFocus(workspace: String?, id: String?) {
        onFocus?(resolveWorkspace(workspace) ?? workspace ?? "")
        if let id = wsFocusedID(id) { focus(onWorkstream: id) }
    }

    /// GET /api/workstreams/bound?session=... — reverse lookup: the workstream(s)
    /// bound to that session (design §6). An unbound session returns an empty list
    /// (the caller falls back to the current session).
    func apiWorkstreamsBound(session: String) -> [String: Any] {
        guard let workspace = resolveWorkspace(nil), !workspace.isEmpty else {
            return WorkstreamError.noWorkspace.apiResult
        }
        guard let needle = wsNonEmpty(session) else {
            return ["ok": false, "error": "missing-session",
                    "hint": "expected ?session=$DSH_SESSION_ID"]
        }
        let loaded = workspace == (workspaceProvider?() ?? "") ? snapshot : WorkstreamsCore.load(workspace: workspace)
        let bindings = WSStore.workstreamSessions(workspace)
        let bound = loaded.workstreams.filter { bindings[$0.id] == needle }
        var out: [String: Any] = [
            "ok": true,
            "session": needle,
            "workstreams": bound.map { WorkstreamsAPIResponse.card($0, session: needle) },
        ]
        if let first = bound.first { out["workstream"] = WorkstreamsAPIResponse.card(first, session: needle) }
        return out
    }

    func apiWorkstreamsCreate(_ request: WorkstreamsCreateRequest) -> [String: Any] {
        guard let workspace = resolveWorkspace(request.workspace), !workspace.isEmpty else {
            return WorkstreamError.noWorkspace.apiResult
        }
        return writeResult({
            try WorkstreamsCore.create(workspace: workspace,
                                       title: request.title,
                                       requirement: request.requirement,
                                       stage: request.stage,
                                       body: request.body,
                                       today: WorkstreamsCore.today())
        }, workspace: workspace, session: request.session)
    }

    func apiWorkstreamsUpdate(_ request: WorkstreamsUpdateRequest) -> [String: Any] {
        guard let workspace = resolveWorkspace(request.workspace), !workspace.isEmpty else {
            return WorkstreamError.noWorkspace.apiResult
        }
        return writeResult({
            try WorkstreamsCore.update(workspace: workspace,
                                       id: request.id,
                                       title: request.title,
                                       requirement: request.requirement,
                                       body: request.body,
                                       today: WorkstreamsCore.today())
        }, workspace: workspace, session: request.session)
    }

    func apiWorkstreamsStage(_ request: WorkstreamsStageRequest) -> [String: Any] {
        guard let workspace = resolveWorkspace(request.workspace), !workspace.isEmpty else {
            return WorkstreamError.noWorkspace.apiResult
        }
        return writeResult({
            try WorkstreamsCore.setStage(workspace: workspace,
                                         id: request.id,
                                         stage: request.stage,
                                         today: WorkstreamsCore.today())
        }, workspace: workspace, session: request.session)
    }

    /// Replace one level-2 section (planning / design prose). heading keeps its
    /// "## " prefix so WorkstreamsCore.replaceSection can match it.
    func apiWorkstreamsPlan(_ request: WorkstreamsPlanRequest) -> [String: Any] {
        guard let workspace = resolveWorkspace(request.workspace), !workspace.isEmpty else {
            return WorkstreamError.noWorkspace.apiResult
        }
        return writeResult({
            let card = try WorkstreamsCore.loadCard(workspace: workspace, id: request.id)
            let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let section = request.heading + "\n\n" + text
            let body = WorkstreamsCore.replaceSection(card.body, heading: request.heading, with: section)
            return try WorkstreamsCore.update(workspace: workspace, id: request.id, body: body,
                                              today: WorkstreamsCore.today())
        }, workspace: workspace, session: request.session)
    }

    func apiWorkstreamsQueues(_ request: WorkstreamsQueuesRequest) -> [String: Any] {
        guard let workspace = resolveWorkspace(request.workspace), !workspace.isEmpty else {
            return WorkstreamError.noWorkspace.apiResult
        }
        return writeResult({
            try WorkstreamsCore.setQueues(workspace: workspace,
                                          id: request.id,
                                          queues: request.queues,
                                          today: WorkstreamsCore.today())
        }, workspace: workspace, session: request.session)
    }

    /// POST /api/workstreams/covered — record the acceptance point record (facts
    /// only, store design 3.2). A nil covered clears it.
    func apiWorkstreamsCovered(_ request: WorkstreamsCoveredRequest) -> [String: Any] {
        guard let workspace = resolveWorkspace(request.workspace), !workspace.isEmpty else {
            return WorkstreamError.noWorkspace.apiResult
        }
        return writeResult({
            try WorkstreamsCore.setCovered(workspace: workspace,
                                           id: request.id,
                                           covered: request.covered,
                                           today: WorkstreamsCore.today())
        }, workspace: workspace, session: request.session)
    }

    /// POST /api/workstreams/delivery — record the delivery facts. The outcome is a
    /// DERIVED cache: it is computed from the PR observation here, never taken from
    /// the caller (store design 5).
    func apiWorkstreamsDelivery(_ request: WorkstreamsDeliveryRequest) -> [String: Any] {
        guard let workspace = resolveWorkspace(request.workspace), !workspace.isEmpty else {
            return WorkstreamError.noWorkspace.apiResult
        }
        return writeResult({
            try WorkstreamsDelivery.writeBack(workspace: workspace,
                                              id: request.id,
                                              pr: request.pr,
                                              url: request.url,
                                              state: request.state,
                                              merged: request.merged,
                                              abandoned: request.abandoned,
                                              today: WorkstreamsCore.today())
        }, workspace: workspace, session: request.session)
    }

    /// Flatten the queue board into the gate's runtime facts (design D3). The queue
    /// is per-workstream; only the tasks tagged with this stage count (a legacy task
    /// without a stage falls back to the current stage).
    func stageCarrier(for card: WorkstreamCard, board: WSBoard) -> WSStageCarrier {
        let queue = board.queue(forWorkstream: card.id, mapping: card.queues)
        guard let queue = queue else {
            return WSStageCarrier(hasQueue: false, done: true, taskCount: 0,
                                  allTasksDone: true, allEvidenceVerified: true)
        }
        let tasks = board.tasks(inQueue: queue.id).filter { ($0.stage ?? card.stage) == card.stage }
        return WSStageCarrier(hasQueue: true,
                              done: queue.state == .done,
                              taskCount: tasks.count,
                              allTasksDone: !tasks.isEmpty && tasks.allSatisfy { $0.state == .done },
                              allEvidenceVerified: !tasks.isEmpty
                                  && tasks.allSatisfy { $0.markerVerified || $0.userConfirmed })
    }

    /// The human confirmation gate (R10): advances the stage only when the machine
    /// predicate already passes; a person is the only caller.
    func apiWorkstreamsStageConfirm(_ request: WorkstreamsStageConfirmRequest) -> [String: Any] {
        guard let workspace = resolveWorkspace(request.workspace), !workspace.isEmpty else {
            return WorkstreamError.noWorkspace.apiResult
        }
        do {
            let card = try WorkstreamsCore.loadCard(workspace: workspace, id: request.id)
            let updated = try WorkstreamsCore.confirmStage(workspace: workspace,
                                                           id: request.id,
                                                           expectedStage: request.stage,
                                                           carrier: stageCarrier(for: card, board: loadBoard(workspace)),
                                                           note: request.note,
                                                           today: WorkstreamsCore.today())
            bindSession(request.session, workspace: workspace, id: updated.id)
            // 对话内阶段推进（第 24 项）：API 路径的人确认同样把下一阶段提示词交给
            // 主场会话；此时 bindSession 已把请求里的 session 落盘，主程序读到新绑定。
            continueToNextStage(after: card, updated: updated)
            if workspace == (workspaceProvider?() ?? "") { reload() }
            let gate = WorkstreamsStageGate.evaluate(updated,
                                                     carrier: stageCarrier(for: updated, board: loadBoard(workspace)),
                                                     workspace: workspace)
            return ["ok": true,
                    "workstream": WorkstreamsAPIResponse.card(updated, session: request.session),
                    "gate": WorkstreamsStageGate.json(gate)]
        } catch let error as WorkstreamError {
            return error.apiResult
        } catch {
            return WorkstreamError.writeFailed(error.localizedDescription).apiResult
        }
    }

    /// The back edge: sends the stage back for rework and records the reason.
    func apiWorkstreamsStageReject(_ request: WorkstreamsStageRejectRequest) -> [String: Any] {
        guard let workspace = resolveWorkspace(request.workspace), !workspace.isEmpty else {
            return WorkstreamError.noWorkspace.apiResult
        }
        return writeResult({
            try WorkstreamsCore.rejectStage(workspace: workspace,
                                            id: request.id,
                                            reason: request.reason,
                                            target: request.target,
                                            today: WorkstreamsCore.today())
        }, workspace: workspace, session: request.session)
    }

    // MARK: Stage task create / start / pause (design A3 / A14)

    /// POST /api/workstreams/task/create — build waiting-state stage tasks. The
    /// panel injects the WorkstreamHandoff prompt (stage default action) into each
    /// task body and appends them to the workstream's single queue.
    func apiWorkstreamsTaskCreate(_ request: WorkstreamsTaskCreateRequest) -> [String: Any] {
        guard let workspace = resolveWorkspace(request.workspace), !workspace.isEmpty else {
            return WorkstreamError.noWorkspace.apiResult
        }
        guard let runner = ensureRunner(workspace) else {
            return WorkstreamError.noWorkspace.apiResult
        }
        do {
            let card = try WorkstreamsCore.loadCard(workspace: workspace, id: request.id)
            let stage = request.stage ?? card.stage
            let titles = request.titles.isEmpty ? [taskTitle(from: request.body)] : request.titles
            let built = runner.createStageQueue(card: card, stage: stage, workspace: workspace, titles: titles)
            guard !built.created.isEmpty else {
                return ["ok": false, "error": "no-queue",
                        "message": "the workstream queue is closed; no task was created"]
            }
            writeBackQueueMapping(card: card, queueID: built.queue.id, workspace: workspace)
            bindSession(request.session, workspace: workspace, id: card.id)
            if workspace == currentWorkspace { reload() }
            return ["ok": true, "queue": queueJSON(built.queue),
                    "tasks": built.created.map { taskJSON($0) }]
        } catch let error as WorkstreamError {
            return error.apiResult
        } catch {
            return WorkstreamError.writeFailed(error.localizedDescription).apiResult
        }
    }

    /// GET /api/workstreams/task/list — the workspace queue board (tasks + queues).
    /// Prefers the live runner board for the visible workspace.
    func apiWorkstreamsTaskList(workspace: String?) -> [String: Any] {
        guard let workspace = resolveWorkspace(workspace), !workspace.isEmpty else {
            return WorkstreamError.noWorkspace.apiResult
        }
        let board = loadBoard(workspace)
        return ["ok": true, "workspace": workspace,
                "tasks": board.tasks.map { taskJSON($0) },
                "queues": board.queues.map { queueJSON($0) }]
    }

    /// POST /api/workstreams/queue/start — item-level (no stage) starts the whole
    /// workstream queue; a stage runs only that stage's tasks (design A3 / D18).
    func apiWorkstreamsQueueStart(_ request: WorkstreamsQueueStartRequest) -> [String: Any] {
        guard let workspace = resolveWorkspace(request.workspace), !workspace.isEmpty else {
            return WorkstreamError.noWorkspace.apiResult
        }
        guard let runner = ensureRunner(workspace) else {
            return WorkstreamError.noWorkspace.apiResult
        }
        do {
            let card = try WorkstreamsCore.loadCard(workspace: workspace, id: request.id)
            guard let queue = runner.workstreamQueue(for: card) else {
                return ["ok": false, "error": "no-queue",
                        "message": "workstream has no queue yet"]
            }
            guard runner.startWorkstream(card, stage: request.stage) else {
                return ["ok": false, "error": "no-queue",
                        "message": "the workstream queue could not be started"]
            }
            bindSession(request.session, workspace: workspace, id: card.id)
            if workspace == currentWorkspace { reload() }
            var out: [String: Any] = ["ok": true, "queue": queueJSON(queue)]
            if let stage = request.stage { out["stage"] = stage.rawValue }
            return out
        } catch let error as WorkstreamError {
            return error.apiResult
        } catch {
            return WorkstreamError.writeFailed(error.localizedDescription).apiResult
        }
    }

    /// POST /api/workstreams/queue/pause.
    func apiWorkstreamsQueuePause(_ request: WorkstreamsQueuePauseRequest) -> [String: Any] {
        guard let workspace = resolveWorkspace(request.workspace), !workspace.isEmpty else {
            return WorkstreamError.noWorkspace.apiResult
        }
        guard let runner = ensureRunner(workspace) else {
            return WorkstreamError.noWorkspace.apiResult
        }
        do {
            let card = try WorkstreamsCore.loadCard(workspace: workspace, id: request.id)
            guard let queue = runner.workstreamQueue(for: card) else {
                return ["ok": false, "error": "no-queue",
                        "message": "workstream has no queue yet"]
            }
            guard runner.pauseQueue(queue.id) else {
                return ["ok": false, "error": "no-queue",
                        "message": "the workstream queue could not be paused"]
            }
            bindSession(request.session, workspace: workspace, id: card.id)
            if workspace == currentWorkspace { reload() }
            return ["ok": true, "queue": queueJSON(queue)]
        } catch let error as WorkstreamError {
            return error.apiResult
        } catch {
            return WorkstreamError.writeFailed(error.localizedDescription).apiResult
        }
    }
}
