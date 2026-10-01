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

    /// Fired when the form's own height changes. Kept for callers that want to know;
    /// the sheet does NOT need it any more — it follows the form's height with a
    /// constraint, so growing happens in the same layout pass.
    var onHeightChanged: (() -> Void)?

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
    /// The task composer's box is the form's ONLY input: give it room.
    static let editorHeight: CGFloat = 160
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
        _ = requiredHeight(label)
        return label
    }

    /// A form never squashes its own contents: its height is what the sheet follows.
    /// Without this, a panel too short for the form compressed a label (text got
    /// clipped) instead of letting the sheet cap itself and scroll.
    static func requiredHeight(_ view: NSView) -> NSView {
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        return view
    }

    /// A caption BESIDE its control (the 高级设置 section): three stacked
    /// caption-above-field rows made the expanded queue form taller than a short
    /// panel's content area, so it scrolled — and a form that scrolls for three
    /// short fields is a form that should have been shorter.
    static func inlineRow(_ caption: NSTextField, _ control: NSView) -> NSStackView {
        control.translatesAutoresizingMaskIntoConstraints = false
        caption.setContentHuggingPriority(.required, for: .horizontal)
        caption.setContentCompressionResistancePriority(.required, for: .horizontal)
        caption.widthAnchor.constraint(equalToConstant: 62).isActive = true
        let stack = NSStackView(views: [caption, control])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        _ = requiredHeight(stack)
        return stack
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
        _ = requiredHeight(stack)
        return stack
    }

    /// A single-line field in its box.
    static func textField(_ value: String, placeholder: String) -> (box: TaskFieldBox, field: NSTextField) {
        let box = TaskFieldBox()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.heightAnchor.constraint(equalToConstant: fieldHeight).isActive = true
        _ = requiredHeight(box)
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
        _ = requiredHeight(box)
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
        _ = requiredHeight(label)
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
        _ = requiredHeight(row)
        return row
    }

    static func buttonRow(_ buttons: [NSButton]) -> NSStackView {
        let row = NSStackView(views: buttons)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        _ = requiredHeight(row)
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

/// The inline task composer: ONE box whose first line is the task's title and
/// whose remaining lines are its description (a single line is both), plus
/// 创建 / 完成 (or 保存 / 取消).
final class TaskComposerView: TaskFormCardView, NSTextViewDelegate {

    private(set) var model: TaskComposerModel

    /// Submit the (valid) draft.
    var onSubmit: ((TaskComposerModel) -> Void)?
    /// Close without submitting.
    var onCancel: (() -> Void)?

    private let heading = NSTextField(labelWithString: "")
    private let info = NSTextField(wrappingLabelWithString: "")
    private let contentCaption = TaskFormKit.caption()
    private let closeButton = CustomIconButton(glyph: .close, tooltip: "", size: 22)
    // Internal (not private) so the headless form tests can type into the box and
    // read the button/hint state the user sees — the same convention the project
    // cards use for their workspace.
    /// The one input surface: a real multi-line text view in a TaskFieldBox.
    let editor: NSTextView
    let editorBox: TaskFieldBox
    let editorPlaceholder: NSTextField
    private var editorBoxHeight: NSLayoutConstraint!
    private var editorTextHeight: NSLayoutConstraint!
    let hint: NSTextField
    let submitButton: NSButton
    let closeActionButton: NSButton

    init(model: TaskComposerModel) {
        self.model = model
        let content = TaskFormKit.textArea(model.content)
        editorBox = content.box
        editor = content.text
        editorPlaceholder = content.placeholder
        editorBoxHeight = content.boxHeight
        editorTextHeight = content.textHeight
        hint = TaskFormKit.hintLabel()
        submitButton = TaskFormKit.button("", primary: true)
        closeActionButton = TaskFormKit.button("", primary: false)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        editor.delegate = self
        build()
        apply(model)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Put the caret in the box once the card is on screen.
    func focusEditor() {
        window?.makeFirstResponder(editor)
    }

    /// Push a model into the (already built) views: labels, texts, values and
    /// the hint. Also drives the live submit-button state while typing.
    func apply(_ model: TaskComposerModel) {
        self.model = model
        heading.stringValue = L10n.tr(model.headingKey)
        info.stringValue = L10n.tr(model.infoKey)
        contentCaption.stringValue = L10n.tr("tasks.new.content")
        editorPlaceholder.stringValue = L10n.tr("tasks.new.contentHint")
        editorPlaceholder.isHidden = !editor.string.isEmpty
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
        _ = TaskFormKit.requiredHeight(info)
        closeButton.onAction = { [weak self] in self?.onCancel?() }
        submitButton.target = self
        submitButton.action = #selector(submitTapped)
        closeActionButton.target = self
        closeActionButton.action = #selector(cancelTapped)

        let headingRow = TaskFormKit.headingRow(title: heading, close: closeButton)
        let contentRow = TaskFormKit.row(contentCaption, editorBox)
        let buttons = TaskFormKit.buttonRow([submitButton, closeActionButton])
        let column = NSStackView(views: [headingRow, info, contentRow, hint, buttons])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false
        // The form's height is what the sheet follows: nothing inside may squash it.
        _ = TaskFormKit.requiredHeight(column)
        addSubview(column)
        // Everything but the button row spans the form: the fields are as wide as
        // the sheet, not as wide as their caption.
        TaskFormKit.stretch([headingRow, info, contentRow, hint], to: column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            column.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
        ])
    }

    private var currentDraft: TaskComposerModel {
        model.typed(content: editor.string)
    }

    /// The editor grows with what is typed.
    ///
    /// The BOX grows so the text is always visible while it fits the sheet; the
    /// text view inside grows with it, and past the maximum box height it scrolls
    /// under the caret instead.
    private func updateEditorHeight() {
        let width = editorBox.bounds.width
        guard width > 1 else { return }
        let needed = TaskFormKit.textHeight(editor.string, width: width)
        // The box never SHRINKS below its comfortable default (the one box IS the
        // task composer) — it only grows with the text, up to the maximum.
        let box = min(TaskFormKit.editorMaxHeight, max(TaskFormKit.editorHeight, needed))
        // Only touch the constraints when something actually changed: this runs on
        // every layout pass (the panel re-measures the sheet).
        if abs(editorBoxHeight.constant - box) > 0.5 { editorBoxHeight.constant = box }
        let text = max(box - 8, needed)
        if abs(editorTextHeight.constant - text) > 0.5 { editorTextHeight.constant = text }
    }

    /// Called once the box has its real width: edit mode then shows the whole task
    /// instead of the first line of it.
    func layoutEditor() { updateEditorHeight() }

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

    // MARK: NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        updateEditorHeight()
        apply(currentDraft)
    }

    func textDidBeginEditing(_ notification: Notification) { apply(currentDraft) }
    func textDidEndEditing(_ notification: Notification) { apply(currentDraft) }

    /// A plain Enter stays a NEWLINE — the lines are the task (first one = title,
    /// the rest = description), so they cannot also mean "submit". ⌘↩ submits and
    /// Esc closes; the form says so in its info line.
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
    /// 不切分支 — explicit, so creating a queue in a directory that is not a git
    /// repository (and any user who simply wants the agent to work in place) can
    /// say so instead of relying on 「留空」 meaning two different things.
    let skipBranchSwitch: NSButton
    let prSwitch: NSButton
    let prNote: NSTextField
    /// 工作流 picker: 跟随设置 (default) + the three modes, the recommended one
    /// marked. Internal for the headless form tests.
    let integrationCaption = TaskFormKit.caption()
    let integrationPopup = NSPopUpButton(frame: .zero, pullsDown: false)
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
        skipBranchSwitch = NSButton(checkboxWithTitle: "", target: nil, action: nil)
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
        // The workspace's own default branch, not a hard-coded "main".
        baseField.placeholderString = model.defaultBaseBranch
        // 不切分支 takes the two branch fields out of play — nothing to type while
        // the queue deliberately leaves git alone.
        skipBranchSwitch.title = L10n.tr("tasks.queue.skipBranch")
        skipBranchSwitch.state = model.skipsBranch ? .on : .off
        // Where there is no repository there is no choice to make: the switch
        // stays on and dead, with the reason written next to it.
        skipBranchSwitch.isEnabled = model.gitAvailable
        branchField.isEnabled = !model.skipsBranch
        branchBox.alphaValue = model.skipsBranch ? 0.45 : 1
        baseField.isEnabled = !model.skipsBranch
        baseBox.alphaValue = model.skipsBranch ? 0.45 : 1
        // A workspace without git gets the reason instead of a promise the
        // runner cannot keep (this WAS the whole of the errNotGit bug: a form
        // that happily derived feature/<slug> for a directory with no repo).
        if !model.gitAvailable {
            branchHint.stringValue = L10n.tr("tasks.queue.notGitRepo")
        } else if model.skipsBranch {
            branchHint.stringValue = L10n.tr("tasks.queue.branchSkipped")
        } else {
            branchHint.stringValue = L10n.tr("tasks.queue.branchWillUse", model.effectiveBranchHint)
        }
        advancedButton.title = L10n.tr("tasks.queue.advanced") + (model.showsAdvanced ? "  ▴" : "  ▾")
        advancedStack.isHidden = !model.showsAdvanced
        // A PR switch that cannot be switched is worse than a sentence: the
        // workspace simply has no PR to open.
        integrationCaption.stringValue = L10n.tr("tasks.integration.label")
        let choices = model.integrationChoices
        // The recommendation rides ON the item it recommends — a separate note row
        // cost the expanded form height it does not have (see inlineRow).
        let recommended = model.recommendedIntegration
        let mark = L10n.tr("tasks.integration.recommendedSuffix")
        integrationPopup.removeAllItems()
        for choice in choices {
            if let choice = choice {
                integrationPopup.addItem(withTitle: choice.label
                    + (choice == recommended ? mark : ""))
            } else {
                integrationPopup.addItem(withTitle:
                    L10n.tr("tasks.integration.follow", model.defaultIntegration.label)
                    + (model.defaultIntegration == recommended ? mark : ""))
            }
        }
        let selected = choices.firstIndex(of: model.integration) ?? 0
        integrationPopup.selectItem(at: selected)
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
        _ = TaskFormKit.requiredHeight(info)
        branchHint.font = TaskFormKit.captionFont
        branchHint.textColor = .tertiaryLabelColor
        _ = TaskFormKit.requiredHeight(branchHint)
        _ = TaskFormKit.requiredHeight(prNote)
        for toggle in [skipBranchSwitch, prSwitch] {
            toggle.font = .systemFont(ofSize: 12)
            toggle.translatesAutoresizingMaskIntoConstraints = false
        }
        integrationPopup.font = .systemFont(ofSize: 12)
        integrationPopup.controlSize = .small
        integrationPopup.translatesAutoresizingMaskIntoConstraints = false
        integrationPopup.target = self
        integrationPopup.action = #selector(integrationChanged)
        skipBranchSwitch.target = self
        skipBranchSwitch.action = #selector(skipBranchTapped)
        closeButton.onAction = { [weak self] in self?.onCancel?() }
        advancedButton.target = self
        advancedButton.action = #selector(advancedTapped)
        submitButton.target = self
        submitButton.action = #selector(submitTapped)
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)

        let headingRow = TaskFormKit.headingRow(title: heading, close: closeButton)
        let nameRow = TaskFormKit.row(nameCaption, nameBox)
        let branchRow = TaskFormKit.inlineRow(branchCaption, branchBox)
        let baseRow = TaskFormKit.inlineRow(baseCaption, baseBox)

        // The branch this queue will use, and the way into the fields that can
        // change it — one line, so creating a queue asks for a name and nothing
        // else unless the user opens the advanced section.
        let hintSpacer = NSView()
        hintSpacer.translatesAutoresizingMaskIntoConstraints = false
        hintSpacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        // 不切分支 sits on the hint line, next to the branch it is about and next
        // to the way into the fields that set it: a policy switch, not a field,
        // and one more stacked row would push the expanded form past the height
        // a panel content area can show without scrolling.
        let hintRow = NSStackView(views: [branchHint, hintSpacer, skipBranchSwitch, advancedButton])
        hintRow.orientation = .horizontal
        hintRow.alignment = .centerY
        hintRow.spacing = 6
        hintRow.translatesAutoresizingMaskIntoConstraints = false
        _ = TaskFormKit.requiredHeight(hintRow)

        advancedStack.orientation = .vertical
        advancedStack.alignment = .leading
        // 3pt: the integration picker added a fourth row to 高级设置, and the whole
        // point of this section is that the expanded form does NOT need a scrollbar.
        advancedStack.spacing = 3
        advancedStack.translatesAutoresizingMaskIntoConstraints = false
        _ = TaskFormKit.requiredHeight(advancedStack)
        // 工作流 sits caption-BESIDE-picker, with the recommendation on the same
        // line: a fourth stacked row would push the expanded form past a short
        // panel's content area (the very mistake inlineRow was introduced to fix).
        integrationCaption.setContentHuggingPriority(.required, for: .horizontal)
        integrationCaption.setContentCompressionResistancePriority(.required, for: .horizontal)
        integrationCaption.widthAnchor.constraint(equalToConstant: 62).isActive = true
        integrationPopup.setContentHuggingPriority(.required, for: .horizontal)
        let integrationSpacer = NSView()
        integrationSpacer.translatesAutoresizingMaskIntoConstraints = false
        integrationSpacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let integrationRow = NSStackView(views: [integrationCaption, integrationPopup,
                                                 integrationSpacer])
        integrationRow.orientation = .horizontal
        integrationRow.alignment = .centerY
        integrationRow.spacing = 8
        integrationRow.translatesAutoresizingMaskIntoConstraints = false
        _ = TaskFormKit.requiredHeight(integrationRow)
        // 自动收尾 switch + its 不可用 note on ONE line: the note already said what
        // the integration picker now says for a non-GitHub workspace, so a whole
        // stacked row for it cost height the expanded form does not have.
        prNote.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        prNote.lineBreakMode = .byTruncatingTail
        let prSpacer = NSView()
        prSpacer.translatesAutoresizingMaskIntoConstraints = false
        prSpacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let prRow = NSStackView(views: [prSwitch, prNote, prSpacer])
        prRow.orientation = .horizontal
        prRow.alignment = .centerY
        prRow.spacing = 8
        prRow.translatesAutoresizingMaskIntoConstraints = false
        _ = TaskFormKit.requiredHeight(prRow)
        for view in [branchRow, baseRow, integrationRow, prRow] {
            advancedStack.addArrangedSubview(view)
        }
        TaskFormKit.stretch([branchRow, baseRow, integrationRow, prRow], to: advancedStack)

        let buttons = TaskFormKit.buttonRow([submitButton, cancelButton])
        let column = NSStackView(views: [headingRow, info, nameRow, hintRow, advancedStack, hint, buttons])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false
        // The form's height is what the sheet follows: nothing inside may squash it.
        _ = TaskFormKit.requiredHeight(column)
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
                    autoPR: prSwitch.state == .on,
                    skippingBranch: skipBranchSwitch.state == .on)
            .typedIntegration(selectedIntegration)
    }

    /// The picker's current choice (nil = 跟随设置). Internal for the form tests.
    var selectedIntegration: QueueIntegration? {
        let choices = model.integrationChoices
        let index = integrationPopup.indexOfSelectedItem
        return (index >= 0 && index < choices.count) ? choices[index] : nil
    }

    /// The 工作流 picker changed: re-apply so the model (and submit) sees it.
    @objc func integrationChanged() { apply(currentDraft) }

    /// 不切分支 toggled: the fields follow it, and the hint stops promising a
    /// branch (the queue will not touch git at all). Internal so the headless
    /// form tests can flip it.
    @objc func skipBranchTapped() {
        apply(currentDraft)
    }

    @objc private func advancedTapped() {
        // Hiding / showing the section changes the form's height, and the sheet
        // follows that height by constraint — one layout pass, nothing to notify.
        apply(model.togglingAdvanced())
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

// MARK: - Tasks settings (token + 工作流)

/// The tasks panel's settings — the two things it can configure.
/// 决策（2026-10-01）：工作流默认是**按工作区**的，与 GitHub token 合并进同一个抽屉
/// （不是两个入口）。需要「全局一份」的话，那属于壳层设置，不属于这个面板。
///
///   1. GitHub token（按仓库文件 / 通用兜底，只写文件、chmod 600）
///   2. 本工作区的工作流默认值（队列没有自己的覆盖时用它收尾）
///
/// Pure, so the form tests can drive it headlessly (like QueueComposerModel).
struct TaskSettingsModel: Equatable {
    var token: String
    var defaultIntegration: QueueIntegration
    /// This workspace's suggestion — shown, never enforced.
    var recommendedIntegration: QueueIntegration
    /// Whether the workspace can open a PR at all (a GitHub remote).
    var prAvailable: Bool
}

/// 面板设置 — a DRAWER (the same formSheet as 新建任务 / 新建队列), NOT a modal
/// alert: one surface for the token and the 工作流 default. The user asked for a
/// drawer explicitly (2026-10-01): an NSAlert next to an inline form is two idioms
/// for the same act.
final class TaskSettingsView: TaskFormCardView, NSTextFieldDelegate {

    private(set) var model: TaskSettingsModel
    var onSubmit: ((TaskSettingsModel) -> Void)?
    var onCancel: (() -> Void)?

    private let heading = NSTextField(labelWithString: "")
    private let info = NSTextField(wrappingLabelWithString: "")
    private let tokenCaption = TaskFormKit.caption()
    private let tokenHint = NSTextField(wrappingLabelWithString: "")
    private let closeButton = CustomIconButton(glyph: .close, tooltip: "", size: 22)
    // Internal for the headless form tests (see TaskComposerView).
    let tokenField: NSTextField
    let tokenBox: TaskFieldBox
    let integrationCaption = TaskFormKit.caption()
    /// One RADIO per workflow — the user asked for a radio group, not a dropdown:
    /// there are only three, and seeing all of them (with the recommendation
    /// marked) is the point of a settings default.
    let integrationRadios: [NSButton]
    let integrationNote = TaskFormKit.hintLabel(.secondaryLabelColor)
    let submitButton: NSButton
    let cancelButton: NSButton

    init(model: TaskSettingsModel) {
        self.model = model
        let token = TaskFormKit.textField(model.token, placeholder: "")
        tokenBox = token.box
        tokenField = token.field
        submitButton = TaskFormKit.button("", primary: true)
        cancelButton = TaskFormKit.button("", primary: false)
        integrationRadios = QueueIntegration.allCases.map { _ in
            NSButton(radioButtonWithTitle: "", target: nil, action: nil)
        }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        tokenField.delegate = self
        build()
        apply(model)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func focusToken() { window?.makeFirstResponder(tokenField) }

    func apply(_ model: TaskSettingsModel) {
        self.model = model
        heading.stringValue = L10n.tr("tasks.settings.title")
        info.stringValue = L10n.tr("tasks.settings.info")
        tokenCaption.stringValue = L10n.tr("tasks.configTitle")
        tokenField.placeholderString = L10n.tr("tasks.tokenPlaceholder")
        tokenHint.stringValue = L10n.tr("tasks.configInfo")
        integrationCaption.stringValue = L10n.tr("tasks.integration.defaultLabel")
        // The recommendation is marked on the radio itself; the 首次设置 preselection
        // happens in configTapped (nothing stored yet → the recommended one).
        for (index, mode) in QueueIntegration.allCases.enumerated() {
            let radio = integrationRadios[index]
            radio.title = mode.label + (mode == model.recommendedIntegration
                                        ? L10n.tr("tasks.integration.recommendedSuffix") : "")
            radio.state = (mode == model.defaultIntegration) ? .on : .off
        }
        // hintLabel starts hidden (it is a VALIDATION hint elsewhere); this one is
        // always-visible information, so it is shown explicitly.
        integrationNote.stringValue = L10n.tr("tasks.integration.recommend",
                                              model.recommendedIntegration.label)
        integrationNote.isHidden = false
        submitButton.title = L10n.tr("tasks.new.save")
        submitButton.isEnabled = true
        cancelButton.title = L10n.tr("btn.cancel")
        closeButton.toolTip = L10n.tr("btn.cancel")
    }

    private func build() {
        // The drawer shares the panel's form sheet with 新建任务 / 新建队列, so it
        // must fit the same short content area: both long explanations are capped
        // at two lines and truncated (full text in the tooltip) instead of
        // letting the sheet push its own buttons out of view.
        info.font = TaskFormKit.captionFont
        info.textColor = .secondaryLabelColor
        info.maximumNumberOfLines = 2
        info.lineBreakMode = .byTruncatingTail
        info.translatesAutoresizingMaskIntoConstraints = false
        info.toolTip = L10n.tr("tasks.settings.info")
        _ = TaskFormKit.requiredHeight(info)
        tokenHint.font = TaskFormKit.captionFont
        tokenHint.textColor = .tertiaryLabelColor
        tokenHint.maximumNumberOfLines = 2
        tokenHint.lineBreakMode = .byTruncatingTail
        tokenHint.translatesAutoresizingMaskIntoConstraints = false
        tokenHint.toolTip = L10n.tr("tasks.configInfo")
        _ = TaskFormKit.requiredHeight(tokenHint)
        integrationNote.font = TaskFormKit.captionFont
        integrationNote.textColor = .tertiaryLabelColor
        integrationNote.maximumNumberOfLines = 2
        integrationNote.lineBreakMode = .byTruncatingTail
        _ = TaskFormKit.requiredHeight(integrationNote)
        for radio in integrationRadios {
            radio.font = .systemFont(ofSize: 12)
            radio.translatesAutoresizingMaskIntoConstraints = false
            radio.target = self
            radio.action = #selector(integrationChanged)
        }
        closeButton.onAction = { [weak self] in self?.onCancel?() }
        submitButton.target = self
        submitButton.action = #selector(submitTapped)
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)

        let headingRow = TaskFormKit.headingRow(title: heading, close: closeButton)
        let tokenRow = TaskFormKit.row(tokenCaption, tokenBox)
        // 默认工作流: a caption + a radio row + the recommendation, as one block.
        let radioRow = NSStackView(views: integrationRadios)
        radioRow.orientation = .horizontal
        radioRow.alignment = .centerY
        radioRow.spacing = 14
        radioRow.translatesAutoresizingMaskIntoConstraints = false
        _ = TaskFormKit.requiredHeight(radioRow)
        let workflowBlock = NSStackView(views: [integrationCaption, radioRow, integrationNote])
        workflowBlock.orientation = .vertical
        workflowBlock.alignment = .leading
        workflowBlock.spacing = 5
        workflowBlock.translatesAutoresizingMaskIntoConstraints = false
        _ = TaskFormKit.requiredHeight(workflowBlock)
        let buttons = TaskFormKit.buttonRow([submitButton, cancelButton])
        let column = NSStackView(views: [headingRow, info, tokenRow, tokenHint,
                                         workflowBlock, buttons])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false
        _ = TaskFormKit.requiredHeight(column)
        addSubview(column)
        TaskFormKit.stretch([headingRow, info, tokenRow, tokenHint, workflowBlock], to: column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            column.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
        ])
    }

    /// The settings as currently typed.
    /// The workflow radio that is ON (the model's value while none is selected yet).
    /// Internal for the headless form tests.
    var selectedIntegration: QueueIntegration {
        for (index, mode) in QueueIntegration.allCases.enumerated()
        where integrationRadios[index].state == .on {
            return mode
        }
        return model.defaultIntegration
    }

    var currentDraft: TaskSettingsModel {
        TaskSettingsModel(token: tokenField.stringValue,
                          defaultIntegration: selectedIntegration,
                          recommendedIntegration: model.recommendedIntegration,
                          prAvailable: model.prAvailable)
    }

    /// A radio was clicked: AppKit keeps the group exclusive; re-apply so the model
    /// (and submit) sees the choice.
    @objc func integrationChanged() { apply(currentDraft) }

    /// The submit button's action; internal so the headless tests can press it.
    @objc func submitTapped() { onSubmit?(currentDraft) }

    @objc private func cancelTapped() { onCancel?() }

    func controlTextDidChange(_ obj: Notification) {}
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

    /// The sheet follows its form's own height, at .defaultHigh + 1 so the panel's
    /// "no taller than the content area" cap can still win on a short panel (and
    /// the form then scrolls inside).
    ///
    /// This is the whole mechanism: no measurement, no callbacks, no constants to
    /// keep in sync — a form that grows from the inside (高级设置 opening, the
    /// description editor growing) grows the sheet in the SAME layout pass.
    private var followsContent: NSLayoutConstraint?

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

    /// Install a form (replacing whatever was there).
    func setContent(_ view: NSView) {
        for subview in docHolder.subviews { subview.removeFromSuperview() }
        followsContent?.isActive = false
        followsContent = nil
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
        let follows = heightAnchor.constraint(equalTo: view.heightAnchor)
        follows.priority = NSLayoutConstraint.Priority(999)
        follows.isActive = true
        followsContent = follows
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

    /// The frosted layer BETWEEN the open form and the list behind it — the
    /// drawer and the content area are drawn with the same panel fills, so an
    /// open form used to read as one more card in the list.
    ///
    /// `.withinWindow` blurs what is drawn behind it IN THIS WINDOW (no window
    /// transparency needed), and `.hudWindow` keeps a translucent dark tint even
    /// where the blur itself is unavailable — so the list is always pushed back,
    /// blur or not. The panel fades it in and out together with the sheet.
    let scrim = NSVisualEffectView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Added FIRST: the sheet the panel mounts later has to stay on top of it.
        scrim.material = .hudWindow
        scrim.blendingMode = .withinWindow
        scrim.state = .active
        scrim.isHidden = true
        scrim.alphaValue = 0
        scrim.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrim)
        NSLayoutConstraint.activate([
            scrim.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrim.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrim.topAnchor.constraint(equalTo: topAnchor),
            scrim.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Put the frost on screen at alpha 0 — the panel then fades it in inside its
    /// own animation group, so it moves exactly with the drawer.
    func showScrim() {
        scrim.isHidden = false
    }

    /// Take it off screen again (after the fade-out finished).
    func hideScrim() {
        scrim.isHidden = true
        scrim.alphaValue = 0
    }

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
