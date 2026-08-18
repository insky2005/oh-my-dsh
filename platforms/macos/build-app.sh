#!/bin/bash
#
# build-app.sh — build the "oh-my-dsh" native macOS shell (.app bundle).
#
# Produces: dist/oh-my-dsh.app
# Requires: Xcode Command Line Tools (swiftc, codesign, iconutil), curl,
#           python3 (to pick the Node LTS version), and network access.
#
# The app is fully SELF-CONTAINED. Nothing is copied from the local machine's
# node/dsh installs — instead the build:
#   1. downloads the official Node.js darwin-arm64 tarball (default: latest
#      LTS; override with DSH_NODE_VERSION, e.g. v22.23.2), verifies its
#      SHA-256, and embeds the `node` binary AND `npm` (used later by the
#      app's built-in dsh upgrade feature) into Contents/Resources/runtime;
#   2. runs `npm install <dsh>` (via that downloaded Node) in
#      Contents/Resources/runtime/dsh, pulling @deepseek-ai/dsh and its whole
#      dependency closure from the npm registry (default spec:
#      @deepseek-ai/dsh@0.1.0-rc.7; override with DSH_PACKAGE_SPEC).
#
# China mirrors are used by default for speed (override with DSH_NODE_MIRROR /
# DSH_NPM_REGISTRY). Downloads and the built runtime are cached in .cache/ so
# rebuilds are fast and work offline.
#
# Usage:
#   ./build-app.sh              full build
#   ./build-app.sh --prefetch   download Node + npm-install dsh into .cache/
#                               (no .app produced) — a later full build reuses
#                               it without touching the network
#
# No DeepSeek Harness source is modified — the app only wraps `dsh web`.
#
set -euo pipefail
cd "$(dirname "$0")"
# 仓库根：脚本位于 platforms/macos/，构建缓存/产物统一放仓库根（CI 缓存、.gitignore 一致）。
ROOT="$(cd ../.. && pwd)"

APP_NAME="oh-my-dsh"
BUNDLE_ID="com.ohmydsh.app"

# 版本单一来源：VERSION 取自最近 semver git tag（vX.Y.Z），BUILD 取自 CI 运行号；
# 本地/无 tag 时由 scripts/version.sh 回退默认值。改版本 = 打 tag，勿在此硬编码。
VERSION="$("$ROOT/scripts/version.sh" | head -1)"
BUILD="$("$ROOT/scripts/version.sh" | tail -1)"

# 目标架构：arm64 / x86_64 / universal（默认本机架构）。CI 用矩阵传参。
#   DSH_ARCH=arm64|x86_64|universal ./build-app.sh
HOST_ARCH="$(uname -m)"
ARCH="${DSH_ARCH:-$HOST_ARCH}"
case "$ARCH" in
  arm64|aarch64)   ARCH="arm64" ;;
  x86_64|amd64)    ARCH="x86_64" ;;
  universal)       ;;
  *) echo "ERROR: unsupported DSH_ARCH '$ARCH' (arm64 | x86_64 | universal)" >&2; exit 1 ;;
esac

SRC="src"
BUILD_DIR="$ROOT/.build"
CACHE_DIR="$ROOT/.cache"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"

# China domestic mirrors by default (override via env)
NPM_REGISTRY="${DSH_NPM_REGISTRY:-https://registry.npmmirror.com}"
NPM_REGISTRY_OFFICIAL="https://registry.npmjs.org"
NODE_MIRROR="${DSH_NODE_MIRROR:-https://npmmirror.com/mirrors/node}"
NODE_MIRROR_OFFICIAL="https://nodejs.org/dist"

MODE="build"
case "${1:-}" in
  --prefetch) MODE="prefetch" ;;
  --help|-h)
    echo "usage: ./build-app.sh [--prefetch]"
    echo "  (default)  full build -> dist/$APP_NAME.app"
    echo "  --prefetch pre-download Node + npm-install dsh into $CACHE_DIR/runtime (no .app)"
    exit 0 ;;
esac

export TMPDIR="$BUILD_DIR/tmp"
mkdir -p "$BUILD_DIR/tmp" "$CACHE_DIR/node" "$CACHE_DIR/npm-cache"

# ---------------------------------------------------------------------------
# resolve_node_version / download_node / install_dsh / build_runtime
# ---------------------------------------------------------------------------

resolve_node_version() {
  local v="${DSH_NODE_VERSION:-}"
  if [ -z "$v" ]; then
    echo "    detecting latest Node LTS …"
    for base in "$NODE_MIRROR" "$NODE_MIRROR_OFFICIAL"; do
      v=$(curl -fsSL --max-time 30 "$base/index.json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
def key(v): return [int(x) for x in v["version"].lstrip("v").split(".")]
lts = [x for x in d if x.get("lts")]
print(max(lts, key=key)["version"])
' 2>/dev/null || true)
      [ -n "$v" ] && break
    done
  fi
  if [ -z "$v" ]; then
    local cached
    cached=$(ls "$CACHE_DIR/node"/node-v*-darwin-arm64.tar.gz 2>/dev/null | head -1 || true)
    if [ -n "$cached" ]; then
      v="v$(basename "$cached" | sed -E 's/^node-v([0-9.]+)-darwin-arm64\.tar\.gz$/\1/')"
      echo "    network unavailable; reusing cached Node $v"
    fi
  fi
  [ -z "$v" ] && { echo "ERROR: could not determine Node version (set DSH_NODE_VERSION)" >&2; exit 1; }
  NODE_VERSION="$v"
}

# node_tarball <arch> -> darwin tarball name (arm64 -> darwin-arm64, x86_64 -> darwin-x64)
node_tarball() {
  local a="$1"
  [ "$a" = "x86_64" ] && a="x64"
  echo "node-v${NODE_VERSION#v}-darwin-$a.tar.gz"
}

download_node() {
  local ver="${NODE_VERSION#v}"
  local archs="$ARCH"
  [ "$ARCH" = "universal" ] && archs="arm64 x86_64"
  local a tarball base url
  for a in $archs; do
    tarball="$(node_tarball "$a")"
    if [ ! -f "$CACHE_DIR/node/$tarball" ]; then
      for base in "$NODE_MIRROR" "$NODE_MIRROR_OFFICIAL"; do
        url="$base/v${ver}/$tarball"
        echo "    downloading $url …"
        if curl -fL --max-time 600 -o "$CACHE_DIR/node/$tarball" "$url"; then break; fi
        echo "    mirror failed, trying next…"
      done
      [ -f "$CACHE_DIR/node/$tarball" ] || { echo "ERROR: Node download failed for $a" >&2; exit 1; }
    fi
    echo "    verifying SHA-256 ($tarball) …"
    local ok=0
    for base in "$NODE_MIRROR" "$NODE_MIRROR_OFFICIAL"; do
      if ( cd "$CACHE_DIR/node" \
           && curl -fsSL --max-time 30 "$base/v${ver}/SHASUMS256.txt" \
              | grep " $tarball\$" | shasum -a 256 -c - ); then ok=1; break; fi
    done
    [ "$ok" = 1 ] || { echo "ERROR: SHA-256 verification failed for $tarball" >&2; exit 1; }
  done
}

# install_dsh <target-dir>: npm install dsh into target; registry fallback
install_dsh() {
  local target="$1"
  local spec="${DSH_PACKAGE_SPEC:-@deepseek-ai/dsh@0.1.0-rc.7}"
  mkdir -p "$target"
  ( cd "$target" \
    && npm init -y >/dev/null 2>&1 \
    && ( npm install --loglevel=error --registry "$NPM_REGISTRY" "$spec" \
         || { echo "    primary registry ($NPM_REGISTRY) failed; retrying official…" >&2; \
              npm install --loglevel=error --registry "$NPM_REGISTRY_OFFICIAL" "$spec"; } ) )
}

# build_runtime: node bin + npm + dsh tree into $CACHE_DIR/runtime (cached)
build_runtime() {
  local spec="${DSH_PACKAGE_SPEC:-@deepseek-ai/dsh@0.1.0-rc.7}"
  local stage="$CACHE_DIR/runtime"
  local info="$stage/.runtime-info"
  if [ -f "$info" ] && grep -qx "$NODE_VERSION|$spec|$ARCH" "$info" 2>/dev/null; then
    echo "    reusing previously built runtime ($NODE_VERSION + $spec, $ARCH)"
    return 0
  fi
  rm -rf "$stage"
  mkdir -p "$stage" "$CACHE_DIR/npm-cache"
  download_node
  local ver="${NODE_VERSION#v}"
  local node_stage="$BUILD_DIR/node-stage"
  rm -rf "$node_stage"
  mkdir -p "$node_stage"

  # Embed one node binary per target arch; universal embeds both (the Swift
  # resolver picks by uname -m: runtime/node-arm64 or runtime/node-x86_64).
  local archs="$ARCH"
  [ "$ARCH" = "universal" ] && archs="arm64 x86_64"
  local a node_arch dist
  for a in $archs; do
    node_arch="$( [ "$a" = "x86_64" ] && echo x64 || echo "$a" )"
    tar -xzf "$CACHE_DIR/node/node-v${ver}-darwin-$node_arch.tar.gz" -C "$node_stage"
    dist="$node_stage/node-v${ver}-darwin-$node_arch"
    ditto "$dist/bin/node" "$stage/node-$a"
    if [ "$a" = "$HOST_ARCH" ]; then
      # The host-arch binary also exists as plain `node` (keeps old layouts /
      # prefetch semantics working without a resolver change).
      ditto "$dist/bin/node" "$stage/node"
    fi
    echo "    node($a): $NODE_VERSION -> $stage/node-$a"
    if [ -z "${NPM_COPIED:-}" ]; then
      ditto "$dist/lib/node_modules/npm" "$stage/npm"
      export PATH="$dist/bin:$PATH"
      export npm_config_cache="$CACHE_DIR/npm-cache"
      export npm_config_audit=false npm_config_fund=false npm_config_update_notifier=false
      NPM_COPIED=1
    fi
  done
  install_dsh "$stage/dsh"
  rm -rf "$node_stage"
  echo "$NODE_VERSION|$spec|$ARCH" > "$info"
  echo "    runtime built: $stage ($NODE_VERSION + $spec, $ARCH)"
}

# ---------------------------------------------------------------------------

resolve_node_version

if [ "$MODE" = "prefetch" ]; then
  echo "==> [prefetch] downloading Node + npm-installing dsh …"
  build_runtime
  echo ""
  echo "Prefetched runtime ready: $CACHE_DIR/runtime"
  echo "Node: $NODE_VERSION | dsh: ${DSH_PACKAGE_SPEC:-@deepseek-ai/dsh@0.1.0-rc.7}"
  echo "A later './build-app.sh' will reuse it without network."
  exit 0
fi

echo "==> [1/7] preparing build dirs"
rm -rf "$BUILD_DIR" "$APP"
mkdir -p "$BUILD_DIR" "$DIST" "$APP/Contents/MacOS" "$APP/Contents/Resources"
# TMPDIR 在脚本开头已指向 $BUILD_DIR/tmp，rm 后必须重建（swiftc 依赖它）。
mkdir -p "$BUILD_DIR/tmp"

# swiftc needs writable caches; keep them inside the workspace (some sandboxes
# block the default clang module cache under /var/folders).
mkdir -p "$BUILD_DIR/module-cache"
SWIFTC_CACHE=(-module-cache-path "$BUILD_DIR/module-cache")

echo "==> [2/7] rendering app icon"
swiftc -O -swift-version 5 "${SWIFTC_CACHE[@]}" -o "$BUILD_DIR/makeicon" "$SRC/MakeIcon.swift"
"$BUILD_DIR/makeicon" "$BUILD_DIR/AppIcon.iconset"
iconutil -c icns "$BUILD_DIR/AppIcon.iconset" -o "$BUILD_DIR/AppIcon.icns"
cp "$BUILD_DIR/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

echo "==> [3/7] compiling app binary"
# 交叉编译：-target 指定 arch+最低系统版本（swiftc 6 不再接受裸 -arch）。
# universal = 编译两个 arch 再 lipo 合成 fat binary。
SWIFT_SOURCES=("$SRC/main.swift" "$SRC/PreviewPanel.swift" "$SRC/TerminalPanel.swift" "$SRC/WikiPanel.swift" "$SRC/IssueRunnerPanel.swift" "$SRC/BrowserPanel.swift" "$SRC/BrowserAPI.swift")
APP_BIN="$APP/Contents/MacOS/$APP_NAME"
case "$ARCH" in
  arm64)
    swiftc -O -swift-version 5 "${SWIFTC_CACHE[@]}" -target arm64-apple-macos13 \
      -framework AppKit -framework WebKit -framework PDFKit \
      -o "$APP_BIN" "${SWIFT_SOURCES[@]}"
    ;;
  x86_64)
    swiftc -O -swift-version 5 "${SWIFTC_CACHE[@]}" -target x86_64-apple-macos13 \
      -framework AppKit -framework WebKit -framework PDFKit \
      -o "$APP_BIN" "${SWIFT_SOURCES[@]}"
    ;;
  universal)
    swiftc -O -swift-version 5 "${SWIFTC_CACHE[@]}" -target arm64-apple-macos13 \
      -framework AppKit -framework WebKit -framework PDFKit \
      -o "$BUILD_DIR/oh-my-dsh-arm64" "${SWIFT_SOURCES[@]}"
    swiftc -O -swift-version 5 "${SWIFTC_CACHE[@]}" -target x86_64-apple-macos13 \
      -framework AppKit -framework WebKit -framework PDFKit \
      -o "$BUILD_DIR/oh-my-dsh-x86_64" "${SWIFT_SOURCES[@]}"
    lipo -create -output "$APP_BIN" "$BUILD_DIR/oh-my-dsh-arm64" "$BUILD_DIR/oh-my-dsh-x86_64"
    rm -f "$BUILD_DIR/oh-my-dsh-arm64" "$BUILD_DIR/oh-my-dsh-x86_64"
    ;;
esac
echo "    app binary: $ARCH ($(lipo -info "$APP_BIN" 2>/dev/null | sed 's/^Architectures in the fat file.*are: //' || file -b "$APP_BIN" | cut -d, -f1))"

echo "==> [4/7] building self-contained runtime (download node + npm install dsh)"
build_runtime
RUNTIME="$APP/Contents/Resources/runtime"
mkdir -p "$RUNTIME"
ditto "$CACHE_DIR/runtime" "$RUNTIME"
# 共享核心 core/ 一并嵌入运行时（shell 通过 node runtime/core/bin/ohmy-core.js 调用）。
if [ -d "$ROOT/core" ]; then
  ditto "$ROOT/core" "$RUNTIME/core"
  echo "    core embedded: $RUNTIME/core"
fi
echo "    runtime embedded: $RUNTIME"

echo "==> [5/7] writing Info.plist"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>zh_CN</string>
	<key>CFBundleLocalizations</key>
	<array>
		<string>zh</string>
		<string>en</string>
	</array>
	<key>CFBundleExecutable</key>
	<string>$APP_NAME</string>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$APP_NAME</string>
	<key>CFBundleDisplayName</key>
	<string>$APP_NAME</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$BUILD</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.developer-tools</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSHumanReadableCopyright</key>
	<string>Native shell wrapper around dsh web. DeepSeek Harness is MIT licensed.</string>
	<key>NSAppTransportSecurity</key>
	<dict>
		<key>NSAllowsLocalNetworking</key>
		<true/>
		<key>NSExceptionDomains</key>
		<dict>
			<key>127.0.0.1</key>
			<dict>
				<key>NSExceptionAllowsInsecureHTTPLoads</key>
				<true/>
				<key>NSIncludesSubdomains</key>
				<true/>
			</dict>
			<key>localhost</key>
			<dict>
				<key>NSExceptionAllowsInsecureHTTPLoads</key>
				<true/>
				<key>NSIncludesSubdomains</key>
				<true/>
			</dict>
		</dict>
	</dict>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> [6/7] slimming app bundle (见 docs/plans/APP_SLIM-app-size.md)"
RUNTIME="$APP/Contents/Resources/runtime"
# 1. 删除重复的纯 node（node-arm64/node-x86_64 已有，纯 node 仅是旧布局兜底；
#    bundledNode() 优先取 node-<arch>，缺失才回退纯 node）。单架构与 universal 均省 ~116M。
if [ -f "$RUNTIME/node" ] && { [ -f "$RUNTIME/node-arm64" ] || [ -f "$RUNTIME/node-x86_64" ]; }; then
  rm -f "$RUNTIME/node"
  echo "    removed duplicate node (~116M)"
fi
# 2. 删除 node-pty 的 win32 预编译（macOS 永用不到，实测 ~23M）
PYY="$RUNTIME/dsh/node_modules/node-pty/prebuilds"
if [ -d "$PYY" ]; then
  rm -rf "$PYY"/win32-*
  echo "    removed node-pty win32 prebuilds"
fi
echo "    slimmed size: $(du -sh "$APP" | cut -f1)"

echo "==> [7/7] ad-hoc code signing"
codesign --force --deep --sign - "$APP"

echo ""
echo "Built: $APP"
du -sh "$APP" | sed 's/^/Size: /'
echo "Run with:  open \"$APP\""
