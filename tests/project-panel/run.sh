#!/bin/bash
# Headless unit tests for the Project Panel model layer (ProjectTemplates.swift):
# manifest parsing / store merge / placeholder rendering / dry-run planning /
# execution (files + git + command) / idempotence / template duplication.
# Pure Foundation, no AppKit. Usage: tests/project-panel/run.sh
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p ../../.build/module-cache
CACHE="$(cd ../../.build/module-cache && pwd)"
TMP="$(mktemp -d)"
cp ../../platforms/macos/src/ProjectTemplates.swift "$TMP/ProjectTemplates.swift"
cp project-tests.swift "$TMP/main.swift"
swiftc -swift-version 5 -module-cache-path "$CACHE"   -o "$TMP/project-tests" "$TMP/ProjectTemplates.swift" "$TMP/main.swift"
"$TMP/project-tests"
rm -rf "$TMP"
