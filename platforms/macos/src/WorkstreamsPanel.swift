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
    var onOpen: (() -> Void)?
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
        headerViews.append(spacer)
        if !stage.queueIDs.isEmpty {
            headerViews.append(WSTierBadgeView(text: stage.queueIDs.joined(separator: ", "), tone: .neutral))
        }
        let headerRow = NSStackView(views: headerViews)
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 6

        var bodyRows: [NSView] = []
        for line in stage.evidence { bodyRows.append(detailLine(line)) }
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

        var body: NSView? = nil
        if !task.detail.isEmpty {
            let detail = NSTextField(wrappingLabelWithString: task.detail)
            detail.font = .systemFont(ofSize: 11)
            detail.textColor = .secondaryLabelColor
            body = detail
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
        WSInk.hairline(dark: dark).setStroke()
        path.lineWidth = 1
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
    /// QA hook (--ui-debug): fires after each render.
    var onDidRender: (() -> Void)?

    static let minWidth: CGFloat = 320

    let view = WSBoardRootView()

    /// What the last load produced.
    private(set) var snapshot = WorkstreamsSnapshot(workspace: "", dshExists: false,
                                                    workstreams: [], unparsed: [])
    /// The active top stage view.
    private(set) var selectedFilter: WSStageFilter = .all
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

    // MARK: Public entry points

    func refreshTooltips() {
        updateLabels()
        render()
    }

    func ensureLoaded() { reload() }

    /// The active workspace changed (main.swift adoptProjectDirectory).
    func workspaceChanged() { reload() }

    func selectFilter(_ filter: WSStageFilter) {
        selectedFilter = filter
        updateLabels()
        render()
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
        if workspace.isEmpty {
            snapshot = WorkstreamsSnapshot(workspace: "", dshExists: false, workstreams: [], unparsed: [])
        } else {
            snapshot = WorkstreamsCore.load(workspace: workspace)
        }
        render()
    }

    private func render() {
        board = WSBoardModel.build(snapshot: snapshot, filter: selectedFilter)
        for sub in list.arrangedSubviews { sub.removeFromSuperview() }
        for model in board.cards {
            let card = WSPrimaryCardView(model: model)
            card.onOpen = { [weak self] in self?.onOpenCard?(model.path) }
            list.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -20).isActive = true
        }
        countLabel.stringValue = L10n.tr("workstreams.count", board.totalCount)
        let empty = board.emptyState
        emptyLabel.stringValue = empty.map { L10n.tr($0.messageKey) } ?? ""
        emptyView.isHidden = empty == nil
        scroll.isHidden = board.cards.isEmpty
        onDidRender?()
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
