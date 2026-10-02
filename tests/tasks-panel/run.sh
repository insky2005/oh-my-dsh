#!/bin/bash
# Headless tests for the Tasks panel logic layer:
#   - TasksCore.swift   the task/queue model, branch naming, queue operations,
#                       summary counts and restart recovery (pure value type);
#   - TasksStore.swift  the four-file persistence under .dsh/tasks/
#                       (index.json v1 shape / manual.json / queues.json /
#                       local.json with its legacy session keys);
#   - TasksRunner.swift the serial queue runner: git branch entry, dsh session,
#                       prompt, push check, queue-level PR, cancel/retry/skip,
#                       restart recovery — driven by a scripted git + dsh;
#   - TaskCardView.swift / TaskInlineForms.swift
#                       the two INLINE forms (新建任务 / 新建队列 and their edit
#                       modes) and the card + queue-header layout, laid out for
#                       real under AppKit but with no window.
# No window, no dsh server. Usage: tests/tasks-panel/run.sh
set -euo pipefail
cd "$(dirname "$0")"
SRC=../../platforms/macos/src
mkdir -p ../../.build/module-cache
CACHE="$(cd ../../.build/module-cache && pwd)"

echo "--- tasks model + store (queues / persistence / restart recovery) ---"
TMP="$(mktemp -d)"
cp "$SRC/TasksCore.swift" "$TMP/TasksCore.swift"
cp "$SRC/TasksStore.swift" "$TMP/TasksStore.swift"
cp model-tests.swift "$TMP/main.swift"   # top-level code needs the main.swift name
swiftc -swift-version 5 -module-cache-path "$CACHE" \
  -o "$TMP/tasks-model-tests" "$TMP/TasksCore.swift" "$TMP/TasksStore.swift" "$TMP/main.swift"
"$TMP/tasks-model-tests"
rm -rf "$TMP"

echo "--- tasks runner (serial queue / branch entry / push + queue PR) ---"
TMP="$(mktemp -d)"
cp "$SRC/TasksCore.swift" "$TMP/TasksCore.swift"
cp "$SRC/TasksStore.swift" "$TMP/TasksStore.swift"
cp "$SRC/TasksRunner.swift" "$TMP/TasksRunner.swift"
cp "$SRC/TasksWorkspaces.swift" "$TMP/TasksWorkspaces.swift"   # one runner per workspace
cp "$SRC/TasksUI.swift" "$TMP/TasksUI.swift"   # TasksRunAllModel decides what a batch runs
cp stubs.swift "$TMP/stubs.swift"         # the L10n stand-in (the brief names failure reasons)
cp runner-tests.swift "$TMP/main.swift"   # top-level code needs the main.swift name
swiftc -swift-version 5 -module-cache-path "$CACHE" \
  -o "$TMP/tasks-runner-tests" "$TMP/TasksCore.swift" "$TMP/TasksStore.swift" \
  "$TMP/TasksRunner.swift" "$TMP/TasksWorkspaces.swift" "$TMP/TasksUI.swift" \
  "$TMP/stubs.swift" "$TMP/main.swift"
"$TMP/tasks-runner-tests"
rm -rf "$TMP"

echo "--- tasks list view models (badges / actions / queue header / summary) ---"
TMP="$(mktemp -d)"
cp "$SRC/TasksCore.swift" "$TMP/TasksCore.swift"
cp "$SRC/TasksUI.swift" "$TMP/TasksUI.swift"
cp stubs.swift "$TMP/stubs.swift"          # the L10n stand-in
cp ui-tests.swift "$TMP/main.swift"        # top-level code needs the main.swift name
swiftc -swift-version 5 -module-cache-path "$CACHE" \
  -o "$TMP/tasks-ui-tests" "$TMP/TasksCore.swift" "$TMP/TasksUI.swift" \
  "$TMP/stubs.swift" "$TMP/main.swift"
"$TMP/tasks-ui-tests"
rm -rf "$TMP"

echo "--- task views (inline forms: create / edit, card + queue header layout) ---"
TMP="$(mktemp -d)"
cp "$SRC/TasksCore.swift" "$TMP/TasksCore.swift"
cp "$SRC/TasksUI.swift" "$TMP/TasksUI.swift"
cp "$SRC/TaskCardView.swift" "$TMP/TaskCardView.swift"
cp "$SRC/TaskInlineForms.swift" "$TMP/TaskInlineForms.swift"
cp "$SRC/PanelSurface.swift" "$TMP/PanelSurface.swift"   # the real color tokens
cp stubs-ui.swift "$TMP/stubs-ui.swift"                  # the chrome + short-label stand-ins
cp form-tests.swift "$TMP/main.swift"                    # top-level code needs the main.swift name
swiftc -swift-version 5 -module-cache-path "$CACHE" -framework AppKit \
  -o "$TMP/tasks-form-tests" "$TMP/"*.swift
"$TMP/tasks-form-tests"
rm -rf "$TMP"

echo "--- tasks panel local API (task-todo skill: /api/tasks/* routing + parsing) ---"
TMP="$(mktemp -d)"
cp "$SRC/TasksCore.swift" "$TMP/TasksCore.swift"
cp "$SRC/TasksAPI.swift" "$TMP/TasksAPI.swift"   # pure model: routing, parsing, workspace resolution
cp api-tests.swift "$TMP/main.swift"             # top-level code needs the main.swift name
swiftc -swift-version 5 -module-cache-path "$CACHE" \
  -o "$TMP/tasks-api-tests" "$TMP/TasksCore.swift" "$TMP/TasksAPI.swift" "$TMP/main.swift"
"$TMP/tasks-api-tests"
rm -rf "$TMP"

echo "--- tasks panel source guards ---"
# The panel must NOT hand-roll session creation: the shared helper carries the
# documented workspaceId→cwd fallback (and tests/dsh-rpc pins it). A private copy
# shipped once and made EVERY task fail with tasks.errSession whenever the stored
# workspaceId was stale (workspace/not-found, no fallback).
if grep -q "DshWebRPC.sessionCreate" ../../platforms/macos/src/IssueRunnerPanel.swift; then
  echo "FAIL - IssueRunnerPanel must use DshWorkspaceOps.createSession, not DshWebRPC.sessionCreate"
  exit 1
fi
echo "ok - the tasks panel delegates session creation to DshWorkspaceOps"

# The runner env must read the dsh web port AT CALL TIME, never freeze it.
# The panel builds that env the moment it adopts a workspace — ~6s BEFORE
# `dsh web` is up, when server.port is still the default 3080 — so a captured
# `let port = serverPortProvider?() ?? 3080` pointed every session RPC of that
# runner at a port nothing listens on: EVERY task failed with tasks.errSession
# while the real server answered fine on its own port. The runner is rebuilt only
# when the workspace PATH changes, so the dead port lasted the whole app run.
if grep -qE 'Self\.(renameSession|promptSession|sessionState|cancelSession)\(port: port,' ../../platforms/macos/src/IssueRunnerPanel.swift \
   || ! grep -q 'let portOf: () -> Int = { \[weak self\] in' ../../platforms/macos/src/IssueRunnerPanel.swift; then
  echo "FAIL - the runner env must resolve the dsh web port per call (portOf()), not freeze it"
  exit 1
fi
echo "ok - the runner env resolves the dsh web port per call"

# The prompt must describe the workspace AS IT IS WHEN THE TASK STARTS. A workspace
# CONVERTS — git init turns a plain directory into a repository, git remote add turns
# that into a GitHub one — and the first task of a queue may be the one doing the
# converting: the task after it must not be told the old story. A queue never goes idle
# between its own tasks, so the panel's re-detection (recheckWorkspaceShape → invalidate
# → adoptWorkspace) cannot step in; probing again inside the promptText closure is the
# only thing that can. Freezing it in makeEnv (the gitAvailable: isGit this replaced)
# left task 2 of a converting queue claiming 「这不是 git 仓库」 for the rest of the queue.
if ! grep -q 'let shape = Self.repoShape(path: repoRoot)' ../../platforms/macos/src/IssueRunnerPanel.swift; then
  echo "FAIL - the task prompt must probe the workspace shape per prompt (Self.repoShape(path:)), not freeze it"
  exit 1
fi
if ! grep -q 'static func repoShape(path: String) -> TaskRepoShape' ../../platforms/macos/src/IssueRunnerPanel.swift; then
  echo "FAIL - the panel must keep the one probe that answers 非 git / git / GitHub for the prompt"
  exit 1
fi
echo "ok - the task prompt probes the workspace shape per prompt"

# 目标仓库集合必须运行期重探测，禁止从 makeEnv 的 env 抄一份：工作区会加/减仓库，
# 提示词必须描述 runner 真正会进入的那组仓库。promptText 现场 detectRepoSet +
# TasksRunner.resolveTargets（queue.repos 优先、否则 primary），两处共用一个解析入口。
if ! grep -q 'TasksRunner.resolveTargets(queue: queue, repos: liveSet.repos' ../../platforms/macos/src/IssueRunnerPanel.swift; then
  echo "FAIL - 提示词的目标仓库必须运行期重探测（detectRepoSet + TasksRunner.resolveTargets），不能从 env 抄一份"
  exit 1
fi
# runner 侧同理：pump 必须用 env.repoSetProvider 现场重探，不能只吃 adopt 时的快照。
if ! grep -q 'let live = repoSetProvider?()' ../../platforms/macos/src/TasksRunner.swift \
   || ! grep -q 'repoSetProvider: { Self.detectRepoSet(repoRoot) }' ../../platforms/macos/src/IssueRunnerPanel.swift; then
  echo "FAIL - pump 的目标仓库必须经 env.repoSetProvider 运行期重探（design §5.1）"
  exit 1
fi
echo "ok - 目标仓库集合在提示词与 pump 里运行期重探测"

# 队列表单里选中的目标仓库必须写回队列：queue.repos 是 P2 预检的真实入口，
# 表单只画选择区、提交时不落库的话，多仓库预检永远只会拿到 primary。编辑时还要
# 按已存的 repos 回填（selected: queue.repos），否则保存会把选择重置成 primary。
if ! grep -q 'repos: composer.storedRepoIDs' ../../platforms/macos/src/IssueRunnerPanel.swift \
   || ! grep -q 'repos: .some(composer.storedRepoIDs)' ../../platforms/macos/src/IssueRunnerPanel.swift \
   || ! grep -q 'selected: queue.repos' ../../platforms/macos/src/IssueRunnerPanel.swift; then
  echo "FAIL - 队列表单的目标仓库必须写回队列（create/update）并在编辑时回填（queue.repos）"
  exit 1
fi
echo "ok - 队列表单的目标仓库写回队列（create/update）并在编辑时回填"

# The 处理 button answers a BOARD question (「有待办吗」), so it has to be re-derived
# whenever the board changes — not only when the WORKSPACE does. It used to be set
# only in updateLabels(), which runs on adopt / language switch: creating a task (the
# one thing that makes 有待办 true) left the button greyed out, and it stayed grey until
# the user switched workspace and back. The action itself was never broken (runAllTapped
# re-derives the model) — the button just never said so.
if ! awk '/^    private func syncFromBoard\(\) \{$/,/^    \}$/' ../../platforms/macos/src/IssueRunnerPanel.swift | grep -q 'updateRunAllButton('; then
  echo "FAIL - syncFromBoard must re-derive the 处理 button (updateRunAllButton) on every board change"
  exit 1
fi
echo "ok - the run-all button is re-derived from the board on every change"

# callAsyncJavaScript turns the arguments into LOCAL VARIABLES of the body, so a body
# that mentions an argument nobody passed throws a ReferenceError — the bridge reported
# it as 「发生了JavaScript异常」. That is exactly what made 「打开会话」 a dead button from the
# TASKS panel (which has no workspace name to offer) while the very same bridge worked
# from the projects panel (which always has one). The app log said it plainly; the UI
# said nothing at all. Both halves are pinned here: the argument is always passed, and
# a bridge error is REPORTED instead of only logged.
if ! grep -q 'args\["workspaceName"\] = ' ../../platforms/macos/src/main.swift; then
  echo "FAIL - openDSHSession must always pass workspaceName (empty when unknown): a missing argument throws in the page"
  exit 1
fi
if ! grep -q 'case "bridge-error":' ../../platforms/macos/src/main.swift; then
  echo "FAIL - a bridge error must reach the user (reportOpenFailure reason bridge-error), not just the log"
  exit 1
fi
echo "ok - the session opener passes every argument and reports bridge errors"

# 提示词只允许有**一份要求清单**：issue 与手动任务都走 TaskPrompts.requirements。
# 各写一份的那段历史，正是 issue 任务被留在「会 push、PR 由面板开」旧政策里的原因
# （2026-09-27 对齐前，issue 侧还要求加载 issue-resolve 技能）。
SHARED_REQUIREMENTS=$(grep -cF 'requirements(branch: branch, queueName: queueName, base: base, targets: targetList)' ../../platforms/macos/src/TasksRunner.swift)
if [ "$SHARED_REQUIREMENTS" != "2" ]; then
  echo "FAIL - issue 与手动任务的提示词必须共用 TaskPrompts.requirements（找到 $SHARED_REQUIREMENTS 处调用，期望 2）"
  exit 1
fi
# 只查**提示词字符串**：注释里提它是解释历史，提示词里提它才是又把它请回来。
if grep -qF '请加载 issue-resolve' ../../platforms/macos/src/TasksRunner.swift ../../platforms/macos/src/IssueRunnerPanel.swift \
   || grep -qF 'skills/issue-resolve' ../../platforms/macos/src/TasksRunner.swift ../../platforms/macos/src/IssueRunnerPanel.swift; then
  echo "FAIL - 提示词不得再指向已退役的 issue-resolve 技能"
  exit 1
fi
echo "ok - issue 与手动任务共用同一份要求清单，且不再引用退役技能"

# P1 完成校验：真实面板 env 必须开启任务完成 marker 门槛，runner 必须按本次尝试的
# marker 判定 done。关掉它 = 「断网导致 turn 结束」又被当成「任务完成」。
if ! grep -q 'requireCompletionMarker: true' ../../platforms/macos/src/IssueRunnerPanel.swift \
   || ! grep -q 'func makeTaskMarker' ../../platforms/macos/src/TasksRunner.swift \
   || ! grep -q 'markerConfirmed(in:' ../../platforms/macos/src/TasksRunner.swift \
   || ! grep -q 'case unverified = "tasks.errUnverified"' ../../platforms/macos/src/TasksCore.swift; then
  echo "FAIL - P1 完成协议：面板必须开启 requireCompletionMarker，runner 必须实现 marker 判定"
  exit 1
fi
echo "ok - P1 完成协议：任务完成 marker 由 runner 生成并作为 done 的唯一依据"

# P2 待确认：独立状态 + 卡片出口（重试 / 标记完成）。复用 .failed 的话「失败」的措辞
# 偏重，而且无法把「用户一键放行」和「真失败」区分开。
if ! grep -q 'case needsReview' ../../platforms/macos/src/TasksCore.swift \
   || ! grep -q 'func markNeedsReview' ../../platforms/macos/src/TasksCore.swift \
   || ! grep -q 'func confirmDone(taskID:' ../../platforms/macos/src/TasksRunner.swift \
   || ! grep -q 'case .needsReview' ../../platforms/macos/src/TasksUI.swift \
   || ! grep -q 'tasks.detailConfirmDone' ../../platforms/macos/src/TaskCardView.swift; then
  echo "FAIL - P2 待确认：必须有独立 needsReview 状态、标记完成动作与卡片出口"
  exit 1
fi
echo "ok - P2 待确认：独立状态 + 重试 / 标记完成"

# P3 完成通知诚实化：队列汇总必须把「完成 / 待确认」分开计数，不得再无条件输出
# 「已全部完成」。状态机（P1/P2）已经给出判定，汇总只负责如实翻译成计数与文案。
if ! grep -q 'func completionCounts' ../../platforms/macos/src/TasksRunner.swift \
   || ! grep -qF 'counts.needsReview == 0' ../../platforms/macos/src/TasksRunner.swift \
   || ! grep -qF '完成 \(counts.done) 条 / 待确认 \(counts.needsReview) 条（共 \(tasks.count) 条）' ../../platforms/macos/src/TasksRunner.swift \
   || ! grep -qF 'case .needsReview: mark = "?"' ../../platforms/macos/src/TasksRunner.swift; then
  echo "FAIL - P3 完成通知：汇总必须把待确认单独计数，不再无条件报「已全部完成」"
  exit 1
fi
echo "ok - P3 完成通知：完成 / 待确认分开计数，待确认带 ? 与人工出口"

# P4 产物校验（可选）：真实面板必须开启它，runner 必须按「应产出提交」推断、并在会话
# 结束后比对基线 HEAD / 工作区改动；没有产物时降级为待确认（带 errNoCommit 原因）。
# 关掉它或删掉推断 = 「agent 什么都没干就结束」又只能靠 marker 兜底。
if ! grep -q 'verifyExpectedCommit: true' ../../platforms/macos/src/IssueRunnerPanel.swift \
   || ! grep -q 'workspaceShape: { Self.repoShape(path: repoRoot) }' ../../platforms/macos/src/IssueRunnerPanel.swift \
   || ! grep -q 'func infersCommitExpectation' ../../platforms/macos/src/TasksRunner.swift \
   || ! grep -q 'func hasProduct' ../../platforms/macos/src/TasksRunner.swift \
   || ! grep -q 'case noCommit = "tasks.errNoCommit"' ../../platforms/macos/src/TasksCore.swift; then
  echo "FAIL - P4 产物校验：面板必须开启 verifyExpectedCommit，runner 必须实现 expectsCommit 推断与产物校验"
  exit 1
fi
echo "ok - P4 产物校验：expectsCommit 推断 + 基线比对，无产物降级待确认"

# 任务面板的每一项设置都必须按工作区存：一个全局键会把某个工作区的选择泄进所有工作区
# （「交付成功后自动关闭队列」曾写全局 tasksAutoCloseOnPublish，于是每个工作区都显示勾上）。
IP=../../platforms/macos/src/IssueRunnerPanel.swift
if ! grep -q 'tasksAutoCloseOnPublishByWorkspace' "$IP" \
   || grep -q 'forKey: autoCloseOnPublishKey\|"tasksAutoCloseOnPublish"' "$IP" \
   || ! grep -q 'storedAutoCloseOnPublish(forWorkspace' "$IP" \
   || ! grep -q 'workspaceSettingsKey' "$IP" \
   || ! grep -q 'setStoredAutoCloseOnPublish(settings.autoCloseOnPublish, forWorkspace: path)' "$IP"; then
  echo "FAIL - 面板设置必须全部按工作区隔离（自动关闭开关不得再用全局键）"
  exit 1
fi
echo "ok - 面板设置按工作区隔离（autoCloseOnPublish 用工作区映射）"

# issue 归属仓库（design §9）：必须按工作区存（默认跟随主仓库），并且真实写进
# issue 任务的 auto queue —— 只画提示、不落 repos 的话，队列仍然按 primary 跑。
if ! grep -q 'tasksIssueRepoByWorkspace' "$IP" \
   || ! grep -q 'runner.startIssueTask(task.id, repos:' "$IP" \
   || ! grep -q 'repos: repos)' ../../platforms/macos/src/TasksRunner.swift; then
  echo "FAIL - issue 归属仓库必须按工作区存并写进 issue 任务的 auto queue（queue.repos）"
  exit 1
fi
echo "ok - issue 归属仓库按工作区存并写进 issue 任务的 auto queue"

echo "tasks-panel tests passed"
