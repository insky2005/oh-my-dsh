# oh-my-dsh — DeepSeek Harness 原生 macOS 壳

把 DeepSeek Harness 的 Web 界面（`dsh web`）封装成一个可以在 macOS 上**直接双击运行**的原生 App。
**不改动任何 DeepSeek Harness 源码**——它只是一个壳：

- **完全自包含**：App 内部内置了 Node 运行时（含 npm）+ 完整的 `@deepseek-ai/dsh` 依赖树，**不依赖电脑上安装的 node 或 dsh**，拿到即可用（甚至全新机器也能用）；
- 启动时检查 `127.0.0.1:3080` 是否已有 `dsh web` 在服务（比如 harness 本身正在运行）→ **复用**，不重复启动；否则用内置运行时**自己拉起** `dsh web`（默认 3080 端口，被占用时自动换空闲端口），等它就绪后把界面装进原生 `WKWebView` 窗口；
- **退出时自行关闭**：Cmd+Q、关窗口、`kill`（SIGTERM/SIGINT/SIGHUP，含注销/关机）都会触发清理，关掉**自己拉起的**服务（先优雅退出，3 秒内未退出则 SIGKILL）；绝不干扰外部已运行的实例；
- **dsh 可升级（含自动升级）**：App 内置「设置」菜单——「检查并升级 dsh…」(`⌘U`) 手动升级；「自动升级 dsh」开关默认开启，每次启动最多检查一次（24h 节流），发现新版本自动用内置 npm 原地升级；
- **中/英文切换（默认跟随系统）**：「设置」→「语言」子菜单可选「系统 / 中文 / English」（默认跟随系统：系统中文→中文壳，否则→英文壳），显式选择会记住；也支持 `DSH_LANG=en|zh` 环境变量强制指定；切换会**联动刷新 dsh web 页面语言**（同步 WebView 的 `navigator.language` 并重载页面，会话在服务端不受影响）；
- **registry 可配置，默认国内源**：检查/升级走 npm registry，默认 `https://registry.npmmirror.com`（国内加速），可在「设置 dsh registry…」里改（运行期），构建期用 `DSH_NPM_REGISTRY` 覆盖；
- **文件/文件夹预览面板**：点击 dsh web 对话中输出的文件链接（工具产出的文件）不再弹系统默认应用，而是在 **WebView 右侧的预览面板**中预览；窗口**最右侧是活动栏**（图标入口，预览面板与终端面板互斥切换）；预览区**左侧是项目目录树**（自动定位当前项目目录，目录可展开、点文件即预览，树宽可拖拽），右侧支持**文本 / 代码 / Markdown**（纯文本显示，保留原始换行）、**图片**、**PDF**、**文件夹列表**与未知类型（图标 + 元数据）；**多文件以页签切换**，可关闭；右上角提供「**项目目录**」（重新定位项目树，RPC 失败时回退手动选文件夹）、「在默认应用中打开」「在 Finder 中显示」「关闭」操作；面板宽度可拖拽调整并记住（也可通过「视图」菜单 / `⌥⌘P` / 活动栏图标开合），且**自动保证 WebView 宽度 ≥1050pt**（dsh web 在宽度低于 1024pt 时会自动收起左侧会话栏，壳层会钳制分隔条/必要时加宽窗口来避免）；纯 WebView 侧注入实现，不改任何 DeepSeek Harness 源码；
- **集成终端面板**：活动栏「终端」图标（或「视图」→「显示/隐藏 终端面板」/ `⌥⌘T`）在右侧打开一个**真实交互的 shell**（原生 PTY，默认 `$SHELL -l`，如 `/bin/zsh`；`TERM=xterm-256color`），支持多标签页（`+` 新建 / `✕` 关闭，默认编号「终端 1/2/3…」；`⌘1-9` 直接切换、`⌘⇧[` / `⌘⇧]` 循环切换，OSC 标题自动更新标签名）、彩色输出（16/256/真彩色）、`vim`/`top`/`less` 等全屏程序的备用屏、窗口缩放列数自适应（`tput cols`）、鼠标拖拽选中 + `⌘C` 复制（无选区时 `⌘C` 发送 SIGINT）/ `⌘V` 粘贴（多行走括号粘贴，不会误执行）/ `⌘A` 全选 / `⌘K` 清屏、触控板滚动查看历史输出；**在 shell 里输入 `exit`（或 `⌃D`）会正常退出并自动关闭该标签页**（最后一个标签页退出则收起终端面板；异常退出如被信号杀死则保留「会话已结束 + 重启」以便查看错误）；新会话默认在**当前 dsh 会话的项目目录**启动（服务就绪后解析，失败则回退用户主目录）；退出 App 时自动终止所有会话进程；所有面板（预览/终端）顶部采用统一背景条与布局，图标按钮在深浅色下均可见；**已知限制**：v1 不支持输入法直接打字（中文等经 `⌘V` 粘贴输入）、DECSTBM 滚动区未实现（个别全屏程序可能显示异常）、组合表情/零宽连接符按近似宽度渲染、会话不跨 App 重启保留；
- **Repo Wiki 知识库面板**：活动栏「知识库」图标（或「视图」→「显示/隐藏 知识库面板」/ `⌥⌘W`）打开**仓库知识库面板**——让 dsh 代理维护一份随代码演进的结构化 markdown 知识库（`.dsh/wiki/`，可随仓库提交/共享），新会话不再盲目重新探索代码库：
  - **生成/更新**：面板右上「+」一键让 dsh 代理执行 `repo-wiki` skill（自动安装到 `<repo>/.dsh/skills/repo-wiki/SKILL.md`）——初始生成（index/overview/architecture/modules/data-model/conventions/tasks，≤20 页）或增量更新（只重写受影响页面）；通过 `session.create` + `session.prompt`（queue 模式）触发，不阻塞对话，生成会话在 dsh web 左侧可见、可取消；状态条显示进度；
  - **浏览**：左侧页面树（分组、过期/手动徽标）+ 右侧渲染后的 markdown（标题/粗斜体/代码/列表/链接，软换行保真）+ 反向链接区 + 页面间点击跳转（dshwiki:// 内部链接）；标题过滤搜索；
  - **维护**：陈旧检测（页面 `sources` 指向的文件比 `updated` 新 → 标 ⚠）；`manual: true` 页面代理绝不覆盖（标 ✎）；生成完成后可选幂等写入项目根 `AGENTS.md` 注册块（「设置」→「写入 AGENTS.md 注册块」，默认关，让新会话自动知道先读 wiki）；「自动更新知识库」（默认关，≥3 页过期且 index 超过 1 小时才触发，每小时最多一次）；wiki 根目录可选「仓库内 .dsh/wiki」或「DSH_HOME 私有」；
  - 设计文档：`docs/repo-wiki-design.md`（含 QMD 检索增强候选，暂不整合）。**已知限制**：v1 的搜索为标题过滤（无正文/语义检索）；知识由代理生成，质量取决于 dsh 代理能力。
- **关于面板**（App 菜单 →「关于 oh-my-dsh」）显示：App 版本、依赖的 dsh 版本、Node 版本、运行时来源、dsh registry。

## 产物

```
dist/oh-my-dsh.app                    编译好的原生 App（arm64，ad-hoc 签名，约 670 MB，含内置运行时）
dist/oh-my-dsh-<version>-arm64.pkg    安装包（装到 /Applications，版本号随 git tag）
dist/oh-my-dsh-<version>-arm64.dmg    拖拽安装镜像（把 App 拖进 Applications）
```

> 版本号由 git tag 驱动（见「构建」）；发布产物（含 SHA-256SUMS）见 GitHub Releases。

## 安装到 Applications

**方式一：安装包（推荐）**

```bash
open "dist/oh-my-dsh-1.8.0-arm64.pkg"
```

跟随安装器向导即可（会要求输入管理员密码）。安装器带 preinstall 脚本，重装前自动移除旧版本。
由于是本地构建、未公证，首次安装时 macOS 可能提示"无法验证开发者"——右键 →「打开」，或在
系统设置 → 隐私与安全性 中允许即可。

**方式二：拖拽镜像**

```bash
open "dist/oh-my-dsh-1.8.0-arm64.dmg"
```

把 `oh-my-dsh.app` 拖进 `Applications` 文件夹。

**构建安装包**（基于已构建的 `dist/oh-my-dsh.app`）：

```bash
./platforms/macos/make-pkg.sh   # 生成 arm64 的 .pkg 与 .dmg
```

## 环境要求

- 运行：macOS 13+（Apple Silicon）。**无需安装 Node、无需安装 dsh**。
- 构建：需要 Xcode Command Line Tools、curl、python3，以及网络（下载 Node + 从 registry 装 dsh）。

## 构建

```bash
./platforms/macos/build-app.sh --prefetch  # （可选）先预下载 Node + 预装 dsh 到 .cache/，不产出 App
./platforms/macos/build-app.sh             # 全量构建 → dist/oh-my-dsh.app（复用 .cache/，无需再联网）
```

内置运行时是**构建时现做**的，不复制本机的任何 node/dsh 文件：

1. **下载 Node**：默认从国内镜像 `npmmirror.com/mirrors/node` 下载 `darwin-arm64` tarball
   （自动选最新 LTS，如 v24.19.0；失败自动回退 nodejs.org），用官方 `SHASUMS256.txt` 校验 SHA-256 后，
   把 `bin/node` 和 `lib/node_modules/npm`（升级功能要用）嵌入 `Contents/Resources/runtime/`；
2. **安装 dsh**：用刚下载的 Node 自带 npm，在 `Contents/Resources/runtime/dsh` 里执行
   `npm install @deepseek-ai/dsh@0.1.0-rc.6`（默认版本，含其全部依赖闭包），默认走国内 npm 源
   `registry.npmmirror.com`（失败自动回退 npmjs.org）。

构建变量：

| 变量 | 默认 | 作用 |
|---|---|---|
| `DSH_NODE_VERSION` | 自动检测最新 LTS | 指定下载的 Node 版本，如 `v22.23.2` |
| `DSH_PACKAGE_SPEC` | `@deepseek-ai/dsh@0.1.0-rc.6` | 传给 `npm install` 的包说明，如 `@deepseek-ai/dsh@latest` |
| `DSH_NODE_MIRROR` | `https://npmmirror.com/mirrors/node` | Node 下载镜像 |
| `DSH_NPM_REGISTRY` | `https://registry.npmmirror.com` | npm registry（构建期装 dsh 用） |
| `DSH_ARCH` | `uname -m` | 目标架构：`arm64` / `x86_64` / `universal`（CI 矩阵用） |

构建缓存：Node tarball、npm 缓存和已构建的运行时存放在 `.cache/`（持久，不随 `.build/` 清除）；
相同 `(Node 版本, dsh 版本)` 组合会直接复用，重建只需几十秒。网络不可用时，会用缓存的 Node tarball 推导版本继续构建。

## 运行

```bash
open "dist/oh-my-dsh.app"
```

或者直接双击 `dist/oh-my-dsh.app`。

- 界面用系统 WebKit 渲染，与 Safari 同引擎；窗口标题固定为 `oh-my-dsh (DeepSeek Harness)`；
- 外部链接、`target=_blank` 会交给默认浏览器打开，不会在壳内跳走；
- 文件下载走原生「另存为」对话框（`WKDownload`）；
- 菜单：菜单栏只有两个菜单——App 菜单（关于/隐藏/退出）与「设置」（`⌘U` 检查并升级 dsh、`⌘L` 打开日志文件夹、registry 设置等）；视图/窗口菜单已移除；
- 「关于 oh-my-dsh」显示 App 版本、dsh 版本（含运行时来源）、Node 版本、registry；
- 首次启动若被 Gatekeeper 拦（“无法验证开发者”），右键 App →「打开」即可（本地构建，无公证）。

## dsh 升级

- **手动**：设置菜单 →「检查并升级 dsh…」(`⌘U`)，对比 registry 最新版，有新版则用内置 npm 原地升级并提示；
- **自动**：设置菜单 →「自动升级 dsh」开关（默认开），每次启动自动检查（24 小时内最多一次），发现新版本在启动服务前先升级；
- 升级只作用于**内置运行时**（`Contents/Resources/runtime/dsh`），绝不碰系统安装的 dsh；
- 升级日志见 `~/Library/Logs/oh-my-dsh/app.log`（`auto-upgrade: …` 行）；
- 注意：升级会改写 App 包内文件，ad-hoc 签名因此失效，但本地运行不受影响；重新 `./platforms/macos/build-app.sh` 可还原干净包。

## 退出行为说明

| 场景 | 行为 |
|---|---|
| App 自己拉起了服务 | 退出时**关闭**（SIGTERM → 3 秒后 SIGKILL 兜底） |
| 复用了已在运行的服务（如 harness CLI 启动的） | 退出时**不关闭**——那台服务不是 App 启动的，不该被 App 杀掉 |

## 环境变量（可选）

| 变量 | 作用 |
|---|---|
| `DSH_CLI` | 直接指定 `dsh` 入口（`@deepseek-ai/dsh` 的 `lib/bin.js` 路径；优先于内置运行时） |
| `DSH_NODE` | 直接指定 `node` 可执行文件路径（优先于内置运行时） |
| `DSH_HOME` | 传给 `dsh web` 的 `DSH_HOME`（默认 `~/.dsh`，首次使用自动初始化 web profile） |
| `DSH_NATIVE_PORT` | 自拉起时使用的端口（默认 3080，被占用则自动换空闲端口） |
| `DSH_NATIVE_FORCE_SPAWN=1` | 跳过「复用已有服务」检查，总是自己拉起（测试/专用实例用） |
| `DSH_REGISTRY` | 运行期 dsh 检查/升级用的 npm registry（优先于「设置 dsh registry…」与默认国内源） |
| `DSH_AUTO_UPGRADE=0` | 本次运行关闭自动升级 |
| `DSH_LANG=zh\|en` | 强制界面语言（优先于「设置」→「语言」的选择；默认跟随系统） |

> **GitHub token（Tasks 面板）**：可在面板「配置 GitHub Token」填入（存 Keychain），或写 `~/.dsh/gh-token`（App 与外部工具/代理共用，`chmod 600`）。公开仓库无需 token；私有仓库拉取/开 PR/评论关闭 issue 需要。

> 构建期变量 `DSH_NODE_VERSION`、`DSH_PACKAGE_SPEC`、`DSH_NODE_MIRROR`、`DSH_NPM_REGISTRY` 见上文「构建」。

## 日志

- `~/Library/Logs/oh-my-dsh/app.log` — App 自身行为（启动、复用/拉起、运行时版本信息、自动/手动升级、页面加载、退出清理）
- `~/Library/Logs/oh-my-dsh/server.log` — 自拉起的 `dsh web` 进程输出

## 工作原理（为什么不动源码）

壳二进制只做三件事：探测端口 → 用内置 `node` 执行内置 `<dsh>/lib/bin.js web --port <n>` 拉起/复用 → `WKWebView` 加载 `http://127.0.0.1:<n>`。
`dsh` 本体、`~/.dsh` 配置、会话数据全部原样，无任何补丁或注入。内置运行时装在 `Contents/Resources/runtime/`（`node` + `npm` + `dsh/` 依赖树），App 优先使用它，找不到时才回退到本机安装。

## 目录

```
platforms/macos/src/main.swift      原生壳（WKWebView 窗口 + 服务管理 + 菜单 + 信号处理 + dsh 升级/registry + 关于面板）
platforms/macos/src/MakeIcon.swift  App 图标生成器（渲染 → iconset → icns）
platforms/macos/build-app.sh        一键构建脚本（编译、打包、国内镜像下载 Node、npm 装 dsh、预下载模式、签名）
platforms/macos/make-pkg.sh         安装包脚本（pkgbuild 生成 .pkg 安装器 + hdiutil 生成 .dmg 镜像）
core/                共享核心（Node 模块：ANSI 模拟器 / 服务管理 / 升级 / 会话 RPC，跨平台复用）
platforms/           各平台壳（macos/ 现有壳，windows/ linux/ 规划中）
scripts/             跨平台工具（版本读取 / CHANGELOG 生成 / 校验和）
.cache/              构建缓存（node tarball、npm 缓存、已构建运行时）
dist/                构建产物（.app / .pkg / .dmg）
docs/                设计/排查文档（含 docs/repo-wiki-design.md —— Repo Wiki 功能设计）
docs/productization.md  产品化方案（路线图/分发/升级/多平台/开源治理 —— 见 [产品化方案](docs/productization.md)）
docs/milestones/        各里程碑目标文档（M1 产品化基础 … M5 Apple 生态，后续开发任务来源）
```

## 如何贡献

欢迎提交 PR、Issue 与建议！请先阅读 [CONTRIBUTING.md](CONTRIBUTING.md)（构建/测试/提交规范/PR 流程）
与 [SECURITY.md](SECURITY.md)（安全报告渠道）。

- **Bug / 功能请求**：使用仓库的 Issue 模板（bug / feature）提交；
- **本地测试**：`tests/terminal-emulator/run.sh`（模拟器单测）、`tests/wiki-panel/run.sh`（Wiki 面板单测）；
- **CI**：push/PR 自动跑 macOS arm64/x64/Universal 构建矩阵 + 单测（`.github/workflows/ci.yml`）。

本项目遵循 [MIT License](LICENSE)，代码只封装、绝不修改 DeepSeek Harness 上游源码。
