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
#      (stage, action) prompt for planning / design / task / acceptance / delivery,
#      injection into a stage queue task's body and the execution completion marker.
#   6. the delivery pipeline (WorkstreamsDelivery.swift): git remote / github / base
#      detection, PR lookup and the token file layout, plus every refusal reason
#      (notDeliveryStage / notGitRepo / noBranch / noRemote / noGitHubRemote / noToken).
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
cp ../../platforms/macos/src/WorkstreamsQueues.swift "$TMP/WorkstreamsQueues.swift"
cp ../../platforms/macos/src/WorkstreamsPrompts.swift "$TMP/WorkstreamsPrompts.swift"
cp ../../platforms/macos/src/WorkstreamsRunner.swift "$TMP/WorkstreamsRunner.swift"
cp runner-tests.swift "$TMP/main.swift"   # top-level code needs the main.swift name
swiftc -swift-version 5 -module-cache-path "$CACHE" \
  -o "$TMP/runner-tests" "$TMP/WorkstreamsCore.swift" "$TMP/WorkstreamsQueues.swift" \
  "$TMP/WorkstreamsPrompts.swift" "$TMP/WorkstreamsRunner.swift" "$TMP/main.swift"
"$TMP/runner-tests"
rm -rf "$TMP"

echo "--- workstreams stage handoff prompts (planning / design / task / acceptance / delivery) ---"
TMP="$(mktemp -d)"
cp ../../platforms/macos/src/WorkstreamsCore.swift "$TMP/WorkstreamsCore.swift"
cp ../../platforms/macos/src/WorkstreamsQueues.swift "$TMP/WorkstreamsQueues.swift"
cp ../../platforms/macos/src/WorkstreamsPrompts.swift "$TMP/WorkstreamsPrompts.swift"
cp ../../platforms/macos/src/WorkstreamsRunner.swift "$TMP/WorkstreamsRunner.swift"
cp prompt-tests.swift "$TMP/main.swift"   # top-level code needs the main.swift name
swiftc -swift-version 5 -module-cache-path "$CACHE" \
  -o "$TMP/prompt-tests" "$TMP/WorkstreamsCore.swift" "$TMP/WorkstreamsQueues.swift" \
  "$TMP/WorkstreamsPrompts.swift" "$TMP/WorkstreamsRunner.swift" "$TMP/main.swift"
"$TMP/prompt-tests"
rm -rf "$TMP"

echo "--- workstreams delivery (git pipeline / GitHub PR / token file reading, A10) ---"
TMP="$(mktemp -d)"
cp ../../platforms/macos/src/WorkstreamsCore.swift "$TMP/WorkstreamsCore.swift"
cp ../../platforms/macos/src/WorkstreamsDelivery.swift "$TMP/WorkstreamsDelivery.swift"
cp delivery-tests.swift "$TMP/main.swift"   # top-level code needs the main.swift name
swiftc -swift-version 5 -module-cache-path "$CACHE" \
  -o "$TMP/delivery-tests" "$TMP/WorkstreamsCore.swift" "$TMP/WorkstreamsDelivery.swift" "$TMP/main.swift"
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
ENGINE="$SRC2/WorkstreamsQueues.swift $SRC2/WorkstreamsRunner.swift $SRC2/WorkstreamsDelivery.swift"
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
           'enum WSDeliveryBlocker' 'struct WSDeliveryPlan' 'static func resolve(' 'static func prompt(plan:'; do
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
for sym in planningEvidence designEvidence executionEvidence acceptanceEvidence deliveryEvidence confirmStage rejectStage; do
  if ! grep -qE "func $sym\b" "$GATE"; then
    echo "FAIL: WorkstreamsStageGate.swift is missing $sym" >&2
    exit 1
  fi
done
if ! grep -q 'evidenceMissing' "$GATE"; then
  echo "FAIL: the gate must refuse confirmation when evidence is missing" >&2
  exit 1
fi
# The agent-facing routes must reach the panel; the human gate is a separate route.
if ! grep -q '/api/workstreams/stage/confirm' "$SRC2/WorkstreamsAPI.swift" \
   || ! grep -q '/api/workstreams/stage/reject' "$SRC2/WorkstreamsAPI.swift"; then
  echo "FAIL: the stage confirm / reject routes are missing from WorkstreamsAPI.swift" >&2
  exit 1
fi
echo "workstreams stage gate guard ok"

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
# 五个阶段的中文名 + 执行阶段的两个动作，缺一不可（design §4）。
for needle in 规划 设计 执行 验收 交付 拆分任务 启动实施; do
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

echo "--- workstreams run state guard (A13: derived, never moves the authoritative stage) ---"
RUNSTATE="$SRC2/WorkstreamsRunState.swift"
if [ ! -f "$RUNSTATE" ]; then
  echo "FAIL: WorkstreamsRunState.swift is missing" >&2
  exit 1
fi
for sym in 'enum WSRunState' 'static func stage(' 'static func workstream(' \
           'static func reworkStage(' 'static func deliveryConfirmed('; do
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

echo "workstreams-panel tests passed"
