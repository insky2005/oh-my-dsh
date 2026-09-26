import Foundation

// Headless tests for the task list's view models (TasksUI.swift). The card list
// itself is pure presentation; every rule about WHAT a card says and which
// action it offers is asserted here. L10n is stubbed to echo the key (plus its
// arguments), so assertions read like the label semantics.

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

func board(tasks: [TaskItem], queues: [TaskQueue]) -> TaskBoard {
    var board = TaskBoard()
    board.tasks = tasks
    board.queues = queues
    board.reindexQueueMembership()
    return board
}

// MARK: - Source and state badges

section("card badges")
do {
    let issue = TaskItem.github(number: 12, title: "Fix dark mode", labels: ["bug"])
    let b = board(tasks: [issue], queues: [])
    let card = TaskCardModel.build(issue, board: b, expanded: false, githubRepo: true)
    eq(card.sourceBadge, "tasks.source.github(12)", "a github task shows its issue number")
    eq(card.stateBadge, "tasks.state.pending", "a new github task is pending")
    eq(card.primaryKey, "tasks.detailProcess", "a github task offers 处理")
    check(!card.canQueue, "a github task is not queued from the card")
    eq(card.meta, ["bug"], "labels land in the meta line")
    eq(card.tone, TaskTone.neutral, "pending is neutral")

    let manual = TaskItem.manual(title: "Polish README", body: "tidy it")
    let b2 = board(tasks: [manual], queues: [])
    let manualCard = TaskCardModel.build(manual, board: b2, expanded: false, githubRepo: false)
    eq(manualCard.sourceBadge, "tasks.source.manual", "a manual task is marked as such")
    eq(manualCard.primaryKey, "tasks.queue.add", "a manual task offers 加入队列")
    check(manualCard.canQueue, "the primary action is the queue picker")
}

section("queue position and running state")
do {
    var board = TaskBoard()
    let t1 = TaskItem.manual(title: "One", id: "manual-0001aaaa")
    let t2 = TaskItem.manual(title: "Two", id: "manual-0002bbbb")
    board.tasks = [t1, t2]
    let queue = board.createQueue(name: "Lane", autoPR: true)
    _ = board.enqueue(taskID: t1.id, into: queue.id)
    _ = board.enqueue(taskID: t2.id, into: queue.id)
    board.markRunning(t1.id)

    let running = TaskCardModel.build(board.task(t1.id)!, board: board, expanded: true, githubRepo: false)
    eq(running.stateBadge, "tasks.state.running", "the running card says so")
    eq(running.tone, TaskTone.running, "running has its own tone")
    eq(running.primaryKey, "tasks.detailCancelTask", "a running task offers 取消")
    check(running.canCancel, "cancel is offered")
    check(running.isExpanded, "the expanded flag is carried through")
    check(running.meta.contains("feature/lane"), "the queue's branch shows in the meta line")
    check(running.detail.contains("tasks.detailQueue"), "the queue name is in the details")

    check(running.isNested, "a card inside a queue draws on the recessed level")
    let unqueued = TaskCardModel.build(TaskItem.manual(title: "Loose", id: "manual-0063aaaa"),
                                       board: board, expanded: false, githubRepo: false)
    check(!unqueued.isNested, "a 未入队 card stands on the panel, so it keeps the raised level")

    let waiting = TaskCardModel.build(board.task(t2.id)!, board: board, expanded: false, githubRepo: false)
    eq(waiting.stateBadge, "tasks.card.queuedAt(2)", "a waiting card shows its position")
    eq(waiting.queuePosition, 2, "the position is exposed for assertions")
    eq(waiting.primaryKey, "tasks.queue.remove", "a waiting task offers 移出队列")
    check(waiting.canDequeue, "移出队列 is offered")
}

section("done, failed and closed cards")
do {
    var board = TaskBoard()
    let done = TaskItem.github(number: 7, title: "Done one", labels: [])
    board.tasks = [done]
    let queue = TaskQueue.auto(for: done)
    board.queues = [queue]
    // The task joins its auto queue the way the runner does it: the queue no
    // longer pre-loads the id (that double-add drew the same card twice).
    _ = board.enqueue(taskID: done.id, into: queue.id)
    board.markRunning(done.id)
    board.markDone(done.id, prUrl: "https://github.com/o/r/pull/42")

    let card = TaskCardModel.build(board.task(done.id)!, board: board, expanded: true, githubRepo: true)
    eq(card.stateBadge, "tasks.state.done", "a finished task is done")
    eq(card.tone, TaskTone.positive, "done is positive")
    eq(card.primaryKey, "tasks.detailOpenPR", "a finished task offers the PR")
    check(card.primaryEnabled, "the PR button is live when there is a PR")
    check(card.canCommentClose, "a github task with a PR can be commented & closed")
    check(card.meta.contains("tasks.detailPR(o/r#42)"), "the PR is shortened in the meta line")
    check(!card.canEdit, "a github task is never edited from the card")
    check(!card.canDelete, "a github task is never deleted")

    let noRepo = TaskCardModel.build(board.task(done.id)!, board: board, expanded: true, githubRepo: false)
    check(!noRepo.canCommentClose, "no GitHub repo means no comment & close")

    var failedBoard = board
    if let i = failedBoard.index(ofTask: done.id) { failedBoard.tasks[i].state = .failed; failedBoard.tasks[i].prUrl = nil }
    let failed = TaskCardModel.build(failedBoard.task(done.id)!, board: failedBoard, expanded: true, githubRepo: true)
    eq(failed.tone, TaskTone.negative, "failed is negative")
    eq(failed.primaryKey, "tasks.detailRetry", "a failed task offers 重试")
    check(failed.canRetry, "retry is offered")
    check(!failed.primaryEnabled == false, "the retry button is enabled")
}

section("manual task editing")
do {
    var board = TaskBoard()
    let manual = TaskItem.manual(title: "Mine", id: "manual-0003cccc")
    board.tasks = [manual]
    let card = TaskCardModel.build(board.task(manual.id)!, board: board, expanded: true, githubRepo: false)
    check(card.canEdit, "a manual task can be edited")
    check(card.canDelete, "a manual task can be deleted")

    board.markRunning(manual.id)
    let running = TaskCardModel.build(board.task(manual.id)!, board: board, expanded: true, githubRepo: false)
    check(!running.canEdit, "a running task cannot be edited")
    check(!running.canDelete, "a running task cannot be deleted")
}

section("error text and detail body")
do {
    var board = TaskBoard()
    let task = TaskItem.manual(title: "Boom", body: "do the thing", id: "manual-0004dddd")
    board.tasks = [task]
    let queue = board.createQueue(name: "Lane")
    _ = board.enqueue(taskID: task.id, into: queue.id)
    board.markRunning(task.id)
    board.markFailed(task.id, error: "tasks.errDirtyTree")
    board.local.sessions[task.id] = "session-9"
    board.attachSessions(board.local.sessions)

    let card = TaskCardModel.build(board.task(task.id)!, board: board, expanded: true, githubRepo: false)
    check(card.detail.contains("tasks.detailSession"), "the session is listed in the details")
    check(card.detail.contains("tasks.errDirtyTree"), "the failure reason is translated through L10n")
    check(card.detail.contains("do the thing"), "the task body is in the details")
}

// MARK: - Queue header

section("queue header")
do {
    var board = TaskBoard()
    let t1 = TaskItem.manual(title: "One", id: "manual-0005eeee")
    let t2 = TaskItem.manual(title: "Two", id: "manual-0006ffff")
    board.tasks = [t1, t2]
    let queue = board.createQueue(name: "Dark Mode", autoPR: true)
    _ = board.enqueue(taskID: t1.id, into: queue.id)
    _ = board.enqueue(taskID: t2.id, into: queue.id)

    var header = QueueHeaderModel.build(board.queue(queue.id)!, board: board, collapsed: false)
    eq(header.name, "Dark Mode", "the queue name is shown")
    eq(header.branchText, "feature/dark-mode → main", "the branch and its base are shown")
    eq(header.progress, "0/2", "progress counts finished over total")
    eq(header.stateKey, "tasks.queue.state.paused", "a fresh queue is paused")
    eq(header.queuedCount, 2, "two tasks are waiting")
    check(header.canStart, "开始 is offered while tasks wait")
    check(!header.canPause, "暂停 is not offered while paused")
    check(!header.canOpenPR, "no PR button before the queue finishes")
    eq(header.failedCount, 0, "no failures yet")

    board.markRunning(t1.id)
    header = QueueHeaderModel.build(board.queue(queue.id)!, board: board, collapsed: false)
    eq(header.stateKey, "tasks.queue.state.active", "running makes the queue active")
    eq(header.tone, TaskTone.running, "an active queue reads as running")
    check(header.canPause, "暂停 is offered while active")
    check(!header.canStart, "开始 is hidden while active")

    board.markDone(t1.id, prUrl: nil)
    board.markRunning(t2.id)
    board.markDone(t2.id, prUrl: nil)
    header = QueueHeaderModel.build(board.queue(queue.id)!, board: board, collapsed: true)
    eq(header.progress, "2/2", "progress follows the finished tasks")
    eq(header.stateKey, "tasks.queue.state.finished", "an empty queue is finished")
    check(header.canOpenPR, "the PR button appears when the queue finishes")
    check(header.isCollapsed, "the collapsed flag is carried through")
}

section("queue without a branch and with failures")
do {
    var board = TaskBoard()
    let t1 = TaskItem.manual(title: "One", id: "manual-0007aaaa")
    board.tasks = [t1]
    let queue = board.createQueue(name: "No Branch", branch: "")
    _ = board.enqueue(taskID: t1.id, into: queue.id)
    board.markRunning(t1.id)
    _ = board.markFailed(t1.id, error: "tasks.errNoPush")

    let header = QueueHeaderModel.build(board.queue(queue.id)!, board: board, collapsed: false)
    eq(header.branchText, "tasks.queue.noBranch", "an empty branch says so")
    eq(header.failedCount, 1, "the failure is counted")
    eq(header.stateKey, "tasks.queue.state.paused", "a failed queue is paused")
    eq(header.tone, TaskTone.negative, "a paused queue with failures reads negative")
    check(!header.canOpenPR, "autoPR is off for this queue")
}

// MARK: - Summary

section("summary card (统计信息)")
do {
    var board = TaskBoard()
    let t1 = TaskItem.manual(title: "One", id: "manual-0008aaaa")
    let t2 = TaskItem.manual(title: "Two", id: "manual-0009bbbb")
    let issue = TaskItem.github(number: 4, title: "Issue four")
    board.tasks = [t1, t2, issue]
    let queue = board.createQueue(name: "Lane")
    _ = board.enqueue(taskID: t1.id, into: queue.id)
    _ = board.enqueue(taskID: t2.id, into: queue.id)
    board.markRunning(t1.id)

    let summary = TasksSummaryModel.build(board)
    eq(summary.queues, 1, "the queue is counted")
    eq(summary.queued, 1, "one task waits")
    eq(summary.running, 1, "one task runs")
    eq(summary.failed, 0, "nothing failed")
    // The card is ONE line of labelled counters, in reading order.
    eq(summary.parts.map { $0.text },
       ["tasks.stat.queues 1", "tasks.stat.queued 1", "tasks.stat.running 1", "tasks.stat.failed 0"],
       "the card prints every counter with its label")
    eq(summary.parts.map { $0.count }, [1, 1, 1, 0], "each part carries its count")
    eq(summary.parts[3].tone, TaskTone.neutral, "zero failures stay quiet")
}

// MARK: - Inline forms (新建任务 / 新建队列)

section("task composer (inline 新建任务)")
do {
    var composer = TaskComposerModel.build(mode: .create)
    eq(composer.headingKey, "tasks.new.title", "a fresh composer is the 新建任务 form")
    eq(composer.submitKey, "tasks.new.create", "its button creates")
    check(composer.isPristine, "a fresh composer is pristine")
    check(!composer.canSubmit, "an empty form cannot be submitted")
    eq(composer.problemKey, nil, "a pristine form shows no problem")

    // ONE box: 首行是标题，其余行是描述。单行 = 同时是标题和描述，因此立即可以创建。
    composer = composer.typed(content: "Polish README")
    eq(composer.problemKey, nil, "typing never nags")
    check(composer.canSubmit, "a single line is a complete task")
    eq(composer.draft.normalizedTitle, "Polish README", "the first line is the title")
    eq(composer.draft.normalizedBody, "Polish README", "and it is the description too")

    composer = composer.typed(content: "Polish README\ntidy it up")
    check(composer.canSubmit, "a multi-line box can be submitted")
    eq(composer.draft.normalizedTitle, "Polish README", "the draft carries the title")
    eq(composer.draft.normalizedBody, "tidy it up", "and the description from the lines after it")

    // Whitespace-only input is still empty.
    let blank = TaskComposerModel.build(mode: .create, content: "  \n  ")
    check(!blank.canSubmit, "whitespace is not a task")
    eq(blank.attemptedSubmit().problemKey, "tasks.errName",
       "submitting an empty form points at the title")

    // Editing an existing task prefills the same box (title line + description
    // lines) and saves instead of creating.
    let task = TaskItem.manual(title: "Old title", body: "old body", id: "manual-0010aaaa")
    let editing = TaskComposerModel.edit(task)
    eq(editing.mode, .edit(taskID: "manual-0010aaaa"), "edit mode carries the task id")
    eq(editing.headingKey, "tasks.new.editTitle", "editing says so")
    eq(editing.submitKey, "tasks.new.save", "editing saves")
    eq(editing.content, "Old title\nold body", "title and description share the box")
    eq(editing.title, "Old title", "the title is prefilled")
    eq(editing.body, "old body", "the description is prefilled")
    check(editing.canSubmit, "a prefilled form is submittable")

    // 单行任务回填成一行，而不是同一句话写两遍。
    let oneLiner = TaskItem.manual(title: "One line", body: "One line", id: "manual-0064aaaa")
    eq(TaskComposerModel.edit(oneLiner).content, "One line", "a one-line task opens as one line")
    eq(TaskComposerModel.edit(oneLiner).draft.normalizedBody, "One line",
       "and still describes itself with that line")

    // 卡片详情不重复：单行任务的描述 == 标题，详情里不再重复一遍。
    var singleBoard = TaskBoard()
    singleBoard.tasks = [oneLiner]
    let singleCard = TaskCardModel.build(oneLiner, board: singleBoard, expanded: true, githubRepo: false)
    check(!singleCard.detail.contains("One line"), "the detail does not repeat a one-line title")
    let twoLine = TaskItem.manual(title: "T", body: "b", id: "manual-0065aaaa")
    var twoLineBoard = TaskBoard()
    twoLineBoard.tasks = [twoLine]
    let twoLineCard = TaskCardModel.build(twoLine, board: twoLineBoard, expanded: true, githubRepo: false)
    check(twoLineCard.detail.contains("b"), "a real description still shows in the detail")
}

section("queue composer (inline 新建队列)")
do {
    var composer = QueueComposerModel.create(taskID: "manual-0011aaaa")
    eq(composer.headingKey, "tasks.queue.newTitle", "a new queue uses the new-queue heading")
    eq(composer.submitKey, "tasks.queue.create", "a queue created from a card joins the task")
    eq(composer.mode.taskID, "manual-0011aaaa", "the waiting task is remembered")
    check(!composer.canSubmit, "a nameless queue cannot be created")
    eq(composer.problemKey, nil, "an untouched form shows no problem")
    eq(composer.attemptedSubmit().problemKey, "tasks.errQueueName",
       "submitting without a name names the missing field")

    composer = composer.typed(name: "Dark Mode", branch: "", baseBranch: "", autoPR: false)
    check(composer.canSubmit, "a named queue can be created")
    eq(composer.effectiveBranchHint, "feature/dark-mode",
       "an empty branch shows the derived default")
    eq(composer.branchValue, nil, "an empty branch asks for the default")
    eq(composer.normalizedBaseBranch, "main", "an empty base branch falls back to main")

    // A pure-Chinese name has no slug, so the hint falls back to the wording
    // rather than promising a branch that cannot be derived.
    let chinese = QueueComposerModel.create().typed(name: "深色模式改造", branch: "", baseBranch: "main",
                                                    autoPR: false)
    eq(chinese.effectiveBranchHint, "tasks.queue.branchAuto",
       "a name with no slug keeps the generic hint")

    // A typed branch wins, and an explicit one is what the queue gets.
    let typed = chinese.typed(name: "深色模式改造", branch: "feature/dark", baseBranch: "develop",
                              autoPR: true)
    eq(typed.effectiveBranchHint, "feature/dark", "a typed branch is echoed back")
    eq(typed.branchValue, "feature/dark", "and is the value the queue is created with")
    eq(typed.normalizedBaseBranch, "develop", "the base branch is carried")

    // Standalone creation (the queues section header button).
    eq(QueueComposerModel.create().submitKey, "tasks.queue.createOnly",
       "a queue created on its own just creates")

    // The queue's own settings.
    var queue = TaskQueue(id: "q-1111", name: "Lane", branch: "feature/lane", baseBranch: "main")
    queue.autoPR = true
    let settings = QueueComposerModel.edit(queue, prAvailable: true)
    eq(settings.headingKey, "tasks.queue.editTitle", "editing a queue says so")
    eq(settings.submitKey, "tasks.new.save", "editing saves")
    eq(settings.mode.queueID, "q-1111", "the edited queue is remembered")
    eq(settings.name, "Lane", "the name is prefilled")
    eq(settings.branch, "feature/lane", "the branch is prefilled")
    check(settings.autoPR, "the PR switch is prefilled")
    check(settings.prAvailable, "a GitHub workspace can open a PR")
    // Clearing the branch means "run on whatever is checked out".
    let cleared = settings.typed(name: "Lane", branch: "", baseBranch: "main", autoPR: false)
    eq(cleared.effectiveBranchHint, "tasks.queue.noBranch", "no branch says so while editing")
    eq(cleared.branchValue, nil, "no branch really means no branch")
}


section("非 git 工作区：队列表单不再许下一个兑现不了的分支")
do {
    // 创建：目录不是 git 仓库 → 默认就是 不切分支，且提交的是「显式不切分支」，
    // 不是「留空 = 派生」—— 后者会让队列带着 feature/<slug> 建起来，然后第一个任务
    // 就以 tasks.errNotGit 失败（这就是那个 bug）。
    var form = QueueComposerModel.create().forWorkspace(git: false, pr: false)
    check(form.skipsBranch, "creating in a non-git directory starts as 不切分支")
    check(!form.gitAvailable, "and the form knows there is no repository")
    form = form.typed(name: "Docs Cleanup", branch: "", baseBranch: "main", autoPR: false)
    eq(form.branchValue, "", "the queue is created with an explicit no-branch")
    eq(form.effectiveBranchHint, "tasks.queue.noBranch", "and the hint says so")

    // 同样的表单在 git 仓库里：老行为一字不改（按名字派生分支）。
    let inGit = QueueComposerModel.create().forWorkspace(git: true, pr: true)
        .typed(name: "Docs Cleanup", branch: "", baseBranch: "main", autoPR: false)
    check(!inGit.skipsBranch, "a git repository keeps deriving a branch")
    eq(inGit.branchValue, nil, "an empty branch still asks for the derived default")
    eq(inGit.effectiveBranchHint, "feature/docs-cleanup", "…which is still feature/<slug>")

    // 显式勾选：在 git 仓库里也可以（「就在当前工作区干」），并且压过已填的分支。
    let skipped = inGit.typed(name: "Docs Cleanup", branch: "feature/docs", baseBranch: "main",
                              autoPR: false, skippingBranch: true)
    check(skipped.skipsBranch, "the switch wins over a typed branch")
    eq(skipped.branchValue, "", "and the queue really gets no branch")

    // 编辑：没有分支的队列打开就是 不切分支…
    let noBranch = QueueComposerModel.edit(TaskQueue(id: "q-0001", name: "Lane"),
                                           prAvailable: false, gitAvailable: false)
    check(noBranch.skipsBranch, "a branchless queue opens on 不切分支")
    // …而有分支的队列保留自己的分支：打开设置不能悄悄把分支丢掉，
    // 用户要清掉它是「清空分支字段 / 勾上开关」这个动作。
    let withBranch = QueueComposerModel.edit(TaskQueue(id: "q-0002", name: "Lane", branch: "feature/lane"),
                                             prAvailable: true, gitAvailable: false)
    check(!withBranch.skipsBranch, "an existing branch is not dropped just by opening the form")
    eq(withBranch.branch, "feature/lane", "it stays visible so the user can clear it")
}

section("非 git 的失败可以一键修好（卡片上的 不切分支并重试）")
do {
    var board = TaskBoard()
    let task = TaskItem.manual(title: "One", id: "manual-0090aaaa")
    board.tasks = [task]
    let queue = board.createQueue(name: "Docs Cleanup")      // 派生 feature/docs-cleanup
    _ = board.enqueue(taskID: task.id, into: queue.id)
    board.markRunning(task.id)
    _ = board.markFailed(task.id, error: TaskFailure.notGitRepo.rawValue)

    var card = TaskCardModel.build(board.task(task.id)!, board: board,
                                   expanded: true, githubRepo: false)
    check(card.clearsBranchOnRetry, "a branch that cannot be entered is fixable from the card")
    eq(card.primaryKey, "tasks.detailRetryNoBranch", "so 重试 becomes 不切分支并重试")
    check(card.canRetry, "and the card still offers the retry")

    // 别的失败没有这个按钮：那些重试就是重试。
    _ = board.markFailed(task.id, error: TaskFailure.dirtyWorktree.rawValue)
    card = TaskCardModel.build(board.task(task.id)!, board: board,
                               expanded: true, githubRepo: false)
    check(!card.clearsBranchOnRetry, "a dirty worktree is not a branch problem")
    eq(card.primaryKey, "tasks.detailRetry", "so the plain 重试 stays")

    // 队列本来就没有分支：没有东西可清。
    var bare = TaskBoard()
    let bareTask = TaskItem.manual(title: "Two", id: "manual-0091bbbb")
    bare.tasks = [bareTask]
    let bareQueue = bare.createQueue(name: "Lane", branch: "")
    _ = bare.enqueue(taskID: bareTask.id, into: bareQueue.id)
    bare.markRunning(bareTask.id)
    _ = bare.markFailed(bareTask.id, error: TaskFailure.notGitRepo.rawValue)
    let bareCard = TaskCardModel.build(bare.task(bareTask.id)!, board: bare,
                                       expanded: true, githubRepo: false)
    check(!bareCard.clearsBranchOnRetry, "nothing to clear when the queue already has no branch")
    eq(bareCard.primaryKey, "tasks.detailRetry", "the plain retry is the way out there")
}

section("头部的工作区行：非 git / 非 GitHub 分开说，GitHub 专属按钮跟着可用性")
do {
    // GitHub 仓库：显示 owner/repo，三个 GitHub 专属按钮可用。
    let gh = TaskWorkspaceModel.build(owner: "insky2005", repo: "oh-my-dsh",
                                      workspacePath: "/tmp/oh-my-dsh", isGitRepo: true)
    eq(gh.title, "insky2005/oh-my-dsh", "GitHub 仓库直接显示 owner/repo")
    check(gh.githubAvailable, "三个 GitHub 专属按钮可用")
    eq(gh.disabledHint, nil, "可用时没有禁用原因")

    // git 仓库但没有 GitHub 远端：说的是 GitHub，不是 git。
    let gitOnly = TaskWorkspaceModel.build(owner: nil, repo: nil,
                                           workspacePath: "/Users/x/notes-repo", isGitRepo: true)
    eq(gitOnly.title, "notes-repo · tasks.noRepoShort", "非 GitHub 仓库说 非 GitHub 仓库")
    check(!gitOnly.githubAvailable, "没有 GitHub 远端：按钮不可用")
    eq(gitOnly.disabledHint, "tasks.githubUnavailable", "并且说清原因")

    // 目录根本不是 git 仓库：这句话必须不一样 —— 队列连分支都切不了（§V2-7）。
    let noGit = TaskWorkspaceModel.build(owner: nil, repo: nil,
                                         workspacePath: "/Users/x/plain-notes", isGitRepo: false)
    eq(noGit.title, "plain-notes · tasks.noGitShort", "非 git 目录说 非 Git 仓库")
    check(!noGit.githubAvailable, "同样没有 GitHub 可用性")

    // 还没解析出工作区：不该假装知道是一个仓库。
    let none = TaskWorkspaceModel.build(owner: nil, repo: nil, workspacePath: nil, isGitRepo: true)
    eq(none.title, "tasks.noRepo", "没有工作区时用通用文案")
    check(!none.githubAvailable, "按钮不可用")
    eq(none.disabledHint, "tasks.errNoWorkspace", "原因指向「还没确定工作区」")
}

section("队列被删掉之后的失败任务：直接给 加入队列 / 处理，不再先给一次空重试")
do {
    // 手动任务 + 一个失败的队列：重试还在（它把任务放回队列并唤醒队列）。
    var board = TaskBoard()
    let task = TaskItem.manual(title: "One", id: "manual-00a0aaaa")
    board.tasks = [task]
    let queue = board.createQueue(name: "Lane")
    _ = board.enqueue(taskID: task.id, into: queue.id)
    board.markRunning(task.id)
    _ = board.markFailed(task.id, error: TaskFailure.session.rawValue)
    var card = TaskCardModel.build(board.task(task.id)!, board: board, expanded: true, githubRepo: false)
    eq(card.primaryKey, "tasks.detailRetry", "队列还在：主操作是 重试")
    eq(card.primaryAction, .retry(clearsBranch: false), "而它真的把任务放回那个队列")
    check(card.canRetry, "canRetry 也说着重试")
    check(!card.canQueue, "这时没有 加入队列")

    // 队列被删除：任务回到未入队区、状态仍是失败 —— 此时 重试 什么也重试不了
    // （retryAndResume 只会把它变回待处理），所以主操作直接是 加入队列。
    _ = board.removeQueue(queue.id)
    eq(board.task(task.id)?.state, .failed, "删队列不动任务的状态")
    eq(board.task(task.id)?.queueId, nil, "只是不再是队列成员")
    card = TaskCardModel.build(board.task(task.id)!, board: board, expanded: true, githubRepo: false)
    eq(card.primaryKey, "tasks.queue.add", "没有队列可重试：主操作是 加入队列")
    eq(card.primaryAction, .joinQueue, "并且面板会打开队列下拉（而不是执行 retry）")
    check(card.canQueue, "下拉由 canQueue 决定")
    check(!card.canRetry, "不再是 重试")

    // 取消的任务同理（也是「可入队」状态之一）。
    var cancelledBoard = TaskBoard()
    let cancelled = TaskItem.manual(title: "Two", id: "manual-00a1bbbb")
    cancelledBoard.tasks = [cancelled]
    let q2 = cancelledBoard.createQueue(name: "Lane")
    _ = cancelledBoard.enqueue(taskID: cancelled.id, into: q2.id)
    cancelledBoard.markRunning(cancelled.id)
    cancelledBoard.markCancelled(cancelled.id)
    _ = cancelledBoard.removeQueue(q2.id)
    let cancelledCard = TaskCardModel.build(cancelledBoard.task(cancelled.id)!, board: cancelledBoard,
                                            expanded: true, githubRepo: false)
    eq(cancelledCard.primaryAction, .joinQueue, "被取消 + 队列没了：同样直接 加入队列")

    // issue 任务的自动单任务队列被删掉：主操作是 处理（会重建那个队列并开跑）。
    var issueBoard = TaskBoard()
    let issue = TaskItem.github(number: 7, title: "Issue seven")
    issueBoard.tasks = [issue]
    let auto = TaskQueue.auto(for: issue)
    issueBoard.queues.append(auto)
    _ = issueBoard.enqueue(taskID: issue.id, into: auto.id)
    issueBoard.markRunning(issue.id)
    _ = issueBoard.markFailed(issue.id, error: TaskFailure.timeout.rawValue)
    var issueCard = TaskCardModel.build(issueBoard.task(issue.id)!, board: issueBoard,
                                        expanded: true, githubRepo: true)
    eq(issueCard.primaryAction, .retry(clearsBranch: false), "issue 任务的队列还在：重试")
    _ = issueBoard.removeQueue(auto.id)
    issueCard = TaskCardModel.build(issueBoard.task(issue.id)!, board: issueBoard,
                                    expanded: true, githubRepo: true)
    eq(issueCard.primaryKey, "tasks.detailProcess", "队列没了：主操作回到 处理")
    eq(issueCard.primaryAction, .processIssue, "而 处理 会重建自动队列")
}

section("卡片主操作的动作枚举（面板按它执行，不再按状态猜）")
do {
    var board = TaskBoard()
    let manual = TaskItem.manual(title: "Mine", id: "manual-00b0aaaa")
    board.tasks = [manual]
    var card = TaskCardModel.build(board.task(manual.id)!, board: board, expanded: true, githubRepo: false)
    eq(card.primaryAction, .joinQueue, "未入队的手动任务：加入队列（下拉，面板不执行动作）")

    let queue = board.createQueue(name: "Lane")
    _ = board.enqueue(taskID: manual.id, into: queue.id)
    card = TaskCardModel.build(board.task(manual.id)!, board: board, expanded: true, githubRepo: false)
    eq(card.primaryAction, .dequeue, "排队中：移出队列")

    board.markRunning(manual.id)
    card = TaskCardModel.build(board.task(manual.id)!, board: board, expanded: true, githubRepo: false)
    eq(card.primaryAction, .cancel, "运行中：取消任务")

    board.markDone(manual.id, prUrl: "https://github.com/o/r/pull/3")
    card = TaskCardModel.build(board.task(manual.id)!, board: board, expanded: true, githubRepo: false)
    eq(card.primaryAction, .openPR, "已完成：打开 PR")

    var issueBoard = TaskBoard()
    let issue = TaskItem.github(number: 9, title: "Nine")
    issueBoard.tasks = [issue]
    let pendingIssue = TaskCardModel.build(issueBoard.task(issue.id)!, board: issueBoard,
                                           expanded: true, githubRepo: true)
    eq(pendingIssue.primaryAction, .processIssue, "待处理的 issue：处理")
    issueBoard.markClosed(issue.id)
    let closedIssue = TaskCardModel.build(issueBoard.task(issue.id)!, board: issueBoard,
                                          expanded: true, githubRepo: true)
    eq(closedIssue.primaryAction, .openIssue, "已关闭的 issue：打开 Issue")
}

section("已完成但没有 PR：仍可评论并关闭；灰掉的主按钮说明原因")
do {
    var board = TaskBoard()
    let issue = TaskItem.github(number: 8, title: "No PR")
    board.tasks = [issue]
    let queue = TaskQueue.auto(for: issue)
    board.queues = [queue]
    _ = board.enqueue(taskID: issue.id, into: queue.id)
    board.markRunning(issue.id)
    board.markDone(issue.id, prUrl: nil)
    var card = TaskCardModel.build(board.task(issue.id)!, board: board, expanded: true, githubRepo: true)
    eq(card.primaryKey, "tasks.detailOpenPR", "主操作还是 打开 PR")
    check(!card.primaryEnabled, "但没有 PR，它是灰的")
    eq(card.primaryDisabledHintKey, "tasks.detailOpenPRNoPR", "灰按钮带着原因（tooltip）")
    check(card.canCommentClose, "评论并关闭仍然可用 —— 它并不需要 PR 链接")

    // 有 PR 时：按钮可用，也就没有「为什么灰」这句话。
    board.markDone(issue.id, prUrl: "https://github.com/o/r/pull/9")
    card = TaskCardModel.build(board.task(issue.id)!, board: board, expanded: true, githubRepo: true)
    check(card.primaryEnabled, "有 PR 时按钮是活的")
    eq(card.primaryDisabledHintKey, nil, "活着的按钮不需要解释")
    check(card.canCommentClose, "评论并关闭照样在")

    // 非 GitHub 工作区：评论并关闭整条不出现（没有 issue 可关）。
    let noRepo = TaskCardModel.build(board.task(issue.id)!, board: board, expanded: true, githubRepo: false)
    check(!noRepo.canCommentClose, "没有 GitHub 就没有 评论并关闭")
}

section("跳过并继续：只有后面还有排队任务时才出现")
do {
    var board = TaskBoard()
    let t1 = TaskItem.manual(title: "One", id: "manual-00c0aaaa")
    let t2 = TaskItem.manual(title: "Two", id: "manual-00c1bbbb")
    board.tasks = [t1, t2]
    let queue = board.createQueue(name: "Lane")
    _ = board.enqueue(taskID: t1.id, into: queue.id)
    _ = board.enqueue(taskID: t2.id, into: queue.id)
    board.markRunning(t1.id)
    _ = board.markFailed(t1.id, error: TaskFailure.session.rawValue)
    var card = TaskCardModel.build(board.task(t1.id)!, board: board, expanded: true, githubRepo: false)
    check(card.canSkip, "后面还有排队的任务 → 给 跳过并继续")
    eq(card.primaryKey, "tasks.detailRetry", "主操作还是 重试（跳过是第二个入口）")

    // 队里只有它一个：跳过只会唤醒一个没活干的队列。
    var loneBoard = TaskBoard()
    let lone = TaskItem.manual(title: "Lone", id: "manual-00c2cccc")
    loneBoard.tasks = [lone]
    let loneQueue = loneBoard.createQueue(name: "Lane")
    _ = loneBoard.enqueue(taskID: lone.id, into: loneQueue.id)
    loneBoard.markRunning(lone.id)
    _ = loneBoard.markFailed(lone.id, error: TaskFailure.session.rawValue)
    let loneCard = TaskCardModel.build(loneBoard.task(lone.id)!, board: loneBoard, expanded: true, githubRepo: false)
    check(!loneCard.canSkip, "队里没有下一个任务 → 不给 跳过并继续")

    // 后面的任务已经跑完：也没有可跳过去的了。
    _ = board.markDone(t2.id, prUrl: nil)
    card = TaskCardModel.build(board.task(t1.id)!, board: board, expanded: true, githubRepo: false)
    check(!card.canSkip, "后面那个已经跑完 → 不给 跳过并继续")

    // 没有队列的失败任务（队列被删）：跳过无从谈起。
    let orphan = TaskCardModel.build(board.task(t2.id)!, board: board, expanded: true, githubRepo: false)
    check(!orphan.canSkip, "不在队列里的任务谈不上跳过")
}

section("队列头 ▶ 的文案跟着它真正做的事")
do {
    var board = TaskBoard()
    let t1 = TaskItem.manual(title: "One", id: "manual-00d0aaaa")
    let t2 = TaskItem.manual(title: "Two", id: "manual-00d1bbbb")
    board.tasks = [t1, t2]
    let queue = board.createQueue(name: "Lane")
    _ = board.enqueue(taskID: t1.id, into: queue.id)
    _ = board.enqueue(taskID: t2.id, into: queue.id)
    var header = QueueHeaderModel.build(board.queue(queue.id)!, board: board, collapsed: false)
    eq(header.startHintKey, "tasks.queue.start", "还没跑过：按钮就是 开始")

    board.markRunning(t1.id)
    _ = board.markFailed(t1.id, error: TaskFailure.session.rawValue)
    header = QueueHeaderModel.build(board.queue(queue.id)!, board: board, collapsed: false)
    eq(header.startHintKey, "tasks.queue.continue", "失败之后它其实是 继续（跳过失败项）")

    // 队里只剩失败的那条：没有下一个可跑，按钮本身也不出现（canStart 为假）。
    var loneBoard = TaskBoard()
    let lone = TaskItem.manual(title: "Lone", id: "manual-00d2cccc")
    loneBoard.tasks = [lone]
    let loneQueue = loneBoard.createQueue(name: "Lane")
    _ = loneBoard.enqueue(taskID: lone.id, into: loneQueue.id)
    loneBoard.markRunning(lone.id)
    _ = loneBoard.markFailed(lone.id, error: TaskFailure.session.rawValue)
    let loneHeader = QueueHeaderModel.build(loneBoard.queue(loneQueue.id)!, board: loneBoard, collapsed: false)
    check(!loneHeader.canStart, "没有排队的任务：连按钮都没有")
}

section("运行中的卡片带一个时钟")
do {
    var board = TaskBoard()
    let task = TaskItem.manual(title: "Long one", id: "manual-00g0aaaa")
    board.tasks = [task]
    let queue = board.createQueue(name: "Lane")
    _ = board.enqueue(taskID: task.id, into: queue.id)
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    board.markRunning(task.id, at: start)
    var card = TaskCardModel.build(board.task(task.id)!, board: board, expanded: false, githubRepo: false,
                                   now: start.addingTimeInterval(65))
    eq(card.runningFor, "1:05", "已运行时长按 mm:ss")
    eq(card.meta.first, "tasks.card.runningFor(1:05)", "而且排在最前面（「是不是卡住了」是运行时最想问的）")

    // 过了一小时：hh:mm:ss（时长不是当地时间，不用本地化）
    card = TaskCardModel.build(board.task(task.id)!, board: board, expanded: false, githubRepo: false,
                               now: start.addingTimeInterval(3725))
    eq(card.runningFor, "1:02:05", "超过一小时带小时")

    // 跑完 / 没跑过的任务没有这个字段（也不该有）。
    board.markDone(task.id, prUrl: nil)
    card = TaskCardModel.build(board.task(task.id)!, board: board, expanded: false, githubRepo: false,
                               now: start.addingTimeInterval(600))
    eq(card.runningFor, nil, "已完成的任务没有运行时钟")
    check(!card.meta.contains { $0.hasPrefix("tasks.card.runningFor") }, "meta 里也不留")
}

section("统计卡跟着来源筛选（不再跟列表打架）")
do {
    var board = TaskBoard()
    let manual = TaskItem.manual(title: "Mine", id: "manual-00h0aaaa")
    let issue = TaskItem.github(number: 4, title: "Issue four")
    board.tasks = [manual, issue]
    let userQueue = board.createQueue(name: "Lane")
    let autoQueue = TaskQueue.auto(for: issue)
    board.queues.append(autoQueue)
    _ = board.enqueue(taskID: manual.id, into: userQueue.id)
    _ = board.enqueue(taskID: issue.id, into: autoQueue.id)

    var summary = TasksSummaryModel.build(board)
    eq(summary.queues, 2, "全部：两个队列都算")
    eq(summary.queued, 2, "两条任务都在排队")

    summary = TasksSummaryModel.build(board, source: .manual)
    eq(summary.queues, 1, "只看手动：issue 的自动队列不算")
    eq(summary.queued, 1, "计数也只剩手动那条")

    summary = TasksSummaryModel.build(board, source: .github)
    eq(summary.queues, 1, "只看 Issue：用户队列不算")
    eq(summary.queued, 1, "计数同样跟着走")

    // 筛选下面一个都不剩时，计数是 0 而不是整张 board。
    var empty = TaskBoard()
    empty.tasks = [issue]
    let solo = TasksSummaryModel.build(empty, source: .manual)
    eq(solo.queues, 0, "没有可选的任务：队列数归零")
    eq(solo.queued, 0, "排队数归零")
}

section("同时活跃的两个队列：只有一个在跑")
do {
    var board = TaskBoard()
    let t1 = TaskItem.manual(title: "A", id: "manual-00i0aaaa")
    let t2 = TaskItem.manual(title: "B", id: "manual-00i1bbbb")
    board.tasks = [t1, t2]
    let q1 = board.createQueue(name: "First")
    let q2 = board.createQueue(name: "Second")
    _ = board.enqueue(taskID: t1.id, into: q1.id)
    _ = board.enqueue(taskID: t2.id, into: q2.id)
    _ = board.resumeQueue(q1.id)
    _ = board.resumeQueue(q2.id)          // 第二个「开始」把 activeQueueID 改成了它

    let current = board.activeQueue()?.id
    eq(current, q2.id, "当前队列是最后点了开始的那个")
    let first = QueueHeaderModel.build(board.queue(q1.id)!, board: board, collapsed: false,
                                       isCurrent: current == q1.id)
    eq(first.stateKey, "tasks.queue.state.waiting", "另一个队列不能说自己在跑：等待中")
    eq(first.tone, .warning, "语气也不是「运行中」")
    let second = QueueHeaderModel.build(board.queue(q2.id)!, board: board, collapsed: false,
                                        isCurrent: current == q2.id)
    eq(second.stateKey, "tasks.queue.state.active", "当前那个才是活跃")
    eq(second.tone, .running, "语气是运行中")

    // 暂停 / 完成不受影响。
    _ = board.pauseQueue(q1.id)
    let paused = QueueHeaderModel.build(board.queue(q1.id)!, board: board, collapsed: false, isCurrent: false)
    eq(paused.stateKey, "tasks.queue.state.paused", "暂停就是暂停，跟是不是当前无关")
}

section("队列头的三个操作与 PR 可用性")
do {
    var board = TaskBoard()
    let task = TaskItem.manual(title: "One", id: "manual-0080aaaa")
    board.tasks = [task]
    let queue = board.createQueue(name: "Lane")
    _ = board.enqueue(taskID: task.id, into: queue.id)

    // GitHub 工作区：自动开 PR 的开关可用。
    var header = QueueHeaderModel.build(board.queue(queue.id)!, board: board, collapsed: false,
                                        prAvailable: true)
    check(header.prAvailable, "a GitHub workspace can carry a PR")
    check(header.showsAutoPRToggle, "so the 自动开 PR toggle is shown")
    check(header.autoPREnabled, "and it is clickable")

    // 非 GitHub 工作区：没有 PR 这回事 —— 开关整块不出现（不是点了没反应的死按钮）。
    header = QueueHeaderModel.build(board.queue(queue.id)!, board: board, collapsed: false,
                                    prAvailable: false)
    check(!header.prAvailable, "a non-GitHub workspace cannot carry a PR")
    check(!header.showsAutoPRToggle, "so the switch disappears instead of sitting there dead")
    check(!header.autoPREnabled, "and it is not clickable")

    // 已经是「自动开 PR」的队列（在 GitHub 工作区建的）换了工作区后：开关还在（状态不能被藏起来），
    // 但不可点，tooltip 说明原因。
    if let i = board.index(ofQueue: queue.id) { board.queues[i].autoPR = true }
    header = QueueHeaderModel.build(board.queue(queue.id)!, board: board, collapsed: false,
                                    prAvailable: false)
    check(header.autoPR, "the queue still knows its switch is on")
    check(header.showsAutoPRToggle, "so the toggle stays visible")
    check(!header.autoPREnabled, "but it cannot be flipped where no PR can be opened")

    // 完成 + autoPR + 有分支时才给「打开 PR」；没有 GitHub 就不给。
    board.markRunning(task.id)
    board.markDone(task.id, prUrl: nil)
    var ready = QueueHeaderModel.build(board.queue(queue.id)!, board: board, collapsed: false,
                                       prAvailable: true)
    check(ready.canOpenPR, "a finished queue with autoPR offers 打开 PR")
    ready = QueueHeaderModel.build(board.queue(queue.id)!, board: board, collapsed: false,
                                   prAvailable: false)
    check(!ready.canOpenPR, "…but never in a workspace without GitHub")
}
section("加入队列 dropdown: 新建队列 first")
do {
    var board = TaskBoard()
    let q1 = board.createQueue(name: "Docs Cleanup")
    let q2 = board.createQueue(name: "Second lane", baseBranch: "develop", autoPR: true)
    _ = q1; _ = q2

    let items = QueuePickerItem.build(board.queueChoices())
    eq(items.count, 3, "新建队列 + 两个已有队列")
    check(items.first?.isNewQueue == true, "新建队列排第一个")
    eq(items.first?.title, "tasks.queue.new", "它用的是 新建队列 文案")
    eq(items.dropFirst().map { $0.title }, ["Docs Cleanup", "Second lane"],
       "已有队列按创建顺序排在后面")
    eq(items.dropFirst().map { $0.queueID }, board.queueChoices().map { $0.id },
       "每一行都带着它要入队的队列 id")
    eq(items.dropFirst().first?.branch, "feature/docs-cleanup", "行里带上该队列的分支")

    // 一个队列都没有时，下拉里只有 新建队列 —— 也就是第一个。
    let fresh = QueuePickerItem.build(TaskBoard().queueChoices())
    eq(fresh.count, 1, "空 board 只有一项")
    check(fresh.first?.isNewQueue == true, "那一项就是 新建队列")
}
section("empty state")
do {
    let fresh = TasksEmptyStateModel.build(filtered: false, githubRepo: true)
    eq(fresh.messageKey, "tasks.empty", "a fresh board points at the way in")
    check(fresh.showsNewTask, "and offers the inline form")
    eq(fresh.symbol, "checklist", "with the checklist symbol")

    let noRepo = TasksEmptyStateModel.build(filtered: false, githubRepo: false)
    eq(noRepo.messageKey, "tasks.emptyManualOnly",
       "a non-GitHub workspace explains what still works")

    let filtered = TasksEmptyStateModel.build(filtered: true, githubRepo: true)
    eq(filtered.messageKey, "tasks.emptyFiltered", "an empty filter says which kind of empty")
    check(!filtered.showsNewTask, "and does not offer to create a task")
}

section("counters, progress and the auto queue flag")
do {
    var board = TaskBoard()
    let t1 = TaskItem.manual(title: "One", id: "manual-0012aaaa")
    let t2 = TaskItem.manual(title: "Two", id: "manual-0013bbbb")
    board.tasks = [t1, t2]
    let queue = board.createQueue(name: "Lane")
    _ = board.enqueue(taskID: t1.id, into: queue.id)
    _ = board.enqueue(taskID: t2.id, into: queue.id)
    board.markRunning(t1.id)

    var header = QueueHeaderModel.build(board.queue(queue.id)!, board: board, collapsed: false)
    eq(header.runningCount, 1, "the running task is counted for the header")
    eq(header.progressFraction, 0, "nothing is finished yet")
    check(!header.isAutoCreated, "a user queue is not an auto queue")

    board.markDone(t1.id, prUrl: nil)
    header = QueueHeaderModel.build(board.queue(queue.id)!, board: board, collapsed: false)
    eq(header.progressFraction, 0.5, "half the queue is done")
    eq(header.runningCount, 0, "nothing runs now")

    let issue = TaskItem.github(number: 7, title: "Seven")
    let auto = board.createQueue(name: "Issue #7", autoCreated: true)
    _ = board.enqueue(taskID: issue.id, into: auto.id)
    let autoHeader = QueueHeaderModel.build(board.queue(auto.id)!, board: board, collapsed: true)
    check(autoHeader.isAutoCreated, "the issue lane is flagged as auto-created")

    // The summary card mirrors the counts, and only 失败 lights up.
    let summary = TasksSummaryModel.build(board)
    eq(summary.parts.count, 4, "four counters")
    eq(summary.parts.map { $0.key },
       ["tasks.stat.queues", "tasks.stat.queued", "tasks.stat.running", "tasks.stat.failed"],
       "the card reads 队列 · 排队 · 运行 · 失败")
    eq(summary.parts.map { $0.count }, [summary.queues, summary.queued, summary.running, summary.failed],
       "every counter carries its count")
    eq(summary.parts[3].tone, TaskTone.neutral, "zero failures stay quiet")
    eq(TaskSummaryPart.tone(forCount: 2, negativeWhenPositive: true), TaskTone.negative,
       "failures light up")
    eq(TaskSummaryPart.tone(forCount: 2, negativeWhenPositive: false), TaskTone.neutral,
       "running is an accent count, not an alarm")
}

if failures == 0 {
    print("ok - \(checks) checks passed")
} else {
    print("FAILED - \(failures) of \(checks) checks failed")
    exit(1)
}
