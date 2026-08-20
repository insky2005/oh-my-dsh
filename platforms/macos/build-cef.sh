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
#
# 编译产物缓存：libcef_dll_wrapper.a + CEFShim.o + helper-bin 是可复用的（按
# CEF 版本 + 本脚本/源码 hash 判定），缓存到 .cache/cef-built-<arch>/，命中则
# 跳过编译——CI 每 run 不再重编 ~300 个 .cc 文件（Chromium 本体是 tarball 里的
# 预编译 framework，只复制不编译）。
set -euo pipefail

# ---- 配置 ----
# CEF 版本单一来源（与 scripts/version.sh 同理）：DSH_CEF_VERSION 覆盖。
CEF_VERSION="${DSH_CEF_VERSION:-150.0.18+gdb11278+chromium-150.0.7871.213}"
# 各平台 tarball 的 sha1（从 cef-builds.spotifycdn.com/index.json 核对）。
CEF_SHA1_arm64="fd046811e325086daddb4539462cd6b8c2af16df"
CEF_SHA1_x86_64="111b3356c9c4a31fbc783fbd572cbed78d0fe134"
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

# ---- 3-5. 编译 libcef_dll wrapper + CEFShim + helper（产物缓存复用） ----
ARTIFACT_CACHE="$CACHE/cef-built-$ARCH"
# 缓存键：CEF 版本 + 本脚本/CEF 源码 hash。任一变化即失效重编。
# 注意：shasum 文件列表时输出带文件名，二次 shasum 会把名字混进 key，
# 所以这里必须统一用 $ROOT 绝对路径（$0 会因调用方用相对/绝对路径而不同，
# 导致 local-ci.sh 与 build-app.sh 算出的 key 不一致、缓存永不命中、CEF 重复编译）。
ARTIFACT_KEY="$CEF_VERSION|$(shasum "$ROOT/platforms/macos/build-cef.sh" "$ROOT/platforms/macos/cef/CEFShim.mm" "$ROOT/platforms/macos/cef/process_helper_mac.cc" "$ROOT/platforms/macos/cef/CEFShim.h" 2>/dev/null | shasum | awk '{print $1}')"
REUSE=0
if [ -f "$ARTIFACT_CACHE/libcef_dll_wrapper-$ARCH.a" ] \
   && [ -f "$ARTIFACT_CACHE/CEFShim-$ARCH.o" ] \
   && [ -f "$ARTIFACT_CACHE/helper-bin-$ARCH" ] \
   && [ "$(cat "$ARTIFACT_CACHE/.key" 2>/dev/null)" = "$ARTIFACT_KEY" ]; then
  REUSE=1
fi
if [ "$REUSE" = "1" ]; then
  echo "==> cef: reusing cached build artifacts ($ARCH)"
  cp "$ARTIFACT_CACHE/libcef_dll_wrapper-$ARCH.a" "$ARTIFACT_CACHE/CEFShim-$ARCH.o" "$ARTIFACT_CACHE/helper-bin-$ARCH" "$CEF_DIR/"
else
  echo "==> cef: building libcef_dll_wrapper ($ARCH)"
  CXXFLAGS="-std=c++20 -fno-exceptions -fno-rtti -fno-threadsafe-statics -fobjc-call-cxx-cdtors -fvisibility=hidden -fvisibility-inlines-hidden -fno-strict-aliasing -O2 -mmacosx-version-min=$MIN $TARGET_ARCH_FLAG -I$INC -DWRAPPING_CEF_SHARED"
  OBJDIR="$CEF_DIR/wrapper-$ARCH"
  rm -rf "$OBJDIR"
  mkdir -p "$OBJDIR"
  PIDS=()
  for f in $(find "$LDL" \( -name "*.cc" -o -name "*.mm" \) | sort); do
    o="$OBJDIR/$(echo "$f" | sed "s|$LDL/||; s|/|_|g; s|\\.cc$|.o|; s|\\.mm$|.o|")"
    "$CXX" $CXXFLAGS -c "$f" -o "$o" &
    PIDS+=($!)
  done
  for p in "${PIDS[@]}"; do wait "$p"; done
  ar rcs "$CEF_DIR/libcef_dll_wrapper-$ARCH.a" "$OBJDIR"/*.o

  echo "==> cef: building CEFShim ($ARCH)"
  "$CXX" $CXXFLAGS -fobjc-arc -c "$ROOT/platforms/macos/cef/CEFShim.mm" -o "$CEF_DIR/CEFShim-$ARCH.o"

  echo "==> cef: building helper binary ($ARCH)"
  "$CXX" $CXXFLAGS -fobjc-arc "$ROOT/platforms/macos/cef/process_helper_mac.cc" \
    "$CEF_DIR/libcef_dll_wrapper-$ARCH.a" \
    -Wl,-undefined,dynamic_lookup \
    -lpthread -framework AppKit -framework Cocoa -framework IOSurface \
    -o "$CEF_DIR/helper-bin-$ARCH"

  mkdir -p "$ARTIFACT_CACHE"
  cp "$CEF_DIR/libcef_dll_wrapper-$ARCH.a" "$CEF_DIR/CEFShim-$ARCH.o" "$CEF_DIR/helper-bin-$ARCH" "$ARTIFACT_CACHE/"
  echo "$ARTIFACT_KEY" > "$ARTIFACT_CACHE/.key"
fi

# ---- 6. 放置 framework（由 build-app.sh 嵌入 app 并签名） ----
rm -rf "$CEF_DIR/Chromium Embedded Framework-$ARCH.framework"
cp -R "$DIST/Release/Chromium Embedded Framework.framework" \
      "$CEF_DIR/Chromium Embedded Framework-$ARCH.framework"

echo "==> cef: done ($ARCH): wrapper $(du -h "$CEF_DIR/libcef_dll_wrapper-$ARCH.a" | cut -f1) framework $(du -sh "$CEF_DIR/Chromium Embedded Framework-$ARCH.framework" | cut -f1)"
