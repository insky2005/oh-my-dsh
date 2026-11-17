#!/bin/bash
# Headless tests for the Workstreams panel:
#   1. the pure model (WorkstreamsCore.swift): frontmatter parsing, the five
#      stages, queues [q-...] (0..1, legacy [{id, stage}] read-compat), covered /
#      delivery blocks, validation, and create / update / stage / queues writes
#      with atomic rename + six-digit ids.
#   2. the localhost API router (WorkstreamsAPI.swift): routing, validation, error
#      codes and response shapes (no AppKit, no disk).
#   3. the pure view models (WorkstreamsUI.swift): the three-level card model,
#      the top stage filter and the empty state.
#   3.5 the stage gate (WorkstreamsStageGate.swift): per-stage machine evidence
#      and the human confirmation / back-edge gate (R10).
#   4. the queue engine (WorkstreamsQueues.swift + WorkstreamsRunner.swift): the
#      serial step/pump phase machine, the session lifecycle (create -> name ->
#      prompt -> poll -> cancel / retry), restart recovery and the
#      queues-local persistence under .dsh/workstreams/.
#   5. the stage handoff prompts (WorkstreamsPrompts.swift): the panel-generated
#      (stage, action) prompt for planning / design / task / acceptance,
#      injection into a stage queue task's body and the execution completion marker.
#   6. the delivery pipeline (WorkstreamsDelivery.swift): accepted(ws) admission,
#      git remote / github / base detection, PR lookup, the token file layout, every
#      refusal reason (notAccepted / notGitRepo / noBranch / noRemote / noGitHubRemote /
#      noToken), and the home-session run verdict (facts / report / timeout).
# No AppKit, no dsh server, no window. Usage: tests/workstreams-panel/run.sh
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p ../../.build/module-cache
CACHE="$(cd ../../.build/module-cache && pwd)"

echo "--- workstreams model (frontmatter / stages / queues / writes) ---"
TMP="$(mktemp -d)"
cp ../../platforms/macos/src/WorkstreamsCore.swift "$TMP/WorkstreamsCore.swift"
cp model-tests.swift "$TMP/main.swift"   # top-level code needs the main.swift name
swiftc -swift-version 5 -module-cache-path "$CACHE" \
  -o "$TMP/model-tests" "$TMP/WorkstreamsCore.swift" "$TMP/main.swift"
"$TMP/model-tests"
rm -rf "$TMP"

echo "--- workstreams API (routing / validation / error codes) ---"
TMP="$(mktemp -d)"
cp ../../platforms/macos/src/WorkstreamsCore.swift "$TMP/WorkstreamsCore.swift"
cp ../../platforms/macos/src/WorkstreamsAPI.swift "$TMP/WorkstreamsAPI.swift"
cp api-tests.swift "$TMP/main.swift"   # top-level code needs the main.swift name
swiftc -swift-version 5 -module-cache-path "$CACHE" \
  -o "$TMP/api-tests" "$TMP/WorkstreamsCore.swift" "$TMP/WorkstreamsAPI.swift" "$TMP/main.swift"
"$TMP/api-tests"
rm -rf "$TMP"

echo "--- workstreams UI models (three-level card / stage filter / empty state) ---"
TMP="$(mktemp -d)"
cp ../../platforms/macos/src/WorkstreamsCore.swift "$TMP/WorkstreamsCore.swift"
cp ../../platforms/macos/src/WorkstreamsStageGate.swift "$TMP/WorkstreamsStageGate.swift"
# The card model now groups the queue engine's tasks, so the pure queue model is
# compiled in too (Foundation only, no AppKit). The derived run state (A13) is
# compiled in as well.
cp ../../platforms/macos/src/WorkstreamsQueues.swift "$TMP/WorkstreamsQueues.swift"
cp ../../platforms/macos/src/WorkstreamsRunState.swift "$TMP/WorkstreamsRunState.swift"
cp ../../platforms/macos/src/WorkstreamsUI.swift "$TMP/WorkstreamsUI.swift"
cp ui-tests.swift "$TMP/main.swift"   # top-level code needs the main.swift name
swiftc -swift-version 5 -module-cache-path "$CACHE" \
  -o "$TMP/ui-tests" "$TMP/WorkstreamsCore.swift" "$TMP/WorkstreamsStageGate.swift" \
  "$TMP/WorkstreamsQueues.swift" "$TMP/WorkstreamsRunState.swift" "$TMP/WorkstreamsUI.swift" "$TMP/main.swift"
"$TMP/ui-tests"
rm -rf "$TMP"

echo "--- workstreams runner (serial pump / session lifecycle / cancel / retry / restart) ---"
TMP="$(mktemp -d)"
cp ../../platforms/macos/src/WorkstreamsCore.swift "$TMP/WorkstreamsCore.swift"
cp ../../platforms/macos/src/WorkstreamsStageGate.swift "$TMP/WorkstreamsStageGate.swift"
cp ../../platforms/macos/src/WorkstreamsQueues.swift "$TMP/WorkstreamsQueues.swift"
cp ../../platforms/macos/src/WorkstreamsPrompts.swift "$TMP/WorkstreamsPrompts.swift"
cp ../../platforms/macos/src/WorkstreamsRunner.swift "$TMP/WorkstreamsRunner.swift"
# 汇总（任务会话 → 主场会话）是 runner 在 applyFinish 后触发的纯文案模块。
cp ../../platforms/macos/src/WorkstreamsSummary.swift "$TMP/WorkstreamsSummary.swift"
cp runner-tests.swift "$TMP/main.swift"   # top-level code needs the main.swift name
# WorkstreamsPrompts now resolves the next stage (WorkstreamStage.next, StageGate).
swiftc -swift-version 5 -module-cache-path "$CACHE" \
  -o "$TMP/runner-tests" "$TMP/WorkstreamsCore.swift" "$TMP/WorkstreamsStageGate.swift" \
  "$TMP/WorkstreamsQueues.swift" "$TMP/WorkstreamsPrompts.swift" "$TMP/WorkstreamsSummary.swift" \
  "$TMP/WorkstreamsRunner.swift" "$TMP/main.swift"
"$TMP/runner-tests"
rm -rf "$TMP"

echo "--- workstreams stage handoff prompts (planning / design / task / acceptance) ---"
TMP="$(mktemp -d)"
cp ../../platforms/macos/src/WorkstreamsCore.swift "$TMP/WorkstreamsCore.swift"
cp ../../platforms/macos/src/WorkstreamsStageGate.swift "$TMP/WorkstreamsStageGate.swift"
cp ../../platforms/macos/src/WorkstreamsQueues.swift "$TMP/WorkstreamsQueues.swift"
cp ../../platforms/macos/src/WorkstreamsPrompts.swift "$TMP/WorkstreamsPrompts.swift"
cp ../../platforms/macos/src/WorkstreamsRunner.swift "$TMP/WorkstreamsRunner.swift"
# The runner now references the summary module (applyFinish callback types).
cp ../../platforms/macos/src/WorkstreamsSummary.swift "$TMP/WorkstreamsSummary.swift"
cp prompt-tests.swift "$TMP/main.swift"   # top-level code needs the main.swift name
# nextStagePrompt uses WorkstreamStage.next (StageGate), so it compiles in too.
swiftc -swift-version 5 -module-cache-path "$CACHE" \
  -o "$TMP/prompt-tests" "$TMP/WorkstreamsCore.swift" "$TMP/WorkstreamsStageGate.swift" \
  "$TMP/WorkstreamsQueues.swift" "$TMP/WorkstreamsPrompts.swift" "$TMP/WorkstreamsSummary.swift" \
  "$TMP/WorkstreamsRunner.swift" "$TMP/main.swift"
"$TMP/prompt-tests"
rm -rf "$TMP"

echo "--- workstreams delivery (git pipeline / GitHub PR / token file reading, A10) ---"
TMP="$(mktemp -d)"
cp ../../platforms/macos/src/WorkstreamsCore.swift "$TMP/WorkstreamsCore.swift"
# 交付准入现在用 accepted(ws)（WorkstreamsStageGate 是唯一判据），编译器里带上门。
cp ../../platforms/macos/src/WorkstreamsStageGate.swift "$TMP/WorkstreamsStageGate.swift"
cp ../../platforms/macos/src/WorkstreamsDelivery.swift "$TMP/WorkstreamsDelivery.swift"
cp delivery-tests.swift "$TMP/main.swift"   # top-level code needs the main.swift name
swiftc -swift-version 5 -module-cache-path "$CACHE" \
  -o "$TMP/delivery-tests" "$TMP/WorkstreamsCore.swift" "$TMP/WorkstreamsStageGate.swift" \
  "$TMP/WorkstreamsDelivery.swift" "$TMP/main.swift"
"$TMP/delivery-tests"
rm -rf "$TMP"

echo "--- workstreams stage gate (machine predicates + human confirmation, R10) ---"
TMP="$(mktemp -d)"
cp ../../platforms/macos/src/WorkstreamsCore.swift "$TMP/WorkstreamsCore.swift"
cp ../../platforms/macos/src/WorkstreamsStageGate.swift "$TMP/WorkstreamsStageGate.swift"
cp stage-gate-tests.swift "$TMP/main.swift"   # top-level code needs the main.swift name
swiftc -swift-version 5 -module-cache-path "$CACHE" \
  -o "$TMP/stage-gate-tests" "$TMP/WorkstreamsCore.swift" "$TMP/WorkstreamsStageGate.swift" "$TMP/main.swift"
"$TMP/stage-gate-tests"
rm -rf "$TMP"

echo "--- view base namespace guard (WSCardView / WSInlineForms / WorkstreamsPanel, design A6) ---"
SRC2="../../platforms/macos/src"
# The workstream panel must NOT reference the tasks panel's view widgets: its
# copies live under the WS* names. The pattern is word-bounded so WSRepoPRButton /
# WSQueueComposerView do not count as RepoPRButton / QueueComposerView.
FORBIDDEN='TaskInk|taskRowGlyph|TaskBadgeView|TaskProgressBarView|TaskSectionHeaderView|TaskSummaryCardView|TaskCardView|RepoPRButton|RepoRetryButton|TaskQueueHeaderView|TaskQueueBlockView|TaskFormCardView|TaskFieldBox|TaskFormKit|TaskComposerView|QueueComposerView|TaskSettingsModel|TaskSettingsRepoModel|TaskSettingsView|TasksHelpTextView|TasksHelpView|TaskFormSheetView|TaskFormSheetHostView'
if grep -nE "\b(${FORBIDDEN})\b" "$SRC2/WSCardView.swift" "$SRC2/WSInlineForms.swift" "$SRC2/WorkstreamsPanel.swift"; then
  echo "FAIL: WS view files still reference tasks-panel view symbols" >&2
  exit 1
fi
# ...and it must actually define its own copies.
for sym in WSCardView WSBadgeView WSProgressBarView WSQueueHeaderView WSQueueBlockView WSFormCardView WSFormKit WSComposerView WSQueueComposerView WSFormSheetHostView; do
  if ! grep -qE "\b(class|struct|enum) $sym\b" "$SRC2/WSCardView.swift" "$SRC2/WSInlineForms.swift"; then
    echo "FAIL: $sym is not defined in the WS view files" >&2
    exit 1
  fi
done
echo "view base namespace guard: $(for s in WSCardView WSBadgeView WSComposerView WSFormSheetHostView; do printf "%s " "$s"; done)ok"

echo "--- workstreams queue engine isolation guard (A1 / A10 / D8) ---"
# The engine is a copy, not a caller: it must not reference the tasks panel's model /
# runner / store symbols in CODE (comment lines may cite them as provenance), and it
# must never touch the tasks storage path.
ENGINE="$SRC2/WorkstreamsQueues.swift $SRC2/WorkstreamsRunner.swift $SRC2/WorkstreamsDelivery.swift $SRC2/WorkstreamsSummary.swift"
if grep -nE '\b(TasksRunner|TasksCore|TasksStore|TaskBoard|TaskItem|TaskQueue|TaskState|TaskFailure|TaskPrompts|TaskLocalState|TaskDraft)\b' $ENGINE \
   | grep -vE ':[0-9]+:[[:space:]]*//' ; then
  echo "FAIL: the workstreams engine/delivery references tasks-panel symbols in code" >&2
  exit 1
fi
if grep -n 'dsh/tasks' $ENGINE | grep -vE ':[0-9]+:[[:space:]]*//' ; then
  echo "FAIL: the workstreams engine/delivery must not touch .dsh/tasks/" >&2
  exit 1
fi
echo "workstreams queue engine isolation guard ok"

echo "--- workstreams delivery guard (A10: git pipeline / PR / token files, staged) ---"
DELIVERY="$SRC2/WorkstreamsDelivery.swift"
if [ ! -f "$DELIVERY" ]; then
  echo "FAIL: WorkstreamsDelivery.swift is missing" >&2
  exit 1
fi
for sym in 'struct WSGitProbe' 'struct WSTokenStore' 'struct WSGitHubPR' 'enum WSDeliveryOutcome' \
           'enum WSDeliveryBlocker' 'struct WSDeliveryPlan' 'static func resolve(' 'static func prompt(plan:' \
           'static func record(' 'static func writeBack(' 'static func parse('; do
  if ! grep -qF "$sym" "$DELIVERY"; then
    echo "FAIL: WorkstreamsDelivery.swift is missing $sym" >&2
    exit 1
  fi
done
# 失败路径必须有明确原因（无分支 / 无远端 / 无 token 的稳定码）。
for code in '"no-branch"' '"no-remote"' '"no-token"'; do
  if ! grep -qF "$code" "$DELIVERY"; then
    echo "FAIL: WorkstreamsDelivery.swift is missing the $code reason" >&2
    exit 1
  fi
done
# 与任务面板一致：token 只读文件，绝不读 Keychain。
if grep -nE 'SecItem|kSecClass|SecCopyMatching' "$DELIVERY" | grep -vE ':[0-9]+:[[:space:]]*//'; then
  echo "FAIL: the delivery module must read tokens from files, not the Keychain" >&2
  exit 1
fi
echo "workstreams delivery guard ok"

echo "--- workstreams panel surface guard (PanelSurface / PanelControl, no new token) ---"
SRC3="../../platforms/macos/src"
if ! grep -q 'PanelSurface' "$SRC3/WorkstreamsPanel.swift" || ! grep -q 'PanelControl' "$SRC3/WorkstreamsPanel.swift"; then
  echo "FAIL: WorkstreamsPanel.swift must paint with the shared PanelSurface / PanelControl tokens" >&2
  exit 1
fi
# A new color token would be a 'static let ...: NSColor'; the panel may only use
# the shared tokens (WSInk / PanelSurface / PanelControl / system colors).
if grep -nE 'static let (dark|light)[A-Za-z]* *: *NSColor' "$SRC3/WorkstreamsPanel.swift"; then
  echo "FAIL: WorkstreamsPanel.swift defines a new color token" >&2
  exit 1
fi
echo "workstreams panel surface guard: PanelSurface + PanelControl ok"

echo "--- main.swift wiring guard (entry points) ---"
# The panel entry wiring is AppKit main.swift (no headless unit test), so freeze
# it with a source guard: RightPanel.workstreams, the activity-bar slot right
# after 需求池, the ⌥⌘K toggle (view menu + shortcut list), the L10n keys, the
# panel instance, and the /api/workstreams/* bridge landing. See design A5 / A11.
MAIN="$SRC3/main.swift"
wiring_check() {
  if ! grep -qE "$1" "$MAIN"; then
    echo "FAIL: main.swift missing $2" >&2
    exit 1
  fi
}
wiring_check 'enum RightPanel \{[^}]*\bworkstreams\b' 'RightPanel.workstreams'
wiring_check 'requirementsBarButton, workstreamsBarButton' 'activity-bar slot immediately after 需求池'
wiring_check 'workstreamsEntryTapped' 'the workstreams toggle handler'
wiring_check 'keyEquivalent: "k"' 'the ⌥⌘K view-menu shortcut'
wiring_check 'menu\.toggleWorkstreams' 'the view-menu L10n key'
wiring_check 'bar\.workstreams' 'the activity-bar L10n key'
wiring_check '\("menu\.toggleWorkstreams", "⌥⌘K"\)' 'the Settings shortcut-list row'
wiring_check 'workstreamsPanel = WorkstreamsPanelController\(\)' 'the panel instance'
wiring_check 'workstreamsPanel\.workspaceProvider' 'the workspace provider wiring'
wiring_check 'bridge\.workstreamsList' 'the /api/workstreams/list bridge landing'
wiring_check 'bridge\.workstreamsQueues' 'the /api/workstreams/queues bridge landing'
wiring_check 'bridge\.workstreamsStageConfirm' 'the /api/workstreams/stage/confirm bridge landing'
wiring_check 'bridge\.workstreamsStageReject' 'the /api/workstreams/stage/reject bridge landing'
echo "main.swift wiring guard ok"

echo "--- workstreams stage gate guard (R10: machine evidence AND human confirmation) ---"
GATE="$SRC2/WorkstreamsStageGate.swift"
if [ ! -f "$GATE" ]; then
  echo "FAIL: WorkstreamsStageGate.swift is missing" >&2
  exit 1
fi
for sym in planningEvidence designEvidence executionEvidence acceptanceEvidence confirmStage rejectStage; do
  if ! grep -qE "func $sym\b" "$GATE"; then
    echo "FAIL: WorkstreamsStageGate.swift is missing $sym" >&2
    exit 1
  fi
done
if ! grep -q 'evidenceMissing' "$GATE"; then
  echo "FAIL: the gate must refuse confirmation when evidence is missing" >&2
  exit 1
fi
# 验收是最后阶段（交付是操作，A17）：门里不得再有交付证据分支。
if grep -qE 'func deliveryEvidence|\.delivery[^\n]*passed' "$GATE"; then
  echo "FAIL: WorkstreamsStageGate.swift must not keep a delivery evidence branch" >&2
  exit 1
fi
if grep -qF 'workstreams.evidence.delivery' "$GATE"; then
  echo "FAIL: the stage gate must not gate on delivery facts (acceptance is last)" >&2
  exit 1
fi
# The agent-facing routes must reach the panel; the human gate is a separate route.
if ! grep -q '/api/workstreams/stage/confirm' "$SRC2/WorkstreamsAPI.swift" \
   || ! grep -q '/api/workstreams/stage/reject' "$SRC2/WorkstreamsAPI.swift"; then
  echo "FAIL: the stage confirm / reject routes are missing from WorkstreamsAPI.swift" >&2
  exit 1
fi
echo "workstreams stage gate guard ok"

echo "--- stage decision source guard (R10: panel tap vs session authorization) ---"
# R10 允许人经两条路签字：面板点按，或在会话里明确授权后由该会话代发。
# 两种来源都写进 "## 阶段确认" 的 source 标记，审计痕迹能分辨是哪一种。
for sym in 'enum WSStageSource' 'case panel' 'case session(String)' \
           'static func from(session: String?)'; do
  if ! grep -qF "$sym" "$GATE"; then
    echo "FAIL: WorkstreamsStageGate.swift is missing $sym" >&2
    exit 1
  fi
done
# confirmStage / rejectStage 都必须带 source 参数。
if [ "$(grep -c 'source: WSStageSource = .panel' "$GATE")" -lt 2 ]; then
  echo "FAIL: confirmStage / rejectStage must record a source marker" >&2
  exit 1
fi
# 标记必须写进行尾并能解析回来（旧记录没有 source 也要照常可读）。
if ! grep -qF 'source:" + source.marker' "$GATE" \
   || ! grep -qF 'WSStageSource.parse(' "$GATE" \
   || ! grep -qF 'e["source"] = source.marker' "$GATE"; then
  echo "FAIL: the source marker must be written, parsed and exposed" >&2
  exit 1
fi
# 面板按钮记 .panel；API 调用按 session 派生（确认 / 退回两条路都要有）。
if ! grep -qF 'source: .panel' "$SRC2/WorkstreamsPanel.swift" \
   || [ "$(grep -c 'WSStageSource.from(session: request.session)' "$SRC2/WorkstreamsPanel.swift")" -lt 2 ]; then
  echo "FAIL: the panel / API confirm-reject paths must record the R10 source" >&2
  exit 1
fi
echo "stage decision source guard ok"

echo "--- workstreams stage prompt guard (D15: panel-generated, injected into the task body) ---"
PROMPTS="$SRC2/WorkstreamsPrompts.swift"
if [ ! -f "$PROMPTS" ]; then
  echo "FAIL: WorkstreamsPrompts.swift is missing" >&2
  exit 1
fi
for sym in 'enum WSStageAction' 'enum WorkstreamHandoff' 'func prompt(card:' 'func stageTask(' \
           'func injectingCompletionMarker('; do
  if ! grep -qF "$sym" "$PROMPTS"; then
    echo "FAIL: WorkstreamsPrompts.swift is missing $sym" >&2
    exit 1
  fi
done
# 四个阶段的中文名 + 执行阶段的两个动作，缺一不可（design §4；交付是操作，不是阶段）。
for needle in 规划 设计 执行 验收 拆分任务 启动实施; do
  if ! grep -qF "$needle" "$PROMPTS"; then
    echo "FAIL: the stage prompt source no longer mentions $needle" >&2
    exit 1
  fi
done
# 写权反转（R10 / D5b）：阶段提示词改卡片只能经 /api/workstreams/*，
# 必须显式要求「不直接改 .dsh 文件」，并点名 workstream-panel 技能。
if ! grep -qF '/api/workstreams/' "$PROMPTS" \
   || ! grep -qF '不直接改' "$PROMPTS" \
   || ! grep -qF 'workstream-panel' "$PROMPTS"; then
  echo "FAIL: the stage prompt must route card edits through /api/workstreams/*" >&2
  exit 1
fi
# D19：任务创建 / 启动走事项面板自有引擎；提示词不得再示例任务面板技能 /task-todo，
# 且必须点名自有 API 并说明任务带 stage（执行阶段的完成协议仍是 runner 注入的 marker）。
if grep -qF '/task-todo' "$PROMPTS"; then
  echo "FAIL: the stage prompt still points at the tasks panel's /task-todo skill" >&2
  exit 1
fi
if ! grep -qF '/api/workstreams/task/create' "$PROMPTS" \
   || ! grep -qF '/api/workstreams/queue/start' "$PROMPTS"; then
  echo "FAIL: the stage prompt must create / start tasks through the workstreams panel API" >&2
  exit 1
fi
if ! grep -qF '任务带 `stage`' "$PROMPTS"; then
  echo "FAIL: the stage prompt must explain that stage tasks carry a stage" >&2
  exit 1
fi
# covered 事实走写路由（验收阶段的提示词必须点名）。交付是操作（design A17），
# 不再由（四阶段）交接提示词承载，故这里只校验 covered。
if ! grep -qF '/api/workstreams/covered' "$PROMPTS"; then
  echo "FAIL: the stage prompt must record covered through the panel API" >&2
  exit 1
fi
# 执行阶段的完成协议仍由 runner 注入 marker；
# 面板生成的提示词必须能被 runner 原样识别，而不是被包成任务模板。
if ! grep -qE 'WorkstreamHandoff\.isHandoff' "$SRC2/WorkstreamsRunner.swift"; then
  echo "FAIL: the runner must recognise a panel-generated handoff body" >&2
  exit 1
fi
if ! grep -qE 'WorkstreamHandoff\.injectingCompletionMarker' "$SRC2/WorkstreamsRunner.swift"; then
  echo "FAIL: the runner must inject the execution marker through WorkstreamHandoff" >&2
  exit 1
fi
if ! grep -qE 'func createStageQueue\(' "$SRC2/WorkstreamsRunner.swift"; then
  echo "FAIL: the runner is missing the panel entry point createStageQueue" >&2
  exit 1
fi
echo "workstreams stage prompt guard ok"

echo "--- stage task create / queue start wiring guard (A3 / A14 / D16-D19) ---"
API="$SRC2/WorkstreamsAPI.swift"
for route in '/api/workstreams/task/create' '/api/workstreams/task/list' \
             '/api/workstreams/queue/start' '/api/workstreams/queue/pause'; do
  if ! grep -qF "$route" "$API"; then
    echo "FAIL: WorkstreamsAPI.swift is missing the $route route" >&2
    exit 1
  fi
done
# One workstream queue: createStageQueue appends instead of creating per stage.
if ! grep -qE 'func ensureWorkstreamQueue\(' "$SRC2/WorkstreamsRunner.swift" \
   || ! grep -qE 'func appendStageTasks\(' "$SRC2/WorkstreamsRunner.swift" \
   || ! grep -qE 'func createStageQueue\(' "$SRC2/WorkstreamsRunner.swift"; then
  echo "FAIL: the runner must append stage tasks to the workstream's single queue" >&2
  exit 1
fi
# Stage-level start (A3 / D18).
if ! grep -qE 'private\(set\) var stageFilter' "$SRC2/WorkstreamsRunner.swift" \
   || ! grep -qE 'func startQueue\(_ queueID: String, stage:' "$SRC2/WorkstreamsRunner.swift" \
   || ! grep -qE 'func nextStartable\(stage:' "$SRC2/WorkstreamsQueues.swift"; then
  echo "FAIL: the runner/board must support stage-level start" >&2
  exit 1
fi
# The panel drives the runner (timer + workspace reload) and lands the routes.
PANEL="$SRC2/WorkstreamsPanel.swift"
for needle in 'WorkstreamsRunner(board:' 'stepTimer' 'serverPortProvider' \
              'ensureRunner(' 'createStageQueue(' 'onStartWorkstream' \
              'apiWorkstreamsTaskCreate' 'apiWorkstreamsQueueStart' \
              'apiWorkstreamsQueuePause' 'apiWorkstreamsTaskList'; do
  if ! grep -qF "$needle" "$PANEL"; then
    echo "FAIL: WorkstreamsPanel.swift is missing $needle" >&2
    exit 1
  fi
done
if ! grep -qF 'bridge.workstreamsTaskCreate' "$MAIN" \
   || ! grep -qF 'bridge.workstreamsQueueStart' "$MAIN" \
   || ! grep -qF 'bridge.workstreamsTaskList' "$MAIN" \
   || ! grep -qF 'bridge.workstreamsQueuePause' "$MAIN"; then
  echo "FAIL: main.swift is missing the task/queue bridge landings" >&2
  exit 1
fi
# Task state keys are switches so the L10n lint sees every key.
for key in workstreams.task.state.pending workstreams.task.state.done workstreams.task.state.needsReview; do
  if ! grep -qF "$key" "$SRC2/WorkstreamsUI.swift"; then
    echo "FAIL: WorkstreamsUI.swift is missing the $key L10n key" >&2
    exit 1
  fi
done
echo "stage task create / queue start wiring guard ok"

echo "--- 启动收口 guard (事项卡是唯一入口 + 阶段 canonical 顺序, UX) ---"
# 阶段卡不再有「启动阶段」入口；移除按钮与 onStartStage / startStage 回调后，
# 面板唯一的启动入口是事项卡「启动事项」。
if grep -qE 'onStartStage|func startStage|workstreams\.stage\.start' "$PANEL"; then
  echo "FAIL: the stage card must not keep a start entry (onStartStage / startStage / workstreams.stage.start)" >&2
  exit 1
fi
if ! grep -qF 'card.onStartWorkstream' "$PANEL" \
   || ! grep -qE 'func startWorkstream\(_ cardID: String\)' "$PANEL"; then
  echo "FAIL: the workstream card must be the panel's single start entry" >&2
  exit 1
fi
# 事项级启动按阶段 canonical 顺序取任务（同阶段内仍按入队序）。
if ! grep -qF 'stageRank(of:' "$SRC2/WorkstreamsQueues.swift" \
   || ! grep -qF 'WorkstreamStage.allCases.firstIndex(of: stage)' "$SRC2/WorkstreamsQueues.swift"; then
  echo "FAIL: nextStartable/firstQueued must order candidates by canonical stage rank" >&2
  exit 1
fi
echo "start-entry / stage-order guard ok"

echo "--- workstreams run state guard (A13: derived, never moves the authoritative stage) ---"
RUNSTATE="$SRC2/WorkstreamsRunState.swift"
if [ ! -f "$RUNSTATE" ]; then
  echo "FAIL: WorkstreamsRunState.swift is missing" >&2
  exit 1
fi
for sym in 'enum WSRunState' 'static func stage(' 'static func workstream(' \
           'static func reworkStage(' 'static func acceptanceConfirmed('; do
  if ! grep -qF "$sym" "$RUNSTATE"; then
    echo "FAIL: WorkstreamsRunState.swift is missing $sym" >&2
    exit 1
  fi
done
# 派生谓词只读：本模块不得写 stage / 调人工门（权威 stage 只由 confirmStage 推进）。
if grep -nE 'confirmStage|rejectStage|setStage|WorkstreamsCore\.' "$RUNSTATE" \
   | grep -vE ':[0-9]+:[[:space:]]*//'; then
  echo "FAIL: the run state must be derived, not written" >&2
  exit 1
fi
# UI 模型接入派生，面板展示徽标。
if ! grep -qF 'WSRunState.stage' "$SRC2/WorkstreamsUI.swift" \
   || ! grep -qF 'WSRunState.workstream' "$SRC2/WorkstreamsUI.swift"; then
  echo "FAIL: WorkstreamsUI.swift does not derive the run state" >&2
  exit 1
fi
if ! grep -qF 'runStateKey' "$SRC2/WorkstreamsPanel.swift"; then
  echo "FAIL: WorkstreamsPanel.swift does not show the run state" >&2
  exit 1
fi
for key in workstreams.run.notStarted workstreams.run.inProgress \
           workstreams.run.awaitingConfirmation workstreams.run.done workstreams.run.blocked; do
  if ! grep -qF "$key" "$SRC2/WorkstreamsUI.swift"; then
    echo "FAIL: WorkstreamsUI.swift is missing the $key L10n key" >&2
    exit 1
  fi
done
echo "workstreams run state guard ok"

echo "--- workstreams default expansion guard (UX: only the first unprocessed card opens) ---"
# 事项面板加载 / 重绘时默认只展开首个未处理（runState != done）的事项卡，其余收起；
# 全完成时不展开任何卡。规则是 WorkstreamsUI.swift 的纯谓词，且必须由
# WSBoardModel.build 在每次重绘时应用（只定义不调用 = 没生效）。
if ! grep -qF 'func wsDefaultExpandedID(' "$SRC2/WorkstreamsUI.swift" \
   || ! grep -qF 'runState != .done' "$SRC2/WorkstreamsUI.swift"; then
  echo "FAIL: WorkstreamsUI.swift is missing the first-unprocessed default-expansion rule" >&2
  exit 1
fi
if ! grep -qF 'wsApplyingDefaultExpansion(built)' "$SRC2/WorkstreamsUI.swift"; then
  echo "FAIL: WSBoardModel.build must apply the default expansion on every redraw" >&2
  exit 1
fi
echo "workstreams default expansion guard ok"

echo "--- 队列 id 展示位置 guard (UX: 队列 id 只在事项主卡，任何阶段卡都不显示) ---"
# 队列属于事项（一事项一队列，design A9 / D16）。修复前 queueIDs 挂在「当前阶段」
# 卡上，拆分后队列 id 会显示到「规划」等二级卡；现在它只作为中性徽标出现在事项主卡
# 标题行，阶段二级卡不再承载。
UI="$SRC2/WorkstreamsUI.swift"
# 恰好一个卡片模型（主卡）声明 queueIDs。
if ! grep -qE 'var queueIDs: \[String\]' "$UI" \
   || [ "$(grep -c 'var queueIDs: \[String\]' "$UI")" -ne 1 ]; then
  echo "FAIL: exactly one card model (the main card) must declare queueIDs" >&2
  exit 1
fi
# 从 WSStageCardModel 结构体抠出正文，断言它不含任何队列字段。
STAGE_BODY="$(awk '/^struct WSStageCardModel/,/^}/' "$UI")"
if printf '%s\n' "$STAGE_BODY" | grep -qE 'queueIDs|hasQueue'; then
  echo "FAIL: WSStageCardModel must not carry queueIDs / hasQueue (a queue is not stage-scoped)" >&2
  exit 1
fi
if ! grep -qF 'queueIDs: card.queues' "$UI"; then
  echo "FAIL: the main card must be built with the workstream's queue ids" >&2
  exit 1
fi
# 主卡标题行用中性徽标渲染；阶段卡不得渲染 stage.queueIDs。
if ! grep -qE 'WSTierBadgeView\(text: model\.queueIDs\.joined' "$PANEL" \
   || ! grep -qF 'tone: .neutral' "$PANEL"; then
  echo "FAIL: the main card title row must render the queue ids as a neutral badge" >&2
  exit 1
fi
if grep -qF 'stage.queueIDs' "$PANEL" || grep -qF 'stage.hasQueue' "$PANEL"; then
  echo "FAIL: a stage card must not render queue ids" >&2
  exit 1
fi
echo "queue id placement guard ok"

echo "--- delivery wiring + covered / delivery write routes guard (A10 / store 3.2 / 5) ---"
# Delivery is an OPERATION in the home session (design A17): it is not a queue task
# and it does not create a session. covered / delivery keep their write routes, and
# delivery.outcome stays a derived cache refused at the API boundary.
for needle in 'apiWorkstreamsCovered' 'apiWorkstreamsDelivery' 'deliverWorkstream('; do
  if ! grep -qF "$needle" "$PANEL"; then
    echo "FAIL: WorkstreamsPanel.swift is missing $needle" >&2
    exit 1
  fi
done
if ! grep -qF 'WorkstreamsDelivery.resolve(' "$PANEL" \
   || ! grep -qF 'WorkstreamsDelivery.prompt(plan:' "$PANEL" \
   || ! grep -qF 'WSDeliveryRun(' "$PANEL"; then
  echo "FAIL: the panel must resolve a delivery plan and run its prompt in the home session" >&2
  exit 1
fi
# 交付不是队列任务：面板与 runner 都不得再建 delivery 任务。
if grep -qE 'runner\.enqueueDelivery\(|func enqueueDelivery\(' "$PANEL" "$SRC2/WorkstreamsRunner.swift"; then
  echo "FAIL: delivery must not enqueue a delivery task (it runs in the home session)" >&2
  exit 1
fi
# 准入的唯一来源是 accepted(ws)（WorkstreamsStageGate 是唯一判据）。
if ! grep -qF 'WorkstreamsStageGate.accepted(card)' "$SRC2/WorkstreamsDelivery.swift" \
   || ! grep -qF '"not-accepted"' "$SRC2/WorkstreamsDelivery.swift"; then
  echo "FAIL: WorkstreamsDelivery.resolve must gate on accepted(ws) with the not-accepted code" >&2
  exit 1
fi
for route in '/api/workstreams/covered' '/api/workstreams/delivery'; do
  if ! grep -qF "$route" "$API"; then
    echo "FAIL: WorkstreamsAPI.swift is missing the $route route" >&2
    exit 1
  fi
done
# outcome is a derived cache: the API refuses a hand-written outcome.
if ! grep -qF 'outcome-derived' "$API" \
   || ! grep -qE 'func parseCovered\(' "$API" \
   || ! grep -qE 'func parseDelivery\(' "$API"; then
  echo "FAIL: the covered / delivery routers must parse facts and refuse a hand-written outcome" >&2
  exit 1
fi
if ! grep -qF 'workstreamsCovered' "$SRC2/BrowserAPI.swift" \
   || ! grep -qF 'workstreamsDelivery' "$SRC2/BrowserAPI.swift" \
   || ! grep -qF 'bridge.workstreamsCovered' "$MAIN" \
   || ! grep -qF 'bridge.workstreamsDelivery' "$MAIN"; then
  echo "FAIL: main.swift / BrowserAPI.swift are missing the covered / delivery bridge landings" >&2
  exit 1
fi
for key in workstreams.deliver.action workstreams.deliver.not-accepted \
           workstreams.deliver.no-home-session workstreams.deliver.no-branch \
           workstreams.deliver.no-remote workstreams.deliver.no-token; do
  if ! grep -qF "$key" "$MAIN"; then
    echo "FAIL: main.swift is missing the $key L10n key" >&2
    exit 1
  fi
done
echo "delivery wiring + covered / delivery write routes guard ok"

echo "--- 发起交付 guard (主卡按钮 == API 同一条路径 + 主场会话执行) ---"
# 面板主卡「交付」按钮与 POST /api/workstreams/deliver 共用同一个 initiateDelivery；
# 交付是操作：不建交付任务、不另起会话，提示词发进事项的主场会话，完成信号是
# agent 调 POST /api/workstreams/delivery 写 pr / url；失败由汇报 + 超时兜底。
if ! grep -qF '/api/workstreams/deliver' "$API"; then
  echo "FAIL: WorkstreamsAPI.swift is missing the /api/workstreams/deliver route" >&2
  exit 1
fi
if ! grep -qE 'func apiWorkstreamsDeliver\(' "$API" \
   || ! grep -qE 'struct WorkstreamsDeliverRequest' "$API"; then
  echo "FAIL: WorkstreamsAPI.swift is missing the deliver DTO / delegate" >&2
  exit 1
fi
for needle in 'func initiateDelivery(' 'func deliverWorkstream(' 'func apiWorkstreamsDeliver('; do
  if ! grep -qF "$needle" "$PANEL"; then
    echo "FAIL: WorkstreamsPanel.swift is missing $needle" >&2
    exit 1
  fi
done
# 两条入口都必须调 initiateDelivery（只接一条 = 两套）。
if [ "$(grep -c 'initiateDelivery(' "$PANEL")" -lt 3 ]; then
  echo "FAIL: the panel button and the API delegate must both call initiateDelivery" >&2
  exit 1
fi
# 准入走 WorkstreamsDelivery；执行走主场会话（绑定会话），不建任务 / 不起会话。
if ! grep -qF 'WorkstreamsDelivery.resolve(' "$PANEL" \
   || ! grep -qF 'WSDeliveryRun(' "$PANEL" \
   || ! grep -qF 'WSStore.loadLocal(workspace).workstreamSessions[card.id]' "$PANEL" \
   || ! grep -qF 'sendDeliveryPrompt(' "$PANEL"; then
  echo "FAIL: initiateDelivery must resolve admission and send the prompt into the home session" >&2
  exit 1
fi
if grep -qE 'enqueueDelivery|ensureRunner\(workspace\).*startWorkstream' "$PANEL"; then
  echo "FAIL: delivery must not create a delivery task or start a stage queue" >&2
  exit 1
fi
# 入口只挂在事项主卡；阶段卡没有交付按钮。
if ! grep -qF 'func deliverButton()' "$PANEL" \
   || [ "$(grep -c 'append(deliverButton())' "$PANEL")" -ne 1 ]; then
  echo "FAIL: only the main card must carry the 交付 button" >&2
  exit 1
fi
if grep -qE 'onDeliverStage|workstreams\.stage\.deliver' "$PANEL"; then
  echo "FAIL: the stage card must not carry a delivery entry" >&2
  exit 1
fi
# 完成信号 / 汇报 / 超时兜底接在面板 tick 上。
if ! grep -qF 'stepDeliveryRuns()' "$PANEL" \
   || ! grep -qF 'func completeDeliveryRun(' "$PANEL"; then
  echo "FAIL: the panel must watch the home-session run (facts / report / timeout)" >&2
  exit 1
fi
if ! grep -qF 'bridge.workstreamsDeliver' "$MAIN" \
   || ! grep -qF 'workstreamsDeliver' "$SRC2/BrowserAPI.swift"; then
  echo "FAIL: main.swift / BrowserAPI.swift are missing the deliver bridge landing" >&2
  exit 1
fi
# 技能入口：说「交付 WS-x」→ 发起交付（与面板同一条路径）。
SKILL="../../.dsh/skills/workstream-panel/SKILL.md"
if ! grep -qF '/api/workstreams/deliver' "$SKILL" \
   || ! grep -qF '交付 WS-x' "$SKILL"; then
  echo "FAIL: the workstream-panel skill is missing the deliver entry" >&2
  exit 1
fi
echo "发起交付 guard ok"

echo "--- workstream 会话绑定 / 拆分任务 guard (design §6) ---"
# 事项 ↔ 会话绑定：local.json 的 workstreamSessions + 反查 + 「拆分任务」动作。
# 模型层：持久化 / 反查 / 目标会话决策。
for sym in 'workstreamSessions' 'rememberWorkstreamSession' 'workstreamSessions(' \
           'workstreamId(boundTo' 'bindWorkstreamSession'; do
  if ! grep -qF "$sym" "$SRC2/WorkstreamsQueues.swift"; then
    echo "FAIL: WorkstreamsQueues.swift is missing $sym" >&2
    exit 1
  fi
done
for sym in 'sessionTarget(' 'boundWorkstream(' 'boundSession(' 'WorkstreamSessionTarget'; do
  if ! grep -qF "$sym" "$SRC2/WorkstreamsCore.swift"; then
    echo "FAIL: WorkstreamsCore.swift is missing $sym" >&2
    exit 1
  fi
done
# API：反查路由 + delegate；list / card 回带绑定。
if ! grep -qF '/api/workstreams/bound' "$SRC2/WorkstreamsAPI.swift" \
   || ! grep -qE 'func apiWorkstreamsBound\(' "$SRC2/WorkstreamsAPI.swift" \
   || ! grep -qF 'sessions: [String: String] = [:]' "$SRC2/WorkstreamsAPI.swift"; then
  echo "FAIL: WorkstreamsAPI.swift is missing the reverse-lookup route / delegate / list binding" >&2
  exit 1
fi
# 面板：写请求 rememberSession + 「拆分任务」按钮 / 动作落地。
for needle in 'apiWorkstreamsBound' 'onSplitTasks' 'splitTasks(' 'bindSession(' \
              'rememberWorkstreamSession' 'wsFirstUnprocessedStage('; do
  if ! grep -qF "$needle" "$SRC2/WorkstreamsPanel.swift"; then
    echo "FAIL: WorkstreamsPanel.swift is missing $needle" >&2
    exit 1
  fi
done
# 只有一个「拆分任务」按钮，且只在主卡（阶段卡不再重复挂这个入口）。
if ! grep -qF 'func splitTasksButton()' "$SRC2/WorkstreamsPanel.swift" \
   || [ "$(grep -c 'append(splitTasksButton())' "$SRC2/WorkstreamsPanel.swift")" -ne 1 ]; then
  echo "FAIL: only the main card must carry the 拆分任务 button" >&2
  exit 1
fi
if ! grep -qF 'workstreamsBound' "$SRC2/BrowserAPI.swift" \
   || ! grep -qF 'bridge.workstreamsBound' "$MAIN" \
   || ! grep -qF 'startWorkstreamSession' "$MAIN" \
   || ! grep -qF 'workstreamsPanel.onSplitTasks' "$MAIN"; then
  echo "FAIL: BrowserAPI.swift / main.swift are missing the bound bridge / split wiring" >&2
  exit 1
fi
for key in workstreams.split workstreams.split.started workstreams.split.continued \
           workstreams.split.fallback workstreams.split.failed workstreams.split.allDone; do
  if ! grep -qF "$key" "$MAIN"; then
    echo "FAIL: main.swift is missing the $key L10n key" >&2
    exit 1
  fi
done
echo "workstream session binding / split guard ok"

echo "--- 拆分任务 guard (UX: main-card button targets the first unprocessed stage) ---"
# 「拆分任务」按 canonical 顺序取首个 runState != 完成 的阶段，经主场会话发该阶段的
# 拆分提示词（WorkstreamHandoff.splitPrompt）；不新建会话语义之外的旁路。
if ! grep -qF 'func wsFirstUnprocessedStage(' "$SRC2/WorkstreamsUI.swift" \
   || ! grep -qF 'card.stages.first { $0.runState != .done }?.stage' "$SRC2/WorkstreamsUI.swift"; then
  echo "FAIL: WorkstreamsUI.swift is missing the first-unprocessed-stage predicate" >&2
  exit 1
fi
if ! grep -qF 'wsFirstUnprocessedStage(model)' "$SRC2/WorkstreamsPanel.swift"; then
  echo "FAIL: the panel must resolve the split target through wsFirstUnprocessedStage" >&2
  exit 1
fi
if ! grep -qE 'func splitPrompt\(' "$PROMPTS"; then
  echo "FAIL: WorkstreamsPrompts.swift is missing splitPrompt" >&2
  exit 1
fi
if ! grep -qF 'WorkstreamHandoff.splitPrompt(card: card, stage: stage, workspace: workspace)' "$SRC2/main.swift"; then
  echo "FAIL: main.swift must send the stage's splitPrompt to the home session" >&2
  exit 1
fi
# 拆分的四件套要求：等待态 / 带 stage / 不自签 / 不启动 / 停下等人。
for needle in '等待态阶段任务' '`stage` 必须传' '不要传 `task`' '不自签' '只建不启动' '停下请人确认拆分合理'; do
  if ! grep -qF "$needle" "$PROMPTS"; then
    echo "FAIL: the split prompt no longer requires: $needle" >&2
    exit 1
  fi
done
# 阶段歧义修复：stageMarker 行必须带原始枚举值（当前 stage：规划（planning））；拆分动作段
# 必须点名原始值并给出带 "stage":"<raw>" 的调用示例；task/create 缺 stage 时回落卡片 stage。
if ! grep -qF 'stageMarker + stageLabel(stage) + "（" + stage.rawValue + "）' "$PROMPTS"; then
  echo "FAIL: the stage marker must carry the raw stage value (当前 stage：规划（planning）)" >&2
  exit 1
fi
if ! grep -qF 'let raw = stage?.rawValue ?? "planning"' "$PROMPTS" \
   || ! grep -qF '\"stage\":\"" + raw + "\"' "$PROMPTS"; then
  echo "FAIL: the split action section must build a call example from the raw stage value" >&2
  exit 1
fi
if ! grep -qF 'let stage = request.stage ?? card.stage' "$PANEL"; then
  echo "FAIL: task/create must fall back to the card stage when stage is absent" >&2
  exit 1
fi
echo "split-task guard ok"

echo "--- focus channel guard (A11 / D6: panel focus + API focus + requirements jump) ---"
# 面板聚焦：高亮 + 滚动，且被阶段筛选隐藏时回落「全部」。
for needle in 'func focus(onWorkstream' 'focusTarget' 'isFocused' 'scrollToFocused' 'onFocus';
  do
  if ! grep -qF "$needle" "$PANEL"; then
    echo "FAIL: WorkstreamsPanel.swift is missing $needle" >&2
    exit 1
  fi
done
if ! grep -qF 'struct WSFocusTarget' "$SRC2/WorkstreamsUI.swift" \
   || ! grep -qF 'static func resolve(' "$SRC2/WorkstreamsUI.swift" \
   || ! grep -qF 'WSFocusTarget.resolve(' "$PANEL"; then
  echo "FAIL: the pure focus target model is missing from WorkstreamsUI.swift" >&2
  exit 1
fi
# API：任何 /api/workstreams/* 带 focus 都走 apiWorkstreamsFocus（写操作 focus:true 也亮面板）。
if ! grep -qF 'func apiWorkstreamsFocus' "$API" \
   || ! grep -qF 'workstreamsFocusFlag' "$API" \
   || ! grep -qF 'focusWorkspace(request:' "$API"; then
  echo "FAIL: WorkstreamsAPI.swift is missing the focus channel" >&2
  exit 1
fi
if ! grep -qF 'workstreamsFocus' "$SRC2/BrowserAPI.swift" \
   || ! grep -qF 'bridge.workstreamsFocus' "$MAIN"; then
  echo "FAIL: main.swift / BrowserAPI.swift are missing the focus bridge landing" >&2
  exit 1
fi
if ! grep -qF 'workstreamsPanel.onFocus' "$MAIN" \
   || ! grep -qF 'private func focusWorkstream(' "$MAIN"; then
  echo "FAIL: main.swift is missing the panel focus / requirements jump wiring" >&2
  exit 1
fi
# 需求池子事项 ↗：主按钮聚焦事项面板，次级仍打开卡文件。
REQ="$SRC2/RequirementsPanel.swift"
if ! grep -qF 'onFocusWorkstream' "$REQ" \
   || ! grep -qF 'requirements.openWorkstreamFocus' "$REQ" \
   || ! grep -qF 'requirements.openWorkstream' "$REQ"; then
  echo "FAIL: RequirementsPanel.swift is missing the focus / open-file child actions" >&2
  exit 1
fi
if ! grep -qF 'requirements.openWorkstreamFocus' "$MAIN"; then
  echo "FAIL: main.swift is missing the requirements.openWorkstreamFocus L10n key" >&2
  exit 1
fi
echo "focus channel guard ok"

echo "--- 对话内阶段推进 guard (第 24 项: confirm -> next-stage prompt to the bound session) ---"
# 阶段确认（人工门）成功后，复用 WorkstreamHandoff 向该事项绑定的主场会话发送下一阶段
# 提示词；无绑定会话则不发。纯函数 nextStagePrompt 承载「下一阶段 + 提示词」决策。
if ! grep -qE 'func nextStagePrompt\(' "$PROMPTS"; then
  echo "FAIL: WorkstreamsPrompts.swift is missing nextStagePrompt" >&2
  exit 1
fi
if ! grep -qF 'var onStageConfirmed' "$PANEL" \
   || ! grep -qF 'func continueToNextStage(' "$PANEL"; then
  echo "FAIL: WorkstreamsPanel.swift is missing the stage-confirm callback / helper" >&2
  exit 1
fi
# 两条确认路径（面板按钮 + API）都必须触发，只接一条不算完成。
if [ "$(grep -c 'continueToNextStage(after:' "$PANEL")" -lt 2 ]; then
  echo "FAIL: both confirm paths (panel button + API) must continue to the next stage" >&2
  exit 1
fi
if ! grep -qF 'WorkstreamHandoff.nextStagePrompt' "$PANEL"; then
  echo "FAIL: the panel must derive the next-stage handoff through WorkstreamHandoff" >&2
  exit 1
fi
# 验收是最后阶段：nextStagePrompt 只认 stage.next（验收返回 nil），面板续发前也必须有
# next != nil 的守卫，所以确认验收后不会再发下一阶段提示词。
if ! grep -qF 'guard let next = card.stage.next' "$PROMPTS" \
   || ! grep -qF 'updated.stage.next != nil' "$PANEL"; then
  echo "FAIL: acceptance is the last stage and must not continue to a next stage" >&2
  exit 1
fi
if ! grep -qF 'workstreamsPanel.onStageConfirmed' "$MAIN" \
   || ! grep -qF 'func continueWorkstreamInSession(' "$MAIN" \
   || ! grep -qF 'WorkstreamHandoff.prompt(card: card, stage: stage, workspace: workspace)' "$MAIN"; then
  echo "FAIL: main.swift is missing the next-stage handoff wiring" >&2
  exit 1
fi
# 无绑定会话不发（绝不凭空起会话）。
if ! grep -qF 'WSStore.workstreamSessions(workspace)[card.id]' "$MAIN" \
   || ! grep -qF 'guard let sessionId = bound, !sessionId.isEmpty else' "$MAIN" \
   || ! grep -qF 'next-stage handoff skipped' "$MAIN"; then
  echo "FAIL: the handoff must be skipped when the workstream has no bound session" >&2
  exit 1
fi
echo "对话内阶段推进 guard ok"

echo "--- 创建任务抽屉 guard (UX: 事项卡抽屉 + 阶段选择 + 首行标题/其余内容) ---"
# 阶段卡的「＋创建任务」入口与 onCreateStageTask 已移除；创建任务移到事项卡，复用
# WSInlineForms 的表单抽屉（WSStageTaskComposerView / WSFormSheetHostView）。
if grep -qE 'onCreateStageTask|workstreams\.stage\.createTask' "$PANEL" "$MAIN"; then
  echo "FAIL: the stage card must no longer create tasks (onCreateStageTask / workstreams.stage.createTask)" >&2
  exit 1
fi
for needle in 'onCreateTask' 'func createTaskButton()' 'openCreateTask(' \
              'submitCreateTask(' 'WSStageTaskComposerView' 'WSFormSheetHostView' \
              'WSStageTaskComposerModel.forCard(' 'contents: [composer.body]'; do
  if ! grep -qF "$needle" "$PANEL"; then
    echo "FAIL: WorkstreamsPanel.swift is missing $needle" >&2
    exit 1
  fi
done
# 抽屉表单：阶段选择器 + 多行输入 + 标题为空禁用 + ⌘↩ / Esc。
FORMS="$SRC2/WSInlineForms.swift"
for needle in 'final class WSStageTaskComposerView' 'let stagePopup: NSPopUpButton' \
              'WSStageTaskComposerModel' 'submitButton.isEnabled = model.canSubmit' \
              'cancelOperation' 'insertNewline'; do
  if ! grep -qF "$needle" "$FORMS"; then
    echo "FAIL: WSInlineForms.swift is missing $needle" >&2
    exit 1
  fi
done
# 纯视图模型：首行标题 / 其余内容 + 默认首个未处理阶段。
if ! grep -qF 'struct WSStageTaskComposerModel' "$SRC2/WorkstreamsUI.swift" \
   || ! grep -qF 'static func forCard(' "$SRC2/WorkstreamsUI.swift" \
   || ! grep -qF 'wsFirstUnprocessedStage(card) ?? card.stage' "$SRC2/WorkstreamsUI.swift"; then
  echo "FAIL: WorkstreamsUI.swift is missing the stage task composer model" >&2
  exit 1
fi
# 面板输入的内容附在阶段交接提示词之后（body 仍以提示词开头，runner 靠它识别交接）。
if ! grep -qF 'content: String = ""' "$PROMPTS" \
   || ! grep -qF 'contents: [String] = []' "$SRC2/WorkstreamsRunner.swift" \
   || ! grep -qF '任务内容：' "$PROMPTS"; then
  echo "FAIL: the stage task prompt/runner must carry the drawer content" >&2
  exit 1
fi
# L10n 键成对（按钮 / 抽屉标签 / 提交）。
for key in workstreams.task.new workstreams.task.create.stage \
           workstreams.task.create.content workstreams.task.create.submit; do
  if ! grep -qF "$key" "$MAIN"; then
    echo "FAIL: main.swift is missing the $key L10n key" >&2
    exit 1
  fi
done
# UI 测试实际覆盖了默认阶段与标题 / 内容拆分。
if ! grep -qF 'WSStageTaskComposerModel.forCard(' ui-tests.swift \
   || ! grep -qF '第一行内容' ui-tests.swift; then
  echo "FAIL: the composer default-stage / one-box rules are not pinned by ui-tests" >&2
  exit 1
fi
echo "创建任务抽屉 guard ok"


echo "--- home summary guard (任务会话 → 主场会话：阶段批量 + 例外即时) ---"
SUMMARY="$SRC2/WorkstreamsSummary.swift"
if [ ! -f "$SUMMARY" ]; then
  echo "FAIL: WorkstreamsSummary.swift is missing" >&2
  exit 1
fi
for sym in 'struct WSSummary' 'enum WSSummaryKind' 'struct WSSummaryFacts' \
           'struct WSSummaryTask' 'func stageKey(' 'func homeSession(' 'func stageFinished('; do
  if ! grep -qF "$sym" "$SUMMARY"; then
    echo "FAIL: WorkstreamsSummary.swift is missing $sym" >&2
    exit 1
  fi
done
# 文案必须带状态 / 汇报 / PR / 提交，并明确「不是人工确认」。
for needle in '状态：' '汇报：' 'PR：' '提交：' '不代表人已确认'; do
  if ! grep -qF "$needle" "$SUMMARY"; then
    echo "FAIL: the summary copy is missing $needle" >&2
    exit 1
  fi
done
# runner：applyFinish 之后触发；例外即时 + 阶段批量去重；失败路径一律走 applyFinish。
RUNNER="$SRC2/WorkstreamsRunner.swift"
for needle in 'summaryFacts:' 'onSummary:' 'summarizedStages' \
              'emitSummary(taskID: taskID, outcome: outcome)' 'stageFinished(forWorkstream:'; do
  if ! grep -qF "$needle" "$RUNNER"; then
    echo "FAIL: WorkstreamsRunner.swift is missing $needle" >&2
    exit 1
  fi
done
if [ "$(grep -c 'applyFinish(taskID:' "$RUNNER")" -lt 4 ]; then
  echo "FAIL: timeout / session-gone / start failures must route through applyFinish" >&2
  exit 1
fi
if [ "$(grep -c 'board.markFailed(' "$RUNNER")" -ne 1 ]; then
  echo "FAIL: board.markFailed must stay in applyFinish (one summary trigger point)" >&2
  exit 1
fi
# panel：汇总事实来自 WS 卡；发进主场会话，无绑定不发。
for needle in 'onSummary:' 'summaryFacts:' 'private func sendSummary(' \
              'WorkstreamsSummary.homeSession(' 'no home session'; do
  if ! grep -qF "$needle" "$PANEL"; then
    echo "FAIL: WorkstreamsPanel.swift is missing $needle" >&2
    exit 1
  fi
done
if ! grep -A18 'private func sendSummary(' "$PANEL" | grep -qF 'WorkstreamsSummary.homeSession('; then
  echo "FAIL: sendSummary must resolve the home session before sending (no binding = no send)" >&2
  exit 1
fi
# 测试覆盖触发时机与文案（阶段批量 / 例外 / 无绑定）。
for needle in 'home summary: stage batch once, exceptions immediate' \
              'home summary: a failed task summarizes immediately (exception)' \
              'home summary: needsReview summarizes immediately (exception)' \
              'home session lookup: no binding = do not send' \
              'text carries the PR fact' 'text carries the commit fact'; do
  if ! grep -qF "$needle" runner-tests.swift; then
    echo "FAIL: runner-tests.swift is missing the summary coverage: $needle" >&2
    exit 1
  fi
done
echo "home summary guard ok"

echo "--- 4 阶段 + 交付操作同步 guard (A17: four stages, delivery is an operation) ---"
# 阶段只有规划 / 设计 / 执行 / 验收；旧卡的 stage: delivery 读出即 acceptance（写回也只写
# acceptance），交付是验收确认后的操作，不是第五个阶段。
if ! grep -qF 'if value == "delivery" { return .acceptance }' "$SRC2/WorkstreamsCore.swift"; then
  echo "FAIL: WorkstreamsCore must read a legacy stage: delivery as acceptance" >&2
  exit 1
fi
if grep -qE '^    case delivery$' "$SRC2/WorkstreamsCore.swift"; then
  echo "FAIL: WorkstreamStage must only have the four stages (no delivery)" >&2
  exit 1
fi
# 门：验收是最后阶段；交付准入只认 accepted(ws)，不按 stage == .delivery。
if ! grep -qF 'static func accepted(' "$SRC2/WorkstreamsStageGate.swift" \
   || ! grep -qF 'WorkstreamsStageGate.accepted(card)' "$SRC2/WorkstreamsDelivery.swift"; then
  echo "FAIL: delivery admission must be accepted(ws), not a delivery stage" >&2
  exit 1
fi
if grep -qE 'stage == \.delivery|notDeliveryStage' "$SRC2/WorkstreamsDelivery.swift"; then
  echo "FAIL: WorkstreamsDelivery must not gate on a delivery stage" >&2
  exit 1
fi
# L10n：四阶段口径（交付阶段的标签与交付证据键已删除，旧卡仍由读兼容映射）。
for key in workstreams.stage.delivery workstreams.evidence.delivery.pr \
           workstreams.evidence.delivery.outcome workstreams.evidence.pr \
           workstreams.evidence.outcome workstreams.evidence.url; do
  if grep -qF "$key" "$MAIN"; then
    echo "FAIL: main.swift still carries the stale 5-stage key $key" >&2
    exit 1
  fi
done
# 技能：只列四个 stage，交付是 accepted 之后的操作，在主场会话执行。
if grep -qF 'not-delivery-stage' "$SKILL"; then
  echo "FAIL: the workstream-panel skill still treats delivery as a stage" >&2
  exit 1
fi
for needle in 'planning` / `design` / `task` / `acceptance`' 'not-accepted' \
              'no-home-session' '验收之后的操作' '不新建会话'; do
  if ! grep -qF "$needle" "$SKILL"; then
    echo "FAIL: the workstream-panel skill is missing $needle" >&2
    exit 1
  fi
done
echo "4-stage + delivery-operation guard ok"

echo "workstreams-panel tests passed"
