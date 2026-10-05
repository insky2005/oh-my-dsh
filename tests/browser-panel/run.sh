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
cp ../../platforms/macos/src/PanelSurface.swift "$TMP/PanelSurface.swift"   # 面板底色 token
# The same localhost service also carries the TASKS panel's routes (/api/tasks/*,
# TasksAPI.swift) and the REQUIREMENTS pool panel's routes (/api/requirements/*,
# RequirementsAPI.swift). Both are pure models; they need the task/queue and
# requirement types, so those model files come along too — that also pins the
# three路由面 sitting on one server.
cp ../../platforms/macos/src/TasksAPI.swift "$TMP/TasksAPI.swift"
cp ../../platforms/macos/src/TasksCore.swift "$TMP/TasksCore.swift"
cp ../../platforms/macos/src/RequirementsAPI.swift "$TMP/RequirementsAPI.swift"
cp ../../platforms/macos/src/RequirementsCore.swift "$TMP/RequirementsCore.swift"
cp browser-tests.swift "$TMP/main.swift"   # top-level code needs the main.swift name
swiftc -swift-version 5 -module-cache-path "$CACHE" -framework AppKit \
  -o "$TMP/browser-tests" "$TMP/stubs.swift" "$TMP/PanelSurface.swift" "$TMP/BrowserPanel.swift" \
  "$TMP/BrowserAPI.swift" "$TMP/TasksAPI.swift" "$TMP/TasksCore.swift" \
  "$TMP/RequirementsAPI.swift" "$TMP/RequirementsCore.swift" \
  "$TMP/BrowserCDP.swift" "$TMP/main.swift"
"$TMP/browser-tests"
rm -rf "$TMP"
