# oh-my-dsh.app 体积瘦身分析

> 状态：✅ **已实施**（2026-08，main 分支；参考 feature/browser-panel 上的 239c6a1 同类改动）
> 目标：把 dist/oh-my-dsh.app（此前约 531M）在不破坏功能的前提下尽量瘦身。
> 实测：531M → ~392M（约减 ~139M，≈26%）。

## 一、体积构成（实测，531M，arm64 单架构构建）

dist/oh-my-dsh.app  531M
├── Contents/Resources  519M
│   └── runtime          518M
│       ├── dsh           270M   （node_modules 内嵌，含 openai/mistralai/anthropic/aws-sdk/node-pty/…）
│       ├── node          116M   （= node-arm64，单架构构建下重复）
│       ├── node-arm64    116M   （arm64 实际使用的 node）
│       ├── npm            16M   （dsh 升级功能需要）
│       └── core          108K
├── Contents/MacOS        1.2M
└── Contents/_CodeSignature 11M

> 说明：当前 main 的构建不含 Chromium/CEF（浏览器面板仍在 feature/browser-panel 分支）；
> 若后续合入 CEF 构建，见「五、CEF 构建下的额外瘦身」补一节。

## 二、可瘦身项（按性价比/风险排序，已实施 1–2）

### 1. 删除重复的 node 二进制 —— 约减 116M（零风险，已实施）

- runtime/node 与 runtime/node-arm64 在单架构（arm64）构建下是同一份文件，被重复复制两份（build-app.sh 的 build_runtime 在 arch == HOST_ARCH 时额外 ditto 一份纯 node）。
- 已确认解析逻辑：main.swift 的 bundledNode() 优先按 uname -m 取 runtime/node-<arch>（arm64 → node-arm64），纯 node 仅是「旧布局 / prefetch 兼容」兜底。
- 做法：不删缓存里的 node（--prefetch / universal 构建仍需），而是在 .app 嵌入 runtime 后删除 bundle 内的纯 node（保留 node-<arch>）；universal 构建同样受益。
- 预期：531M → ~415M。

### 2. 删除 node-pty 的 win32 预编译 —— 约减 23M（零风险，已实施）

- runtime/dsh/node_modules/node-pty/prebuilds/ 包含（当前 dsh rc.7 实测）：
  - darwin-arm64 140K（本机用）
  - darwin-x64 72K（universal 用）
  - linux-arm64/x64 68K/76K（保留，体积可忽略）
  - win32-arm64 11M + win32-x64 12M（macOS 永用不到）
- 做法：.app 嵌入 runtime 后删除 prebuilds/win32-*。macOS app 不会运行 win32 二进制；dsh 升级时会重新 npm install 拉全量，不影响。
- 预期：415M → ~392M。

### 3. 裁剪 CEF 多余语言包 —— 约 30M（N/A：main 当前无 CEF 构建）

- 仅当 .app 内嵌 Chromium Embedded Framework.framework 时适用（当前在 feature/browser-panel 分支）。
- 做法（届时参考）：只保留 en*.lproj 与 zh*.lproj，删除其余 *.lproj（Chromium 语言包按需加载、缺失回退 en-US）。

### 合计（main）：约减 139M（≈26%），531M → ~392M。

## 三、不建议动（风险高 / 不可省）

- dsh 的模型 SDK 依赖（openai / @mistralai / @anthropic-ai / @aws-sdk / @google / @opentelemetry 等，合计约 120M）：是 @deepseek-ai/dsh 运行时必需依赖闭包，硬删会破坏 dsh web 启动/功能。除非上游出 slim 包，否则不动。
- npm 16M：dsh 内置升级功能需要。
- _CodeSignature 11M / MacOS 1.2M：签名与可执行文件，不可省。

## 四、实施方式

在 build-app.sh 加了一个后置瘦身步骤（在 runtime 已嵌入 .app、codesign 之前）：

1. 若 bundle 内有纯 node 且存在 node-<arch>，删除纯 node
2. 删除 runtime/dsh/node_modules/node-pty/prebuilds/win32-*

- 位置：[6/7] slimming app bundle，位于 [5/7] writing Info.plist 与 [7/7] ad-hoc code signing 之间。
- 统一走 build-app.sh；后续 .pkg/.dmg 打包自动受益（make-pkg.sh 打包 dist/oh-my-dsh.app）。
- 验证：build-app.sh 重新打包后 du -sh 确认降幅（[6/7] 会打印 slimmed size）；启动 app 验证浏览器/DevTools/升级功能正常。

## 五、CEF 构建下的额外瘦身（待 browser-panel 合入 main 后补）

- 删除 CEF 语言包只留 en*/zh*（~30M）。
- CEF 主 dylib 209M 是 Chromium 本体，无法避免；resources.pak / icudtl.dat / chrome_*_percent.pak 是通用资源，保留。
