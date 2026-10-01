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
    eq(card.primaryKey, "tasks.detailOpenIssue", "完成的 issue 任务：主操作是 打开 Issue")
    check(card.primaryAction == .openIssue, "…而它真的打开 issue")
    check(!card.meta.isEmpty, "PR 仍然写在 meta 行里（小字），不是一枚按钮")
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

section("卡片不再显示已经离开的那条分支")
do {
    var board = TaskBoard()
    let task = TaskItem.manual(title: "One", id: "manual-jj001111")
    board.tasks = [task]
    let queue = board.createQueue(name: "Lane")
    _ = board.enqueue(taskID: task.id, into: queue.id)
    board.markRunning(task.id)
    _ = board.markFailed(task.id, error: "tasks.errSession")
    var card = TaskCardModel.build(board.task(task.id)!, board: board, expanded: false, githubRepo: false)
    check(card.meta.contains("feature/lane"), "还在队列里：卡片显示这条分支")

    _ = board.retryAndResume(task.id)
    _ = board.dequeue(taskID: task.id)
    card = TaskCardModel.build(board.task(task.id)!, board: board, expanded: false, githubRepo: false)
    check(!card.meta.contains("feature/lane"), "移出队列后卡片不再显示它")
    check(!card.meta.contains { $0.hasPrefix("feature/") }, "也不显示任何别的分支")
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

    // 已完成的任务是「记录」而不是「待办」：编辑与删除都不再给（用户 2026-09-27 的规则）。
    board.markDone(manual.id, report: "做完了。")
    let done = TaskCardModel.build(board.task(manual.id)!, board: board, expanded: true, githubRepo: false)
    check(!done.canEdit, "a finished task cannot be edited")
    check(!done.canDelete, "a finished task cannot be deleted")
    check(done.detail.contains("做完了。"), "汇报照旧看得见（记录并没有被锁死内容）")

    // 还会再跑的（失败 / 已取消）仍然可改可删 —— 重试前改标题正是编辑按钮的用处。
    board.markRunning(manual.id)
    _ = board.markFailed(manual.id, error: "tasks.errTimeout")
    let failed = TaskCardModel.build(board.task(manual.id)!, board: board, expanded: true, githubRepo: false)
    check(failed.canEdit, "a failed task can still be edited before a retry")
    check(failed.canDelete, "…and deleted")
}

section("来源页签：泳道按「里面有没有匹配的任务」出现，不按 autoCreated")
do {
    // 全部处理给**手动任务**建的也是**自动队列**（autoCreated = true），而旧规则拿
    // autoCreated 当「issue 队列」用：点 Issue 会列出一堆以手动任务命名的泳道（里面
    // 的卡片全被过滤掉，只剩空泳道），点手动反而什么都没有。
    var board = TaskBoard()
    let issue = TaskItem.github(number: 7, title: "Fix dark mode")
    let manual = TaskItem.manual(title: "改 README", id: "manual-ff900001")
    board.tasks = [issue, manual]
    let issueQueue = board.createQueue(name: "Issue #7", autoPR: true, autoCreated: true)
    let manualAutoQueue = board.createQueue(name: "改 README", autoPR: false, autoCreated: true)
    let userQueue = board.createQueue(name: "Docs")
    _ = board.enqueue(taskID: issue.id, into: issueQueue.id)
    _ = board.enqueue(taskID: manual.id, into: manualAutoQueue.id)

    let all = TaskSourceFilter.all
    check(all.shows(issueQueue, in: board) && all.shows(manualAutoQueue, in: board)
          && all.shows(userQueue, in: board), "「全部」不落下任何泳道（空泳道也照画）")

    let issues = TaskSourceFilter.issues
    check(issues.shows(issueQueue, in: board), "Issue 页签：装着 issue 任务的自动队列要在")
    check(!issues.shows(manualAutoQueue, in: board), "装着手动任务的自动队列不在（这条就是那个 bug）")
    check(!issues.shows(userQueue, in: board), "空的用户队列也不在（这个页签下它没内容）")
    eq(issues.cards(of: issueQueue, in: board).map { $0.id }, [issue.id], "里面的卡片就是 issue 那条")

    let manualFilter = TaskSourceFilter.manual
    check(manualFilter.shows(manualAutoQueue, in: board), "手动页签：装着手动任务的自动队列要在")
    check(manualFilter.shows(userQueue, in: board),
          "用户自建（空）队列也在：用户泳道就是手动这一侧（下一个手动任务要放进去）")
    check(!TaskSourceFilter.issues.shows(userQueue, in: board), "同一个空泳道在 Issue 页签下不出现")
    check(!manualFilter.shows(issueQueue, in: board), "issue 的队列不在")
    eq(manualFilter.cards(of: manualAutoQueue, in: board).map { $0.id }, [manual.id], "卡片是手动那条")

    // 未入队区用 matches，与这里同一份判据。
    check(TaskSourceFilter.manual.matches(manual) && !TaskSourceFilter.manual.matches(issue),
          "matches 与卡片筛选同源")
    // 页签顺序与含义由枚举一处定义：标题数组从 allCases 生成（面板如此），所以
    // 「下标 → 含义」再也不可能对不上 —— 用户要求「手动」排在 Issue 前面。
    eq(TaskSourceFilter.allCases.map { $0.titleKey },
       ["tasks.filter.all", "tasks.filter.manual", "tasks.filter.issues"],
       "页签顺序：全部 / 手动 / Issue")
    for (index, filter) in TaskSourceFilter.allCases.enumerated() {
        eq(filter.rawValue, index, "第 \(index) 个页签的 rawValue 就是它的下标")
    }
    eq(TaskSourceFilter.issues.source, TaskSource.github, "汇总卡计数用的是同一个来源值")
    eq(TaskSourceFilter.all.source, nil, "「全部」= 不过滤")
}
section("已完成的任务与队列：可编辑性各就各位")
do {
    var board = TaskBoard()
    let t1 = TaskItem.manual(title: "One", id: "manual-gg201010")
    let t2 = TaskItem.manual(title: "Two", id: "manual-gg202020")
    board.tasks = [t1, t2]
    let doneQueue = board.createQueue(name: "Lane", branch: "feature/x", autoPR: false)
    _ = board.enqueue(taskID: t1.id, into: doneQueue.id)
    board.markRunning(t1.id)
    board.markDone(t1.id)
    eq(board.queue(doneQueue.id)?.state, QueueState.done, "队列已完成")
    let doneHeader = QueueHeaderModel.build(board.queue(doneQueue.id)!, board: board, collapsed: false)
    check(!doneHeader.canEdit, "已完成的队列没有「设置」")
    check(!doneHeader.canDelete, "也没有「删除」")
    check(doneHeader.canClose, "但可以手动关闭")
    check(doneHeader.canOpenPR, "已完成 + 有分支 → 可以发布（不再要求 autoPR）")

    // .closed = 手动终态：保留记录，但什么都不能做。
    var closedBoard = TaskBoard()
    let ct = TaskItem.manual(title: "CT", id: "manual-gg203030")
    closedBoard.tasks = [ct]
    let cq = closedBoard.createQueue(name: "Closed lane", branch: "feature/c")
    _ = closedBoard.enqueue(taskID: ct.id, into: cq.id)
    closedBoard.markRunning(ct.id)
    closedBoard.markDone(ct.id)
    check(closedBoard.closeQueue(cq.id), "关闭队列")
    eq(closedBoard.queue(cq.id)?.state, QueueState.closed, "状态是 closed")
    let closedHeader = QueueHeaderModel.build(closedBoard.queue(cq.id)!, board: closedBoard, collapsed: false)
    eq(closedHeader.stateKey, "tasks.queue.state.closed", "关闭态文案")
    check(!closedHeader.canStart, "关闭后不能启动")
    check(!closedHeader.canEdit, "关闭后不能改设置")
    check(!closedHeader.canClose, "不能重复关闭")
    check(!closedHeader.canOpenPR, "关闭后不能发布")
    let extra = TaskItem.manual(title: "Extra", id: "manual-gg204040")
    closedBoard.tasks.append(extra)
    check(!closedBoard.enqueue(taskID: extra.id, into: cq.id), "关闭后不能追加任务")

    // 还有活在等的队列照旧：设置与删除都在（失败任务的清理就走这条路）。
    let liveQueue = board.createQueue(name: "Busy", branch: "feature/y", autoPR: false)
    _ = board.enqueue(taskID: t2.id, into: liveQueue.id)
    let liveHeader = QueueHeaderModel.build(board.queue(liveQueue.id)!, board: board, collapsed: false)
    check(liveHeader.canEdit, "还在排队的队列可以改设置")
    check(liveHeader.canDelete, "也可以删除")
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

section("详情里的汇报：任务结束后写回卡片（会话删了也还在）")
do {
    var board = TaskBoard()
    let task = TaskItem.manual(title: "改 README", body: nil, id: "manual-rr101010")
    board.tasks = [task]
    board.markRunning(task.id)
    board.markDone(task.id, report: "重写了安装段；文档类没有可跑测试，用 markdownlint 校验过。")

    let card = TaskCardModel.build(board.task(task.id)!, board: board, expanded: true, githubRepo: false)
    check(card.detail.contains(L10n.tr("tasks.detailReport")), "详情里有「汇报」这一行")
    check(card.detail.contains("重写了安装段"), "汇报正文也在")
    check(board.task(task.id)?.sessionId == nil, "这里连会话都没有 —— 汇报仍然读得到")

    // 没有汇报的任务不该凭空多出一行。
    var bare = TaskBoard()
    let quiet = TaskItem.manual(title: "没汇报", id: "manual-rr102020")
    bare.tasks = [quiet]
    let quietCard = TaskCardModel.build(bare.task(quiet.id)!, board: bare, expanded: true, githubRepo: false)
    check(!quietCard.detail.contains(L10n.tr("tasks.detailReport")), "没有汇报就不显示这一行")
}

section("队列头：开 PR 失败时把原因写在按钮的 tooltip 上")
do {
    var board = TaskBoard()
    let task = TaskItem.manual(title: "One", id: "manual-rr103030")
    board.tasks = [task]
    let queue = board.createQueue(name: "Lane", branch: "feature/x", autoPR: true)
    _ = board.enqueue(taskID: task.id, into: queue.id)
    board.markRunning(task.id)
    board.markDone(task.id)
    let idle = QueueHeaderModel.build(board.queue(queue.id)!, board: board, collapsed: false)
    eq(idle.prErrorKey, nil, "没失败过就没有原因")
    check(idle.canOpenPR, "完成的队列给「开 PR」按钮")

    _ = board.setQueuePRError(queue.id, "tasks.errPR")
    let failed = QueueHeaderModel.build(board.queue(queue.id)!, board: board, collapsed: false)
    eq(failed.prErrorKey, "tasks.errPR", "失败原因跟着队列走到卡片上")
    check(failed.canOpenPR, "按钮还在：可以再开一次")
    eq(failed.prUrl, nil, "失败时不会留下假的 PR 链接")
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
    eq(header.stateKey, "tasks.queue.state.draft", "a fresh queue is draft (等待启动), not paused")
    eq(header.tone, TaskTone.warning, "a waiting queue reads as actionable")
    eq(header.queuedCount, 2, "two tasks are waiting")
    eq(header.startHintKey, "tasks.queue.start", "draft offers 开始, not 继续")
    check(header.canStart, "开始 is offered while tasks wait")
    check(!header.reportsToSession, "no originating session → no report marker")
    board.local.queueSessions[queue.id] = "session-x"
    header = QueueHeaderModel.build(board.queue(queue.id)!, board: board, collapsed: false)
    check(header.reportsToSession, "a queue created by a session shows the 回传 marker")
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

section("任务改变了工作区的形状：重新识别（「初始化 git 仓库」曾经和提示词打架）")
do {
    // 之前不是仓库，现在是：头部那句话、队列表单的分支字段、全部处理的措辞全都作废。
    let becameGit = TaskWorkspaceShape.change(wasGit: false, hadRemote: false,
                                              isGitNow: true, hasRemoteNow: false)
    eq(becameGit?.becameGit, true, "认出「现在是 git 仓库了」")
    eq(becameGit?.messageKey, "tasks.gitAppeared", "并且有话说（状态行）")

    // 仓库一直是仓库，只是多了个 GitHub 远端：只提远端这件事。
    let becameRemote = TaskWorkspaceShape.change(wasGit: true, hadRemote: false,
                                                 isGitNow: true, hasRemoteNow: true)
    eq(becameRemote?.becameRemote, true, "认出「现在有 GitHub 远端的了」")
    eq(becameRemote?.messageKey, "tasks.remoteAppeared", "说的是远端，不是仓库")

    // 一次同时变化的（git init + git remote add）优先说仓库 —— 那是更根本的那条。
    let both = TaskWorkspaceShape.change(wasGit: false, hadRemote: false,
                                        isGitNow: true, hasRemoteNow: true)
    eq(both?.messageKey, "tasks.gitAppeared", "两条同时成立时说仓库")

    // 什么都没变：不该重建 runner，也不该在状态行上说话。
    check(TaskWorkspaceShape.change(wasGit: true, hadRemote: true,
                                    isGitNow: true, hasRemoteNow: true) == nil,
          "一直是 GitHub 仓库：什么都不做")
    check(TaskWorkspaceShape.change(wasGit: false, hadRemote: false,
                                    isGitNow: false, hasRemoteNow: false) == nil,
          "仍然不是仓库：什么都不做")
    // 远端消失（或仓库被删）不是「形状变化」，不该把工作区重新识别一遍。
    check(TaskWorkspaceShape.change(wasGit: true, hadRemote: true,
                                    isGitNow: true, hasRemoteNow: false) == nil,
          "远端没了不重新识别（那是另一个话题）")
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
    // 完成的手动任务没有主操作：PR 是队列的产物，队列头上有按钮（用户 2026-09-27）。
    eq(card.primaryKey == nil, true, "已完成的手动任务：没有主按钮")
    eq(card.primaryAction == nil, true, "也没有主操作可执行")

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
    // 没有 PR 也一样：卡片的主操作是「打开 Issue」——有没有 PR 是队列的事（2026-09-27）。
    eq(card.primaryKey, "tasks.detailOpenIssue", "主操作是 打开 Issue（与 PR 无关）")
    check(card.primaryAction == .openIssue, "并且它真的打开 issue")
    check(card.canCommentClose, "评论并关闭仍然可用 —— 它并不需要 PR 链接")

    // 有 PR 时主操作不变：那一枚属于队列头，卡片这里不会因此多出/少掉什么。
    board.markDone(issue.id, prUrl: "https://github.com/o/r/pull/9")
    card = TaskCardModel.build(board.task(issue.id)!, board: board, expanded: true, githubRepo: true)
    eq(card.primaryKey, "tasks.detailOpenIssue", "有 PR 也不改主操作")
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
    eq(card.meta.first, "tasks.card.runningFor(1:05,60)",
       "而且排在最前面（「是不是卡住了」是运行时最想问的），并带上超时上限")

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

section("队列表单的「基于分支」跟着工作区自己的默认分支")
do {
    var form = QueueComposerModel.create().forWorkspace(git: true, pr: true, defaultBase: "develop")
    eq(form.defaultBaseBranch, "develop", "表单知道工作区的默认分支")
    eq(form.baseBranch, "develop", "并预填进去（看得见、可改）")

    form = form.typed(name: "Lane", branch: "", baseBranch: "", autoPR: false)
    eq(form.normalizedBaseBranch, "develop", "留空时回落到它，而不是硬编码 main")
    eq(form.typed(name: "Lane", branch: "", baseBranch: "release", autoPR: false).normalizedBaseBranch,
       "release", "手填的优先")

    // 队列设置：仍然显示队列自己存的那个基线（不是工作区的默认分支）。
    let queue = TaskQueue(id: "q-9001", name: "Lane", branch: "feature/lane", baseBranch: "release")
    let settings = QueueComposerModel.edit(queue, prAvailable: true, gitAvailable: true,
                                          defaultBaseBranch: "develop")
    eq(settings.baseBranch, "release", "队列自己的基线原样预填")
    eq(settings.defaultBaseBranch, "develop", "工作区默认分支仍然带着（清空字段时回落用）")
    eq(settings.typed(name: "Lane", branch: "feature/lane", baseBranch: "", autoPR: false).normalizedBaseBranch,
       "develop", "清空后就回落到工作区的默认分支")
}

section("处理按钮：看的是「有没有待办」，不是「有没有 GitHub」")
do {
    var board = TaskBoard()
    let issue = TaskItem.github(number: 5, title: "Issue five")
    let manual = TaskItem.manual(title: "Mine", id: "manual-aa001111")
    board.tasks = [issue, manual]

    var model = TasksRunAllModel.build(board, githubAvailable: true)
    eq(model.issueCount, 1, "一个 issue 待处理")
    eq(model.manualCount, 1, "一个手动任务待处理")
    check(model.enabled, "有待办就能点")
    // tooltip 只承担两件事：说清这个图标按钮做什么，或者它为什么不能点。
    eq(model.tooltip, "tasks.runAllHint", "提示就是这个按钮的文案")
    check(!model.tooltip.contains("runAllInfo"), "计数不进 tooltip —— 统计信息卡第一行已经有了")
    check(!model.tooltip.contains("PR"), "PR 策略也不进 tooltip —— 那是确认框的事")
    // 计数与策略都在用户真要下决定的那一刻：确认框。
    check(model.confirmationText.contains("runAllInfo(2)"), "确认框正文带计数")
    check(model.confirmationText.contains("runAllInfoWithPR"), "并说明队列跑完会开 PR")

    // 非 GitHub 工作区：只有手动任务待办时「处理」依然可用 —— 这正是这次要改的点。
    var manualOnly = TaskBoard()
    manualOnly.tasks = [TaskItem.manual(title: "Mine", id: "manual-aa002222")]
    model = TasksRunAllModel.build(manualOnly, githubAvailable: false)
    check(model.enabled, "非 GitHub 工作区里「处理」仍然可用（手动任务不需要 GitHub）")
    eq(model.tooltip, "tasks.runAllHint",
       "提示不变：它只说按钮做什么（工作区是不是 GitHub，头部那行已经写了）")
    check(model.confirmationText.contains("runAllInfoNoPR"), "确认框按非 GitHub 的说法")
    check(!model.confirmationText.contains("runAllInfoWithPR"), "不会同时出现「会开 PR」")

    // 非 git 目录：队列根本不带分支，确认框也不能承诺分支 / PR。
    var plain = TaskBoard()
    plain.tasks = [TaskItem.manual(title: "Mine", id: "manual-aa004444")]
    model = TasksRunAllModel.build(plain, githubAvailable: false, gitAvailable: false)
    check(model.enabled, "非 git 目录里「处理」同样可用")
    check(model.confirmationText.contains("runAllInfoNoGit"), "确认框说「不切分支、也不开 PR」")
    check(!model.confirmationText.contains("runAllInfoWithPR"), "不会承诺 PR")
    check(!model.confirmationText.contains("runAllInfoNoPR"), "也不会说「只切分支」")
    eq(model.tooltip, "tasks.runAllHint", "tooltip 依旧只写按钮做什么")

    // 没有待办：禁用（顺带修掉「点了没反应」）。
    model = TasksRunAllModel.build(TaskBoard(), githubAvailable: true)
    check(!model.enabled, "没有待办就禁用")
    eq(model.tooltip, "tasks.runAllNone", "禁用时提示说明为什么不能点")
    eq(model.confirmationText, "tasks.runAllNone", "确认框正文同样只有这一句")

    // 队列被删掉之后的失败 / 已取消任务：它们已经「自己站着」，批量必须带上 ——
    // 否则用户看到的是「失败的还在失败，而全部处理不认它们」。
    var orphanBoard = TaskBoard()
    let orphan = TaskItem.manual(title: "Failed one", id: "manual-aa005555")
    let orphanCancelled = TaskItem.manual(title: "Cancelled one", id: "manual-aa006666")
    orphanBoard.tasks = [orphan, orphanCancelled]
    let goneQueue = orphanBoard.createQueue(name: "Lane")
    _ = orphanBoard.enqueue(taskID: orphan.id, into: goneQueue.id)
    _ = orphanBoard.enqueue(taskID: orphanCancelled.id, into: goneQueue.id)
    orphanBoard.markRunning(orphan.id)
    _ = orphanBoard.markFailed(orphan.id, error: TaskFailure.timeout.rawValue)
    orphanBoard.markRunning(orphanCancelled.id)
    orphanBoard.markCancelled(orphanCancelled.id)
    model = TasksRunAllModel.build(orphanBoard, githubAvailable: false)
    eq(model.manualCount, 0, "还在队列里 → 不归批量管（泳道自己的重试 / 跳过并继续）")
    _ = orphanBoard.removeQueue(goneQueue.id)
    model = TasksRunAllModel.build(orphanBoard, githubAvailable: false)
    eq(model.manualCount, 2, "队列删掉之后，失败的与被取消的都归批量管")
    check(model.enabled, "所以按钮亮着")
    check(TasksRunAllModel.isStartable(orphan, board: orphanBoard), "isStartable 也这么说")
    check(TasksRunAllModel.isStartable(orphan, board: TaskBoard()), "队列记录不在了同样算「自己站着」（陈旧 queueId 不会把它藏起来）")

    // 跑过的、已关闭的都不算待办。
    var finished = TaskBoard()
    let done = TaskItem.manual(title: "Done", id: "manual-aa003333")
    let closedIssue = TaskItem.github(number: 9, title: "Closed")
    finished.tasks = [done, closedIssue]
    finished.markRunning(done.id)
    finished.markDone(done.id, prUrl: nil)
    finished.markClosed(closedIssue.id)
    model = TasksRunAllModel.build(finished, githubAvailable: true)
    eq(model.total, 0, "已完成 / 已关闭的都不算待办")
    check(!model.enabled, "所以按钮是灰的")
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
section("工作流：发布按钮与可用性跟着队列的模式走")
do {
    // The workspace's usual mode is a RECOMMENDATION, never enforced.
    eq(QueueIntegration.recommended(isGit: true, hasGitHubRemote: true), .pr,
       "GitHub 远端推荐 PR")
    eq(QueueIntegration.recommended(isGit: true, hasGitHubRemote: false), .merge,
       "普通 git 仓库推荐合并并推送")
    eq(QueueIntegration.recommended(isGit: false, hasGitHubRemote: false), .none,
       "非 git 目录推荐「无」（没什么可发布的）")

    var board = TaskBoard()
    let task = TaskItem.manual(title: "One", id: "manual-0090abcd")
    board.tasks = [task]
    let queue = board.createQueue(name: "Lane", integration: .merge)
    _ = board.enqueue(taskID: task.id, into: queue.id)
    board.markRunning(task.id)
    board.markDone(task.id, prUrl: nil)

    // merge 覆盖：不需要 GitHub 远端，有分支就能发布。
    var header = QueueHeaderModel.build(board.queue(queue.id)!, board: board, collapsed: false,
                                        prAvailable: false, integration: .merge)
    eq(header.integration, .merge, "header 记住解析后的工作流")
    check(header.canOpenPR, "merge 只需要分支：非 GitHub 工作区也能发布")
    eq(header.integration.publishSymbol, "arrow.triangle.merge", "发布图标跟着模式")
    eq(header.integration.publishHintKey, "tasks.queue.mergePush", "发布文案跟着模式")

    // pr 模式仍然要 GitHub。
    header = QueueHeaderModel.build(board.queue(queue.id)!, board: board, collapsed: false,
                                    prAvailable: false, integration: .pr)
    check(!header.canOpenPR, "pr 模式没有 GitHub 远端就不能发布")

    // 「无」：明确不收尾，即使有分支也不给发布按钮。
    header = QueueHeaderModel.build(board.queue(queue.id)!, board: board, collapsed: false,
                                    prAvailable: true, integration: .none)
    check(!header.canOpenPR, "工作流「无」时没有发布按钮")

    // 关闭的队列是手动终态：不能再发布。
    _ = board.closeQueue(queue.id)
    header = QueueHeaderModel.build(board.queue(queue.id)!, board: board, collapsed: false,
                                    prAvailable: true, integration: .merge)
    check(!header.canOpenPR, "关闭的队列不能发布")
}
section("收尾结果写在队列卡上")
do {
    var board = TaskBoard()
    let task = TaskItem.manual(title: "One", id: "manual-0091abcd")
    board.tasks = [task]
    let queue = board.createQueue(name: "Lane")
    _ = board.enqueue(taskID: task.id, into: queue.id)
    _ = board.setQueueIntegrationNote(queue.id, "已合并并推送到 origin/main")
    let header = QueueHeaderModel.build(board.queue(queue.id)!, board: board, collapsed: false)
    eq(header.integrationNote, "已合并并推送到 origin/main", "收尾结果带到卡上")
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
    eq(items.dropFirst().map { $0.title }, ["Second lane", "Docs Cleanup"],
       "已有队列按创建时间倒序（最新在前）排在后面")
    eq(items.dropFirst().map { $0.queueID }, board.queueChoices().map { $0.id },
       "每一行都带着它要入队的队列 id")
    eq(items.dropFirst().first?.branch, "feature/second-lane", "行里带上该队列的分支")

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
