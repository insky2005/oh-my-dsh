import AppKit

// MARK: - Small shared pieces

/// A pill-shaped badge (source / state / progress). The color comes from the
/// view model's tone, so the card never decides semantics itself.
final class TaskBadgeView: NSView {

    private let label = NSTextField(labelWithString: "")
    private var tone: TaskTone = .neutral
    private var filled = false

    init(text: String, tone: TaskTone, filled: Bool = false) {
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

    /// Fixed width text (progress counters) must not stretch.
    override var intrinsicContentSize: NSSize { label.intrinsicContentSize }

    private func applyTone() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let color = TaskBadgeView.color(tone)
        layer?.backgroundColor = filled
            ? color.cgColor
            : color.withAlphaComponent(dark ? 0.24 : 0.14).cgColor
        label.textColor = filled ? .white : color
    }

    static func color(_ tone: TaskTone) -> NSColor {
        switch tone {
        case .neutral: return .secondaryLabelColor
        case .running: return .controlAccentColor
        case .positive: return .systemGreen
        case .warning: return .systemOrange
        case .negative: return .systemRed
        }
    }

    /// The card's body text color for the same tone (error text reads red).
    static func bodyColor(_ tone: TaskTone) -> NSColor {
        switch tone {
        case .negative: return .systemRed
        case .warning: return .systemOrange
        default: return .labelColor
        }
    }
}

/// A queue's progress as a hairline bar: how far through the queue we are, in
/// the queue's own tone. Cheap, always visible, and it reads at a glance where
/// the "3/7" text alone does not.
final class TaskProgressBarView: NSView {

    var fraction: Double = 0 { didSet { needsDisplay = true } }
    var tone: TaskTone = .neutral { didSet { needsDisplay = true } }

    static let barHeight: CGFloat = 4

    override var intrinsicContentSize: NSSize { NSSize(width: 72, height: Self.barHeight) }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let radius = bounds.height / 2
        let track = dark ? NSColor(calibratedWhite: 0.42, alpha: 0.8)
                         : NSColor(calibratedWhite: 0.80, alpha: 1)
        track.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        let clamped = max(0, min(1, fraction))
        guard clamped > 0 else { return }
        let width = max(bounds.height, bounds.width * CGFloat(clamped))
        TaskBadgeView.color(tone).withAlphaComponent(0.95).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: width, height: bounds.height),
                     xRadius: radius, yRadius: radius).fill()
    }
}

/// A section caption with a count (未入队 (7) / 队列 / Issue 任务) and a hairline
/// rule that carries the eye to the right edge — sections read as sections
/// without drawing a box around them.
final class TaskSectionHeaderView: NSView {

    /// Optional trailing action (the queues section's 新建队列), rendered as a
    /// small flat button right after the rule.
    init(text: String, actionTitle: String? = nil, onAction: (() -> Void)? = nil) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .bold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)

        let rule = NSBox()
        rule.boxType = .separator
        rule.translatesAutoresizingMaskIntoConstraints = false
        rule.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        addSubview(label)
        addSubview(rule)
        var constraints = [
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            rule.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            rule.centerYAnchor.constraint(equalTo: label.centerYAnchor),
        ]
        if let actionTitle = actionTitle {
            // NOTE: the designated initializer, never NSButton's convenience
            // init(title:target:action:) through a subclass (that factory
            // dispatches on the instance and crashes — see PanelIconButton).
            let button = HoverButton(frame: .zero)
            button.title = actionTitle
            button.isBordered = false
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11, weight: .medium)
            button.contentTintColor = .controlAccentColor
            button.translatesAutoresizingMaskIntoConstraints = false
            button.target = self
            button.action = #selector(actionTapped)
            self.onAction = onAction
            addSubview(button)
            constraints.append(contentsOf: [
                button.leadingAnchor.constraint(equalTo: rule.trailingAnchor, constant: 6),
                button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
                button.centerYAnchor.constraint(equalTo: label.centerYAnchor),
                button.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 2),
                button.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -2),
            ])
        } else {
            constraints.append(rule.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2))
        }
        NSLayoutConstraint.activate(constraints)
    }

    private var onAction: (() -> Void)?

    @objc private func actionTapped() { onAction?() }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

// MARK: - Task card

/// One task card. A pure renderer: it is handed a TaskCardModel (built by
/// TasksUI.swift) and only forwards clicks.
///
/// Clicking anywhere that is not a button expands/collapses the details — the
/// same interaction as v1's table row, so nothing has to be relearned.
final class TaskCardView: NSView {

    let model: TaskCardModel

    var onToggle: (() -> Void)?
    var onPrimary: (() -> Void)?
    var onQueue: (() -> Void)?
    var onCommentClose: (() -> Void)?
    var onEdit: (() -> Void)?
    var onDelete: (() -> Void)?

    private var isHovered = false
    private var trackingArea: NSTrackingArea?

    init(model: TaskCardModel) {
        self.model = model
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

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = trackingArea { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        PanelControl.fill(dark: dark, highlighted: model.isExpanded || isHovered).setFill()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        path.fill()
        if model.state == .running {
            TaskBadgeView.color(.running).withAlphaComponent(0.6).setStroke()
        } else if model.isExpanded {
            NSColor.controlAccentColor.withAlphaComponent(dark ? 0.55 : 0.45).setStroke()
        } else {
            (dark ? NSColor(calibratedWhite: 0.38, alpha: 0.7) : NSColor(calibratedWhite: 0.82, alpha: 1)).setStroke()
        }
        path.lineWidth = 1
        path.stroke()
    }

    /// Labels are hit-testable views but must not swallow the card click; the
    /// buttons keep working because AppKit hit-tests the deepest view first.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if hit is NSButton || hit is TaskBadgeView || hit is NSTextView || hit is CustomIconButton { return hit }
        return self
    }

    override func mouseDown(with event: NSEvent) { onToggle?() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    // MARK: layout

    private func build() {
        let source = TaskBadgeView(text: model.sourceBadge, tone: .neutral)
        let state = TaskBadgeView(text: model.stateBadge, tone: model.tone, filled: model.state == .running)
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let topRow = NSStackView(views: [source, state, spacer])
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = 6
        topRow.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(wrappingLabelWithString: model.title)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = TaskBadgeView.bodyColor(model.tone)
        title.maximumNumberOfLines = model.isExpanded ? 0 : 2
        title.translatesAutoresizingMaskIntoConstraints = false
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var rows: [NSView] = [topRow, title]

        if !model.meta.isEmpty {
            let meta = NSTextField(labelWithString: model.meta.joined(separator: "  ·  "))
            meta.font = .systemFont(ofSize: 11)
            meta.textColor = .secondaryLabelColor
            meta.lineBreakMode = .byTruncatingMiddle
            meta.toolTip = model.meta.joined(separator: "\n")
            meta.translatesAutoresizingMaskIntoConstraints = false
            rows.append(meta)
        }

        if model.isExpanded {
            if !model.detail.isEmpty {
                let detail = NSTextField(wrappingLabelWithString: model.detail)
                detail.font = .systemFont(ofSize: 11)
                detail.textColor = .secondaryLabelColor
                detail.maximumNumberOfLines = 0
                detail.translatesAutoresizingMaskIntoConstraints = false
                detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                rows.append(detail)
            }
            rows.append(actionRow())
        }

        let column = NSStackView(views: rows)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            column.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            topRow.widthAnchor.constraint(equalTo: column.widthAnchor),
            title.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])
    }

    /// The expanded card's actions: the primary action as text, everything that
    /// is secondary as an icon button — three text buttons do not fit a narrow
    /// panel, and they made the card demand more width than the list had.
    private func actionRow() -> NSView {
        var views: [NSView] = [actionButton(model.primaryKey, #selector(primaryTapped), enabled: model.primaryEnabled)]
        if model.canCommentClose {
            views.append(actionButton("tasks.detailCommentClose", #selector(commentCloseTapped)))
        }
        if model.canEdit {
            views.append(iconButton("pencil", tooltipKey: "tasks.card.edit", action: #selector(editTapped)))
        }
        if model.canDelete {
            views.append(iconButton("trash", tooltipKey: "tasks.card.delete", action: #selector(deleteTapped)))
        }
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        views.append(spacer)
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func iconButton(_ symbol: String, tooltipKey: String, action: Selector) -> CustomIconButton {
        let button = CustomIconButton(glyph: .symbol(symbol), tooltip: L10n.tr(tooltipKey), size: 22)
        button.onAction = { [weak self] in self?.perform(action, with: nil) }
        return button
    }

    private func actionButton(_ key: String, _ selector: Selector, enabled: Bool = true) -> NSButton {
        let button = NSButton(title: L10n.tr(key), target: self, action: selector)
        button.controlSize = .small
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 11)
        button.isEnabled = enabled
        button.translatesAutoresizingMaskIntoConstraints = false
        // A narrow panel wins over the button's ideal width (the title
        // truncates); without this the card would push the list wider.
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return button
    }

    @objc private func primaryTapped() {
        if model.canQueue { onQueue?() } else { onPrimary?() }
    }

    @objc private func commentCloseTapped() { onCommentClose?() }
    @objc private func editTapped() { onEdit?() }
    @objc private func deleteTapped() { onDelete?() }
}

// MARK: - Queue header

/// The queue (lane) header: how many queues there are, which branch each one
/// works on, how far along it is, and the actions that apply to the queue.
///
/// Shape follows the channel panel's SessionTitleBar: an opaque highlighted fill
/// (never a translucent card), one line while collapsed, two while expanded.
final class TaskQueueHeaderView: NSView {

    let model: QueueHeaderModel

    var onToggle: (() -> Void)?
    var onStart: (() -> Void)?
    var onPause: (() -> Void)?
    var onOpenPR: (() -> Void)?
    var onSettings: (() -> Void)?
    var onTogglePR: (() -> Void)?
    var onDelete: (() -> Void)?

    private var isHovered = false
    private var trackingArea: NSTrackingArea?

    init(model: QueueHeaderModel) {
        self.model = model
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

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = trackingArea { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        // Opaque highlighted fill (SessionTitleBar's体例): the queue header is a
        // bar, not another card, so it must not read as a translucent overlay.
        PanelControl.fill(dark: dark, highlighted: true).setFill()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        path.fill()
        if isHovered {
            (dark ? NSColor(calibratedWhite: 0.5, alpha: 0.5) : NSColor(calibratedWhite: 0.72, alpha: 0.9)).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if hit is NSButton || hit is TaskBadgeView || hit is CustomIconButton { return hit }
        return self
    }

    override func mouseDown(with event: NSEvent) { onToggle?() }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    private func build() {
        let disclosure = NSTextField(labelWithString: model.isCollapsed ? "▸" : "▾")
        disclosure.font = .systemFont(ofSize: 11, weight: .semibold)
        disclosure.textColor = .secondaryLabelColor
        disclosure.translatesAutoresizingMaskIntoConstraints = false
        disclosure.setContentHuggingPriority(.required, for: .horizontal)

        let name = NSTextField(labelWithString: model.name)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.lineBreakMode = .byTruncatingTail
        name.toolTip = model.name
        name.translatesAutoresizingMaskIntoConstraints = false
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let progress = compressible(TaskBadgeView(text: model.progress, tone: .neutral))
        let state = compressible(TaskBadgeView(text: L10n.tr(model.stateKey), tone: model.tone,
                                               filled: model.tone == .running))

        // Row 1 carries the state and the queue's actions as ICON buttons (text
        // buttons 开始 / 暂停 / 更多 … needed more width than a narrow panel has);
        // the numbers live on the meta row, where they have room.
        var trailing: [NSView] = [progress, state]
        if model.canPause {
            trailing.append(iconButton("pause.fill", tooltipKey: "tasks.queue.pause", action: #selector(pauseTapped)))
        } else if model.canStart {
            trailing.append(iconButton("play.fill", tooltipKey: "tasks.queue.start", action: #selector(startTapped)))
        }
        if model.canOpenPR {
            trailing.append(iconButton("arrow.up.right.square", tooltipKey: "tasks.queue.openPR",
                                       action: #selector(openPRTapped)))
        }
        if let prUrl = model.prUrl {
            let link = NSButton(title: TaskCardModel.shortPR(prUrl), target: self, action: #selector(openPRTapped))
            link.isBordered = false
            link.controlSize = .small
            link.contentTintColor = .controlAccentColor
            link.font = .systemFont(ofSize: 11)
            link.toolTip = prUrl
            link.translatesAutoresizingMaskIntoConstraints = false
            link.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            trailing.append(link)
        }
        trailing.append(iconButton("ellipsis", tooltipKey: "tasks.queue.more", action: #selector(moreTapped)))

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        let actions = NSStackView(views: trailing)
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 6
        actions.translatesAutoresizingMaskIntoConstraints = false

        let branch = NSTextField(labelWithString: model.branchText)
        branch.font = .systemFont(ofSize: 11)
        branch.textColor = .secondaryLabelColor
        branch.lineBreakMode = .byTruncatingMiddle
        branch.toolTip = model.branchText
        branch.translatesAutoresizingMaskIntoConstraints = false
        branch.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let bar = TaskProgressBarView()
        bar.fraction = model.progressFraction
        bar.tone = model.tone
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.setContentHuggingPriority(.required, for: .horizontal)

        let titleRow = NSStackView(views: [disclosure, name, spacer, actions])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 6
        titleRow.translatesAutoresizingMaskIntoConstraints = false

        // Row 2 (an expanded queue): where it works, how far along it is, and
        // how many tasks failed. A collapsed queue is one line — the branch is
        // its tooltip there.
        let spacer2 = NSView()
        spacer2.translatesAutoresizingMaskIntoConstraints = false
        spacer2.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let metaRow = NSStackView(views: [branch, spacer2, bar])
        metaRow.orientation = .horizontal
        metaRow.alignment = .centerY
        metaRow.spacing = 8
        metaRow.translatesAutoresizingMaskIntoConstraints = false
        if model.failedCount > 0 {
            let failed = TaskBadgeView(text: L10n.tr("tasks.queue.failedCount", model.failedCount),
                                       tone: .negative)
            metaRow.addArrangedSubview(failed)
        }
        var rows: [NSView] = [titleRow]
        if model.isCollapsed {
            branch.toolTip = model.branchText
            branch.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        } else {
            rows.append(metaRow)
        }

        let column = NSStackView(views: rows)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            column.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
        for row in rows {
            row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        bar.widthAnchor.constraint(equalToConstant: 72).isActive = true
    }

    private func iconButton(_ symbol: String, tooltipKey: String, action: Selector) -> CustomIconButton {
        let button = CustomIconButton(glyph: .symbol(symbol), tooltip: L10n.tr(tooltipKey), size: 22)
        button.onAction = { [weak self] in self?.perform(action, with: nil) }
        return button
    }

    /// The state badge and the branch must give way before the panel width does.
    private func compressible(_ view: NSView) -> NSView {
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    @objc private func startTapped() { onStart?() }
    @objc private func pauseTapped() { onPause?() }
    @objc private func openPRTapped() { onOpenPR?() }

    /// The overflow menu: the queue's own settings (inline form), the PR switch
    /// and delete.
    @objc private func moreTapped() {
        let menu = NSMenu()
        menu.addItem(withTitle: L10n.tr("tasks.queue.settings"),
                     action: #selector(settingsTapped), keyEquivalent: "").target = self
        let prItem = menu.addItem(withTitle: L10n.tr("tasks.queue.autoPR"),
                                  action: #selector(togglePRTapped), keyEquivalent: "")
        prItem.target = self
        prItem.state = model.autoPR ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.tr("tasks.queue.delete"),
                     action: #selector(deleteTapped), keyEquivalent: "").target = self
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height), in: self)
    }

    @objc private func settingsTapped() { onSettings?() }
    @objc private func togglePRTapped() { onTogglePR?() }
    @objc private func deleteTapped() { onDelete?() }
}
