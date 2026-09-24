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
        layer?.cornerRadius = 4
        layer?.masksToBounds = true
        label.stringValue = text
        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 1.5),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1.5),
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

/// A section caption with a count: 未入队 (7) / 队列 / Issue 任务.
final class TaskSectionHeaderView: NSView {
    init(text: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
    }

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

    init(model: TaskCardModel) {
        self.model = model
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        PanelControl.fill(dark: dark, highlighted: model.isExpanded).setFill()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        path.fill()
        if model.state == .running {
            TaskBadgeView.color(.running).withAlphaComponent(0.7).setStroke()
        } else {
            (dark ? NSColor(calibratedWhite: 0.36, alpha: 0.7) : NSColor(calibratedWhite: 0.84, alpha: 1)).setStroke()
        }
        path.lineWidth = 1
        path.stroke()
    }

    /// Labels are hit-testable views but must not swallow the card click; the
    /// buttons keep working because AppKit hit-tests the deepest view first.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if hit is NSButton || hit is TaskBadgeView { return hit }
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
        title.font = .systemFont(ofSize: 12, weight: model.isExpanded ? .semibold : .regular)
        title.textColor = TaskBadgeView.bodyColor(model.tone)
        title.maximumNumberOfLines = model.isExpanded ? 0 : 2
        title.translatesAutoresizingMaskIntoConstraints = false
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var rows: [NSView] = [topRow, title]

        if !model.meta.isEmpty {
            let meta = NSTextField(labelWithString: model.meta.joined(separator: " · "))
            meta.font = .systemFont(ofSize: 10)
            meta.textColor = .secondaryLabelColor
            meta.lineBreakMode = .byTruncatingMiddle
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
        column.spacing = 5
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            column.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            topRow.widthAnchor.constraint(equalTo: column.widthAnchor),
            title.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])
    }

    private func actionRow() -> NSView {
        var buttons: [NSView] = [actionButton(model.primaryKey, #selector(primaryTapped), enabled: model.primaryEnabled)]
        if model.canCommentClose {
            buttons.append(actionButton("tasks.detailCommentClose", #selector(commentCloseTapped)))
        }
        if model.canEdit {
            buttons.append(actionButton("tasks.card.edit", #selector(editTapped)))
        }
        if model.canDelete {
            buttons.append(actionButton("tasks.card.delete", #selector(deleteTapped)))
        }
        let row = NSStackView(views: buttons)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func actionButton(_ key: String, _ selector: Selector, enabled: Bool = true) -> NSButton {
        let button = NSButton(title: L10n.tr(key), target: self, action: selector)
        button.controlSize = .small
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 11)
        button.isEnabled = enabled
        button.translatesAutoresizingMaskIntoConstraints = false
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
final class TaskQueueHeaderView: NSView {

    let model: QueueHeaderModel

    var onToggle: (() -> Void)?
    var onStart: (() -> Void)?
    var onPause: (() -> Void)?
    var onOpenPR: (() -> Void)?
    var onRename: (() -> Void)?
    var onBranch: (() -> Void)?
    var onTogglePR: (() -> Void)?
    var onDelete: (() -> Void)?

    init(model: QueueHeaderModel) {
        self.model = model
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        PanelControl.fill(dark: dark, highlighted: true).withAlphaComponent(0.55).setFill()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        path.fill()
        TaskBadgeView.color(model.tone).withAlphaComponent(0.35).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if hit is NSButton || hit is TaskBadgeView { return hit }
        return self
    }

    override func mouseDown(with event: NSEvent) { onToggle?() }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    private func build() {
        let disclosure = NSTextField(labelWithString: model.isCollapsed ? "▸" : "▾")
        disclosure.font = .systemFont(ofSize: 11)
        disclosure.textColor = .secondaryLabelColor
        disclosure.translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: model.name)
        name.font = .systemFont(ofSize: 12, weight: .semibold)
        name.lineBreakMode = .byTruncatingTail
        name.translatesAutoresizingMaskIntoConstraints = false
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let branch = NSTextField(labelWithString: model.branchText)
        branch.font = .systemFont(ofSize: 10)
        branch.textColor = .secondaryLabelColor
        branch.lineBreakMode = .byTruncatingMiddle
        branch.translatesAutoresizingMaskIntoConstraints = false

        let progress = TaskBadgeView(text: model.progress, tone: .neutral)
        let state = TaskBadgeView(text: L10n.tr(model.stateKey), tone: model.tone, filled: model.tone == .running)

        var trailing: [NSView] = [progress, state]
        if model.failedCount > 0 {
            trailing.append(TaskBadgeView(text: L10n.tr("tasks.queue.failedCount", model.failedCount), tone: .negative))
        }
        if model.canPause {
            trailing.append(button("tasks.queue.pause", #selector(pauseTapped)))
        } else if model.canStart {
            trailing.append(button("tasks.queue.start", #selector(startTapped)))
        }
        if model.canOpenPR {
            trailing.append(button("tasks.queue.openPR", #selector(openPRTapped)))
        }
        if let prUrl = model.prUrl {
            let link = NSButton(title: TaskCardModel.shortPR(prUrl), target: self, action: #selector(openPRTapped))
            link.isBordered = false
            link.controlSize = .small
            link.contentTintColor = .controlAccentColor
            link.font = .systemFont(ofSize: 10)
            link.translatesAutoresizingMaskIntoConstraints = false
            trailing.append(link)
        }
        trailing.append(button("tasks.queue.more", #selector(moreTapped)))

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        let actions = NSStackView(views: trailing)
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 6
        actions.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [disclosure, name, branch, spacer, actions])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
    }

    private func button(_ key: String, _ selector: Selector) -> NSButton {
        let button = NSButton(title: L10n.tr(key), target: self, action: selector)
        button.controlSize = .small
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 10)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    @objc private func startTapped() { onStart?() }
    @objc private func pauseTapped() { onPause?() }
    @objc private func openPRTapped() { onOpenPR?() }

    /// The overflow menu: the queue's own settings (rename, branch, PR switch,
    /// delete).
    @objc private func moreTapped() {
        let menu = NSMenu()
        menu.addItem(withTitle: L10n.tr("tasks.queue.rename"), action: #selector(renameTapped), keyEquivalent: "").target = self
        menu.addItem(withTitle: L10n.tr("tasks.queue.changeBranch"), action: #selector(branchTapped), keyEquivalent: "").target = self
        let prItem = menu.addItem(withTitle: L10n.tr("tasks.queue.autoPR"),
                                  action: #selector(togglePRTapped), keyEquivalent: "")
        prItem.target = self
        prItem.state = model.autoPR ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.tr("tasks.queue.delete"), action: #selector(deleteTapped), keyEquivalent: "").target = self
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height), in: self)
    }

    @objc private func renameTapped() { onRename?() }
    @objc private func branchTapped() { onBranch?() }
    @objc private func togglePRTapped() { onTogglePR?() }
    @objc private func deleteTapped() { onDelete?() }
}
