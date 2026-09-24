#!/bin/bash
# Headless tests for the Tasks panel logic layer:
#   - TasksCore.swift   the task/queue model, branch naming, queue operations,
#                       summary counts and restart recovery (pure value type);
#   - TasksStore.swift  the four-file persistence under .dsh/tasks/
#                       (index.json v1 shape / manual.json / queues.json /
#                       local.json with its legacy session keys);
#   - TasksRunner.swift the serial queue runner: git branch entry, dsh session,
#                       prompt, push check, queue-level PR, cancel/retry/skip,
#                       restart recovery — driven by a scripted git + dsh.
# No window, no dsh server, no AppKit. Usage: tests/tasks-panel/run.sh
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

echo "tasks-panel tests passed"
