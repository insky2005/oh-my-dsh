#!/bin/bash
# Headless tests for the Requirements Pool panel:
#   1. the pure model (RequirementsCore.swift): frontmatter parsing, effective-state
#      derivation, create/state/propose/confirm/reject with atomic writes;
#   2. the localhost API router (RequirementsAPI.swift): routing, validation, error
#      codes and response shapes (no AppKit, no disk).
# No dsh server, no window. Usage: tests/requirements-panel/run.sh
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p ../../.build/module-cache
CACHE="$(cd ../../.build/module-cache && pwd)"

echo "--- requirements model (frontmatter / derivation / writes / breakdown) ---"
TMP="$(mktemp -d)"
cp ../../platforms/macos/src/RequirementsCore.swift "$TMP/RequirementsCore.swift"
cp ../../platforms/macos/src/RequirementsUI.swift "$TMP/RequirementsUI.swift"
cp model-tests.swift "$TMP/main.swift"   # top-level code needs the main.swift name
swiftc -swift-version 5 -module-cache-path "$CACHE" \
  -o "$TMP/model-tests" "$TMP/RequirementsCore.swift" "$TMP/RequirementsUI.swift" "$TMP/main.swift"
"$TMP/model-tests"
rm -rf "$TMP"

echo "--- requirements API (routing / validation / error codes) ---"
TMP="$(mktemp -d)"
cp ../../platforms/macos/src/RequirementsCore.swift "$TMP/RequirementsCore.swift"
cp ../../platforms/macos/src/RequirementsAPI.swift "$TMP/RequirementsAPI.swift"
cp api-tests.swift "$TMP/main.swift"
swiftc -swift-version 5 -module-cache-path "$CACHE" \
  -o "$TMP/api-tests" "$TMP/RequirementsCore.swift" "$TMP/RequirementsAPI.swift" "$TMP/main.swift"
"$TMP/api-tests"
rm -rf "$TMP"

echo "requirements-panel tests passed"
