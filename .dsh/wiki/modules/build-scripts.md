---
title: 模块：构建与打包脚本
tags: [module, build, packaging, icon]
updated: 2026-08-15T12:19:42Z
sources: [build-app.sh, make-pkg.sh, src/MakeIcon.swift]
manual: false
---

# 模块：构建与打包脚本

## build-app.sh（一键构建，277 行）

`set -euo pipefail`，用法：`./build-app.sh [--prefetch]`。顶部常量：`APP_NAME=oh-my-dsh`、`BUNDLE_ID=com.ohmydsh.app`、`VERSION=1.7.1`、`BUILD=61`；国内镜像默认值（`NPM_REGISTRY`/`NODE_MIRROR`，可用 `DSH_*` 环境变量覆盖）。

- `resolve_node_version`：`DSH_NODE_VERSION` 未设时查镜像 `index.json` 用 python3 选最新 LTS；网络不可用则从 `.cache/node` 缓存 tarball 推导；
- `download_node`：下载 darwin-arm64 tarball（镜像失败换官方），用 `SHASUMS256.txt` + `shasum -a 256 -c` 校验；
- `install_dsh` / `build_runtime`：用下载的 Node 自带 npm 在 `runtime/dsh` 装 `@deepseek-ai/dsh@0.1.0-rc.6`（默认 `DSH_PACKAGE_SPEC`），主 registry 失败自动重试官方源；`(Node版本|spec)` 写入 `.runtime-info`，相同组合直接复用 `.cache/runtime`；
- **`--prefetch`**：只建 runtime 到 `.cache/runtime`，不产出 App（供离线全量构建）；
- **6 步构建**：① 准备目录（`rm -rf .build dist/oh-my-dsh.app`）② `MakeIcon.swift` 编译渲染 iconset → `iconutil -c icns` → 拷入 Resources ③ `swiftc -O -swift-version 5 -framework AppKit/WebKit/PDFKit` 编译 `main/PreviewPanel/TerminalPanel/WikiPanel`（**清单在此，新增文件必须登记**）④ `build_runtime` + `ditto` 嵌入 `Contents/Resources/runtime/` ⑤ 写 `Info.plist`（`LSMinimumSystemVersion` 13.0、`CFBundleLocalizations` zh/en、ATS 允许 127.0.0.1/localhost 明文、`NSHighResolutionCapable`）⑥ `codesign --force --deep --sign -`（ad-hoc）。

## make-pkg.sh（安装包 + 镜像，80 行）

- 前置：`dist/oh-my-dsh.app` 必须已由 build-app.sh 产出；
- 版本/ID 从 App 的 Info.plist 读取（`PlistBuddy`），产物 `dist/oh-my-dsh-<version>-<arch>.pkg` / `.dmg`（`ARCH=$(uname -m)`，即 arm64）；
- preinstall 脚本：先 `rm -rf /Applications/oh-my-dsh.app`（重装不留旧文件）→ `pkgbuild --component` 装到 `/Applications`（工具链接受 `--sign -` 则 ad-hoc 签名，否则不签名）；
- DMG：`ditto` 拷贝 App + `ln -s /Applications`，`hdiutil create -format UDZO`（拖拽安装）。

## MakeIcon.swift（图标生成器，104 行）

- 用法：`MakeIcon <output.iconset-dir>`；`render(px:)` 程序化绘制：圆角矩形渐变背景 + 高光 + 圆环 + 字母「D」，输出 16…1024px 全部 @1x/@2x 尺寸（iconset 命名约定）；
- 构建脚本随后 `iconutil -c icns` 生成 `AppIcon.icns`；不提交二进制图标文件。

## 构建变量速查

| 变量 | 默认 | 作用 |
|---|---|---|
| `DSH_NODE_VERSION` | 自动检测最新 LTS | 指定 Node 版本（如 v22.23.2） |
| `DSH_PACKAGE_SPEC` | `@deepseek-ai/dsh@0.1.0-rc.6` | npm install 的包说明 |
| `DSH_NODE_MIRROR` | `https://npmmirror.com/mirrors/node` | Node 下载镜像 |
| `DSH_NPM_REGISTRY` | `https://registry.npmmirror.com` | npm registry（构建期装 dsh） |

缓存位置：`.cache/`（node tarball、npm-cache、已构建 runtime），持久且不随 `.build/` 清除；构建中间产物在 `.build/`（含 `module-cache`，swiftc 沙箱规避用）。
