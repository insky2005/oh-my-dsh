#!/bin/bash
# build-cef.sh — 下载/编译 CEF（Chromium Embedded Framework）集成产物。
# 由 build-app.sh 按架构调用（arm64 / x86_64）。产物：
#   $BUILD_DIR/cef/libcef_dll_wrapper.a    （CEF C++ 包装层静态库）
#   $BUILD_DIR/cef/CEFShim.o               （ObjC++ shim，swiftc -import-objc-header 用）
#   $BUILD_DIR/cef/helper-bin              （五个 helper 共用的子进程可执行文件）
#   $BUILD_DIR/cef/Chromium Embedded Framework.framework
#
# 关键背景（2026-08 实测定位）：CEF 148+ 的 macOS 分发要求**五个 helper app**
# （base / (Alerts) / (GPU) / (Plugin) / (Renderer)，同一份二进制，名字承重，
# 见 docs/plans/BROWSER_PLAN-browser-panel.md §二）。只打 base helper 会导致
# renderer 进程静默失败（页面空白）——这正是此前 spike 卡住的根因（非签名）。
set -euo pipefail

# ---- 配置 ----
# CEF 版本单一来源（与 scripts/version.sh 同理）：DSH_CEF_VERSION 覆盖。
CEF_VERSION="${DSH_CEF_VERSION:-151.3.18+gbeff58d+chromium-151.0.7922.138}"
# 各平台 tarball 的 sha1（从 cef-builds.spotifycdn.com/index.json 核对）。
CEF_SHA1_arm64="b02a884311a41a2025b8fb28d14ac20deedf30c7"
CEF_SHA1_x86_64="25272bd42c650d570ee52b47b6cd7d49d94921f8"
CDN="https://cef-builds.spotifycdn.com"

ARCH="${1:?usage: build-cef.sh <arm64|x86_64>}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CACHE="$ROOT/.cache"
BUILD_DIR="${BUILD_DIR:-$ROOT/.build}"
CEF_DIR="$BUILD_DIR/cef"
MIN="13.0"
CXX="${CXX:-clang++}"

if [ "$ARCH" = "arm64" ]; then
  PLATFORM="macosarm64"
  SHA1="$CEF_SHA1_arm64"
elif [ "$ARCH" = "x86_64" ]; then
  PLATFORM="macosx64"
  SHA1="$CEF_SHA1_x86_64"
else
  echo "unknown arch: $ARCH" >&2
  exit 1
fi

# 版本里的 + 在文件名里原样保留（URL 直接用即可）。
TARBALL="cef_binary_${CEF_VERSION}_${PLATFORM}.tar.bz2"
CACHED="$CACHE/$TARBALL"
TARGET_ARCH_FLAG="-target ${ARCH}-apple-macos13"

mkdir -p "$CACHE" "$CEF_DIR"

# ---- 1. 下载（.cache 缓存，sha1 校验，同 node tarball 策略） ----
if [ ! -f "$CACHED" ]; then
  echo "==> cef: downloading $TARBALL"
  curl -fL --retry 3 --max-time 900 "$CDN/$TARBALL" -o "$CACHED.part"
  mv "$CACHED.part" "$CACHED"
fi
ACTUAL_SHA1="$(shasum -a 1 "$CACHED" | awk '{print $1}')"
if [ "$ACTUAL_SHA1" != "$SHA1" ]; then
  echo "cef: sha1 mismatch for $TARBALL (got $ACTUAL_SHA1, want $SHA1)" >&2
  rm -f "$CACHED"
  exit 1
fi

# ---- 2. 解压（build 目录，每次重来） ----
DIST="$BUILD_DIR/cef-dist-$ARCH"
rm -rf "$DIST"
mkdir -p "$DIST"
tar -xjf "$CACHED" -C "$DIST" --strip-components=1
INC="$DIST"
LDL="$DIST/libcef_dll"

# ---- 3. 编译 libcef_dll wrapper（.cc + .mm 都要） ----
echo "==> cef: building libcef_dll_wrapper ($ARCH)"
CXXFLAGS="-std=c++20 -fno-exceptions -fno-rtti -fno-threadsafe-statics -fobjc-call-cxx-cdtors -fvisibility=hidden -fvisibility-inlines-hidden -fno-strict-aliasing -O2 -mmacosx-version-min=$MIN $TARGET_ARCH_FLAG -I$INC -DWRAPPING_CEF_SHARED"
OBJDIR="$CEF_DIR/wrapper-$ARCH"
rm -rf "$OBJDIR"
mkdir -p "$OBJDIR"
PIDS=()
for f in $(find "$LDL" \( -name "*.cc" -o -name "*.mm" \) | sort); do
  o="$OBJDIR/$(echo "$f" | sed "s|$LDL/||; s|/|_|g; s|\.cc$|.o|; s|\.mm$|.o|")"
  "$CXX" $CXXFLAGS -c "$f" -o "$o" &
  PIDS+=($!)
done
for p in "${PIDS[@]}"; do wait "$p"; done
ar rcs "$CEF_DIR/libcef_dll_wrapper-$ARCH.a" "$OBJDIR"/*.o

# ---- 4. 编译 CEFShim（ObjC++） ----
echo "==> cef: building CEFShim ($ARCH)"
"$CXX" $CXXFLAGS -fobjc-arc -c "$ROOT/platforms/macos/cef/CEFShim.mm" -o "$CEF_DIR/CEFShim-$ARCH.o"

# ---- 5. 编译 helper 可执行（五个 helper 共用一份） ----
echo "==> cef: building helper binary ($ARCH)"
"$CXX" $CXXFLAGS -fobjc-arc "$ROOT/platforms/macos/cef/process_helper_mac.cc" \
  "$CEF_DIR/libcef_dll_wrapper-$ARCH.a" \
  -Wl,-undefined,dynamic_lookup \
  -lpthread -framework AppKit -framework Cocoa -framework IOSurface \
  -o "$CEF_DIR/helper-bin-$ARCH"

# ---- 6. 放置 framework（由 build-app.sh 嵌入 app 并签名） ----
rm -rf "$CEF_DIR/Chromium Embedded Framework-$ARCH.framework"
cp -R "$DIST/Release/Chromium Embedded Framework.framework" \
      "$CEF_DIR/Chromium Embedded Framework-$ARCH.framework"

echo "==> cef: done ($ARCH): wrapper $(du -h "$CEF_DIR/libcef_dll_wrapper-$ARCH.a" | cut -f1) framework $(du -sh "$CEF_DIR/Chromium Embedded Framework-$ARCH.framework" | cut -f1)"
