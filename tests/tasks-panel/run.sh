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

echo "tasks-panel tests passed"
