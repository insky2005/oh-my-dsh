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
/// in the panel's bottom sheet (IssueRunnerPanel's form sheet), and the sheet owns
/// the surface, its accent edge and its shadow. Keeping the form itself
/// transparent means one form can be presented anywhere without a card fighting
/// the surface behind it.
class TaskFormCardView: NSView {
    override var isOpaque: Bool { false }
}

/// Small builders shared by the two forms: captions above fields (the panel's
/// existing formRow convention), fields, the multi-line editor and the footer.
enum TaskFormKit {

    static let captionFont = NSFont.systemFont(ofSize: 11)
    static let fieldFont = NSFont.systemFont(ofSize: 12)
    static let hintFont = NSFont.systemFont(ofSize: 11)

    static func caption() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = captionFont
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

    /// A single-line field.
    static func textField(_ value: String, placeholder: String) -> NSTextField {
        let field = NSTextField(string: value)
        field.placeholderString = placeholder
        field.font = fieldFont
        field.controlSize = .regular
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        field.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return field
    }

    /// The multi-line description editor: an NSTextView in a scroll view — the
    /// same shape the old modal used, sized by the caller.
    static func textView(_ value: String, height: CGFloat) -> (scroll: NSScrollView, text: NSTextView) {
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: height))
        text.isEditable = true
        text.isRichText = false
        text.font = fieldFont
        text.string = value
        text.drawsBackground = false
        text.backgroundColor = PanelSurface.dynamic
        text.textContainerInset = NSSize(width: 4, height: 6)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView()
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
        return (scroll, text)
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
    private let bodyScroll: NSScrollView
    let bodyView: NSTextView
    let hint: NSTextField
    let submitButton: NSButton
    let closeActionButton: NSButton

    init(model: TaskComposerModel) {
        self.model = model
        titleField = TaskFormKit.textField(model.title, placeholder: "")
        let body = TaskFormKit.textView(model.body, height: 108)
        bodyScroll = body.scroll
        bodyView = body.text
        hint = TaskFormKit.hintLabel()
        submitButton = TaskFormKit.button("", primary: true)
        closeActionButton = TaskFormKit.button("", primary: false)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        titleField.delegate = self
        bodyView.delegate = self
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
        submitButton.title = L10n.tr(model.submitKey)
        closeActionButton.title = L10n.tr(model.mode.isCreate ? "tasks.new.done" : "btn.cancel")
        closeButton.toolTip = L10n.tr("tasks.new.done")
        submitButton.isEnabled = model.canSubmit
        TaskFormKit.setHint(hint, key: model.problemKey)
    }

    private func build() {
        info.font = TaskFormKit.captionFont
        info.textColor = .secondaryLabelColor
        info.translatesAutoresizingMaskIntoConstraints = false
        closeButton.onAction = { [weak self] in self?.onCancel?() }
        submitButton.target = self
        submitButton.action = #selector(submitTapped)
        closeActionButton.target = self
        closeActionButton.action = #selector(cancelTapped)

        let column = NSStackView(views: [TaskFormKit.headingRow(title: heading, close: closeButton),
                                         info,
                                         TaskFormKit.row(titleCaption, titleField),
                                         TaskFormKit.row(bodyCaption, bodyScroll),
                                         hint,
                                         TaskFormKit.buttonRow([submitButton, closeActionButton])])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            column.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            column.arrangedSubviews[0].widthAnchor.constraint(equalTo: column.widthAnchor),
            info.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])
    }

    private var currentDraft: TaskComposerModel {
        model.typed(title: titleField.stringValue, body: bodyView.string)
    }

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

    func textDidChange(_ notification: Notification) { apply(currentDraft) }

    /// In the description a plain Enter stays a newline (the text IS the prompt
    /// handed to the agent); only Esc closes the composer from there.
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
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
    let branchField: NSTextField
    let baseField: NSTextField
    let branchHint: NSTextField
    let prSwitch: NSButton
    let hint: NSTextField
    let submitButton: NSButton
    let cancelButton: NSButton

    init(model: QueueComposerModel) {
        self.model = model
        nameField = TaskFormKit.textField(model.name, placeholder: "")
        branchField = TaskFormKit.textField(model.branch, placeholder: "")
        baseField = TaskFormKit.textField(model.baseBranch, placeholder: "main")
        branchHint = TaskFormKit.hintLabel(.secondaryLabelColor)
        prSwitch = NSButton(checkboxWithTitle: "", target: nil, action: nil)
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
        branchField.placeholderString = L10n.tr("tasks.queue.branchHint")
        baseField.placeholderString = L10n.tr("tasks.queue.baseHint")
        branchHint.stringValue = L10n.tr("tasks.queue.branchWillUse", model.effectiveBranchHint)
        branchHint.isHidden = false
        prSwitch.title = L10n.tr("tasks.queue.createPR")
        prSwitch.state = model.autoPR ? .on : .off
        prSwitch.isEnabled = model.prAvailable
        prSwitch.toolTip = model.prAvailable ? "" : L10n.tr("tasks.queue.prUnavailable")
        submitButton.title = L10n.tr(model.submitKey)
        submitButton.isEnabled = model.canSubmit
        cancelButton.title = L10n.tr("btn.cancel")
        closeButton.toolTip = L10n.tr("btn.cancel")
        TaskFormKit.setHint(hint, key: model.problemKey)
    }

    private func build() {
        info.font = TaskFormKit.captionFont
        info.textColor = .secondaryLabelColor
        info.translatesAutoresizingMaskIntoConstraints = false
        branchHint.font = TaskFormKit.captionFont
        branchHint.textColor = .tertiaryLabelColor
        prSwitch.font = .systemFont(ofSize: 12)
        prSwitch.translatesAutoresizingMaskIntoConstraints = false
        closeButton.onAction = { [weak self] in self?.onCancel?() }
        submitButton.target = self
        submitButton.action = #selector(submitTapped)
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)

        let column = NSStackView(views: [TaskFormKit.headingRow(title: heading, close: closeButton),
                                         info,
                                         TaskFormKit.row(nameCaption, nameField),
                                         TaskFormKit.row(branchCaption, branchField),
                                         branchHint,
                                         TaskFormKit.row(baseCaption, baseField),
                                         prSwitch,
                                         hint,
                                         TaskFormKit.buttonRow([submitButton, cancelButton])])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            column.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            column.arrangedSubviews[0].widthAnchor.constraint(equalTo: column.widthAnchor),
            info.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])
    }

    private var currentDraft: QueueComposerModel {
        model.typed(name: nameField.stringValue,
                    branch: branchField.stringValue,
                    baseBranch: baseField.stringValue,
                    autoPR: prSwitch.state == .on)
    }

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
/// list: creating a task is a deliberate act that deserves room, the sheet spans
/// the whole panel (so the fields are as wide as the panel, not as wide as a
/// card), and it can be pulled up and dismissed without the list reflowing under
/// the pointer.
///
/// Raised fill + radius 10 + an accent top edge (the "a form is open" signal) —
/// the same tokens the rest of the shell uses, no new greys.
final class TaskFormSheetView: NSView {

    override var isOpaque: Bool { false }

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
/// It is transparent AND click-through: a plain NSView would swallow every click
/// aimed at the list behind it (hitTest returns the view itself), so a hit that
/// lands on the host rather than on the sheet is passed on.
final class TaskFormSheetHostView: NSView {

    /// Where the sheet rests: this far above the host's bottom edge, which
    /// leaves the status bar (26pt) and its message visible.
    static let restingBottom: CGFloat = 34

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}
