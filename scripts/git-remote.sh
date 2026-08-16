#!/bin/bash
#
# scripts/git-remote.sh — 检测推送用 remote 名：优先 github，其次 origin，
# 否则取第一个 remote；无 remote 时输出空并退出 1。
# 供所有需要 git push / ls-remote 的脚本复用（避免硬编码 origin）。
#
# 用法：
#   REMOTE="$(scripts/git-remote.sh)"            # 当前目录
#   REMOTE="$(scripts/git-remote.sh /path/to)"   # 指定仓库
#
set -euo pipefail

REPO="${1:-$(pwd)}"

names="$(git -C "$REPO" remote 2>/dev/null || true)"
[ -n "$names" ] || { echo ""; exit 1; }

for name in github origin; do
  if echo "$names" | grep -qx "$name"; then
    echo "$name"
    exit 0
  fi
done
echo "$names" | head -1
