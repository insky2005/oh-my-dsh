#!/bin/bash
#
# scripts/release-fix.sh — 已发布版本的 bug 修复 + patch 发布辅助脚本。
#
# 场景：已发布版本（如 v1.9.0）有 bug，需要在独立维护线上修复并发布 patch
# 版本（如 v1.9.1），再把修复同步回 main。规范详见 docs/git-workflow.md。
#
# 用法：
#   scripts/release-fix.sh <base-tag> <patch-version> [branch]
#
#   <base-tag>      从哪个已发布 tag 切维护分支（如 v1.9.0）
#   <patch-version> 要发布的 patch 版本（如 1.9.1，tag 为 v1.9.1）
#   [branch]        维护分支名（默认 release/<X.Y>，如 release/1.9）
#
# 示例：
#   scripts/release-fix.sh v1.9.0 1.9.1
#     → 切 release/1.9（基于 v1.9.0）→ 提示你在分支上修复 → 打 v1.9.1 tag 推送
#
# 注意：本脚本只完成「切分支 + 打 tag + 推送」骨架；修复代码由你提交到分支。
# 打 tag 推送后 release.yml 会自动构建发布 patch 版本。
#
set -euo pipefail
cd "$(dirname "$0")/.."

BASE_TAG="${1:-}"
PATCH_VER="${2:-}"
[ -n "$BASE_TAG" ] && [ -n "$PATCH_VER" ] || {
  echo "usage: scripts/release-fix.sh <base-tag> <patch-version> [branch]" >&2
  echo "  e.g.  scripts/release-fix.sh v1.9.0 1.9.1" >&2
  exit 1
}
# 校验 base tag 存在
git rev-parse -q --verify "refs/tags/$BASE_TAG" >/dev/null || {
  echo "ERROR: tag $BASE_TAG not found" >&2; exit 1
}
# 校验 patch 版本格式
[[ "$PATCH_VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "ERROR: patch version must be X.Y.Z (got '$PATCH_VER')" >&2; exit 1
}

MAJOR_MINOR="${PATCH_VER%.*}"            # 1.9.1 → 1.9
BRANCH="${3:-release/$MAJOR_MINOR}"      # release/1.9
PATCH_TAG="v$PATCH_VER"

echo "==> 1/4 从 $BASE_TAG 切维护分支 $BRANCH（不含未发布功能）"
git checkout -b "$BRANCH" "$BASE_TAG" 2>/dev/null || {
  # 分支已存在（如上次修复遗留）→ 检出并确认基于 base tag
  echo "    分支已存在，检出之；请确认其基于 $BASE_TAG（git merge-base 校验）"
  git checkout "$BRANCH"
}

echo "==> 2/4 请在该分支上完成修复并提交（如 git commit -m \"fix(…): …\"）"
echo "    完成后手动执行："
echo "      git push -u origin $BRANCH"
echo ""

echo "==> 3/4 打 patch tag $PATCH_TAG 并推送（触发 release.yml 发布）"
git tag -a "$PATCH_TAG" -m "oh-my-dsh $PATCH_VER (patch fix)"
git push origin "$BRANCH"
git push origin "$PATCH_TAG"
echo "    已推送：$BRANCH + $PATCH_TAG —— release.yml 将自动构建发布 $PATCH_VER"

echo ""
echo "==> 4/4 修复同步回 main（走 PR，不直接 push）——请手动执行："
echo "    FIX_COMMIT=\$(git log -1 --format=%H)   # 或你的修复 commit"
echo "    git checkout main && git pull"
echo "    git checkout -b fix/sync-$PATCH_VER main"
echo "    git cherry-pick \$FIX_COMMIT && git push -u origin fix/sync-$PATCH_VER"
echo "    开 PR：fix/sync-$PATCH_VER → main（CI 绿 + review 后合并）"
echo ""
echo "规范见 docs/git-workflow.md"
echo ""
echo "规范见 docs/git-workflow.md"
