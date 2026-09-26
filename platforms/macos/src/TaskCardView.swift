import AppKit

// MARK: - Small shared pieces

/// The card family's palette — the AUDIT panel's (ReviewPanel) block grammar,
/// verbatim, so a queue lane and a task card read exactly like a session block
/// and a file block:
///
///   * ONE hairline outline for every block: no state-tinted borders (a state
///     lives in its badge, the way the audit panel keeps it in its trailing
///     summary). The only accent is the "current" one — see accentFill;
///   * fills alternate BY NESTING LEVEL instead of by interaction state: the
///     container sits on the raised fill (PanelControl normal), the blocks
///     inside it on the recessed one (highlight) — the audit panel's
///     session → turn → file ladder is white → white → grey.
enum TaskInk {
    /// The audit panel's own hairline (ReviewInk.hairline).
    static func hairline(dark: Bool) -> NSColor {
        dark ? NSColor(calibratedWhite: 0.38, alpha: 0.7) : NSColor(calibratedWhite: 0.80, alpha: 1)
    }

    /// A block's fill by nesting level: recessed = INSIDE a container (a task
    /// card in its queue lane), everything else = raised.
    static func fill(dark: Bool, recessed: Bool) -> NSColor {
        PanelControl.fill(dark: dark, highlighted: recessed)
    }

    /// The running task — this panel's "current" (the audit panel tints the
    /// session dsh web is showing the same way).
    static func accentFill(dark: Bool) -> NSColor {
        NSColor.controlAccentColor.withAlphaComponent(dark ? 0.40 : 0.20)
    }

    static func accentBorder(dark: Bool) -> NSColor {
        NSColor.controlAccentColor.withAlphaComponent(dark ? 0.55 : 0.45)
    }
}

/// A pill-shaped badge (source / state / progress). The color comes from the
/// view model's tone, so the card never decides semantics itself.
final class TaskBadgeView: NSView {

    /// What the pill says — kept so callers (and the layout tests) can tell one
    /// badge from another without reaching into its label.
    let text: String
    private let label = NSTextField(labelWithString: "")
    private var tone: TaskTone = .neutral
    private var filled = false

    init(text: String, tone: TaskTone, filled: Bool = false) {
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

    /// The pill is its label PLUS the pill's own padding (6pt each side), and it
    /// must never stretch (progress counters are fixed text). Returning the bare
    /// label size — 12pt too narrow — made Auto Layout clip the text the moment a
    /// constrained row used it: "队列中 #2" rendered as "队列中 #".
    override var intrinsicContentSize: NSSize {
        let size = label.intrinsicContentSize
        return NSSize(width: size.width + 12, height: size.height + 2 * 2)
    }

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

    init(text: String) {
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
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            rule.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            rule.centerYAnchor.constraint(equalTo: label.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

// MARK: - Summary card (统计信息)

/// The content area's FIRST row: the board's four counters as one line inside a
/// rounded block. This is the review panel's summary card, applied to tasks —
/// the counts used to be pills up in the toolbar, where they competed with the
/// workspace name for the same 28pt strip.
///
/// Counts are the only thing it says: like the review card, every number is
/// labelled ("队列 12 · 排队 5 · …") and only 失败 ever turns red.
final class TaskSummaryCardView: NSView {

    let model: TasksSummaryModel

    init(model: TasksSummaryModel) {
        self.model = model
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isOpaque: Bool { false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// The audit panel's summary card, block for block: raised fill, one hairline.
    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        TaskInk.fill(dark: dark, recessed: false).setFill()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        path.fill()
        TaskInk.hairline(dark: dark).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    /// The counters joined the way the review panel joins its summary
    /// ("已审 3/12  ·  对话 8  ·  +120 −30"): one font, muted by default, with
    /// the failing counter in red and everything else left to the tone map.
    var summaryText: NSAttributedString {
        let font = NSFont.systemFont(ofSize: 11)
        let text = NSMutableAttributedString()
        for (index, part) in model.parts.enumerated() {
            if index > 0 {
                text.append(NSAttributedString(string: "  ·  ", attributes: [
                    .font: font,
                    .foregroundColor: NSColor.tertiaryLabelColor,
                ]))
            }
            text.append(NSAttributedString(string: part.text, attributes: [
                .font: font,
                .foregroundColor: TaskBadgeView.color(part.tone),
            ]))
        }
        return text
    }

    private func build() {
        let label = NSTextField(wrappingLabelWithString: "")
        label.attributedStringValue = summaryText
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        // Padding matches a task card's own inset (8 / 7), so the summary line
        // starts where the card titles under it start.
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])
    }
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
    /// The 加入队列 dropdown: the panel opens the list under the view it is handed
    /// (the menu button itself).
    var onQueue: ((NSView) -> Void)?
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

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// The audit panel's block: one rounded block, one hairline, and a fill that
    /// says how DEEP in the tree it sits — never one that changes because the
    /// block is open or hovered. Only the RUNNING task is accented (this panel's
    /// "current").
    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if model.state == .running {
            TaskInk.accentFill(dark: dark).setFill()
        } else {
            TaskInk.fill(dark: dark, recessed: model.isNested).setFill()
        }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        path.fill()
        if model.state == .running {
            TaskInk.accentBorder(dark: dark).setStroke()
        } else {
            TaskInk.hairline(dark: dark).setStroke()
        }
        path.lineWidth = 1
        path.stroke()
    }

    /// Labels are hit-testable views but must not swallow the card click; the
    /// buttons keep working because AppKit hit-tests the deepest view first.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if hit is NSButton || hit is TaskBadgeView || hit is NSTextView || hit is CustomIconButton {
            return hit
        }
        // The 加入队列 dropdown owns its clicks (it is not an NSButton).
        if hit is PanelMenuButton || hit.superview is PanelMenuButton { return hit }
        return self
    }

    override func mouseDown(with event: NSEvent) { onToggle?() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    // MARK: layout

    private func build() {
        // 标题与状态同一行 (the review panel's block体例: the block's identity on
        // the left, its own status on the right). The badges never give way; the
        // title does — and a long title still wraps, with the badges riding its
        // FIRST line, which is what the .top alignment buys (a .centerY row would
        // float them between two lines of text).
        let source = TaskBadgeView(text: model.sourceBadge, tone: .neutral)
        let state = TaskBadgeView(text: model.stateBadge, tone: model.tone, filled: model.state == .running)
        for badge in [source, state] {
            badge.setContentHuggingPriority(.required, for: .horizontal)
            badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        let title = NSTextField(wrappingLabelWithString: model.title)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = TaskBadgeView.bodyColor(model.tone)
        title.maximumNumberOfLines = model.isExpanded ? 0 : 2
        // Long titles are truncated with a tooltip carrying the whole thing —
        // the same deal the review panel's block titles make.
        title.toolTip = model.title
        title.translatesAutoresizingMaskIntoConstraints = false
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // The disclosure chevron the audit panel's blocks carry: it (not a fill
        // or a border) is what says whether the card is open.
        let chevron = NSImageView()
        if let image = NSImage(systemSymbolName: model.isExpanded ? "chevron.down" : "chevron.right",
                               accessibilityDescription: nil) {
            chevron.image = image
            chevron.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            chevron.contentTintColor = .tertiaryLabelColor
        }
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.widthAnchor.constraint(equalToConstant: 14).isActive = true
        chevron.heightAnchor.constraint(equalToConstant: 14).isActive = true

        let titleRow = NSStackView(views: [chevron, source, title, spacer, state])
        titleRow.orientation = .horizontal
        titleRow.alignment = .top
        titleRow.spacing = 6
        titleRow.translatesAutoresizingMaskIntoConstraints = false

        var rows: [NSView] = [titleRow]

        if !model.meta.isEmpty {
            // Same slot, size and colour as the audit panel's detail/subtitle
            // line under a block title (10pt, tertiary).
            let meta = NSTextField(labelWithString: model.meta.joined(separator: "  ·  "))
            meta.font = .systemFont(ofSize: 10)
            meta.textColor = .tertiaryLabelColor
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
            // The audit panel's header insets (8 / 7).
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            column.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            titleRow.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])
    }

    /// The expanded card's actions: the primary action as text, everything that
    /// is secondary as an icon button — three text buttons do not fit a narrow
    /// panel, and they made the card demand more width than the list had.
    private func actionRow() -> NSView {
        var views: [NSView] = [primaryControl()]
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

    /// The card's primary action. 加入队列 is a DROPDOWN, so it is the shell's menu
    /// button (icon + label + chevron + hover highlight) — the exact control the
    /// files panel's 打开项目 button uses — and the list it opens drops right under
    /// it. Every other primary action is a plain button that just fires.
    private func primaryControl() -> NSView {
        guard model.canQueue else {
            return actionButton(model.primaryKey, #selector(primaryTapped), enabled: model.primaryEnabled)
        }
        let button = PanelMenuButton(glyph: .symbol("rectangle.stack.badge.plus"),
                                     title: L10n.tr(model.primaryKey),
                                     tooltip: L10n.tr("tasks.queue.addHint"))
        button.onShowMenu = { [weak self, weak button] in
            guard let button = button else { return }
            self?.onQueue?(button)
        }
        return button
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

    /// 加入队列 never lands here: it is the dropdown (primaryControl), which opens
    /// the picker instead of firing an action.
    @objc private func primaryTapped() { onPrimary?() }

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

    init(model: QueueHeaderModel) {
        self.model = model
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isOpaque: Bool { false }

    /// The header itself draws NOTHING: its queue's block (TaskQueueBlockView)
    /// paints the lane the header and its task cards live in, which is what makes
    /// the containment read. The header only owns the click that collapses it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if hit is NSButton || hit is TaskBadgeView || hit is CustomIconButton { return hit }
        return self
    }

    override func mouseDown(with event: NSEvent) { onToggle?() }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    private func build() {
        // The same disclosure glyph the audit panel's blocks use (a symbol, not
        // a text arrow), so queue headers and task cards open the same way.
        let disclosure = NSImageView()
        if let image = NSImage(systemSymbolName: model.isCollapsed ? "chevron.right" : "chevron.down",
                               accessibilityDescription: nil) {
            disclosure.image = image
            disclosure.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            disclosure.contentTintColor = .tertiaryLabelColor
        }
        disclosure.translatesAutoresizingMaskIntoConstraints = false
        disclosure.widthAnchor.constraint(equalToConstant: 14).isActive = true
        disclosure.heightAnchor.constraint(equalToConstant: 14).isActive = true
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
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            column.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
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

// MARK: - Queue block (the lane a queue's tasks live in)

/// One queue, drawn as a single CONTAINER: the lane surface plus its header and
/// the task cards inside it (the review panel's tree体例 — an outer block holds
/// a header and an indented stack of inner blocks, so "these cards belong to
/// this queue" is a matter of geometry, not of reading two parallel cards).
///
/// The lane takes the recessed control fill while the cards inside keep the
/// raised one: the nesting reads in both themes without inventing a colour.
final class TaskQueueBlockView: NSView {

    let model: QueueHeaderModel

    private let header: TaskQueueHeaderView
    private let cards: [NSView]
    private let collapsed: Bool

    init(header: TaskQueueHeaderView, cards: [NSView], collapsed: Bool) {
        self.model = header.model
        self.header = header
        self.cards = cards
        self.collapsed = collapsed
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

    /// A lane is a CONTAINER block in the audit panel's sense: the raised fill
    /// with one hairline — no tint of its own. What the queue is doing lives in
    /// its badges, exactly the way a session block keeps its counts in the
    /// trailing summary instead of colouring its outline.
    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        TaskInk.fill(dark: dark, recessed: false).setFill()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        path.fill()
        TaskInk.hairline(dark: dark).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    private func build() {
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)
        // The header owns the lane's full width minus its padding...
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])
        guard !cards.isEmpty else {
            // Collapsed: the lane IS its header.
            header.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7).isActive = true
            return
        }
        // ...and the cards are stacked INSIDE it, inset 12/10 under the
        // container's own 8 — the audit panel's exact child geometry. Two inset
        // levels plus two fill levels (raised lane → recessed cards) is what makes
        // the queue read as the container.
        let children = NSStackView()
        children.orientation = .vertical
        children.alignment = .leading
        children.spacing = 6
        children.translatesAutoresizingMaskIntoConstraints = false
        for card in cards {
            children.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: children.widthAnchor).isActive = true
        }
        addSubview(children)
        NSLayoutConstraint.activate([
            children.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            children.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            children.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            children.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }
}
