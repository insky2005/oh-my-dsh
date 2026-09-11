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
rm -rf "$TMP"
