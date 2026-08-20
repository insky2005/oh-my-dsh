#!/bin/bash
#
# scripts/release-checksums.sh — write SHA-256SUMS for the release artifacts
# in dist/ matching <app>-<version>-<arch>.{pkg,dmg}, and print the release
# body for the GitHub Release (right-click → open install guidance).
#
# Usage:
#   scripts/release-checksums.sh [version]
#     → writes dist/SHA-256SUMS and prints the release notes to stdout.
#   版本可不传：缺省自动读 scripts/version.sh（版本单一来源 git tag）。
#
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
  VERSION="$(scripts/version.sh | head -1)"
  echo "    checksums: version auto ($VERSION)" >&2
fi

# 产品只出 arm64 / x86_64，不再出 universal。
ARTIFACTS=()
for arch in arm64 x86_64; do
  for ext in pkg dmg; do
    f="dist/oh-my-dsh-${VERSION}-${arch}.${ext}"
    [ -f "$f" ] && ARTIFACTS+=("$f")
  done
done
if [ "${#ARTIFACTS[@]}" -eq 0 ]; then
  echo "ERROR: no dist/oh-my-dsh-${VERSION}-* artifacts found (run build + make-pkg first)" >&2
  exit 1
fi

SUMS="dist/SHA-256SUMS"
: > "$SUMS"
for f in "${ARTIFACTS[@]}"; do
  ( cd dist && shasum -a 256 "$(basename "$f")" ) >> "$SUMS"
done
echo "Wrote $SUMS:"
cat "$SUMS"

cat <<'EOF'

## 安装引导（首次运行）

- 下载对应架构的安装包（`.pkg` 安装到 /Applications，或 `.dmg` 拖入 Applications）；
- 本地构建、未公证：macOS 可能提示「无法验证开发者」→ **右键 → 打开**，或在
  「系统设置 → 隐私与安全性」中允许；
- 校验完整性：`shasum -a 256 -c SHA-256SUMS`（在下载目录执行）。
EOF
