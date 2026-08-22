#!/bin/bash
# scripts/github-publish.sh — 创建/更新 GitHub Release 并上传 dist/ 产物。
# 供 Jenkins（以及本地/其他 CI）调用；优先用 gh CLI，无 gh 则用 curl API 兜底。
#
# 环境变量：
#   GH_TOKEN           GitHub token（必填）
#   GITHUB_REPOSITORY  owner/repo（默认 insky2005/oh-my-dsh）
#   IS_PRERELEASE      1 = 预发布（默认 1）
#
# 用法：scripts/github-publish.sh [version]   # version 不带前导 v；不传则自动读 version.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
  VERSION="$(scripts/version.sh | head -1)"
  echo "    publish: version auto ($VERSION)" >&2
fi
# 发布安全校验：VERSION 单一来源是 git tag —— HEAD 必须恰好在 vVERSION tag 上，
# 否则可能把 fallback/错误版本发布到错误 commit（创建/重建同名 tag）。
HEAD_TAG="$(git tag --points-at HEAD | grep -E "^v[0-9]+\.[0-9]+\.[0-9]+$" | head -1 || true)"
if [ -z "$HEAD_TAG" ] || [ "${HEAD_TAG#v}" != "$VERSION" ]; then
  echo "ERROR: 发布要求 HEAD 恰好在 v$VERSION tag 上（当前 HEAD_TAG=${HEAD_TAG:-无}）。" >&2
  echo "      VERSION 单一来源是 git tag：请先 git tag v$VERSION 并让 HEAD 落在其上。" >&2
  exit 1
fi
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
  API="https://api.github.com/repos/$REPO"
  # 幂等：release 已存在（上次上传中断残留 / CI 已建）则复用，只补传缺失资产，
  # 失败后可直接重跑本脚本，无需手动删除半成品 release。
  EXISTING="$(curl -s -H "Authorization: token $GH_TOKEN" -H "Accept: application/vnd.github+json" "$API/releases/tags/$TAG")"
  REL_ID="$(python3 -c 'import sys,json; print(json.load(sys.stdin).get("id",""))' <<<"$EXISTING" 2>/dev/null || true)"
  if [ -n "$REL_ID" ]; then
    echo "==> release $TAG 已存在（id=$REL_ID），复用并更新 title/notes"
    curl -s -X PATCH -H "Authorization: token $GH_TOKEN" -H "Accept: application/vnd.github+json" \
      "$API/releases/$REL_ID" \
      -d "{\"name\":\"oh-my-dsh $VERSION\",\"body\":$BODY_JSON,\"prerelease\":$PRERELEASE_JSON}" >/dev/null
    UPLOADED_NAMES="$(python3 -c 'import sys,json; print("\n".join(a["name"] for a in json.load(sys.stdin).get("assets",[])))' <<<"$EXISTING" 2>/dev/null || true)"
  else
    REL="$(curl -s -X POST -H "Authorization: token $GH_TOKEN" \
      -H "Accept: application/vnd.github+json" \
      "$API/releases" \
      -d "{\"tag_name\":\"$TAG\",\"target_commitish\":\"$HEAD\",\"name\":\"oh-my-dsh $VERSION\",\"body\":$BODY_JSON,\"prerelease\":$PRERELEASE_JSON}")"
    REL_ID="$(python3 -c 'import sys,json; print(json.load(sys.stdin).get("id",""))' <<<"$REL")"
    [ -n "$REL_ID" ] || { echo "release create failed: $REL" >&2; exit 1; }
    UPLOADED_NAMES=""
  fi
  for f in "${ARTIFACTS[@]}"; do
    [ -f "$f" ] || continue
    name="$(basename "$f")"
    if [ -n "$UPLOADED_NAMES" ] && grep -qxF "$name" <<<"$UPLOADED_NAMES"; then
      echo "    $name 已存在，跳过"
      continue
    fi
    case "$name" in
      *.dmg) CT="application/x-apple-diskimage" ;;
      *.pkg) CT="application/octet-stream" ;;
      *)     CT="application/octet-stream" ;;
    esac
    size="$(du -sh "$f" | awk '{print $1}')"
    echo "==> uploading $name ($size) ..."
    curl -s -X POST -H "Authorization: token $GH_TOKEN" \
      -H "Content-Type: $CT" \
      "https://uploads.github.com/repos/$REPO/releases/$REL_ID/assets?name=$name" \
      --data-binary "@$f" >/dev/null
    echo "    $name 完成"
  done
fi
echo "Published: $TAG -> https://github.com/$REPO/releases/tag/$TAG"
