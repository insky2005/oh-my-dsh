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
cp runner-tests.swift "$TMP/main.swift"   # top-level code needs the main.swift name
swiftc -swift-version 5 -module-cache-path "$CACHE" \
  -o "$TMP/tasks-runner-tests" "$TMP/TasksCore.swift" "$TMP/TasksStore.swift" \
  "$TMP/TasksRunner.swift" "$TMP/main.swift"
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

echo "tasks-panel tests passed"
