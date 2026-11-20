# 任务面板：关闭队列触发历史汇报回灌

> 日期：2026-11-20
> 状态：已实施（`platforms/macos/src/TasksCore.swift` / `TasksStore.swift` / `TasksRunner.swift` + `tests/tasks-panel`，分支 `release/1.19`，hotfix v1.19.1）
> 现象版本：v1.19.0（逐任务通知随 `6a52f86` 进入 1.19.0）

## 现象

在任务面板点「关闭队列」，队列里**每个已完成任务**都会向创建该队列的会话发一条汇报；
如果队列是升级前就存在的，条数等于队列里的任务数（用户实测：关闭「事项面板」44 任务的
队列，会话里瞬间收到 44 条）。同一次启动里，两条**早就关闭**的旧队列也在第一个空闲 tick
被回灌（5 条 / 9 条）。`app.log` 证据：

```
13:05:51.470Z tasks: queue q-e55dd503 closed
13:05:51.925Z tasks: queue q-e55dd503 — 44 notification(s) sent to session-4cfad37c-…
12:57:45.913Z tasks: queue q-2033f858 — 5 notification(s) sent …
12:57:45.941Z tasks: queue q-876e43fb — 9 notification(s) sent …
```

## 根因

关闭操作本身**不发任何消息**：`TasksRunner.closeQueue` 只调 `TaskBoard.closeQueue`，把
`queue.state` 置为 `.closed`。消息来自**空闲 tick 的补发扫描** `notifyFinishedQueues()`。

那条扫描里有一条「别把历史任务一次性灌给用户」的抑制：

```swift
let isDone = queue.state == .done
let alreadyWrapped = isDone && board.local.queueNotified[queue.id] != nil
```

它把「这条队列已经收尾过」**绑在 `state == .done` 上**。于是：

1. **关闭**（`.done` → `.closed`）让 `isDone` 变 `false`，抑制失效；
2. **追加任务**（`.done` → `.draft`，并清 `queueNotified`）同样让它失效；
3. 扫描于是按「逐任务」重看一遍：`taskNotified[taskID] == nil` 就算从未通知过。

而 `taskNotified` 是 1.19.0 才引入的：在那之前，一个队列跑完只写**一条**队列级
`queueNotified`，那些终态任务**没有**逐任务标记。所以对 1.19.0 之前跑完的任务，
`taskNotified` 全空 → 全部被判定为「未通知」→ 每条各发一条。

结论：**不是关闭要汇报，而是关闭改变了队列状态，把一个只对 `.done` 生效的历史抑制关掉了。**

## 修复

1. **一次性迁移**（`TaskBoard.seedLegacyNotificationMarks` + `TasksStore.load`）：local.json
   没有 `notifyScheme`（= 1.19.1 之前的文件）时，为**有来源会话的队列里所有已终态任务**
   补写 `taskNotified` 标记，并置 `notifyScheme = 2`。补的是**标记**不是消息——这些汇报
   在旧方案下已经发过（或本来就不发），重放反而制造噪音。迁移只跑一次，之后完成的任务
   照常在使用时写标记，**重启补发**（app 在终态与回传之间退出）不受影响。
2. **关闭即静默**（`notifyFinishedQueues` 跳过 `state == .closed`）：关闭是用户的手动终态，
   没有任何「结果」要汇报；它也永远到不了 `.done`，所以那条抑制本来就不会生效。这道
   护栏让关闭在任何数据形态下都不再触发逐任务回灌。

## 验证

- `tests/tasks-panel/model-tests.swift`（+9 checks）：迁移在 `TasksStore.load` 上补标记、
  只跑一次（之后完成的任务保持未标记）、没来源会话的队列不写标记、`notifyScheme` 往返。
- `tests/tasks-panel/runner-tests.swift`（+6 checks）：关闭后空闲 tick 零消息；启动时已
  `.closed` 的旧队列零消息；迁移后追加任务不重发历史汇报；方案已存在时未标记终态任务仍
  照常补发一次。
- **反证**：临时去掉 `.closed` 跳过，两条断言立刻失败（`got 2, want 0`），证明测试真的
  咬住了这次的根因，而不是同义反复。
- 全量：`tests/tasks-panel/run.sh` **2255 项**（模型 393 + 运行器 856 + 视图模型 504 +
  视图 370 + 本地 API 132）全绿。

## 影响面

- 升级到 1.19.1 后**第一次**打开老工作区，会给历史终态任务补标记（一次性、不发消息）；
- 升级前**最后几秒**刚结束、还没来得及通知的任务会被当成历史（无法与「一个月前结束」区分，
  属于可接受的极小窗口）；
- 关闭队列从此**不产生任何会话消息**，队列卡片与报告文件照旧保留。
