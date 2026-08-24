---
title: 模块：构建与打包脚本
tags: [module, build, packaging, icon, release, ci]
updated: 2026-08-22T15:04:38Z
sources: [platforms/macos/build-app.sh, platforms/macos/swift-sources.sh, platforms/macos/make-pkg.sh, platforms/macos/src/MakeIcon.swift, platforms/macos/build-cef.sh, scripts/version.sh, scripts/local-release.sh, scripts/release-checksums.sh, scripts/github-publish.sh, scripts/local-ci.sh, Jenkinsfile, .github/workflows/release.yml, .github/workflows/ci.yml, platforms/macos/src/FilePanel.swift, platforms/macos/src/CodeEditorView.swift, platforms/macos/src/ChannelPanel.swift, platforms/macos/src/SkillInstaller.swift, platforms/macos/src/vendor/Highlightr/]
manual: false
---

# 模块：构建与打包脚本

## platforms/macos/swift-sources.sh（编译清单单一事实来源）

定义 `swift_sources <src_dir>`（打印每个源文件一行）：glob 收录 `src/*.swift` + `vendor/Highlightr/*.swift`，**排除独立工具 `MakeIcon.swift`**（顶层代码、非 app target）。被 `build-app.sh` / `scripts/local-ci.sh` / `.github/workflows/ci.yml` 三方共用——新增 app Swift 文件**自动收录、无需登记**，三处清单永不漂移（根治「新增文件遗漏 local-ci」）。`scripts/local-ci.sh` 另有 `dev` 模式（`DSH_DEV_BUILD=1` 打开发版）与 `tests/skills/run.sh` 步骤。

## platforms/macos/build-app.sh（一键构建，约 350 行）

`set -euo pipefail`，用法：`./build-app.sh [--prefetch]`（自 platforms/macos/ 执行）。版本单一来源：VERSION/BUILD 来自 `scripts/version.sh`（git tag / CI 运行号驱动）；`DSH_ARCH=arm64|x86_64|universal` 交叉构建（swiftc `-target` + universal lipo）；国内镜像默认值（`NPM_REGISTRY`/`NODE_MIRROR`，可用 `DSH_*` 环境变量覆盖）；共享核心 `core/` 一并嵌入 `Contents/Resources/runtime/core`。

- `resolve_node_version`：`DSH_NODE_VERSION` 未设时查镜像 `index.json` 用 python3 选最新 LTS；网络不可用则从 `.cache/node` 缓存 tarball 推导；
- `download_node`：下载 darwin-arm64 tarball（镜像失败换官方），用 `SHASUMS256.txt` + `shasum -a 256 -c` 校验；
- `install_dsh` / `build_runtime`：用下载的 Node 自带 npm 在 `runtime/dsh` 装 `@deepseek-ai/dsh@0.1.1-rc.2`（默认 `DSH_PACKAGE_SPEC`），主 registry 失败自动重试官方源；`(Node版本|spec|arch)` 写入 `.runtime-info`，相同组合直接复用 `.cache/runtime/<arch>`；
- **`--prefetch`**：只建 runtime 到 `.cache/runtime`，不产出 App（供离线全量构建）；
- **6 步构建**：① 准备目录（`rm -rf .build dist/oh-my-dsh.app`）② `MakeIcon.swift` 编译渲染 iconset → `iconutil -c icns` → 拷入 Resources ③ `swiftc -O -swift-version 5 -framework AppKit/WebKit/PDFKit` 编译源清单经 `swift_sources`（`platforms/macos/swift-sources.sh` **单一事实来源**：glob 自动收录 `src/*.swift` + `vendor/Highlightr/*`，排除独立工具 `MakeIcon.swift`），`build-app.sh` / `scripts/local-ci.sh` / `ci.yml` 三方共用、**新增文件无需登记**（根治此前 `feature/channel` 追加 `ChannelPanel.swift` 后曾漏登 local-ci 导致编译检查失败、3e69783 修复的问题）④ `build_runtime` + `ditto` 嵌入 `Contents/Resources/runtime/` ④.5 **Highlightr 资源嵌入**：`cp` 4 个 highlight.js 资源文件（`highlight.min.js`/`pojoaque.min.css`/`xcode.min.css`/`atom-one-dark.min.css`）到 `$APP/Contents/Resources/` **根**（Highlightr 用 `Bundle.main` 无子目录加载，见 [file-panel](file-panel.md)；缺失给 WARNING 不影响构建）⑤ 写 `Info.plist`（`LSMinimumSystemVersion` 13.0、`CFBundleLocalizations` zh/en、ATS 允许 127.0.0.1/localhost 明文、`NSHighResolutionCapable`）⑥ `codesign --force --deep --sign -`（ad-hoc）。

## platforms/macos/make-pkg.sh（安装包 + 镜像，85 行）

- 前置：`dist/oh-my-dsh.app` 必须已由 platforms/macos/build-app.sh 产出；
- 版本/ID 从 App 的 Info.plist 读取（`PlistBuddy`），产物 `dist/oh-my-dsh-<version>-<arch>.pkg` / `.dmg`（`ARCH="${DSH_ARCH:-$(uname -m)}"`，aarch64→arm64、amd64→x86_64 映射，即可交叉产出）；
- preinstall 脚本：先 `rm -rf /Applications/oh-my-dsh.app`（重装不留旧文件）→ `pkgbuild --component` 装到 `/Applications`（工具链接受 `--sign -` 则 ad-hoc 签名，否则不签名）；
- DMG：`ditto` 拷贝 App + `ln -s /Applications`，`hdiutil create -format UDZO`（拖拽安装）。

## MakeIcon.swift（图标生成器，104 行）

- 用法：`MakeIcon <output.iconset-dir>`；`render(px:)` 程序化绘制：圆角矩形渐变背景 + 高光 + 圆环 + 字母「D」，输出 16…1024px 全部 @1x/@2x 尺寸（iconset 命名约定）；
- 构建脚本随后 `iconutil -c icns` 生成 `AppIcon.icns`；不提交二进制图标文件。

## 构建变量速查

| 变量 | 默认 | 作用 |
|---|---|---|
| `DSH_NODE_VERSION` | 自动检测最新 LTS | 指定 Node 版本（如 v22.23.2） |
| `DSH_PACKAGE_SPEC` | `@deepseek-ai/dsh@0.1.1-rc.2` | npm install 的包说明 |
| `DSH_NODE_MIRROR` | `https://npmmirror.com/mirrors/node` | Node 下载镜像 |
| `DSH_NPM_REGISTRY` | `https://registry.npmmirror.com` | npm registry（构建期装 dsh） |
| `DSH_DEV_BUILD` | `0` | =1 打开发版：Info.plist 写 `DSHDevBuild=1`（运行时 `isDevBuild`：独立 CEF profile `~/.dsh/browser-dev` + 跳过单实例退出） |

缓存位置：`.cache/`（node tarball、npm-cache、已构建 runtime），持久且不随 `.build/` 清除；**runtime 缓存按架构分目录（`.cache/runtime/<arch>`）**——双架构 release 的 arm64/x86_64 各自 node+dsh 树互不覆盖、缓存跨轮生效；构建中间产物在 `.build/`（含 `module-cache`，swiftc 沙箱规避用）。

## platforms/macos/build-cef.sh（CEF 构建管线）

- 版本固定 + sha1 校验（arm64/x86_64 从 cef-builds.spotifycdn.com/index.json 核对）+ `.cache` 缓存；wrapper/shim/helper 编译；五 helper（base/Alerts/GPU/Plugin/Renderer）组装与由内向外签名；`build-app.sh`/CI 接入；
- **编译产物缓存 `.cache/cef-built-<arch>/`**：按（CEF 版本 + 脚本/源码 hash）判定命中，命中则直接复用已编译二进制，双架构 release 不必各自重编（CEF 编译从数分钟降到约 18s）；
- 缓存 key 用稳定绝对路径（修复 local-ci 重复编译 CEF 的问题）。

## scripts/version.sh（版本单一来源）

- 输出两行 `VERSION`/`BUILD`：VERSION 仅当 HEAD 恰在 `vX.Y.Z` tag 上取该 tag，否则回退 `FALLBACK_VERSION`（当前 1.13.0）；BUILD 取 CI 运行号（`GITHUB_RUN_NUMBER`/`CI_PIPELINE_IID`/`BUILD_NUMBER`），否则回退 69；
- `build-app.sh`/`local-release.sh`/`github-publish.sh`/`release-checksums.sh` 统一读它，**版本不再由调用方传参**。

## scripts/local-release.sh（本机 Release，与 release.yml 对齐）

- 三阶段：prepare（逐架构 `build-app.sh --prefetch` 命中 `.cache/`）→ build（逐架构 `build-app.sh` + `make-pkg.sh`）→ release（`release-checksums.sh` + `github-publish.sh`），不依赖 GitHub Actions；
- 用法：`scripts/local-release.sh`（两架构发布）/ `scripts/local-release.sh <arch...>` / `scripts/local-release.sh pack [arch...]`（只打包不发布 GitHub）；
- **版本不传参**（统一读 version.sh）；发布模式要求 HEAD 恰在 `vX.Y.Z` tag 上，否则阻断（防止把 fallback 版本发布到错误 commit）；pack 模式可用开发线版本临时打包；
- 环境变量：`GH_TOKEN`（或已登录 gh CLI）、`GITHUB_REPOSITORY`（默认 insky2005/oh-my-dsh）、`IS_PRERELEASE`（默认 1=预发布）、`DSH_NPM_REGISTRY`。

## scripts/release-checksums.sh + scripts/github-publish.sh（发布）

- `release-checksums.sh [version]`：对 `dist/oh-my-dsh-<version>-<arch>.{pkg,dmg}`（arm64/x86_64，不再出 universal）写 `dist/SHA-256SUMS` 并打印 release notes（安装引导）；版本可不传（自动读 version.sh）；
- `github-publish.sh [version]`：创建/更新 GitHub Release 并上传产物；**发布统一走 curl API 路径**（暂不使用 gh CLI，gh 分支保留为自动检测兜底）；发布前校验 HEAD 恰在 vVERSION tag 上；**幂等化**（v1.12.0 起）：release 已存在（上次中断残留）则复用只 PATCH title/notes + **只补传缺失资产**（已上传的按名字跳过）+ 逐资产进度输出（`du -sh`），中断可安全重跑无需手动删半成品 release。

## Jenkinsfile（Jenkins 打包 + 发布）

- macOS（Apple Silicon）agent 上 `build-app.sh` + `make-pkg.sh` 打包；参数化 `DSH_ARCH`（arm64/x86_64/universal）、`PUBLISH_RELEASE`、`IS_PRERELEASE`、`DSH_CEF_VERSION`；发布优先 gh CLI、无 gh 用 curl API；
- 依赖同一 agent workspace 的 `.cache/` 跨构建保留（CEF + node/runtime 缓存复用）；token 用 Jenkins Credentials（ID = github-release-token）。
