#!/bin/bash
# scripts/github-publish.sh — 创建/更新 GitHub Release 并上传 dist/ 产物。
# 供 Jenkins（以及本地/其他 CI）调用；优先用 gh CLI，无 gh 则用 curl API 兜底。
#
# 环境变量：
#   GH_TOKEN           GitHub token（必填）
#   GITHUB_REPOSITORY  owner/repo（默认 insky2005/oh-my-dsh）
#   IS_PRERELEASE      1 = 预发布（默认 1）
#
# 用法：scripts/github-publish.sh <version>    # version 不带前导 v
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
[ -n "$VERSION" ] || { echo "usage: github-publish.sh <version>" >&2; exit 1; }
GH_TOKEN="${GH_TOKEN:?GH_TOKEN required}"
REPO="${GITHUB_REPOSITORY:-insky2005/oh-my-dsh}"
PRERELEASE="${IS_PRERELEASE:-1}"
TAG="v${VERSION}"
HEAD="$(git rev-parse HEAD)"

# 校验 + 生成 SHA-256SUMS 与 release notes（输出到 stdout）
BODY="$(scripts/release-checksums.sh "$VERSION")"
[ -f dist/SHA-256SUMS ] || { echo "ERROR: dist/SHA-256SUMS missing" >&2; exit 1; }
ARTIFACTS=(dist/oh-my-dsh-${VERSION}-*.pkg dist/oh-my-dsh-${VERSION}-*.dmg dist/SHA-256SUMS)
if [ "${#ARTIFACTS[@]}" -eq 0 ]; then echo "ERROR: no release artifacts for v$VERSION" >&2; exit 1; fi

if command -v gh >/dev/null 2>&1; then
  echo "==> publishing via gh CLI"
  export GH_TOKEN
  # 幂等：先删同名旧 Release（连同 tag，--cleanup-tag），再重建
  gh release delete "$TAG" --repo "$REPO" --yes --cleanup-tag 2>/dev/null || true
  gh release create "$TAG" \
    --repo "$REPO" \
    --target "$HEAD" \
    --title "oh-my-dsh $VERSION" \
    --notes "$BODY" \
    --prerelease \
    "${ARTIFACTS[@]}"
else
  echo "==> gh not found, publishing via curl API"
  GH_TOKEN="${GH_TOKEN:?GH_TOKEN required}"
  BODY_JSON="$(python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' <<<"$BODY")"
  PRERELEASE_JSON="$( [ "$PRERELEASE" = "1" ] && echo true || echo false )"
  REL="$(curl -s -X POST -H "Authorization: token $GH_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$REPO/releases" \
    -d "{\"tag_name\":\"$TAG\",\"target_commitish\":\"$HEAD\",\"name\":\"oh-my-dsh $VERSION\",\"body\":$BODY_JSON,\"prerelease\":$PRERELEASE_JSON}")"
  REL_ID="$(python3 -c 'import sys,json; print(json.load(sys.stdin).get("id",""))' <<<"$REL")"
  [ -n "$REL_ID" ] || { echo "release create failed: $REL" >&2; exit 1; }
  for f in "${ARTIFACTS[@]}"; do
    [ -f "$f" ] || continue
    name="$(basename "$f")"
    case "$name" in
      *.dmg) CT="application/x-apple-diskimage" ;;
      *.pkg) CT="application/octet-stream" ;;
      *)     CT="application/octet-stream" ;;
    esac
    curl -s -X POST -H "Authorization: token $GH_TOKEN" \
      -H "Content-Type: $CT" \
      "https://uploads.github.com/repos/$REPO/releases/$REL_ID/assets?name=$name" \
      --data-binary "@$f" >/dev/null
  done
fi
echo "Published: $TAG -> https://github.com/$REPO/releases/tag/$TAG"
