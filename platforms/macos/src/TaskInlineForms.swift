//
//  TaskInlineForms.swift — the two INLINE forms of the tasks panel.
//
//  新建任务 / 编辑任务 and 新建队列 / 队列设置 used to be NSAlert modals: they
//  covered the list, they could not be moved, and every value was lost when they
//  closed. Both are now ordinary cards inside the panel — same widgets, same
//  colors, same scroll view as the task cards — anchored where the action came
//  from (the list top for a new task, the card being edited, the queue header
//  being configured).
//
//  The views own the text fields and forward three events; every rule about what
//  a form says and when it may be submitted lives in TasksUI.swift
//  (TaskComposerModel / QueueComposerModel) and is asserted headlessly.
//

import AppKit

/// Base class of the two forms. It draws NOTHING on purpose: a form is presented
/// in the panel's form sheet (IssueRunnerPanel), and the sheet owns the surface,
/// its accent edge and its scroll view. Keeping the form itself transparent means
/// one form can be presented anywhere without a card fighting the surface behind
/// it.
class TaskFormCardView: NSView {
    override var isOpaque: Bool { false }
}

/// The input chrome shared by every field of a form: a rounded, recessed box.
///
/// Both inputs draw inside the SAME box — the single-line one is a bezel-less
/// NSTextField, the description is a real NSTextView — so they cannot drift apart.
/// The system's rounded bezel looked nothing like a multi-line editor, and an
/// editable NSTextField turned out to be single-line whatever its height (its cell
/// reports one line for any bounds, so a taller field was just a taller box).
final class TaskFieldBox: NSView {

    override var isOpaque: Bool { false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        // One step below the sheet's raised surface: an input well.
        PanelControl.fill(dark: dark, highlighted: true).setFill()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        path.fill()
        (dark ? NSColor(calibratedWhite: 0.4, alpha: 0.9) : NSColor(calibratedWhite: 0.8, alpha: 1)).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

/// Small builders shared by the two forms: captions above fields (the panel's
/// existing formRow convention), fields, the multi-line editor and the footer.
enum TaskFormKit {

    static let captionFont = NSFont.systemFont(ofSize: 11)
    static let fieldFont = NSFont.systemFont(ofSize: 13)
    static let hintFont = NSFont.systemFont(ofSize: 11)
    /// Roomier than a stock field: the form is the panel's main input surface.
    static let fieldHeight: CGFloat = 30
    static let editorHeight: CGFloat = 120
    static let editorMaxHeight: CGFloat = 260
    /// Never smaller than a few lines: the sheet scrolls rather than shrinking
    /// the description down to a couple of lines.
    static let editorMinHeight: CGFloat = 88
    /// Padding inside a field box (left/right for text, top/bottom for the box).
    static let textInset: CGFloat = 9

    static func caption() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    /// A caption above its control, both stretched to the column width.
    static func row(_ caption: NSTextField, _ control: NSView, spacing: CGFloat = 4) -> NSStackView {
        control.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: [caption, control])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        control.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    /// A single-line field in its box.
    static func textField(_ value: String, placeholder: String) -> (box: TaskFieldBox, field: NSTextField) {
        let box = TaskFieldBox()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.heightAnchor.constraint(equalToConstant: fieldHeight).isActive = true
        let field = NSTextField(string: value)
        field.placeholderString = placeholder
        field.font = fieldFont
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: textInset),
            field.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -textInset),
            field.centerYAnchor.constraint(equalTo: box.centerYAnchor),
        ])
        return (box, field)
    }

    /// The description editor: a real multi-line NSTextView in the same box, with
    /// the box growing with the text (the sheet around it scrolls when the panel
    /// is short).
    static func textArea(_ value: String) -> (box: TaskFieldBox, text: NSTextView,
                                              placeholder: NSTextField,
                                              boxHeight: NSLayoutConstraint,
                                              textHeight: NSLayoutConstraint) {
        let box = TaskFieldBox()
        box.translatesAutoresizingMaskIntoConstraints = false
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: editorHeight))
        text.isEditable = true
        text.isRichText = false
        text.font = fieldFont
        text.string = value
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 4, height: 6)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.minSize = NSSize(width: 0, height: 0)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                              height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView()
        scroll.documentView = text
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(scroll)
        // A text view has no placeholder of its own; this label sits on top of the
        // (empty) editor and the composer hides it as soon as there is text.
        let placeholder = NSTextField(labelWithString: "")
        placeholder.font = fieldFont
        placeholder.textColor = .placeholderTextColor
        placeholder.lineBreakMode = .byTruncatingTail
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: textInset),
            placeholder.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor,
                                                  constant: -textInset),
            placeholder.topAnchor.constraint(equalTo: box.topAnchor, constant: 7),
            scroll.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -4),
            scroll.topAnchor.constraint(equalTo: box.topAnchor, constant: 4),
            scroll.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -4),
        ])
        // The box is as tall as the text (within bounds); the sheet's own height
        // cap is the only thing allowed to shrink it, and then the text scrolls.
        let boxHeight = box.heightAnchor.constraint(equalToConstant: editorHeight)
        boxHeight.priority = NSLayoutConstraint.Priority(999)
        boxHeight.isActive = true
        box.heightAnchor.constraint(greaterThanOrEqualToConstant: editorMinHeight).isActive = true
        // The document view must WRAP at the visible width and be at least as tall
        // as it: an auto-sizing document view used to stay one line tall (only that
        // line was clickable) or 300pt too wide (long lines were clipped, not
        // wrapped).
        text.translatesAutoresizingMaskIntoConstraints = false
        let textHeight = text.heightAnchor.constraint(greaterThanOrEqualToConstant: editorHeight)
        textHeight.isActive = true
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            text.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            text.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        ])
        return (box, text, placeholder, boxHeight, textHeight)
    }

    /// How tall the text needs to be at this width, so the editor can grow with
    /// what is typed into it.
    static func textHeight(_ text: String, width: CGFloat) -> CGFloat {
        let usable = max(40, width - 16)   // the box's own padding
        guard !text.isEmpty else { return editorMinHeight }
        let rect = (text as NSString).boundingRect(
            with: NSSize(width: usable, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: fieldFont])
        return ceil(rect.height) + 18
    }

    /// The footer's buttons: the primary action first, then the way out. The
    /// primary carries the accent bezel so an open form has one obvious target.
    /// Target/action are wired by the form after construction.
    static func button(_ title: String, primary: Bool) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.font = .systemFont(ofSize: 12)
        button.translatesAutoresizingMaskIntoConstraints = false
        if primary { button.bezelColor = .controlAccentColor }
        return button
    }

    /// A small flat button (the 高级设置 toggle): no bezel, accent ink.
    /// Target/action are wired by the form after construction.
    static func linkButton(_ title: String) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        button.isBordered = false
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11, weight: .medium)
        button.contentTintColor = .controlAccentColor
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }

    /// The inline problem line: hidden while the form is fine, so the card never
    /// reserves space for a message nobody sees.
    static func hintLabel(_ color: NSColor = .systemRed) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = hintFont
        label.textColor = color
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 3
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isHidden = true
        return label
    }

    static func setHint(_ label: NSTextField, key: String?) {
        label.isHidden = key == nil
        label.stringValue = key.map { L10n.tr($0) } ?? ""
    }

    /// The heading row of a form card: title, optional info line and the close
    /// button, all on one line with the close pinned right.
    static func headingRow(title: NSTextField, close: NSView) -> NSStackView {
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let row = NSStackView(views: [title, spacer, close])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    static func buttonRow(_ buttons: [NSButton]) -> NSStackView {
        let row = NSStackView(views: buttons)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    /// Stretch a form's rows to the form's own width.
    ///
    /// A vertical NSStackView with .leading alignment sizes every arranged view to
    /// its FITTING width, so a caption+field row would hug whichever of the two is
    /// wider — and an EMPTY text field's intrinsic width is almost nothing, so the
    /// field collapsed to the caption's width (measured: ~25pt wide, placeholder
    /// clipped to a single character). Every row that is not a hugging control row
    /// (the button row) must therefore be pinned to the column.
    static func stretch(_ rows: [NSView], to column: NSStackView) {
        for row in rows {
            row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
    }
}

// MARK: - 新建任务 / 编辑任务

/// The inline task composer: title, description, 创建 / 完成 (or 保存 / 取消).
final class TaskComposerView: TaskFormCardView, NSTextFieldDelegate, NSTextViewDelegate {

    private(set) var model: TaskComposerModel

    /// Submit the (valid) draft.
    var onSubmit: ((TaskComposerModel) -> Void)?
    /// Close without submitting.
    var onCancel: (() -> Void)?

    private let heading = NSTextField(labelWithString: "")
    private let info = NSTextField(wrappingLabelWithString: "")
    private let titleCaption = TaskFormKit.caption()
    private let bodyCaption = TaskFormKit.caption()
    private let closeButton = CustomIconButton(glyph: .close, tooltip: "", size: 22)
    // Internal (not private) so the headless form tests can type into the fields
    // and read the button/hint state the user sees — the same convention the
    // project cards use for their workspace.
    let titleField: NSTextField
    let titleBox: TaskFieldBox
    /// The description editor (a real multi-line text view in the same kind of box
    /// as the title field).
    let bodyText: NSTextView
    let bodyBox: TaskFieldBox
    let bodyPlaceholder: NSTextField
    private var bodyBoxHeight: NSLayoutConstraint!
    private var bodyTextHeight: NSLayoutConstraint!
    let hint: NSTextField
    let submitButton: NSButton
    let closeActionButton: NSButton

    init(model: TaskComposerModel) {
        self.model = model
        let title = TaskFormKit.textField(model.title, placeholder: "")
        titleBox = title.box
        titleField = title.field
        let body = TaskFormKit.textArea(model.body)
        bodyBox = body.box
        bodyText = body.text
        bodyPlaceholder = body.placeholder
        bodyBoxHeight = body.boxHeight
        bodyTextHeight = body.textHeight
        hint = TaskFormKit.hintLabel()
        submitButton = TaskFormKit.button("", primary: true)
        closeActionButton = TaskFormKit.button("", primary: false)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        titleField.delegate = self
        bodyText.delegate = self
        build()
        apply(model)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Focus the first field once the card is on screen.
    func focusTitle() {
        window?.makeFirstResponder(titleField)
    }

    /// Push a model into the (already built) views: labels, texts, values and
    /// the hint. Also drives the live submit-button state while typing.
    func apply(_ model: TaskComposerModel) {
        self.model = model
        heading.stringValue = L10n.tr(model.headingKey)
        info.stringValue = L10n.tr(model.infoKey)
        titleCaption.stringValue = L10n.tr("tasks.new.name")
        bodyCaption.stringValue = L10n.tr("tasks.new.body")
        titleField.placeholderString = L10n.tr("tasks.new.nameHint")
        bodyPlaceholder.stringValue = L10n.tr("tasks.new.bodyHint")
        bodyPlaceholder.isHidden = !bodyText.string.isEmpty
        submitButton.title = L10n.tr(model.submitKey)
        closeActionButton.title = L10n.tr(model.mode.isCreate ? "tasks.new.done" : "btn.cancel")
        closeButton.toolTip = L10n.tr("tasks.new.done")
        submitButton.isEnabled = model.canSubmit
        TaskFormKit.setHint(hint, key: model.problemKey)
    }

    private func build() {
        info.font = TaskFormKit.captionFont
        info.textColor = .secondaryLabelColor
        // Two lines at most: the form's height must stay predictable so the
        // sheet (and the buttons inside it) always fit a short panel.
        info.maximumNumberOfLines = 2
        info.lineBreakMode = .byTruncatingTail
        info.translatesAutoresizingMaskIntoConstraints = false
        closeButton.onAction = { [weak self] in self?.onCancel?() }
        submitButton.target = self
        submitButton.action = #selector(submitTapped)
        closeActionButton.target = self
        closeActionButton.action = #selector(cancelTapped)

        let headingRow = TaskFormKit.headingRow(title: heading, close: closeButton)
        let titleRow = TaskFormKit.row(titleCaption, titleBox)
        let bodyRow = TaskFormKit.row(bodyCaption, bodyBox)
        let buttons = TaskFormKit.buttonRow([submitButton, closeActionButton])
        let column = NSStackView(views: [headingRow, info, titleRow, bodyRow, hint, buttons])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        // Everything but the button row spans the form: the fields are as wide as
        // the sheet, not as wide as their caption.
        TaskFormKit.stretch([headingRow, info, titleRow, bodyRow, hint], to: column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            column.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
        ])
    }

    private var currentDraft: TaskComposerModel {
        model.typed(title: titleField.stringValue, body: bodyText.string)
    }

    /// The editor grows with what is typed.
    ///
    /// The BOX grows so the text is always visible while it fits the sheet; the
    /// text view inside grows with it, and past the maximum box height it scrolls
    /// under the caret instead.
    private func updateBodyHeight() {
        let width = bodyBox.bounds.width
        guard width > 1 else { return }
        let needed = TaskFormKit.textHeight(bodyText.string, width: width)
        let box = min(TaskFormKit.editorMaxHeight, max(TaskFormKit.editorMinHeight, needed))
        // Only touch the constraints when something actually changed: this runs on
        // every layout pass (the panel re-measures the sheet).
        if abs(bodyBoxHeight.constant - box) > 0.5 { bodyBoxHeight.constant = box }
        let text = max(box - 8, needed)
        if abs(bodyTextHeight.constant - text) > 0.5 { bodyTextHeight.constant = text }
    }

    /// Called once the field has its real width: edit mode then shows the whole
    /// description instead of the first line of it.
    func layoutBody() { updateBodyHeight() }

    /// The submit button's action; internal so the headless tests can press it.
    @objc func submitTapped() {
        let typed = currentDraft
        guard typed.canSubmit else {
            // An incomplete draft cannot be submitted: the disabled button
            // already says so, and Enter now explains WHICH field is missing.
            apply(typed.attemptedSubmit())
            return
        }
        onSubmit?(typed)
    }

    @objc private func cancelTapped() { onCancel?() }

    // MARK: NSTextFieldDelegate / NSTextViewDelegate

    func controlTextDidChange(_ obj: Notification) { apply(currentDraft) }

    // MARK: NSTextViewDelegate (the description)

    func textDidChange(_ notification: Notification) {
        updateBodyHeight()
        apply(currentDraft)
    }

    func textDidBeginEditing(_ notification: Notification) { apply(currentDraft) }
    func textDidEndEditing(_ notification: Notification) { apply(currentDraft) }

    /// In the description a plain Enter stays a newline (the text IS the prompt
    /// handed to the agent); Esc closes the form.
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            onCancel?()
            return true
        }
        return false
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        // Enter submits from the TITLE field; in the description it stays a
        // newline (the text IS the prompt handed to the agent) — Esc closes.
        if commandSelector == #selector(NSResponder.insertNewline(_:)), control === titleField {
            submitTapped()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            onCancel?()
            return true
        }
        return false
    }
}

// MARK: - 新建队列 / 队列设置

/// The inline queue form: 队列名 / 分支 / 基于分支 / 完成后创建 PR.
final class QueueComposerView: TaskFormCardView, NSTextFieldDelegate {

    private(set) var model: QueueComposerModel

    var onSubmit: ((QueueComposerModel) -> Void)?
    var onCancel: (() -> Void)?

    private let heading = NSTextField(labelWithString: "")
    private let info = NSTextField(wrappingLabelWithString: "")
    private let nameCaption = TaskFormKit.caption()
    private let branchCaption = TaskFormKit.caption()
    private let baseCaption = TaskFormKit.caption()
    private let closeButton = CustomIconButton(glyph: .close, tooltip: "", size: 22)
    // Internal for the headless form tests (see TaskComposerView).
    let nameField: NSTextField
    let nameBox: TaskFieldBox
    let branchField: NSTextField
    let branchBox: TaskFieldBox
    let baseField: NSTextField
    let baseBox: TaskFieldBox
    let branchHint: NSTextField
    let prSwitch: NSButton
    let prNote: NSTextField
    let advancedButton: NSButton
    /// The 高级设置 section (分支 / 基于分支 / PR): hidden while creating, open
    /// while editing. Internal so the tests can assert the default.
    let advancedStack: NSStackView
    let hint: NSTextField
    let submitButton: NSButton
    let cancelButton: NSButton

    init(model: QueueComposerModel) {
        self.model = model
        let name = TaskFormKit.textField(model.name, placeholder: "")
        nameBox = name.box
        nameField = name.field
        let branch = TaskFormKit.textField(model.branch, placeholder: "")
        branchBox = branch.box
        branchField = branch.field
        let base = TaskFormKit.textField(model.baseBranch, placeholder: "main")
        baseBox = base.box
        baseField = base.field
        branchHint = TaskFormKit.hintLabel(.secondaryLabelColor)
        prSwitch = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        prNote = TaskFormKit.hintLabel(.secondaryLabelColor)
        advancedButton = TaskFormKit.linkButton("")
        advancedStack = NSStackView()
        hint = TaskFormKit.hintLabel()
        submitButton = TaskFormKit.button("", primary: true)
        cancelButton = TaskFormKit.button("", primary: false)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        for field in [nameField, branchField, baseField] { field.delegate = self }
        build()
        apply(model)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func focusName() {
        window?.makeFirstResponder(nameField)
    }

    func apply(_ model: QueueComposerModel) {
        self.model = model
        heading.stringValue = L10n.tr(model.headingKey)
        info.stringValue = L10n.tr(model.infoKey)
        nameCaption.stringValue = L10n.tr("tasks.queue.name")
        branchCaption.stringValue = L10n.tr("tasks.queue.branch")
        baseCaption.stringValue = L10n.tr("tasks.queue.base")
        nameField.placeholderString = L10n.tr("tasks.queue.nameHint")
        branchField.placeholderString = model.branchPlaceholder
        baseField.placeholderString = L10n.tr("tasks.queue.baseHint")
        branchHint.stringValue = L10n.tr("tasks.queue.branchWillUse", model.effectiveBranchHint)
        advancedButton.title = L10n.tr("tasks.queue.advanced") + (model.showsAdvanced ? "  ▴" : "  ▾")
        advancedStack.isHidden = !model.showsAdvanced
        // A PR switch that cannot be switched is worse than a sentence: the
        // workspace simply has no PR to open.
        prSwitch.title = L10n.tr("tasks.queue.createPR")
        prSwitch.state = model.autoPR ? .on : .off
        prSwitch.isHidden = !model.prAvailable
        prSwitch.isEnabled = model.prAvailable
        prNote.stringValue = L10n.tr("tasks.queue.prUnavailable")
        prNote.isHidden = model.prAvailable
        submitButton.title = L10n.tr(model.submitKey)
        submitButton.isEnabled = model.canSubmit
        cancelButton.title = L10n.tr("btn.cancel")
        closeButton.toolTip = L10n.tr("btn.cancel")
        TaskFormKit.setHint(hint, key: model.problemKey)
    }

    private func build() {
        info.font = TaskFormKit.captionFont
        info.textColor = .secondaryLabelColor
        info.maximumNumberOfLines = 2
        info.lineBreakMode = .byTruncatingTail
        info.translatesAutoresizingMaskIntoConstraints = false
        branchHint.font = TaskFormKit.captionFont
        branchHint.textColor = .tertiaryLabelColor
        prSwitch.font = .systemFont(ofSize: 12)
        prSwitch.translatesAutoresizingMaskIntoConstraints = false
        closeButton.onAction = { [weak self] in self?.onCancel?() }
        advancedButton.target = self
        advancedButton.action = #selector(advancedTapped)
        submitButton.target = self
        submitButton.action = #selector(submitTapped)
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)

        let headingRow = TaskFormKit.headingRow(title: heading, close: closeButton)
        let nameRow = TaskFormKit.row(nameCaption, nameBox)
        let branchRow = TaskFormKit.row(branchCaption, branchBox)
        let baseRow = TaskFormKit.row(baseCaption, baseBox)

        // The branch this queue will use, and the way into the fields that can
        // change it — one line, so creating a queue asks for a name and nothing
        // else unless the user opens the advanced section.
        let hintSpacer = NSView()
        hintSpacer.translatesAutoresizingMaskIntoConstraints = false
        hintSpacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let hintRow = NSStackView(views: [branchHint, hintSpacer, advancedButton])
        hintRow.orientation = .horizontal
        hintRow.alignment = .centerY
        hintRow.spacing = 6
        hintRow.translatesAutoresizingMaskIntoConstraints = false

        advancedStack.orientation = .vertical
        advancedStack.alignment = .leading
        advancedStack.spacing = 8
        advancedStack.translatesAutoresizingMaskIntoConstraints = false
        for view in [branchRow, baseRow, prSwitch, prNote] { advancedStack.addArrangedSubview(view) }
        TaskFormKit.stretch([branchRow, baseRow, prNote], to: advancedStack)

        let buttons = TaskFormKit.buttonRow([submitButton, cancelButton])
        let column = NSStackView(views: [headingRow, info, nameRow, hintRow, advancedStack, hint, buttons])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        TaskFormKit.stretch([headingRow, info, nameRow, hintRow, advancedStack], to: column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            column.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
        ])
    }

    private var currentDraft: QueueComposerModel {
        model.typed(name: nameField.stringValue,
                    branch: branchField.stringValue,
                    baseBranch: baseField.stringValue,
                    autoPR: prSwitch.state == .on)
    }

    @objc private func advancedTapped() { apply(model.togglingAdvanced()) }

    /// The submit button's action; internal so the headless tests can press it.
    @objc func submitTapped() {
        let typed = currentDraft
        guard typed.canSubmit else {
            apply(typed.attemptedSubmit())
            return
        }
        onSubmit?(typed)
    }

    @objc private func cancelTapped() { onCancel?() }

    func controlTextDidChange(_ obj: Notification) { apply(currentDraft) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            submitTapped()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            onCancel?()
            return true
        }
        return false
    }
}
// MARK: - Form sheet (the surface a form slides up in)

/// The panel's bottom sheet. A form is presented HERE rather than inline in the
/// The panel's form sheet. A form is presented HERE rather than inline in the
/// list: creating a task is a deliberate act that deserves room, the sheet spans
/// the whole panel (so the fields are as wide as the panel, not as wide as a
/// card), and it can be dropped in and dismissed without the list reflowing
/// under the pointer.
///
/// The form inside SCROLLS when it is taller than the space the panel leaves:
/// a form that shrank itself to fit used to squeeze the description editor down
/// to a couple of lines, which is not something a text area should do.
///
/// Raised fill + radius 10 + an accent top edge (the "a form is open" signal) —
/// the same tokens the rest of the shell uses, no new greys.
final class TaskFormSheetView: NSView {

    /// A flipped holder so the form starts at the TOP of the scroll view.
    private final class DocHolder: NSView {
        override var isFlipped: Bool { true }
    }

    private let scroll = NSScrollView()
    private let docHolder = DocHolder()

    /// The form currently installed (nil when the sheet was emptied).
    var content: NSView? { docHolder.subviews.first }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.translatesAutoresizingMaskIntoConstraints = false
        docHolder.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = docHolder
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            docHolder.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            docHolder.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            docHolder.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isOpaque: Bool { false }

    /// The height the form WANTS right now.
    ///
    /// The sheet is sized from this measurement rather than by a constraint to the
    /// document view: AppKit keeps a document view at least as tall as the clip
    /// view, so chaining the sheet to the document view made the sheet
    /// unshrinkable and the panel's height cap was silently dropped (measured: a
    /// 304pt form inside a 240pt content area). The document view is pinned to the
    /// form's height instead, which leaves the form free to be its natural size
    /// while the sheet around it gets capped — and then it scrolls.
    func idealHeight() -> CGFloat {
        guard let content = content else { return 0 }
        content.layoutSubtreeIfNeeded()
        return content.frame.height
    }

    /// Install a form (replacing whatever was there).
    func setContent(_ view: NSView) {
        for subview in docHolder.subviews { subview.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        docHolder.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: docHolder.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: docHolder.trailingAnchor),
            view.topAnchor.constraint(equalTo: docHolder.topAnchor),
            // The document view follows the form's OWN height (not the other way
            // round): that is what lets the sheet be capped and scroll.
            docHolder.heightAnchor.constraint(equalTo: view.heightAnchor),
        ])
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        PanelControl.fill(dark: dark, highlighted: false).setFill()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        path.fill()
        (dark ? NSColor(calibratedWhite: 0.42, alpha: 0.9) : NSColor(calibratedWhite: 0.78, alpha: 1)).setStroke()
        path.lineWidth = 1
        path.stroke()
        // The accent edge across the top: this surface is an open form.
        NSColor.controlAccentColor.withAlphaComponent(dark ? 0.75 : 0.65).setFill()
        NSBezierPath(roundedRect: NSRect(x: bounds.minX + 1, y: bounds.maxY - 4,
                                         width: bounds.width - 2, height: 3),
                     xRadius: 1.5, yRadius: 1.5).fill()
    }
}

/// The clipping host the form sheet slides inside.
///
/// AppKit does not clip a subview to its superview's bounds, so a sheet that
/// starts BELOW the panel would paint over the neighbouring split pane while it
/// animates. This host is transparent, layer-backed and masksToBounds, so the
/// sheet is only ever visible inside the panel's content area.
///
/// With no form open the host is transparent AND click-through: a plain NSView
/// would swallow every click aimed at the list behind it (hitTest returns the view
/// itself), so a hit that lands on the host rather than on the sheet is passed on.
///
/// With a form open the host behaves like a sheet instead and nothing reaches the
/// list behind it: clicking a task card (or the list background) through an open
/// form is startling — the form is what you are working in.
final class TaskFormSheetHostView: NSView {

    /// Where the sheet rests: this far below the TOP of the content area. The
    /// sheet drops down from there, over the list — the bottom of the panel keeps
    /// the status bar and the form's own buttons stay inside the sheet.
    static let restingTop: CGFloat = 8

    /// Fired after every layout: the sheet's height follows its form, which
    /// depends on the width the form was given.
    var onLayout: (() -> Void)?

    /// True while a form is on screen.
    var blocksClicksBelow = false

    override func layout() {
        super.layout()
        onLayout?()
    }

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // A point inside the host but not on one of its controls (the form's own
        // surroundings) is what this decides about.
        // (No superview only happens in the headless tests, where the point already
        // arrives in this view's own coordinates.)
        let local = superview.map { convert(point, from: $0) } ?? point
        guard bounds.contains(local) else { return super.hitTest(point) }
        if let hit = super.hitTest(point), hit !== self { return hit }
        // No form open: hand the click back to the list behind. Form open: swallow
        // it, so a task card cannot react through the drawer.
        return blocksClicksBelow ? self : nil
    }

    /// A click that landed on the host itself (the area around the form) never
    /// reaches the list behind.
    override func mouseDown(with event: NSEvent) {}
}
