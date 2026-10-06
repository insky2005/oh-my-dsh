#!/bin/bash
# Headless tests for the Workstreams panel model layer:
#   1. the pure model (WorkstreamsCore.swift): frontmatter parsing, the five
#      stages, queues [{id, stage}], covered / delivery blocks, validation, and
#      create / update / stage / queues writes with atomic rename + six-digit ids.
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

echo "workstreams-panel tests passed"
