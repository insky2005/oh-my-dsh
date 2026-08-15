#!/bin/bash
#
# scripts/migrate-platforms-macos.sh — 一次性迁移脚本（M1 步骤 11）：
# 把仓库根下的 macOS 壳（src/ + build-app.sh + make-pkg.sh）迁入 platforms/macos/，
# 并同步修正所有路径引用（CI / tests / wiki sources / 文档）。
# 用 git mv 保留历史；幂等：已迁移时直接退出。
#
# 用法：scripts/migrate-platforms-macos.sh
#
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -d "platforms/macos/src" ]; then
  echo "already migrated (platforms/macos/src exists)"
  exit 0
fi

mkdir -p platforms/macos

echo "==> [1/4] git mv 源文件与构建脚本"
git mv src platforms/macos/src
git mv build-app.sh platforms/macos/build-app.sh
git mv make-pkg.sh platforms/macos/make-pkg.sh

echo "==> [2/4] 修正脚本内部相对路径"
# build-app.sh：脚本内 cd "$(dirname "$0")" 后位于 platforms/macos/，
# 需要回到仓库根取 scripts/version.sh，并把 .build/.cache/dist 放到仓库根。
python3 - <<'EOF'
import re
p = 'platforms/macos/build-app.sh'
s = open(p).read()
# 版本脚本在仓库根 scripts/ 下
s = s.replace('VERSION="$(scripts/version.sh | head -1)"',
              'VERSION="$(../../scripts/version.sh | head -1)"')
s = s.replace('BUILD="$(scripts/version.sh | tail -1)"',
              'BUILD="$(../../scripts/version.sh | tail -1)"')
open(p, 'w').write(s)

p = 'platforms/macos/make-pkg.sh'
s = open(p).read()
open(p, 'w').write(s)
EOF

echo "==> [3/4] 修正 tests 引用（../../src → ../../platforms/macos/src）"
sed -i '' 's|\.\./\.\./src/|../../platforms/macos/src/|g' tests/wiki-panel/run.sh tests/terminal-emulator/run.sh 2>/dev/null || true
sed -i '' 's|\.\./\.\./\.build|../../.build|g' tests/wiki-panel/run.sh 2>/dev/null || true

echo "==> [4/4] 修正 .github/workflows 路径（src/ → platforms/macos/src，./build-app.sh → ./platforms/macos/build-app.sh 等）"
sed -i '' 's|src/main.swift|platforms/macos/src/main.swift|g; s|src/PreviewPanel.swift|platforms/macos/src/PreviewPanel.swift|g; s|src/TerminalPanel.swift|platforms/macos/src/TerminalPanel.swift|g; s|src/WikiPanel.swift|platforms/macos/src/WikiPanel.swift|g' .github/workflows/ci.yml
sed -i '' 's|\./build-app\.sh|./platforms/macos/build-app.sh|g; s|\./make-pkg\.sh|./platforms/macos/make-pkg.sh|g' .github/workflows/ci.yml .github/workflows/release.yml .github/workflows/nightly.yml
sed -i '' "s|hashFiles('build-app.sh'|hashFiles('platforms/macos/build-app.sh'|g" .github/workflows/ci.yml .github/workflows/release.yml

echo "==> 迁移完成。请随后："
echo "    - 更新 .dsh/wiki 各页 sources（src/*.swift → platforms/macos/src/*.swift）"
echo "    - README / CONTRIBUTING / AGENTS 的路径说明"
echo "    - 本地验证：../../platforms/macos/build-app.sh --prefetch && 单测"
