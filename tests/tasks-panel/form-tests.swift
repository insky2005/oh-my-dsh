import AppKit
import Foundation

// Headless tests for the task panel's VIEWS: the two inline forms (新建任务 /
// 新建队列 and their edit modes) and the card / queue-header renderers.
//
// The forms exist so the panel never raises a modal dialog, so these checks are
// about exactly that contract: the fields are real text fields, the submit
// button follows what is in them, an incomplete draft explains itself instead of
// silently failing, and submitting hands the panel a validated model. Layout is
// asserted too — a card that does not fill the list width was a real bug.
//
// No window, no dsh server: only the models and the views.

_ = NSApplication.shared

var checks = 0
var failures = 0

func check(_ condition: Bool, _ label: String) {
    checks += 1
    if !condition { failures += 1; print("  FAIL \(label)") }
}

func eq<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    checks += 1
    if actual != expected {
        failures += 1
        print("  FAIL \(label): got \(actual), want \(expected)")
    }
}

func section(_ name: String) { print("--- \(name) ---") }

/// Lay a view out at the panel's list width and report the size it settled on.
func layout(_ view: NSView, width: CGFloat) -> NSSize {
    let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 900))
    view.translatesAutoresizingMaskIntoConstraints = false
    host.addSubview(view)
    NSLayoutConstraint.activate([
        view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
        view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        view.topAnchor.constraint(equalTo: host.topAnchor),
    ])
    host.layoutSubtreeIfNeeded()
    return view.frame.size
}

/// What a text field's delegate receives while the user types.
func typed(_ field: NSTextField) -> Notification {
    Notification(name: NSControl.textDidChangeNotification, object: field)
}

// MARK: - 新建任务 / 编辑任务

section("inline 新建任务 form")
do {
    var submitted: TaskComposerModel?
    var cancelled = false
    let form = TaskComposerView(model: TaskComposerModel.build(mode: .create))
    form.onSubmit = { submitted = $0 }
    form.onCancel = { cancelled = true }

    let size = layout(form, width: 320)
    eq(size.width, 320, "the form fills the list width")
    check(size.height > 140, "the form carries two fields and a button row")
    eq(form.submitButton.title, "create", "the primary button creates")
    check(!form.submitButton.isEnabled, "an empty form cannot be submitted")
    check(form.hint.isHidden, "and shows no problem yet")

    // A title alone is not enough: the description IS the prompt.
    form.titleField.stringValue = "Polish README"
    form.controlTextDidChange(typed(form.titleField))
    check(!form.submitButton.isEnabled, "a title without a description is not submittable")
    check(form.hint.isHidden, "and the form does not nag while it is being typed into")

    form.bodyView.string = "tidy it up"
    form.textDidChange(Notification(name: NSText.didChangeNotification, object: form.bodyView))
    check(form.submitButton.isEnabled, "both fields filled enables 创建")

    form.submitTapped()
    eq(submitted?.draft.normalizedTitle, "Polish README", "submitting hands over the typed title")
    eq(submitted?.draft.normalizedBody, "tidy it up", "and the typed description")
    eq(submitted?.mode, .create, "in create mode")
    check(!cancelled, "submitting does not close the form (完成 / Esc does)")

    // Enter on an incomplete draft explains what is missing.
    let empty = TaskComposerView(model: TaskComposerModel.build(mode: .create))
    empty.submitTapped()
    check(!empty.hint.isHidden, "an attempted submit shows the problem")
    eq(empty.hint.stringValue, "errName", "and names the title field")
}

section("inline 编辑任务 form")
do {
    let task = TaskItem.manual(title: "Old title", body: "old body", id: "manual-0030aaaa")
    var submitted: TaskComposerModel?
    let form = TaskComposerView(model: TaskComposerModel.edit(task))
    form.onSubmit = { submitted = $0 }
    _ = layout(form, width: 320)

    eq(form.titleField.stringValue, "Old title", "the title is prefilled")
    eq(form.bodyView.string, "old body", "the description is prefilled")
    eq(form.submitButton.title, "save", "编辑 saves")
    eq(form.closeActionButton.title, "cancel", "编辑 can be cancelled")
    check(form.submitButton.isEnabled, "a prefilled form can be saved")

    form.titleField.stringValue = "New title"
    form.controlTextDidChange(typed(form.titleField))
    form.submitTapped()
    eq(submitted?.mode, .edit(taskID: "manual-0030aaaa"), "saving keeps the task id")
    eq(submitted?.draft.normalizedTitle, "New title", "and carries the edited title")
}

// MARK: - 新建队列 / 队列设置

section("inline 新建队列 form")
do {
    var submitted: QueueComposerModel?
    let form = QueueComposerView(model: QueueComposerModel.create(taskID: "manual-0031aaaa"))
    form.onSubmit = { submitted = $0 }

    let size = layout(form, width: 320)
    eq(size.width, 320, "the form fills the list width")
    check(size.height > 180, "three labelled fields, the branch hint and the button row")
    eq(form.submitButton.title, "create", "creating from a card joins that task")
    check(!form.submitButton.isEnabled, "a nameless queue cannot be created")
    check(!form.prSwitch.isEnabled, "the PR switch is dead without a GitHub repo")
    eq(form.branchHint.stringValue, "branchWillUse(branchHint)",
       "with no name there is no derived branch to promise")

    form.nameField.stringValue = "Dark Mode"
    form.controlTextDidChange(typed(form.nameField))
    check(form.submitButton.isEnabled, "a named queue can be created")
    eq(form.branchHint.stringValue, "branchWillUse(feature/dark-mode)",
       "the derived branch follows the name as it is typed")

    form.prSwitch.state = .on
    form.submitTapped()
    eq(submitted?.normalizedName, "Dark Mode", "the typed name is submitted")
    eq(submitted?.mode.taskID, "manual-0031aaaa", "the task waiting for a queue comes along")
    eq(submitted?.branchValue, nil, "an empty branch asks for the derived default")
    eq(submitted?.autoPR, true, "and the PR switch is carried")
}

section("inline 队列设置 form")
do {
    var queue = TaskQueue(id: "q-3333", name: "Lane", branch: "feature/lane", baseBranch: "main")
    queue.autoPR = true
    var submitted: QueueComposerModel?
    let form = QueueComposerView(model: QueueComposerModel.edit(queue, prAvailable: true))
    form.onSubmit = { submitted = $0 }
    _ = layout(form, width: 320)

    eq(form.submitButton.title, "save", "settings save")
    eq(form.nameField.stringValue, "Lane", "the name is prefilled")
    eq(form.branchField.stringValue, "feature/lane", "the branch is prefilled")
    eq(form.baseField.stringValue, "main", "the base branch is prefilled")
    eq(form.prSwitch.state, .on, "the PR switch reflects the queue")
    check(form.prSwitch.isEnabled, "and stays live in a GitHub workspace")

    // Clearing the branch means "run on whatever is checked out".
    form.branchField.stringValue = ""
    form.controlTextDidChange(typed(form.branchField))
    eq(form.branchHint.stringValue, "branchWillUse(noBranch)",
       "an empty branch says it will not switch branches")
    form.submitTapped()
    eq(submitted?.mode.queueID, "q-3333", "the edited queue is identified")
    eq(submitted?.branchValue, nil, "and the cleared branch is submitted as no branch")
    eq(submitted?.normalizedBaseBranch, "main", "the base branch survives")
}

// MARK: - Cards

section("card and queue header layout")
do {
    var board = TaskBoard()
    let task = TaskItem.manual(title: "A fairly long task title that has to wrap in a narrow panel",
                               body: "the description an agent receives", id: "manual-0032aaaa")
    board.tasks = [task]
    let queue = board.createQueue(name: "A queue with a long name")
    _ = board.enqueue(taskID: task.id, into: queue.id)

    let card = TaskCardView(model: TaskCardModel.build(task, board: board, expanded: true, githubRepo: false))
    let cardSize = layout(card, width: 320)
    eq(cardSize.width, 320, "the card fills the list width")
    check(cardSize.height > 80, "an expanded card fits its detail and its buttons")

    let collapsedCard = TaskCardView(model: TaskCardModel.build(task, board: board, expanded: false, githubRepo: false))
    let collapsedSize = layout(collapsedCard, width: 320)
    check(collapsedSize.height < cardSize.height, "a collapsed card is the compact one")

    let expandedHeader = TaskQueueHeaderView(model: QueueHeaderModel.build(board.queue(queue.id)!, board: board,
                                                                          collapsed: false))
    let headerSize = layout(expandedHeader, width: 320)
    eq(headerSize.width, 320, "the queue header fills the list width")
    check(headerSize.height > 40, "an expanded header carries the branch and the progress bar")

    let collapsedHeader = TaskQueueHeaderView(model: QueueHeaderModel.build(board.queue(queue.id)!, board: board,
                                                                           collapsed: true))
    let oneLiner = layout(collapsedHeader, width: 320)
    check(oneLiner.height < headerSize.height, "a collapsed queue header is one line")
}

section("fields span the whole form")
do {
    // An EMPTY NSTextField's intrinsic width is almost nothing, and a .leading
    // vertical stack hugs its widest arranged view — so a caption+field row used
    // to collapse to the caption's width (measured on screen: ~25pt wide, the
    // placeholder clipped to one character). The rows must be pinned to the form.
    let taskForm = TaskComposerView(model: TaskComposerModel.build(mode: .create))
    _ = layout(taskForm, width: 360)
    let titleWidth = taskForm.titleField.frame.width
    check(titleWidth > 300, "the title field spans the form (got \(titleWidth)pt)")
    // The editor is the form's other input surface, and it must WRAP at the same
    // width: an autoresizing document view used to keep a width 318pt wider than
    // the clip view, so long lines were clipped instead of wrapped.
    let bodyWidth = taskForm.bodyView.frame.width
    check(bodyWidth > 280, "the description editor spans the form (got \(bodyWidth)pt)")
    check(abs(bodyWidth - titleWidth) < 12,
          "the editor wraps at the fields' width (editor \(bodyWidth), field \(titleWidth))")

    let queueForm = QueueComposerView(model: QueueComposerModel.create())
    _ = layout(queueForm, width: 360)
    for (name, field) in [("name", queueForm.nameField), ("branch", queueForm.branchField),
                          ("base", queueForm.baseField)] {
        check(field.frame.width > 300, "the \(name) field spans the form (got \(field.frame.width)pt)")
    }

    // Widening the panel widens the fields with it.
    let wide = TaskComposerView(model: TaskComposerModel.build(mode: .create))
    _ = layout(wide, width: 520)
    check(wide.titleField.frame.width > titleWidth, "a wider panel gives wider fields")
}

section("a form fits a short panel")
do {
    // The sheet caps its height to the content area, so the form must be able to
    // GIVE WAY (the description editor shrinks and scrolls) instead of pushing
    // its own buttons out of sight — the reported symptom of the bottom-anchored
    // sheet on a short panel.
    func fits(_ height: CGFloat, _ label: String) {
        let form = TaskComposerView(model: TaskComposerModel.build(mode: .create))
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: height))
        form.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(form)
        NSLayoutConstraint.activate([
            form.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            form.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            form.topAnchor.constraint(equalTo: host.topAnchor),
            form.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        host.layoutSubtreeIfNeeded()
        let button = form.submitButton.convert(form.submitButton.bounds, to: host)
        check(host.bounds.contains(button), "the 创建 button stays inside a \(Int(height))pt panel: \(label)")
        let field = form.titleField.convert(form.titleField.bounds, to: host)
        check(field.height >= 24, "the title field keeps a usable height in a \(Int(height))pt panel")
    }
    fits(420, "a roomy panel")
    fits(300, "a tight panel")
    fits(260, "a very short panel")
}

// MARK: - Section header

section("section header + progress bar")
do {
    let header = TaskSectionHeaderView(text: "queues (2)")
    let size = layout(header, width: 320)
    eq(size.width, 320, "the section header fills the list width")
    check(size.height > 20, "and keeps its caption line")

    let bar = TaskProgressBarView()
    bar.fraction = 0.5
    bar.tone = .positive
    let barSize = layout(bar, width: 72)
    check(barSize.height > 0, "the progress bar has a visible thickness")
}

section("queue block containment")
do {
    var board = TaskBoard()
    let t1 = TaskItem.manual(title: "One", body: "b1", id: "manual-0040aaaa")
    let t2 = TaskItem.manual(title: "Two", body: "b2", id: "manual-0041bbbb")
    board.tasks = [t1, t2]
    let queue = board.createQueue(name: "Lane")
    _ = board.enqueue(taskID: t1.id, into: queue.id)
    _ = board.enqueue(taskID: t2.id, into: queue.id)

    func block(collapsed: Bool) -> TaskQueueBlockView {
        let model = QueueHeaderModel.build(board.queue(queue.id)!, board: board, collapsed: collapsed)
        let header = TaskQueueHeaderView(model: model)
        let cards = collapsed ? [] : [t1, t2].map {
            TaskCardView(model: TaskCardModel.build($0, board: board, expanded: false, githubRepo: false))
        }
        return TaskQueueBlockView(header: header, cards: cards, collapsed: collapsed)
    }

    let open = block(collapsed: false)
    let openSize = layout(open, width: 320)
    eq(openSize.width, 320, "the queue block fills the list width")
    check(openSize.height > 150, "an open lane holds its header AND its cards")
    // Every card sits strictly inside the lane — that is the containment the
    // user asked for (queue and tasks were two parallel stacks before).
    let headers = open.subviews.compactMap { $0 as? TaskQueueHeaderView }
    eq(headers.count, 1, "the lane carries one queue header")
    let headerInset = headers[0].frame.minX
    let cards = open.subviews.flatMap { $0.subviews }.compactMap { $0 as? TaskCardView }
    eq(cards.count, 2, "both tasks are laid out inside the lane")
    for card in cards {
        let frame = card.convert(card.bounds, to: open)
        check(frame.minX > headerInset, "a card is indented past the lane header, not level with it")
        check(frame.maxX < open.bounds.width, "and never spills out of the lane")
    }

    let closed = block(collapsed: true)
    let closedSize = layout(closed, width: 320)
    eq(closedSize.width, 320, "a collapsed lane still fills the list width")
    check(closedSize.height < openSize.height, "and collapses to its header line")
}

if failures == 0 {
    print("ok - \(checks) checks passed")
} else {
    print("FAILED - \(failures) of \(checks) checks failed")
    exit(1)
}
