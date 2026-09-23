#!/bin/bash
# Headless unit tests for the snapshot UI data model (SnapshotModel.swift):
# decoding `ohmy-core snapshot list|status|plan-rollback` JSON for display.
# Pure Foundation, no AppKit; the CLI itself is covered by
# tests/snapshot-rollback/run.sh (end-to-end, real files).
# Usage: tests/snapshot-panel/run.sh
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p ../../.build/module-cache
CACHE="$(cd ../../.build/module-cache && pwd)"
TMP="$(mktemp -d)"
cp ../../platforms/macos/src/SnapshotModel.swift "$TMP/SnapshotModel.swift"
cp snapshot-tests.swift "$TMP/main.swift"   # top-level code needs the main.swift name
swiftc -swift-version 5 -module-cache-path "$CACHE" \
  -o "$TMP/snapshot-tests" "$TMP/SnapshotModel.swift" "$TMP/main.swift"
"$TMP/snapshot-tests"
rm -rf "$TMP"
