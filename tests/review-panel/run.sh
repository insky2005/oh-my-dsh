#!/bin/bash
# Headless unit tests for the Review (change audit) panel data model
# (ReviewLogModel.swift): decoding the core CLI JSON and folding it for display.
# Pure Foundation, no AppKit. The audit itself is covered by
# node --test core/tests/review-log.test.js. Usage: tests/review-panel/run.sh
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p ../../.build/module-cache
CACHE="$(cd ../../.build/module-cache && pwd)"
TMP="$(mktemp -d)"
cp ../../platforms/macos/src/ReviewLogModel.swift "$TMP/ReviewLogModel.swift"
cp review-tests.swift "$TMP/main.swift"
swiftc -swift-version 5 -module-cache-path "$CACHE" \
  -o "$TMP/review-tests" "$TMP/ReviewLogModel.swift" "$TMP/main.swift"
"$TMP/review-tests"

echo "--- review panel controller (headless regression: a live session's log) ---"
# Separate build dir: top-level code must live in a file named main.swift, and
# the model-layer binary above already owns the outer one.
mkdir -p "$TMP/panel"
cp controller-stubs.swift "$TMP/panel/stubs.swift"
cp ../../platforms/macos/src/ReviewLogModel.swift "$TMP/panel/ReviewLogModel.swift"
cp ../../platforms/macos/src/ReviewPanel.swift "$TMP/panel/ReviewPanel.swift"
cp ../../platforms/macos/src/PanelSurface.swift "$TMP/panel/PanelSurface.swift"   # 面板底色 token
cp controller-tests.swift "$TMP/panel/main.swift"
swiftc -swift-version 5 -module-cache-path "$CACHE" -framework AppKit \
  -o "$TMP/review-controller-tests" "$TMP/panel/"*.swift
"$TMP/review-controller-tests"

rm -rf "$TMP"
