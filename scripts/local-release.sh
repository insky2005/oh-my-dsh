#!/bin/bash
#
# scripts/local-release.sh — 本机 Release：与 .github/workflows/release.yml 对齐
# 的三阶段流程（prepare → build → checksum+publish），不依赖 GitHub Actions。
#
# 对应 GitHub Release job：
#   阶段1 prepare ↔ release.yml 构建的前置（预下载 node + 预取 runtime，命中 .cache/）
#   阶段2 build   ↔ release.yml 的 build  job（矩阵 arm64/x86_64，每个都
#                   build-app.sh + make-pkg.sh 产出 pkg+dmg）
#   阶段3 release ↔ release.yml 的 release job（写 SHA-256SUMS + gh release create）
#
# 用法：
#   scripts/local-release.sh <ver>               # 两架构全发（对齐 GitHub：arm64+x86_64）
#   scripts/local-release.sh <ver> <arch...>     # 只发指定架构，可多个（arm64 / x86_64）
#   scripts/local-release.sh <ver> arm64         # 只发 arm64 一个
#   scripts/local-release.sh pack <ver> [arch...]  # 只打包（pkg/dmg），不发布 GitHub
#
#   <ver> 版本号不带前导 v（如 1.11.0）
#   [pre] 通过环境变量 IS_PRERELEASE 控制（默认 1=预发布；0=正式）
#
# 环境变量：
#   GH_TOKEN            GitHub token（repo 写权限）；或已登录 gh CLI 可省略
#   GITHUB_REPOSITORY   覆盖目标仓库（默认 insky2005/oh-my-dsh）
#   IS_PRERELEASE       1=预发布（默认）| 0=正式发布
#   DSH_NPM_REGISTRY    npm registry（默认 npmmirror；GitHub 构建显式走官方 npmjs）
#
# 发布规范（docs/git-workflow.md）：版本单一来源是 git tag。
#   发布前请先 'git tag v<ver>' 且让 HEAD 落在其上；否则会用回退版本并警告。
#   主版本 vX.Y.0 在 main 打 tag；patch 从 release/X.Y 分支打 tag。
set -euo pipefail
cd "$(dirname "$0")/.."   # 仓库根

VER="${1:-}"
ALL_ARCHS="arm64 x86_64"
ARCHS="${@:2}"

# pack 模式：只打包不发布（prepare + build，跳过 checksums/publish）
MODE="release"
if [ "$VER" = "pack" ]; then
  MODE="pack"
  VER="${2:-}"
  ARCHS="${@:3}"
fi

# ===== 脚本实现见下方（勿改帮助文案） =====
usage() {
  sed -n '2,/^# ===== 脚本实现/p' "$0" | sed -E 's/^# ?//' | sed '$d'
  exit 0
}
[ -n "$VER" ] || usage
[ "$VER" = "-h" ] || [ "$VER" = "--help" ] && usage
# 无 arch 参数 → 两架构全发（对齐 GitHub 矩阵）
[ -n "$ARCHS" ] && ARCHS="$ARCHS" || ARCHS="$ALL_ARCHS"

[ "$(uname)" = "Darwin" ] || { echo "ERROR: this project must be built on macOS." >&2; exit 1; }
for t in swiftc codesign iconutil lipo pkgbuild hdiutil curl python3; do
  command -v "$t" >/dev/null 2>&1 || { echo "ERROR: missing tool '$t' (need Xcode Command Line Tools)." >&2; exit 1; }
done
for a in $ARCHS; do
  case "$a" in
    arm64|x86_64) ;;
    *) echo "ERROR: unsupported arch '$a' (arm64 | x86_64)" >&2; exit 1 ;;
  esac
done

echo "==> [RELEASE] v$VER archs=($ARCHS) prerelease=${IS_PRERELEASE:-1}"

# 版本一致性：VERSION 单一来源是 git tag —— build-app.sh 从 version.sh 解析
# （HEAD 恰在 vX.Y.Z tag 上取该 tag，否则 fallback），make-pkg.sh 再取自
# Info.plist。传参 VER 只用于发布命名/校验，不参与构建，不一致会导致
# Release 按 v$VER 创建但产物实为其他版本。
cur="$(scripts/version.sh | head -1)"
HEAD_TAG="$(git tag --points-at HEAD | grep -E "^v[0-9]+\.[0-9]+\.[0-9]+$" | head -1 || true)"
if [ "$MODE" = "release" ]; then
  # 发布模式：必须 HEAD 恰在 vVER tag 上（fallback 巧合匹配合格也不行，
  # 否则 publish 删同名旧 tag 重建会落在错误 commit 上）。
  if [ -z "$HEAD_TAG" ] || [ "${HEAD_TAG#v}" != "$VER" ]; then
    echo "ERROR: 发布要求 HEAD 恰好在 v$VER tag 上（当前 HEAD_TAG=${HEAD_TAG:-无}，解析版本 $cur）。" >&2
    echo "      VERSION 单一来源是 git tag：请先 git tag v$VER 并让 HEAD 落在其上，" >&2
    echo "      再重跑本脚本；否则产物版本与 Release 版本不一致（或同名 tag 被重建）。" >&2
    exit 1
  fi
  echo "    version v$VER = HEAD tag ✓（产物版本一致）"
else
  # pack 模式：不发布，仅提示（产物命名始终以实际解析版本为准）
  if [ "$cur" != "$VER" ]; then
    echo "WARN: pack 传参 VER=$VER ≠ HEAD 解析版本 $cur。" >&2
    echo "      pkg/dmg 文件名将使用实际解析版本 $cur，如需指定请打对应 tag。" >&2
  else
    echo "    version v$VER matches version.sh at HEAD ✓"
  fi
fi

# ---------- 阶段1 prepare：预下载 node + 预取 runtime（命中 .cache/） ----------
# 按目标架构逐个 prefetch：runtime 缓存按架构分目录（.cache/runtime/<arch>），
# 各架构互不覆盖、跨轮命中；只 prefetch 宿主架构会让 x86_64 的下载/安装
# 堆到 build 阶段首次发生（网络阻塞在构建时）。
for a in $ARCHS; do
  echo "==> [1/3 prepare] prefetch node + runtime (arch=$a)"
  DSH_ARCH="$a" ./platforms/macos/build-app.sh --prefetch
done

# ---------- 阶段2 build：逐架构 build-app.sh + make-pkg.sh ----------
for a in $ARCHS; do
  echo "==> [2/3 build] arch=$a"
  DSH_ARCH="$a" ./platforms/macos/build-app.sh
  DSH_ARCH="$a" ./platforms/macos/make-pkg.sh
done
echo "==> [2/3 build] artifacts:"
ls -lh dist/oh-my-dsh-*.pkg dist/oh-my-dsh-*.dmg 2>/dev/null || true

# ---------- 阶段3 release：校验和 + gh release create ----------
# pack 模式：只打包不发布——跳过 checksums 与 GitHub 发布
if [ "$MODE" = "pack" ]; then
  echo "==> [3/3] pack 模式：跳过 SHA-256SUMS 与 GitHub 发布"
  echo "==> [PACK] done（未发布）: dist/oh-my-dsh-*.pkg / .dmg"
  echo "     发布请去掉 pack 重跑本脚本，或手动执行:"
  echo "       scripts/release-checksums.sh $cur && scripts/github-publish.sh $cur"
  exit 0
fi
echo "==> [3/3 release] write SHA-256SUMS + release notes"
scripts/release-checksums.sh "$VER"

echo "==> [3/3 release] publish GitHub Release"
if [ -z "${GH_TOKEN:-}" ] && ! command -v gh >/dev/null 2>&1; then
  echo "ERROR: need GH_TOKEN (repo write) or a logged-in 'gh' CLI to publish." >&2
  exit 1
fi
scripts/github-publish.sh "$VER"
echo "==> [RELEASE] done: https://github.com/${GITHUB_REPOSITORY:-insky2005/oh-my-dsh}/releases/tag/v$VER"
