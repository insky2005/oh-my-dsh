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

/// A row-kind marker: the small SF Symbol before a queue's name and before a task's
/// title (泳道 / 任务). Quiet by design — tertiary, like the disclosure chevron —
/// because the STATE lives in the badge on the other side of the row. A symbol the
/// running macOS does not have degrades to a zero-width view: no hole, no crash.
func taskRowGlyph(_ symbol: String, accessibility: String) -> NSView {
    guard let image = NSImage(systemSymbolName: symbol,
                              accessibilityDescription: L10n.tr(accessibility)) else {
        let empty = NSView()
        empty.translatesAutoresizingMaskIntoConstraints = false
        return empty
    }
    let view = NSImageView(image: image)
    // Testable identity (the layout tests cannot read a symbol out of an NSImageView).
    view.identifier = NSUserInterfaceItemIdentifier("taskGlyph:" + symbol)
    view.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
    view.contentTintColor = .tertiaryLabelColor
    view.translatesAutoresizingMaskIntoConstraints = false
    view.widthAnchor.constraint(equalToConstant: 13).isActive = true
    view.heightAnchor.constraint(equalToConstant: 13).isActive = true
    view.setContentHuggingPriority(.required, for: .horizontal)
    view.setContentCompressionResistancePriority(.required, for: .horizontal)
    return view
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
    /// 跳过并继续: keep this failure's record and run the next queued task.
    var onSkip: (() -> Void)?
    /// The task's dsh session: show it in dsh web / audit its changes.
    var onOpenSession: (() -> Void)?
    var onReview: (() -> Void)?
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

        // 任务名前面一枚行标：这是「一条任务」，与队列头的泳道图标成对（2026-09-27，
        // 用户要求：卡片上的队列名与任务名前都加图标）。quiet 的第三档灰 —— 它是标记，
        // 不是状态（状态在右边那枚徽标上）。
        let glyph = taskRowGlyph("checklist", accessibility: "tasks.glyph.task")
        // 顺序（2026-09-27，用户要求）：▸ 行标 任务名 [来源徽标] …… [状态徽标]。
        // 来源（手动 / Issue #N）跟在名字后面：它是这条任务的注解，不该抢在名字前面。
        let titleRow = NSStackView(views: [chevron, glyph, title, source, spacer, state])
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
    ///
    /// A card WITHOUT a primary (a finished manual task: nothing left to do with it)
    /// starts the row at the session/review icons — an empty leading slot, no gap.
    private func actionRow() -> NSView {
        var views: [NSView] = []
        if let primary = primaryControl() { views.append(primary) }
        // The session this task runs in: the two things the user wants right after
        // a task ran — look at it, and see what it changed. The panel hands the id
        // to the shell (openDSHSession / the audit panel), which needs nothing new.
        if model.sessionId != nil {
            views.append(iconButton("arrow.up.forward.app", tooltipKey: "tasks.detailOpenSession",
                                    action: #selector(openSessionTapped)))
            views.append(iconButton("doc.text.magnifyingglass", tooltipKey: "tasks.detailReview",
                                    action: #selector(reviewTapped)))
        }
        if model.canCommentClose {
            views.append(actionButton("tasks.detailCommentClose", #selector(commentCloseTapped)))
        }
        if model.canSkip {
            views.append(actionButton("tasks.detailSkip", #selector(skipTapped)))
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
    private func primaryControl() -> NSView? {
        guard let primaryKey = model.primaryKey else { return nil }   // 没有主操作（见 actionRow）
        guard model.canQueue else {
            return actionButton(primaryKey, #selector(primaryTapped),
                                enabled: model.primaryEnabled,
                                disabledHintKey: model.primaryDisabledHintKey)
        }
        let button = PanelMenuButton(glyph: .symbol("rectangle.stack.badge.plus"),
                                     title: L10n.tr(primaryKey),
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

    /// A text action button. A DISABLED one carries the reason as its tooltip: a
    /// grey button the user cannot explain is worse than a sentence.
    private func actionButton(_ key: String, _ selector: Selector, enabled: Bool = true,
                              disabledHintKey: String? = nil) -> NSButton {
        let button = NSButton(title: L10n.tr(key), target: self, action: selector)
        button.controlSize = .small
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 11)
        button.isEnabled = enabled
        if !enabled, let hint = disabledHintKey { button.toolTip = L10n.tr(hint) }
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
    @objc private func skipTapped() { onSkip?() }
    @objc private func openSessionTapped() { onOpenSession?() }
    @objc private func reviewTapped() { onReview?() }
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
    /// 发布：push 分支 + 开/更新 PR（独立的发布会话）。
    var onOpenPR: (() -> Void)?
    /// 打开已有 PR 的链接（与「发布」分开：PR 已存在时仍要能再次发布以更新它）。
    var onOpenPRLink: (() -> Void)?
    var onSettings: (() -> Void)?
    var onTogglePR: (() -> Void)?
    var onDelete: (() -> Void)?
    /// 关闭队列（手动终态，保留记录）。
    var onClose: (() -> Void)?

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
            trailing.append(iconButton("play.fill", tooltipKey: model.startHintKey,
                                       action: #selector(startTapped)))
        }
        // 打开 PR 排在**最后**（用户 2026-09-27：它是这一行的收尾动作，不是夹在中间的
        // 一枚）。图标与 PR 链接互斥（有链接就说明 PR 已经在了），但都给同一件事留位置，
        // 所以两者都在收尾处追加 —— 见下面 trailing.append(prControl)。
        // 自动开 PR / 队列设置 / 删除队列 were hidden behind a ⋯ menu; they are
        // their own icon buttons now (the audit panel's blocks have no overflow
        // menu either — every action is on the row). The PR toggle keeps its state
        // visible: accent while on, and it disappears entirely in a workspace that
        // cannot carry a PR (unless it is already on, then it says why).
        if model.showsAutoPRToggle {
            let toggle = iconButton(model.autoPR ? "checkmark.circle.fill" : "circle",
                                    tooltipKey: model.autoPREnabled
                                        ? (model.autoPR ? "tasks.queue.autoPROn" : "tasks.queue.autoPROff")
                                        : "tasks.queue.prUnavailable",
                                    action: #selector(togglePRTapped))
            toggle.tintColor = model.autoPR ? .controlAccentColor : nil
            toggle.isEnabled = model.autoPREnabled
            trailing.append(toggle)
        }
        // 已完成不再是「记录」：设置/删除/发布/关闭都还在（见 QueueHeaderModel.canEdit）。
        if model.canEdit {
            trailing.append(iconButton("gearshape", tooltipKey: "tasks.queue.settings",
                                       action: #selector(settingsTapped)))
        }
        if model.canDelete {
            trailing.append(iconButton("trash", tooltipKey: "tasks.queue.delete",
                                       action: #selector(deleteTapped)))
        }
        // 关闭排在发布前，保持「PR 永远在这一行最右」的既有约定。
        if model.canClose {
            trailing.append(iconButton("archivebox", tooltipKey: "tasks.queue.close",
                                       action: #selector(closeTapped)))
        }
        // 发布 / PR 链接 —— 收尾动作，排在这一行最后。
        if let prControl = openPRControl() { trailing.append(prControl) }
        if let link = prLinkControl() { trailing.append(link) }

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

        // 队列名前面一枚行标：这是「一条队列（泳道）」——与任务卡片上的 checklist 成对。
        let glyph = taskRowGlyph("rectangle.stack", accessibility: "tasks.glyph.queue")
        // 队列有来源会话（由会话 / task-todo 创建）时，名字后带一枚 ↺：完成情况会回传
        // 那个会话。信息性标记，不可点，tooltip 说清楚。
        var titleViews: [NSView] = [disclosure, glyph, name]
        if model.reportsToSession { titleViews.append(reportGlyph()) }
        titleViews.append(spacer)
        titleViews.append(actions)
        let titleRow = NSStackView(views: titleViews)
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
            // The last finalize session's outcome (its report's first line, or the
            // failure reason) — on the card, not only in the log.
            if let note = model.integrationNote, !note.isEmpty {
                rows.append(resultRow(note))
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
        for row in rows {
            row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        bar.widthAnchor.constraint(equalToConstant: 72).isActive = true
    }

    /// One line under the meta row: what the last finalize session reported (a
    /// success summary, or why it could not finish). Truncating, with the full text
    /// in the tooltip.
    private func resultRow(_ note: String) -> NSView {
        let label = NSTextField(labelWithString: note)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = note
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    /// A small ↺ after the queue name when its completion reports back to the session
    /// that created it (board.local.queueSessions). Informational, not a control.
    private func reportGlyph() -> NSView {
        let view = NSImageView()
        if let image = NSImage(systemSymbolName: "arrow.uturn.backward",
                               accessibilityDescription: L10n.tr("tasks.queue.reportsToSession")) {
            view.image = image
            view.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
            view.contentTintColor = .secondaryLabelColor
        }
        view.toolTip = L10n.tr("tasks.queue.reportsToSession")
        view.translatesAutoresizingMaskIntoConstraints = false
        view.setContentHuggingPriority(.required, for: .horizontal)
        return view
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

    /// 打开 PR: the icon while the queue has no PR yet (its tooltip carries the reason
    /// when a PR run came back empty), the PR link once it has one. The LAST control of
    /// the row — the queue's publishing step reads as the close of the line, not as one
    /// icon among the settings.
    /// 发布（push + 开/更新 PR）。图标只在队列可发布时出现；已有 PR 时它就是「更新」。
    private func openPRControl() -> NSView? {
        guard model.canOpenPR else { return nil }
        // The mode decides both the icon and the sentence: 开 PR / 合并并推送 / 推送.
        return iconButton(model.integration.publishSymbol,
                          tooltipKey: model.prErrorKey ?? model.integration.publishHintKey,
                          action: #selector(openPRTapped))
    }

    /// The PR link, once a PR exists — kept separate from 发布 so a queue that has
    /// one can still be published again (push the new commits, reuse the PR).
    private func prLinkControl() -> NSView? {
        guard let prUrl = model.prUrl else { return nil }
        let link = NSButton(title: TaskCardModel.shortPR(prUrl), target: self, action: #selector(prLinkTapped))
        link.isBordered = false
        link.controlSize = .small
        link.contentTintColor = .controlAccentColor
        link.font = .systemFont(ofSize: 11)
        link.toolTip = prUrl
        link.translatesAutoresizingMaskIntoConstraints = false
        link.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return link
    }

    @objc private func startTapped() { onStart?() }
    @objc private func pauseTapped() { onPause?() }
    @objc private func openPRTapped() { onOpenPR?() }
    @objc private func prLinkTapped() { onOpenPRLink?() }
    @objc private func closeTapped() { onClose?() }

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
