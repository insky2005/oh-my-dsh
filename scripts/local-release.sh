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
#   scripts/local-release.sh                 # 两架构发布（版本自动 = HEAD tag）
#   scripts/local-release.sh <arch...>       # 发布指定架构（arm64 / x86_64，可多个）
#   scripts/local-release.sh pack [arch...]  # 只打包（pkg/dmg），不发布 GitHub
#
#   版本号**不传参**：与 build-app.sh 统一读取 scripts/version.sh（版本单一来源
#   是 git tag：HEAD 恰好在 vX.Y.Z tag 上时取该 tag，否则回退开发线版本）。
#   发布模式要求 HEAD 恰在 vX.Y.Z tag 上；pack 模式可用开发线版本临时打包。
#   [pre] 通过环境变量 IS_PRERELEASE 控制（默认 1=预发布；0=正式）
#
# 环境变量：
#   GH_TOKEN            GitHub token（repo 写权限）；或已登录 gh CLI 可省略
#   GITHUB_REPOSITORY   覆盖目标仓库（默认 insky2005/oh-my-dsh）
#   IS_PRERELEASE       1=预发布（默认）| 0=正式发布
#   DSH_NPM_REGISTRY    npm registry（默认 npmmirror；GitHub 构建显式走官方 npmjs）
#
# 发布规范（docs/git-workflow.md）：版本单一来源是 git tag。
#   发布前请先 'git tag v<ver>' 且让 HEAD 落在其上；否则发布模式会阻断。
#   主版本 vX.Y.0 在 main 打 tag；patch 从 release/X.Y 分支打 tag。
set -euo pipefail
cd "$(dirname "$0")/.."   # 仓库根

ALL_ARCHS="arm64 x86_64"

# pack 模式：只打包不发布（prepare + build，跳过 checksums/publish）
MODE="release"
ARGS=("${@:-}")
if [ "${1:-}" = "pack" ]; then
  MODE="pack"
  ARGS=("${@:2}")
fi

# 版本**不传参**：统一从 scripts/version.sh 读取（与 build-app.sh 同一来源）。
# 旧 <ver> 位置参数已移除——传版本号就是误用，直接报错。
for a in "${ARGS[@]}"; do
  case "$a" in
    [0-9]*.[0-9]*.[0-9]*)
      echo "ERROR: 版本已自动从 git tag 读取，无需（也不能）传版本参数 '$a'。" >&2
      echo "      用法: scripts/local-release.sh [pack] [arch...]" >&2
      exit 1 ;;
    *) ;;
  esac
done

# ===== 脚本实现见下方（勿改帮助文案） =====
usage() {
  sed -n '2,/^# ===== 脚本实现/p' "$0" | sed -E 's/^# ?//' | sed '$d'
  exit 0
}
[ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] && usage
[ "${1:-}" = "pack" ] && [ -z "${2:-}" ] && usage
# 剩余参数都是架构，默认两架构全发（对齐 GitHub 矩阵）
[ "${#ARGS[@]}" -gt 0 ] && ARCHS="${ARGS[*]}" || ARCHS="$ALL_ARCHS"

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

# 版本统一读取 scripts/version.sh（与 build-app.sh 同一来源）：HEAD 恰在
# vX.Y.Z tag 上 → 取该 tag；否则 → 开发线 fallback。
VER="$(scripts/version.sh | head -1)"

# 发布模式：必须 HEAD 恰好在 v$VER tag 上（version.sh 在 HEAD 无 tag 时输出
# fallback，此时发布会按错误的 commit/版本建 Release——阻断）。
if [ "$MODE" = "release" ]; then
  HEAD_TAG="$(git tag --points-at HEAD | grep -E "^v[0-9]+\.[0-9]+\.[0-9]+$" | head -1 || true)"
  if [ -z "$HEAD_TAG" ] || [ "${HEAD_TAG#v}" != "$VER" ]; then
    echo "ERROR: 发布要求 HEAD 恰好在 v$VER tag 上（当前 HEAD_TAG=${HEAD_TAG:-无}）。" >&2
    echo "      VERSION 单一来源是 git tag：请先 git tag v$VER 并让 HEAD 落在其上，" >&2
    echo "      再重跑本脚本。pack 模式（临时打包）不受此限。" >&2
    exit 1
  fi
  echo "    version v$VER = HEAD tag ✓（产物版本一致）"
else
  echo "    version $VER（pack 模式，来自 version.sh：$(git tag --points-at HEAD >/dev/null 2>&1 && [ -n "$(git tag --points-at HEAD | head -1)" ] && echo 'HEAD tag' || echo '开发线 fallback')）"
fi

echo "==> [RELEASE] v$VER archs=($ARCHS) prerelease=${IS_PRERELEASE:-1}"

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
  echo "       scripts/release-checksums.sh $VER && scripts/github-publish.sh $VER"
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
