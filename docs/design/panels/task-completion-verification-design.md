# 任务完成校验设计（Task Completion Verification）

> 状态：草案（问题已定位，方案未实现）· 日期：2026-10-02 · 关联：docs/design/panels/issue-runner-design.md、docs/design/panels/tasks-queue-session-loop-design.md、platforms/macos/src/TasksRunner.swift
> 来源：2026-10-02 多仓库队列实测（P2/P3/P4 断网未完成却被标记「已完成」）

## 1. 现象

多仓库工作区队列运行时网络中断：任务 **P3 / P4 实际没有任何提交与实现**，P2 也只提交了一部分、没有最终汇报；但面板把三条都标成「已完成」，队列汇总还报「**6/6 已完成**」。用户据此以为工作做完，直到核对分支提交才发现缺失。

这是一个会**让人误判交付**的问题，比普通报错更危险。

## 2. 根因

runner 把「dsh 会话不再 running」直接当成「任务完成」，全程没有对「完成」做任何证据校验：

1. `step()` 看到会话状态 `.idle` 就调 `finish()`，注释原文就是「dsh lists the session and says it is done: the task is over」（`platforms/macos/src/TasksRunner.swift` 的 `step`）。
2. `finish()` 里 `var outcome: FinishOutcome = .done` 是**写死的初值**，之后只读取汇报、从不依据证据改判；`applyFinish(.done)` 直接 `markDone`（同上文件 `finish` / `applyFinish`）。
3. `sessionState` 只读 dsh 会话列表里的 `running` 布尔（`platforms/macos/src/IssueRunnerPanel.swift` 的 `sessionState`）——**dsh 不提供「为什么结束」**，网络断掉导致 turn 结束，和正常完成在列表里长得一模一样。
4. 既有的 `missingPolls`（会话持续不在列表 → 判 `interrupted`）只覆盖「会话消失」，覆盖不了本次这种「会话还在、只是 idle」。
5. `reconcileAfterRestart` 只覆盖 App 重启，覆盖不了单次会话被网络打断。

一句话：**「会话结束」被当成了「任务完成」。**

## 3. 目标与非目标

**目标**

1. 任务只有在拿到**可机检的完成证据**时才判 `.done`；
2. 证据不足时，任务进入「待确认」，**队列暂停**，不继续跑后面的任务、不自动开 PR；
3. 队列完成通知如实汇报（不再一律「全部完成」）；
4. 正常完成的任务与现有流程零额外负担。

**非目标**

- 不校验任务内容的「质量」或验收标准本身（那是人/AI 审查的事）；
- 不修改 dsh 上游，不依赖 dsh 提供结束原因（可作为增强信号）；
- 不因为「没有提交」就一概判失败（有的任务确实不产提交）。

## 4. 方案

### 4.1 完成协议 marker（主路径）

- 任务提示词要求会话在**最后单独一行**输出一个**每任务唯一**的完成标记（形如 `DSH-TASK-DONE-XXXXXXXX`），并保留现有「必须在结束时汇报」的要求（`TaskPrompts.reportRequirement`）。
- `finish()` 读取 `sessionReport` 后：**只有拿到该 marker 才判 `.done`**；否则进入「待确认」（§4.2）。
- 复用 finalize 已有机制：交付会话已经用 `TasksRunner.makeMarker()` 做「只采纳本次 turn 的汇报」（`platforms/macos/src/TasksRunner.swift` 的 `makeFinalizeRun` / `makeMarker`）。本设计只是把它从「交付会话」扩展到「任务会话」。
- marker 由 runner 生成（带任务 id 或 UUID），随 prompt 注入；不写进卡片正文。

### 4.2 「待确认」状态

会话结束但没有 marker / 汇报为空 → 任务进入**待确认**。两种落地方式：

| 方式 | 说明 | 取舍 |
|---|---|---|
| **A. 新增 `TaskState.needsReview`** | 独立状态，语义清晰：不是成功、也未必是失败 | 要动 `TaskState` 的 `isFinished` / `isQueueable` / 视图分支，改动面较大 |
| **B. 复用 `.failed` + 新 `TaskFailure.unverified`** | 记为失败，错误键 `tasks.errUnverified`；卡片额外给「标记完成」 | 改动小；但「失败」的措辞对「可能只是漏写 marker」偏重 |

建议先用 **A**（若想快速落地可先 B）。待确认的行为：

- **队列暂停**（与失败一致）：后续任务不启动，队列停在 `.paused`，**不**发完成通知、**不**自动开 PR；
- 卡片状态徽标「待确认」，动作两个：**重试**（重新跑这条任务）与**标记完成**（用户确认其实做完了，直接转 `.done`）；
- 待确认不写入队列交接简报的「已完成」段（它是未确认的）。

### 4.3 产物校验（增强，可选）

给任务加一个 `expectsCommit` 标志（按任务来源/队列类型推断，或提示词里声明）：会话结束后检查队列分支在任务开始后是否有新提交、或工作区是否有改动；没有则同样降级为待确认。

- 能抓住「agent 什么都没干就结束」这一类；
- 抓不住「干了一半」，所以它是 §4.1 的补充而不是替代。

### 4.4 完成通知诚实化（低成本兜底）

队列汇总只把**有 marker/汇报**的任务计为「完成」，其余计为「待确认」。通知文案改为「N 条完成 / M 条待确认」，不再无条件输出「已全部完成（N/N）」。即使 §4.1–4.3 暂不实现，这一条也应单独做。

### 4.5 网络异常信号（调研项）

若 dsh 的会话列表或会话日志暴露 abort / error 类结束原因，可直接判 `interrupted`，比 marker 更早、更准。当前 `sessionState` 只读 `running`，需先确认 dsh 是否提供；不提供就完全依赖 §4.1。

## 5. 数据模型

- `TaskFailure` 新增 `unverified`（L10n 键 `tasks.errUnverified`）；若走方式 A，则新增 `TaskState.needsReview`。
- `TaskItem` 记录本次尝试的 marker（以及是否已校验），用于重启恢复后仍能判断；marker 是机器私有，只进 `local.json` / 内存，不进 `index.json` 的 issue 条目正文。

## 6. UI

| 位置 | 改动 |
|---|---|
| 任务卡状态徽标 | 新增「待确认」态（与 已完成 / 失败 并列） |
| 任务卡动作 | 待确认时给「重试」+「标记完成」 |
| 队列汇总 / 完成通知 | 文案区分「完成」与「待确认」，计数不再笼统 |
| 队列头 | 待确认导致队列暂停时，说明原因 |

## 7. 兼容与风险

| 项 | 处理 |
|---|---|
| 提示词变更 | 多仓库改造要求「单仓库提示词逐字节不变」，加 marker 会破坏该断言 → 两者不要混在同一个提交里，或同步更新断言 |
| agent 漏写 marker | 误入待确认：用「标记完成」一键放行；先观察误报率再决定是否收紧 |
| marker 被复述/伪造 | 每任务唯一随机串；只认「最后一行」且只由本次 turn 采纳 |
| 历史任务无 marker | 不做回溯改判；只对新任务生效 |
| 与交付 marker 混用 | 交付会话已有自己的 marker，两套独立、互不干扰 |

## 8. 实施阶段

| 阶段 | 内容 | 价值 |
|---|---|---|
| **P1** | 任务会话 marker 协议 + `finish()` 依据 marker 判定 | 堵住「断网 = 完成」 |
| **P2** | 待确认状态 + 卡片动作（重试 / 标记完成）+ 队列暂停 | 把判断权交回用户 |
| **P3** | 完成通知诚实化 | 低成本纠偏 |
| **P4** | `expectsCommit` 产物校验（可选） | 抓「什么都没干」 |

## 9. 测试

- **运行器**：会话 idle 但汇报无 marker → 不判 done（待确认 / unverified）；有 marker → done；marker 不属于本次 turn → 不采纳；空汇报 → 待确认。
- **通知**：混合「完成 / 待确认」时的计数与文案。
- **视图模型**：待确认徽标与「标记完成 / 重试」动作；队列暂停原因。
- **兼容**：既有「会话正常结束即 done」的用例需要显式补上 marker（或标记为 legacy 路径）。

## 10. 开放问题

| # | 问题 | 建议 |
|---|---|---|
| Q1 | 待确认用新状态 `needsReview` 还是复用 `failed + errUnverified` | 新状态更准；急则先复用 failed |
| Q2 | marker 是否所有任务都要求，还是只要求「应产出提交」的任务 | 先全部要求（简单一致），观察漏写率 |
| Q3 | 是否同时要求 agent 复述验收命令与结果（可解析段） | 可作 §4.3 的补充，但不作唯一判据 |
| Q4 | 是否利用 dsh 的结束原因（§4.5） | 先调研，有则优先于 marker |

## 11. 参考

- `platforms/macos/src/TasksRunner.swift` — `step` / `finish` / `applyFinish` / `makeMarker` / `startQueueIntegration`
- `platforms/macos/src/TasksCore.swift` — `TaskState` / `TaskFailure`
- `platforms/macos/src/IssueRunnerPanel.swift` — `sessionState`（只读 running）
- `docs/design/panels/issue-runner-design.md` — 任务面板主设计
- `docs/design/panels/tasks-queue-session-loop-design.md` — 队列 × 会话回传
