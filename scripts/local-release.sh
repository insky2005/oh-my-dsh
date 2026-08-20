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

# 版本一致性（仅提示，不阻断本地临时构建）
cur="$(scripts/version.sh | head -1)"
if [ "$cur" = "$VER" ]; then
  echo "    version v$VER matches tag at HEAD ✓"
else
  echo "WARN: HEAD 不在 v$VER tag 上（当前解析版本 $cur）。" >&2
  echo "     请先 'git tag v$VER' 并让 HEAD 落在其上，否则产物版本可能与 tag 不符。" >&2
fi

# ---------- 阶段1 prepare：预下载 node + 预取 runtime（命中 .cache/） ----------
echo "==> [1/3 prepare] prefetch node + runtime"
./platforms/macos/build-app.sh --prefetch

# ---------- 阶段2 build：逐架构 build-app.sh + make-pkg.sh ----------
for a in $ARCHS; do
  echo "==> [2/3 build] arch=$a"
  DSH_ARCH="$a" ./platforms/macos/build-app.sh
  DSH_ARCH="$a" ./platforms/macos/make-pkg.sh
done
echo "==> [2/3 build] artifacts:"
ls -lh dist/oh-my-dsh-*.pkg dist/oh-my-dsh-*.dmg 2>/dev/null || true

# ---------- 阶段3 release：校验和 + gh release create ----------
echo "==> [3/3 release] write SHA-256SUMS + release notes"
scripts/release-checksums.sh "$VER"

echo "==> [3/3 release] publish GitHub Release"
if [ -z "${GH_TOKEN:-}" ] && ! command -v gh >/dev/null 2>&1; then
  echo "ERROR: need GH_TOKEN (repo write) or a logged-in 'gh' CLI to publish." >&2
  exit 1
fi
scripts/github-publish.sh "$VER"
echo "==> [RELEASE] done: https://github.com/${GITHUB_REPOSITORY:-insky2005/oh-my-dsh}/releases/tag/v$VER"
