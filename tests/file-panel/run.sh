#!/bin/bash
# Headless tests for the Files panel (FilePanel.swift / CodeEditorView.swift):
#   1. WorkspaceTabMemory model — the per-workspace "which tabs were open" store;
#   2. the real FilePanelController driven through workspace switches, the Close
#      action and folder/file tabs (no window, no dsh server).
# AppKit views are instantiated without a run loop; Highlightr's bundle assets
# are absent in the test binary, so editors degrade to plain text (by design).
# Usage: tests/file-panel/run.sh
set -euo pipefail
cd "$(dirname "$0")"                 # tests/file-panel
SRC="../../platforms/macos/src"
mkdir -p ../../.build/module-cache
CACHE="$(cd ../../.build/module-cache && pwd)"

echo "--- workspace tab memory (model) ---"
TMP="$(mktemp -d)"
cp "$SRC/WorkspaceTabMemory.swift" "$TMP/WorkspaceTabMemory.swift"
cp workspace-tab-tests.swift "$TMP/main.swift"   # top-level code needs the main.swift name
swiftc -swift-version 5 -module-cache-path "$CACHE" \
  -o "$TMP/workspace-tab-tests" "$TMP/WorkspaceTabMemory.swift" "$TMP/main.swift"
"$TMP/workspace-tab-tests"
rm -rf "$TMP"

echo "--- open project directory with… (model) ---"
TMP="$(mktemp -d)"
cp "$SRC/OpenWithApps.swift" "$TMP/OpenWithApps.swift"
cp open-with-tests.swift "$TMP/main.swift"
swiftc -swift-version 5 -module-cache-path "$CACHE" \
  -o "$TMP/open-with-tests" "$TMP/OpenWithApps.swift" "$TMP/main.swift"
"$TMP/open-with-tests"
rm -rf "$TMP"

echo "--- tree context menu (model) ---"
TMP="$(mktemp -d)"
cp "$SRC/FilePanelTreeMenu.swift" "$TMP/FilePanelTreeMenu.swift"
cp tree-menu-tests.swift "$TMP/main.swift"
swiftc -swift-version 5 -module-cache-path "$CACHE" \
  -o "$TMP/tree-menu-tests" "$TMP/FilePanelTreeMenu.swift" "$TMP/main.swift"
"$TMP/tree-menu-tests"
rm -rf "$TMP"

echo "--- injected composer script (lint) ---"
# The bridge script is a SWIFT string literal injected into dsh web: a lone
# backslash escape is eaten by Swift before the page sees it (a raw newline
# inside a JS string literal then breaks parsing and the bridge silently never
# installs — exactly how it shipped broken once). It must stay escape-free.
python3 - "$SRC/main.swift" <<'PY'
import re, sys, pathlib
src = pathlib.Path(sys.argv[1]).read_text()
m = re.search(r'private static let composerReferenceScript = """\n(.*?)\n    """', src, re.S)
assert m, "composerReferenceScript block not found in main.swift"
bad = [line for line in m.group(1).splitlines() if "\\" in line]
assert not bad, "injected script must not contain backslash escapes: " + " | ".join(bad)
print("ok - composerReferenceScript is escape-free (%d lines)" % len(m.group(1).splitlines()))
PY

echo "--- composer reference grammar (model) ---"
TMP="$(mktemp -d)"
cp "$SRC/ComposerReference.swift" "$TMP/ComposerReference.swift"
cp composer-reference-tests.swift "$TMP/main.swift"
swiftc -swift-version 5 -module-cache-path "$CACHE" \
  -o "$TMP/composer-reference-tests" "$TMP/ComposerReference.swift" "$TMP/main.swift"
"$TMP/composer-reference-tests"
rm -rf "$TMP"

echo "--- image preview zoom (model) ---"
TMP="$(mktemp -d)"
cp "$SRC/ImageZoom.swift" "$TMP/ImageZoom.swift"
cp image-zoom-tests.swift "$TMP/main.swift"
swiftc -swift-version 5 -module-cache-path "$CACHE" \
  -o "$TMP/image-zoom-tests" "$TMP/ImageZoom.swift" "$TMP/main.swift"
"$TMP/image-zoom-tests"
rm -rf "$TMP"

echo "--- editor load policy (model) ---"
TMP="$(mktemp -d)"
cp "$SRC/EditorLoadPolicy.swift" "$TMP/EditorLoadPolicy.swift"
cp editor-load-policy-tests.swift "$TMP/main.swift"
swiftc -swift-version 5 -module-cache-path "$CACHE" \
  -o "$TMP/editor-load-policy-tests" "$TMP/EditorLoadPolicy.swift" "$TMP/main.swift"
"$TMP/editor-load-policy-tests"
rm -rf "$TMP"

echo "--- file panel workspace hand-off (panel) ---"
TMP="$(mktemp -d)"
cp ../terminal-emulator/stubs.swift "$TMP/stubs.swift"   # L10n/AppLog/ShellConfig/共享 UI 基件
cp "$SRC/FilePanel.swift" "$TMP/FilePanel.swift"
cp "$SRC/CodeEditorView.swift" "$TMP/CodeEditorView.swift"
cp "$SRC/PanelSurface.swift" "$TMP/PanelSurface.swift"   # 面板底色 token
cp "$SRC/WorkspaceTabMemory.swift" "$TMP/WorkspaceTabMemory.swift"
cp "$SRC/OpenWithApps.swift" "$TMP/OpenWithApps.swift"   # 项目目录「用外部应用打开」catalog（#2）
cp "$SRC/FilePanelTreeMenu.swift" "$TMP/FilePanelTreeMenu.swift"   # 目录树右键菜单模型（#1）
cp "$SRC/ComposerReference.swift" "$TMP/ComposerReference.swift"   # @ 引用语法（右键「添加到对话」）
cp "$SRC/EditorLoadPolicy.swift" "$TMP/EditorLoadPolicy.swift"     # 大文件高亮/重载策略
cp "$SRC/ImagePreviewView.swift" "$TMP/ImagePreviewView.swift"     # 图片预览（自适应 + 缩放）
cp "$SRC/ImageZoom.swift" "$TMP/ImageZoom.swift"                   # 缩放数学（纯模型）
cp "$SRC"/vendor/Highlightr/*.swift "$TMP/"
cp panel-switch-tests.swift "$TMP/main.swift"
swiftc -swift-version 5 -module-cache-path "$CACHE" \
  -framework AppKit -framework PDFKit -framework JavaScriptCore \
  -o "$TMP/panel-switch-tests" \
  "$TMP/stubs.swift" "$TMP/PanelSurface.swift" "$TMP/FilePanel.swift" "$TMP/CodeEditorView.swift" \
  "$TMP/WorkspaceTabMemory.swift" "$TMP/OpenWithApps.swift" "$TMP/FilePanelTreeMenu.swift" \
  "$TMP/ComposerReference.swift" \
  "$TMP/EditorLoadPolicy.swift" "$TMP/ImagePreviewView.swift" "$TMP/ImageZoom.swift" \
  "$TMP"/Highlightr.swift "$TMP"/CodeAttributedString.swift \
  "$TMP"/Theme.swift "$TMP"/HTMLUtils.swift "$TMP"/Shims.swift "$TMP/main.swift"
"$TMP/panel-switch-tests"
rm -rf "$TMP"
