#!/bin/bash
# Headless unit tests for ShellConfig (platforms/macos/src/ShellConfig.swift):
# the one-time merge of pre-1.14 UserDefaults settings into
# $DSH_HOME/shell/config.json. No window, no app, no core CLI.
# Usage: tests/shell-config/run.sh
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p ../../.build/module-cache
CACHE="$(cd ../../.build/module-cache && pwd)"
TMP="$(mktemp -d)"
cp stubs.swift "$TMP/stubs.swift"
cp ../../platforms/macos/src/ShellConfig.swift "$TMP/ShellConfig.swift"
cp shell-config-tests.swift "$TMP/main.swift"   # top-level code needs the main.swift name
swiftc -swift-version 5 -module-cache-path "$CACHE" -framework Foundation \
  -o "$TMP/shell-config-tests" "$TMP/stubs.swift" "$TMP/ShellConfig.swift" "$TMP/main.swift"
"$TMP/shell-config-tests"
rm -rf "$TMP"
