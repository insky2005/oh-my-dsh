#!/bin/bash
# Headless unit tests for the Browser panel model layer (BrowserPanel.swift +
# BrowserAPI.swift + BrowserCDP.swift): log buffer, URL normalization, HTTP
# request parsing and REST routing. No window/CEF instantiation, so they run
# anywhere (CEFShim 经 ObjC 头导入，测试不实例化，无需链接 CEF 产物)。
# Usage: tests/browser-panel/run.sh
set -euo pipefail
cd "$(dirname "$0")"
# swiftc 需要 module-cache；CI 干净环境没有 .build/，先建好再 cd。
mkdir -p ../../.build/module-cache
CACHE="$(cd ../../.build/module-cache && pwd)"
TMP="$(mktemp -d)"
cp ../terminal-emulator/stubs.swift "$TMP/stubs.swift"
cp ../../platforms/macos/src/BrowserPanel.swift "$TMP/BrowserPanel.swift"
cp ../../platforms/macos/src/BrowserAPI.swift "$TMP/BrowserAPI.swift"
cp ../../platforms/macos/src/BrowserCDP.swift "$TMP/BrowserCDP.swift"
cp browser-tests.swift "$TMP/main.swift"   # top-level code needs the main.swift name
swiftc -swift-version 5 -module-cache-path "$CACHE" -framework AppKit \
  -o "$TMP/browser-tests" "$TMP/stubs.swift" "$TMP/BrowserPanel.swift" "$TMP/BrowserAPI.swift" "$TMP/BrowserCDP.swift" "$TMP/main.swift"
"$TMP/browser-tests"
rm -rf "$TMP"
