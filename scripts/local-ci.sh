#!/bin/bash
#
# scripts/local-ci.sh — 本机 CI：与 .github/workflows/ci.yml 完全对齐的三阶段
# 流程（core → swift → build），不发布、不打包 pkg/dmg。
#
# 对应 GitHub CI job：
#   阶段1 core  ↔  ci.yml 的 core  job（Node 单测，GitHub 上跑 ubuntu）
#   阶段2 swift ↔  ci.yml 的 swift job（模拟器/面板测试 + swiftc 编译检查）
#   阶段3 build ↔  ci.yml 的 build job（build-app.sh + 产物校验，不含 make-pkg）
#
# 用法：
#   scripts/local-ci.sh                # 默认 full：跑通所有阶段（arm64 构建）
#   scripts/local-ci.sh full           # 同默认：所有阶段（arm64 构建）
#   scripts/local-ci.sh arm64          # 所有阶段，build 用 arm64（与矩阵一致）
#   scripts/local-ci.sh test           # 只跑阶段1(core)+阶段2(swift) 的测试
#   scripts/local-ci.sh swift          # 只跑阶段2(swift)：测试 + swiftc 编译检查
#   scripts/local-ci.sh build [arch]   # 只跑阶段3(build)：build-app.sh + 校验（不打包）
#
# 与 GitHub CI 的差异（本地环境的合理简化）：
#   - GitHub 在 ubuntu 上跑 core、在 macos-14 上跑其余；本地只有一台 macOS，顺序执行。
#   - GitHub 每次是干净工作区靠 actions/cache 缓存；本地复用 .cache/（等价缓存命中）。
#   - CI 只做 arm64 构建校验（x86_64 交叉编译由 release.yml 打 tag 时校验），
#     不打包 pkg/dmg —— 打包属 release。
#   - GitHub 构建显式走官方 npm registry / Node 镜像（DSH_NPM_REGISTRY /
#     DSH_NODE_MIRROR）；本地默认 npmmirror（国内更快）。
set -euo pipefail
cd "$(dirname "$0")/.."   # 仓库根

CMD="${1:-}"
ARG="${2:-arm64}"

# ===== 脚本实现见下方（勿改帮助文案） =====
usage() {
  # 只打印头部说明注释（到 "===== 脚本实现" 分隔线之前）
  sed -n '2,/^# ===== 脚本实现/p' "$0" | sed -E 's/^# ?//' | sed '$d'
  exit 0
}
[ "$CMD" = "-h" ] || [ "$CMD" = "--help" ] && usage

[ "$(uname)" = "Darwin" ] || { echo "ERROR: this project must be built on macOS." >&2; exit 1; }
for t in swiftc codesign iconutil lipo pkgbuild hdiutil curl python3 node; do
  command -v "$t" >/dev/null 2>&1 || { echo "ERROR: missing tool '$t' (need Xcode CLT + node)." >&2; exit 1; }
done

# ---------- 阶段1 core：Node 单测（ci.yml core job） ----------
stage_core() {
  echo "==> [1/3 core] node unit tests (core job)"
  node --test core/tests/*.test.js
}

# ---------- 阶段2 swift：面板测试 + swiftc 编译检查（ci.yml swift job） ----------
stage_swift() {
  echo "==> [2/3 swift] panel tests + swiftc compile check (swift job)"
  echo "--- terminal emulator (migrated to core) ---"
  node --test core/tests/ansi.test.js
  echo "--- wiki panel tests ---"
  tests/wiki-panel/run.sh
  echo "--- browser panel tests ---"
  tests/browser-panel/run.sh
  echo "--- build CEF integration artifacts (arm64) ---"
  mkdir -p .build/module-cache
  platforms/macos/build-cef.sh arm64
  echo "--- swiftc compile check (all sources) ---"
  mkdir -p .build/module-cache
  swiftc -O -swift-version 5 -module-cache-path .build/module-cache \
    -framework AppKit -framework WebKit -framework PDFKit \
    -Xlinker -undefined -Xlinker dynamic_lookup \
    -import-objc-header platforms/macos/cef/CEFShim.h \
    .build/cef/CEFShim-arm64.o .build/cef/libcef_dll_wrapper-arm64.a \
    -o /tmp/oh-my-dsh-check \
    platforms/macos/src/main.swift platforms/macos/src/PreviewPanel.swift platforms/macos/src/FilePanel.swift platforms/macos/src/CodeEditorView.swift platforms/macos/src/TerminalPanel.swift platforms/macos/src/WikiPanel.swift platforms/macos/src/IssueRunnerPanel.swift platforms/macos/src/BrowserPanel.swift platforms/macos/src/BrowserAPI.swift platforms/macos/src/BrowserCDP.swift platforms/macos/src/vendor/Highlightr/CodeAttributedString.swift platforms/macos/src/vendor/Highlightr/Highlightr.swift platforms/macos/src/vendor/Highlightr/Theme.swift platforms/macos/src/vendor/Highlightr/HTMLUtils.swift platforms/macos/src/vendor/Highlightr/Shims.swift
  file /tmp/oh-my-dsh-check
}

# ---------- 阶段3 build：build-app.sh + 产物校验（ci.yml build job，不打包） ----------
stage_build() {
  local a="$1"
  case "$a" in
    arm64) ;;
    *) echo "ERROR: build 阶段仅支持 arm64（与 ci.yml 矩阵一致；x86_64 由 release.yml 打 tag 时交叉编译校验）" >&2; exit 1 ;;
  esac
  echo "==> [3/3 build] build-app.sh + verify bundle (build job, arch=$a)"
  DSH_ARCH="$a" ./platforms/macos/build-app.sh
  echo "--- verify bundle ---"
  test -x dist/oh-my-dsh.app/Contents/MacOS/oh-my-dsh
  /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" dist/oh-my-dsh.app/Contents/Info.plist
  du -sh dist/oh-my-dsh.app
  echo "==> [3/3 build] done"
}

# ---------- 分发 ----------
case "$CMD" in
  test)    stage_core; stage_swift ;;
  swift)   stage_swift ;;
  build)   stage_build "$ARG" ;;
  arm64)
    stage_core
    stage_swift
    stage_build "$CMD"
    ;;
  ""|full)
    stage_core
    stage_swift
    stage_build arm64
    ;;
  *)
    echo "ERROR: unknown command '$CMD'." >&2
    usage
    ;;
esac
