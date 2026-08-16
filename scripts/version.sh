#!/bin/bash
#
# version.sh — 版本单一来源：从 git tag / CI 环境推导 VERSION 与 BUILD。
#
# 输出（按行）：
#   VERSION  如 1.8.0（HEAD 恰好在 v1.8.0 tag 上 → 1.8.0）；否则回退 fallback
#   BUILD    如 64（CI 运行号）；本地构建回退 fallback_build
#
# 用法：
#   scripts/version.sh                 # 输出 "1.8.0\n64"
#   VERSION=$(scripts/version.sh | head -1)
#   BUILD=$(scripts/version.sh | tail -1)
#
# 规则：
#   - VERSION 仅当 HEAD 恰好落在 vX.Y.Z tag 上时取该 tag（发布构建，CI 打 tag 的
#     job 恰在 tag commit 上）；未打 tag 的日常开发构建回退 FALLBACK_VERSION
#     （当前开发线版本，避免本地构建无版本）；
#   - BUILD 优先取 CI 运行号（GITHUB_RUN_NUMBER / CI_PIPELINE_IID / BUILD_NUMBER），
#     否则回退 FALLBACK_BUILD。
#
set -euo pipefail
cd "$(dirname "$0")/.."

FALLBACK_VERSION="${FALLBACK_VERSION:-1.10.0}"
FALLBACK_BUILD="${FALLBACK_BUILD:-66}"

VERSION="$FALLBACK_VERSION"
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  HEAD_TAG="$(git tag --points-at HEAD 2>/dev/null | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -1 || true)"
  if [ -n "$HEAD_TAG" ]; then
    VERSION="${HEAD_TAG#v}"
  fi
fi

BUILD="$FALLBACK_BUILD"
for var in GITHUB_RUN_NUMBER CI_PIPELINE_IID BUILD_NUMBER; do
  if [ -n "${!var:-}" ]; then
    BUILD="${!var}"
    break
  fi
done

printf '%s\n%s\n' "$VERSION" "$BUILD"
