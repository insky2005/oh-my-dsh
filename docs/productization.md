# oh-my-dsh 产品化方案

> 版本：v1.0（方案文档）
> 日期：2026-08-15
> 状态：已批准执行（按里程碑推进）
> 范围：把 oh-my-dsh（macOS 原生壳，v1.7.1 / build 63）从个人工具产品化为**可分发、可升级、跨平台、社区化**的开源产品
> 事实核对：本文档「附录：现状核对表」中的现状均来自当前仓库（git `80dedfa`，2026-08-15 21:53 CST）；网络事实经 2026-08-15 检索核实并附链接；标注「待确认」处需在实施前再核实
> 配套：本文档为总纲，各章节落地时产出对应的设计文档（沿用 `docs/` 惯例）
> 调整（2026-08-15）：**Apple 开发者账号相关事项暂缓处理**（Developer ID 签名 / 公证 / App 自动升级 Sparkle / Homebrew Cask 上架），统一移至最后阶段 F（见 §2）；相关章节保留为届时实施方案

## 目录

1. [产品定位与现状](#1-产品定位与现状)
2. [产品路线图（Productization Roadmap）](#2-产品路线图productization-roadmap)
3. [功能路线图（Feature Roadmap）](#3-功能路线图feature-roadmap)
4. [源代码管理](#4-源代码管理)
5. [构建与持续集成](#5-构建与持续集成)
6. [签名与信任](#6-签名与信任)
7. [安装包分发](#7-安装包分发)
8. [自动化升级](#8-自动化升级)
9. [多操作系统支持](#9-多操作系统支持)
10. [Issue 反馈与用户支持](#10-issue-反馈与用户支持)
11. [质量保障与测试](#11-质量保障与测试)
12. [安全与隐私](#12-安全与隐私)
13. [风险与依赖](#13-风险与依赖)
14. [里程碑与排期](#14-里程碑与排期)
15. [附录：现状核对表](#15-附录现状核对表)

---

## 1. 产品定位与现状

### 1.1 一句话定位

**oh-my-dsh 是 DeepSeek Harness（`dsh`）的自包含原生桌面壳**——不改动任何 Harness 源码，把 `dsh web` 封装成双击即用的原生 App，并围绕它提供文件预览、集成终端、仓库知识库等原生增强能力。

### 1.2 核心原则（产品化过程中不得破坏）

| 原则 | 含义 |
|---|---|
| 不改上游源码 | 壳层只消费 `dsh web`，无任何补丁/注入；上游升级天然兼容 |
| 零依赖自包含 | App 内置 Node/npm/dsh 依赖闭包，全新机器开箱即用 |
| 服务生命周期清晰 | 复用外部实例不杀、自拉实例退出必清 |
| 国内加速取向 | 默认国内镜像（Node 下载 / npm registry），保留官方回退 |
| 隐私优先 | 数据留在用户机器，遥测/崩溃上报一律 opt-in |
| 版本分层 | App 版本与 dsh 版本解耦，dsh 可独立升级 |

### 1.3 当前能力清单（v1.7.1 / build 63，macOS 13+ arm64）

- **原生壳**：WKWebView 窗口、服务探测/自拉起（默认 3080，被占用自动换端口）、外部实例复用、退出清理（SIGTERM → 3s → SIGKILL 兜底）
- **面板**：文件/文件夹预览面板（项目目录树 + 多页签 + 宽度记忆）；集成终端面板（PTY + 自研 ANSI 模拟器 + 多标签）；Repo Wiki 知识库面板（dsh 代理生成/维护，可随仓库提交）
- **语言**：中/英（跟随系统，`DSH_LANG` 可强制），联动 WebView 语言
- **升级**：dsh 包手动（⌘U）与自动升级（24h 节流），npm registry 可配置（默认国内源）
- **产物**：`.app`（ad-hoc 签名）、`.pkg`、`.dmg`

### 1.4 产品化缺口清单（本文档要解决的）

| # | 缺口 | 影响 | 对应章节 |
|---|---|---|---|
| G1 | 无远端仓库 / LICENSE / Issue 渠道 | 无法协作、无反馈入口、无社区 | §4 / §10 |
| G2 | 无 CI/CD | 构建不可复现、发布靠手工 | §5 |
| G3 | 无代码签名/公证 | Gatekeeper 拦截、用户信任低、无法上 Homebrew | §6（暂缓 → F） |
| G4 | App 本身无自动升级（只升级 dsh 包） | 壳层新功能无法触达用户 | §8（暂缓 → F） |
| G5 | 升级会破坏包内签名（dsh 原地升级改写 `Contents`） | 公证后系统可能拒绝启动 | §6.3 / §8.2（暂缓 → F） |
| G6 | 仅 macOS arm64 | 平台覆盖单一 | §9 |
| G7 | 无崩溃上报/遥测（opt-in） | 质量闭环缺失 | §10.4 |
| G8 | 无自动化测试接入 | 回归风险 | §11 |

> 注：G3/G4/G5 依赖 Apple 开发者账号，按决策**暂缓处理**，统一放到最后阶段 F（见 §2）。

---

## 2. 产品路线图（Productization Roadmap）

五个阶段加暂缓的 F 阶段（P0–P4 + F），每阶段给出**目标 / 关键交付物 / 退出标准**。产品化主线：工程化与开源（P1）→ 跨平台覆盖（P2/P3）→ 生态增长（P4）→ Apple 生态（F，暂缓）。

### P0 · 现状基线（v1.7.x）— 已达成

- **目标**：功能完备的 macOS 单平台壳，验证「壳层 + 自包含运行时」模式可行
- **交付物**：v1.7.1（预览/终端/Wiki 面板、双语、dsh 升级）
- **退出标准**：`dist/oh-my-dsh.app` 可本地构建、安装、使用 ✅

### P1 · 产品化基础（≈1–2 周）

- **目标**：把「可用的 App」变成「可信赖、可分发、可协作的开源项目」
- **关键交付物**：
  1. GitHub 公开仓库：历史迁移、LICENSE（MIT）、CONTRIBUTING、Issue 模板（→ §4 / §10）
  2. CI：GitHub Actions 全量构建（arm64 / x64 / Universal）+ 测试 + Release 产物（→ §5）
  3. 共享核心抽取：端口探测 / 服务管理 / 升级 / 会话 RPC / ANSI 模拟器（→ §9.5）
  4. dsh 升级保留 + npm lockfile 固化（→ §12）
  5. 设置窗口化、首次引导（→ §3.4）
- **退出标准**：新用户可从 GitHub Releases 下载安装（附「右键 → 打开」引导，README 已有）；CI 绿灯；共享核心可被 P2 复用
- **依赖**：GitHub 仓库
- **暂缓项**：签名公证 / App 自动升级 / 运行时迁出（与 Apple 账号相关，统一移至 F 阶段，见下）

### P2 · Windows 版（≈2–3 个月）

- **目标**：覆盖最大桌面用户群
- **关键交付物**：
  1. 原生 Windows 壳（WinUI 3 + WebView2，C#/.NET 建议，→ §9.3）
  2. 共享核心抽取：端口探测 / 服务管理 / 升级 / 会话 RPC / ANSI 模拟器（→ §9.5）
  3. 终端面板移植（ConPTY + 复用模拟器）
  4. 安装包（MSI / Inno）与自动升级（Squirrel.Windows 或自研，→ §8.4）
- **退出标准**：Windows 10/11 x64 上「安装 → 运行 → 升级 → 卸载」全流程通过；CI 产出 Windows 产物
- **依赖**：P1 共享核心先行；Windows 代码签名证书（Authenticode）

### P3 · Linux 版（≈1–2 个月）

- **目标**：覆盖开发者主力发行版
- **关键交付物**：
  1. 原生 Linux 壳（GTK4 + WebKitGTK，→ §9.4）
  2. 分发：`.deb` / `.rpm` / AppImage（或 Flatpak）
  3. 升级：AppImage 增量更新 / Flatpak 自动更新 / 自研校验更新
- **退出标准**：Ubuntu 22.04/24.04 与 Fedora 上「安装 → 运行 → 升级」全流程通过；兼容性矩阵建立
- **依赖**：P2 共享核心复用；无签名要求但需发布校验和

### P4 · 生态与增长（持续）

- **目标**：从「能用的工具」到「有社区的生态」
- **关键交付物**：
  1. winget 上架（Windows）；Homebrew Cask 移至 F 阶段（暂缓）
  2. 国内分发镜像（延续 npmmirror 思路：OSS/CDN 镜像 pkg/dmg/appcast）
  3. 文档站（下载 / FAQ / 上手教程）、Discussions 社区运营
  4. 指标闭环：下载 / 崩溃 / opt-in 使用统计
  5. 功能路线图 P2/P3 项持续交付（→ §3）
- **退出标准**：指标定期回顾；两个以上外部贡献者合入 PR

### F · Apple 生态能力（暂缓，最后处理）

> 决策（2026-08-15）：以下事项依赖 **Apple 开发者账号**，**当前暂不处理**，统一放到本阶段；仅在产品需要时启动（正式对外推广、用户量增长、或 Homebrew Cask 成为刚需）。

- **目标**：补齐 Apple 生态的信任与分发能力
- **关键交付物**：
  1. 注册 Apple Developer Program（个人 $99/年）并申请 Developer ID 证书（→ §6.2）
  2. 签名 + `notarytool` 公证 + stapling；`.pkg` / `.dmg` 一并公证（→ §6）
  3. 运行时迁出签名包：`~/Library/Application Support/oh-my-dsh/runtime/`（→ §6.3；**可提前做，非阻塞**）
  4. App 自动升级：Sparkle 2 + appcast（→ §8.2）
  5. Homebrew Cask 上架（→ §7.2）
- **退出标准**：Gatekeeper 零拦截安装；App 自动升级闭环可用；Homebrew Cask 合入
- **触发条件**：正式对外推广 / 用户量增长 / 分发渠道（Cask）成为刚需

---

## 3. 功能路线图（Feature Roadmap）

> 优先级：**P1** 近期（P1/P2 阶段内）· **P2** 中期（P2/P3 阶段内）· **P3** 远期（P4 起）。
> 每项标注「现状 → 目标」与关联的产品化阶段。依据：README 已文档化的已知限制 + 上游 dsh 能力。

### 3.1 终端体验（现状：v1 无 IME 直输、DECSTBM 未实现、会话不持久）

| 功能 | 现状 → 目标 | 优先级 | 关联阶段 |
|---|---|---|---|
| 输入法直接输入 | 中文等需 ⌘V 粘贴 → 原生 IME 直输（macOS `NSTextInputClient` / Windows ConPTY IME / GTK IM） | P1 | P1–P3 |
| DECSTBM 滚动区 | 解析但忽略 → 实现（vim/top 等全屏程序兼容） | P2 | 任意 |
| 会话持久化 | 跨重启丢失 → 会话记录/恢复 | P2 | P1 后 |
| 字体与主题 | 固定等宽 13pt → 设置面板可配字体/字号/配色 | P2 | P1 设置窗口 |
| 剪贴板增强 | 基础复制/粘贴 → 选区格式、多行粘贴安全策略细化 | P2 | 任意 |

### 3.2 知识库增强（现状：仅标题过滤搜索）

| 功能 | 现状 → 目标 | 优先级 | 关联阶段 |
|---|---|---|---|
| 正文/语义检索 | 标题过滤 → QMD 检索落地（`docs/repo-wiki-design.md` 已列为候选） | P1 | P1 |
| 页面编辑 | 只读浏览 → 手动编辑/新建页（`manual: true` 页保护机制已有） | P2 | P1 后 |
| 跨项目/团队共享 | 单仓库 `.dsh/wiki/` → 多项目视图、共享只读知识库 | P3 | P4 |
| 生成质量评测 | 依赖 dsh 代理 → 抽样评测集 + 页面间链接校验 | P3 | P4 |

### 3.3 预览增强（现状：文本/图片/PDF/文件夹/未知类型）

| 功能 | 现状 → 目标 | 优先级 | 关联阶段 |
|---|---|---|---|
| 代码 Diff | 单文件预览 → 文件版本/变更对比视图 | P2 | P2 |
| Office 文档 | 不支持 → docx/xlsx/pptx 渲染 | P2 | P2–P3 |
| 音视频 | 不支持 → 内置播放器（系统解码） | P3 | P3 |
| 大文件 | 全量载入 → 虚拟滚动/分块读取 | P2 | P2 |

### 3.4 壳层体验（现状：单窗口、设置分散在菜单）

| 功能 | 现状 → 目标 | 优先级 | 关联阶段 |
|---|---|---|---|
| 设置窗口化 | 菜单内嵌设置 → 独立设置窗口（语言/registry/升级/主题/快捷键） | P1 | P1 |
| 命令面板 | 无 → ⌘K 全局命令面板（面板切换、动作、打开项目） | P2 | P2 |
| 菜单栏/托盘 | 仅 Dock → 托盘常驻 + 快捷唤起（macOS `NSStatusItem` / Windows TrayIcon / Linux AppIndicator） | P2 | P2–P3 |
| 多窗口 | 单窗口 → 多项目多窗口 | P3 | P3 |
| 首次引导 | 无 → onboarding（首次运行检查、教程、示例项目） | P1 | P1 |

### 3.5 dsh 深度集成（现状：仅消费 dsh web 界面；上游已具备插件/skills/goals/MCP 能力）

| 功能 | 现状 → 目标 | 优先级 | 关联阶段 |
|---|---|---|---|
| 会话管理器 UI | 靠 web 界面 → 原生侧栏：多会话/多 profile 切换 | P2 | P2 |
| 模型/provider 切换 | 进设置 → 壳层 UI 快速切换 | P2 | P2 |
| 插件市场 UI | 无 → 浏览/安装/启用 dsh cordis 插件 | P3 | P3 |
| MCP 管理 | 无 → MCP 服务器列表/开关/日志 | P3 | P3 |
| 目标可视化 | 无 → goals 进度面板 | P3 | P3 |

### 3.6 可靠性与性能（现状：启动即建面板基础结构）

| 功能 | 现状 → 目标 | 优先级 | 关联阶段 |
|---|---|---|---|
| 启动性能 | 面板懒加载 → 首窗 ≤2s 目标、WebView 预热分级 | P1 | P1 |
| 崩溃恢复 | 无 → 崩溃后会话恢复提示、DSH_HOME 备份 | P2 | P1 后 |
| 数据备份/迁移 | 无 → 一键备份/恢复 `~/.dsh` 与运行时 | P2 | P2 |

### 3.7 协作与生态（P4 起，隐私优先）

| 功能 | 说明 | 优先级 |
|---|---|---|
| 会话分享/导出 | 导出对话为 Markdown/JSON、链接分享 | P3 |
| 团队共享知识库 | 只读共享 wiki 源（git 仓库或私有端点） | P3 |
| 设置云同步（可选） | opt-in 同步语言/registry/主题等非敏感设置 | P3 |

---

## 4. 源代码管理

### 4.1 仓库策略（已决策：GitHub 公开 + MIT）

- **仓库**：GitHub 公开仓库（建议同名 `oh-my-dsh`）
- **License**：MIT（与上游 deepseek-harness 一致）；新增 `LICENSE` 文件
- **历史迁移**：现有本地仓库仅 2 个 commit（`80dedfa` / `b4bceba`），直接 `git push` 即可；`.cache/`、`dist/`、`pic/` 已被 `.gitignore` 排除（确认无大文件入库）

### 4.2 分支与发布模型

- 主干开发（trunk-based）+ `release/*` 分支发布；hotfix 上主干并 cherry-pick 到当前 release
- 每个发布打 tag：`v<major>.<minor>.<patch>`（如 `v1.8.0`），tag 驱动 CI 发布（→ §5.3）
- 提交规范：沿用 conventional commits（`feat(wiki): …`）；CHANGELOG 由发布脚本按 tag 区间生成（或手动维护 + 发布前校验）

### 4.3 版本与兼容性策略

- **App 版本（semver）与 dsh 版本解耦**；`build-app.sh` 的 `VERSION/BUILD` 改为单一来源（建议读 git tag，待实施定夺）
- **dsh 依赖锁定**：`DSH_PACKAGE_SPEC` 固定 RC 版本（当前 `@deepseek-ai/dsh@0.1.0-rc.6`），升级走显式发布流程（→ §8.3），不做 daily 追新
- **支持策略**：维护最近 2 个大版本；维护「App 版本 × dsh 版本」兼容矩阵（→ §11.3）

### 4.4 开源治理

- `CONTRIBUTING.md`（构建/测试/PR 流程，内容可复用 README 与本文档）
- `CODEOWNERS`（`src/`、`scripts/` 分设 owner）
- Issue 模板与标签体系（→ §10.1）

### 4.5 目录结构规划（当前 → 目标）

> 决策（2026-08-15）：只规划，暂不动手迁移；随各阶段实施逐步落位。

**当前结构**（git 实际跟踪，2026-08-15 核实）：

```
README.md  TERMINAL_PLAN.md  build-app.sh  make-pkg.sh  .gitignore
src/            5 个 Swift 文件（macOS 壳 + 面板 + 图标生成器）
tests/          terminal-emulator/ + wiki-panel/（各含 run.sh + swift 单测）
docs/           设计文档 + raw/；.dsh/  wiki + skills（随仓库提交）
（不入库：.cache/ .build/ dist/ pic/）
```

**问题**：壳逻辑（端口探测/服务管理/升级/ANSI 模拟器）全在 Swift 里无法跨平台复用；`src/` 无平台边界（P2/P3 无处安放）；版本号硬编码在 `build-app.sh`；缺开源基础设施（LICENSE/.github/等）；模拟器测试跟着 macOS 壳走而非跟着共享代码走。

**目标结构**（P1 起逐步落位）：

```
oh-my-dsh/
├── LICENSE  README.md  CHANGELOG.md  CONTRIBUTING.md  SECURITY.md  AGENTS.md(可选)
├── .github/
│   ├── workflows/          # ci.yml / release.yml / nightly.yml（P1）
│   ├── ISSUE_TEMPLATE/     # bug / feature / crash 模板（P1）
│   ├── dependabot.yml      # core 的 npm 依赖
│   └── CODEOWNERS
├── core/                   # ★ 共享核心（Node 模块建议，或 Rust）——P1
│   ├── package.json        # 端口探测 / 服务管理 / 升级 / 会话 RPC / ANSI 模拟器
│   └── tests/              # 模拟器测试随代码迁入
├── platforms/
│   ├── macos/              # ★ 现有 src/ + build-app.sh + make-pkg.sh 迁入（git mv 保留历史）
│   ├── windows/            # P2：WinUI 3 + WebView2
│   └── linux/              # P3：GTK4 + WebKitGTK
├── scripts/                # 跨平台工具：版本读取（读 git tag）/ CHANGELOG 生成 / 校验和
├── tests/                  # 保留：跨切面的集成 / QA 测试
├── docs/                   # 设计文档 + productization.md（plans/ 归档历史计划，可选）
├── .dsh/                   # 保留：wiki / skills 随仓库提交（已是产品特性）
└── .gitignore              # 补全 node_modules/ *.log .env 各平台构建产物
```

**要点**：
- `core/` 提到顶层：决定 P2/P3 成败，清晰表达「平台无关」边界，CI 可独立测试
- `platforms/<os>/`：每个平台自带源码 + 构建脚本 + README；macOS 整体迁入 `platforms/macos/`
- 版本单一来源：`build-app.sh` 的 `VERSION/BUILD` 常量改为读 git tag（P1 与 CI 同步做）
- 模拟器测试随代码进 `core/tests/`

**迁移注意点**：
- `.dsh/wiki` 的 frontmatter `sources` 引用了 `src/`、`README.md` 等路径——移动后用 repo-wiki 做一次**增量更新**修复陈旧标记
- 用 `git mv` 保留历史；`build-app.sh` 内部路径常量同步修改
- `dist/`、`.cache/`、`pic/` 继续不入库（产物走 GitHub Releases 附件）

**落地节奏**：P1 先做安全项（LICENSE / `.github/` / 版本单一来源 / 骨架）；P1 中期随共享核心抽取同步迁 `core/`；macOS 迁入 `platforms/macos/` 建议 P1 一次定好骨架（纯搬移、低风险），避免 P2 时二次搬迁。

### 4.6 版本发布规划

> 定义版本体系、通道、节奏与发布流程；与 §14 里程碑对齐，落地时遵循 §11.2 发布验收清单。

#### 4.6.1 版本体系

- **统一版本号**：一次 tag 产出全平台产物（macOS/Windows/Linux 同一 `vX.Y.Z`），避免平台间版本混乱；VERSION 取自 git tag，BUILD 取 CI 运行号（写入 `CFBundleVersion`）
- **分层版本模型**（App / 运行时 / dsh 三层独立，互不绑定）：

| 层 | 版本来源 | 更新方式 |
|---|---|---|
| App（壳层） | git tag `vX.Y.Z`（semver） | 整包发布；F 阶段起 Sparkle 自动升级 |
| 运行时（Node） | 构建期锁定（`DSH_NODE_VERSION`） | 随 App 发布 |
| dsh 上游 | `DSH_PACKAGE_SPEC` 固定（当前 `0.1.0-rc.6`） | npm 原地升级（现有机制，独立于 App） |

- **semver 语义**：MAJOR = 破坏性变更/跨平台里程碑（如 v2.0.0）；MINOR = 新功能；PATCH = 缺陷修复

#### 4.6.2 发布通道

| 通道 | tag 形态 | 分发形态 | 面向用户 |
|---|---|---|---|
| stable | `v1.8.0` | GitHub Release 正式 + 国内镜像同步 | 所有用户 |
| beta / rc | `v1.9.0-rc.1` | GitHub Release **pre-release** | 尝鲜/发布前验证 |
| nightly（可选） | 无 tag（CI 产物） | 独立工作流，不公开 | 内部/贡献者 |

- 暂缓期（无签名公证）：仅 stable + pre-release，无自动升级；F 阶段起 appcast 多通道（stable/beta）由 Sparkle 消费

#### 4.6.3 发布节奏

- **MINOR（功能）**：随里程碑，约每 1–2 个月一个（M1→v1.8.0、M2→v1.9.0、M3→v2.0.0）
- **PATCH（修复）**：按需；严重缺陷单人维护口径下 48h 内出修复版
- **dsh 上游升级**：不追新；新版本经 nightly 冒烟（§5.2）通过后，随一个 MINOR 或独立 PATCH 显式发布（§8.3）
- **支持策略**：维护最近 2 个大版本（沿用 §4.3）
- 发布窗口：避开周末/长假（国内镜像与社区同步需要人工确认）

#### 4.6.4 发布流程

1. **代码冻结**：功能合入主干，CI 全绿（构建矩阵 + 单测）
2. **版本号**：打 tag `vX.Y.Z`，同步生成 CHANGELOG（conventional commits → 按 tag 区间）
3. **构建发布**：`release.yml` 自动执行——构建矩阵 → 打包 → 校验和 → 创建 GitHub Release（先 pre-release 验证）
4. **QA 门禁**：§11.2 发布验收清单全过（含干净机器冒烟）
5. **转正式**：Release notes 模板（新功能 / 修复 / 已知问题 / 升级说明）；转 stable 并置顶
6. **双通道同步**：国内镜像同步产物与 appcast（→ §7 / §8.5）
7. **发布后**：监控 opt-in 崩溃与 issue 反馈；严重问题立即出 PATCH，必要时回滚（F 阶段 Sparkle 回滚机制）

#### 4.6.5 版本计划映射（与里程碑对齐）

| 版本 | 里程碑 | 内容 |
|---|---|---|
| v1.8.0 | M1（P1） | 开源 + CI + 设置窗口 + 共享核心（macOS 单平台） |
| v1.9.0 | M2（P2） | Windows MVP（统一版本号，双平台产物） |
| v2.0.0 | M3（P3） | Linux 加入，首个三平台版本（跨平台稳定版语义） |
| v2.1+ | M4（P4） | 渠道上架 / 文档站 / 指标，按 MINOR 节奏持续 |
| （F 阶段） | M5 | 签名公证后正式对外分发，App 自动升级启用 |

> 上表为建议计划，实际以里程碑达成情况为准；版本号不绑定 dsh 上游版本。

#### 4.6.6 发布后事项

- 镜像同步确认、社区公告（Discussions / Release notes 转发）
- 已知问题跟踪：issue 模板 + 标签体系（→ §10.1）
- 回滚预案：严重缺陷 → 立即 PATCH；App 层自动升级回滚（F 阶段）

---

## 5. 构建与持续集成

### 5.1 现状与目标

- **现状**：`build-app.sh` 本地构建（需 Xcode CLT + 网络）、`make-pkg.sh` 本地打包，无自动化
- **目标**：一次 tag push → 自动构建、测试、打包、发布（签名/公证在 F 阶段接入）

### 5.2 工作流设计（GitHub Actions）

| 工作流 | 触发 | 内容 |
|---|---|---|
| `ci.yml` | push / PR | 全平台构建矩阵 + 单测（`tests/run.sh`）+ Swift 编译检查；缓存 `.cache/` |
| `release.yml` | tag `v*` | 构建矩阵 → 打包（pkg/dmg）→ 创建 GitHub Release 附产物；F 阶段起接入签名/公证 → appcast → Homebrew Cask PR |
| `nightly.yml`（可选） | cron | 新 dsh 版本对壳的兼容冒烟（升级矩阵预检） |

### 5.3 关键设计

- **构建矩阵**：macOS 用 `macos-14` runner（Sonoma 镜像 2024-01 起可用，含 arm64 原生 runner，见 [GitHub Changelog](https://github.blog/changelog/2024-01-30-github-actions-macos-14-sonoma-is-now-available/)）；x64 同理；Universal 用 `lipo -create` 合并两架构二进制（或直接双 target 编译）；Windows `windows-2022`（P2）；Linux `ubuntu-24.04`（P3）
- **缓存**：`actions/cache` 复用 `.cache/`（node tarball + npm cache + 已构建运行时，按 node+dsh 版本做 key），与本地 `--prefetch` 语义一致
- **版本单一来源**：VERSION 取自 git tag；BUILD 取 CI 运行号；Info.plist 由脚本注入（P1 改造 `build-app.sh`）
- **密钥**：Windows Authenticode 证书存 GitHub Secrets；Apple Developer ID 证书（p12）与 notarytool API key 待 F 阶段接入；产物哈希写入 Release notes

### 5.4 测试接入

`tests/terminal-emulator/run.sh`、`tests/wiki-panel/run.sh` 直接接入 CI；新增冒烟测试（→ §11）。

---

## 6. 签名与信任

> ⚠️ 本节内容属于 **F 阶段（暂缓）**：依赖 Apple 开发者账号，当前不实施。保留目标与方案，供届时直接落地。

### 6.1 现状

`build-app.sh` 末尾 `codesign --force --deep --sign -`（ad-hoc）；`make-pkg.sh` 尝试 `--sign -`，失败则 unsigned。后果：Gatekeeper「无法验证开发者」、无法公证、无法上 Homebrew Cask（社区惯例要求签名+公证，见 [katrain#785](https://github.com/sanderland/katrain/issues/785)）。

### 6.2 目标（P1）

- 注册 Apple Developer Program（$99/年），申请 **Developer ID Application** 证书
- 构建产物 Developer ID 签名 → `xcrun notarytool submit` 公证 → `stapler` stapling（官方要求见 [Apple 文档：Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)）
- `.pkg` 与 `.dmg` 一并签名/公证（.dmg 整体公证）

### 6.3 关键设计变更：运行时迁出签名包（解决 G5）

当前 dsh 升级是「原地改写 `Contents/Resources/runtime/dsh`」——对 ad-hoc 包无碍，但对 Developer ID 包会破坏代码签名密封，公证后系统可能拒绝后续启动。

- **方案**：把可升级运行时从 `Contents/Resources/runtime/` 迁到用户目录 `~/Library/Application Support/oh-my-dsh/runtime/`；App 包内保留一个「种子运行时」用于首次启动播种（支持离线首装）
- **迁移**：首次启动检测旧版包内运行时 → 复制到新位置并继续使用；`DSH_CLI` / `DSH_NODE` 环境变量覆盖机制保留
- **收益**：App 包保持密封；Sparkle 整包更新与 dsh 层升级互不干扰；包体积进一步缩小（种子可裁剪 npm）

---

## 7. 安装包分发

### 7.1 渠道矩阵

| 平台 | 产物 | 主渠道 | 国内加速（延续既有取向） | 上架（P4 / F） |
|---|---|---|---|---|
| macOS | `.dmg`（拖拽）/ `.pkg`（安装器） | GitHub Releases | OSS/CDN 镜像 + Gitee Releases 兜底 | Homebrew Cask（F，暂缓） |
| Windows | MSI / Inno Setup exe | GitHub Releases | 同左 | winget |
| Linux | `.deb` / `.rpm` / AppImage（或 Flatpak） | GitHub Releases + 发行版仓库 | 同左 | Flathub |

### 7.2 macOS 分发细化

- GitHub Releases 为主：tag 触发 CI 附 `.dmg` + `.pkg` + appcast（§8）+ `SHA-256SUMS`
- Homebrew Cask（暂缓，F 阶段）：cask 需公证签名 App；`appcast` stanza 指向 Sparkle feed（cask 规范见 [homebrew-cask 文档](https://github.com/phatblat/homebrew-cask/blob/master/doc/cask_language_reference/stanzas/appcast.md)）
- 国内镜像：OSS/COS 存产物 + 镜像 appcast（→ §8.5）；下载页给出双通道
- **暂缓期分发方式**：保持现状（GitHub Releases + 国内镜像 + ad-hoc 签名），安装引导「右键 → 打开」已在 README 写明

### 7.3 下载页

GitHub Pages 单页：平台选择 → 最新版本 / 校验和 / 更新日志 / 安装说明（P4 与文档站合并）。

---

## 8. 自动化升级

### 8.1 分层升级模型

| 层 | 内容 | 机制 | 现状 |
|---|---|---|---|
| **App 层** | 壳层（Swift/UI/面板） | Sparkle 2 整包更新 | ❌ 暂缓（F 阶段，依赖签名公证） |
| **运行时层** | Node + npm | 随 App 整包更新（迁出 bundle 后由 App 层管理） | 随包（P1 调整） |
| **dsh 层** | `@deepseek-ai/dsh` 及其依赖闭包 | 现有 npm 原地升级（⌘U / 自动 24h 节流） | ✅ 已有，保留 |

### 8.2 App 层：Sparkle 2（暂缓，F 阶段）

> 本节为 F 阶段实施方案，当前不实施（依赖 Apple 账号的签名公证）。

- 集成 [Sparkle 2](https://deepwiki.com/sparkle-project/Sparkle/5-integration-guide)（EdDSA 签名 appcast；私钥仅存 CI 密钥库，公钥嵌入 App）
- 更新策略：启动检查（24h 节流，与现有 dsh 升级节流一致）+ 手动「检查更新…」菜单；可选 beta 通道（多 channel appcast）
- 更新流程：自动下载 → 校验 EdDSA → 替换整包 → 重启；失败自动回滚并保留旧包日志
- **退出标准**：CI 发布自动产出 `appcast.xml` + 新包；App 内完成「发现 → 下载 → 安装 → 重启」闭环

### 8.3 dsh 层：保留 + 加固

- 保留现有 npm 原地升级（用户习惯，国内 registry 可用）
- 加固：升级前校验 npm 包来源与 registry TLS；升级失败回滚到上一版本（保留备份目录）；升级日志入 `~/Library/Logs/oh-my-dsh/app.log`
- 发布流程：新 dsh 版本在 nightly 冒烟（§5.2）通过后才标记为「推荐升级」

### 8.4 其他平台（P2/P3）

- **Windows**：Squirrel.Windows（NSIS 安装器 + Delta 更新）或自研（下载 MSI → 校验 → 静默安装）；feed 结构对齐 appcast 便于双通道
- **Linux**：AppImage 增量更新 / Flatpak 自动更新 / 自研（校验和 + 替换）
- 所有 feed 支持镜像（→ §8.5）

### 8.5 Feed 托管与国内可达

- **主 feed**：GitHub Pages（`https://<owner>.github.io/oh-my-dsh/appcast.xml`）
- **镜像 feed**：国内 OSS/CDN 定期同步（CI 步骤）；App 内 registry/feed 可配置（沿用「设置 dsh registry」模式）

---

## 9. 多操作系统支持

### 9.1 平台能力对照（目标态）

| 能力 | macOS（现有） | Windows（P2） | Linux（P3） |
|---|---|---|---|
| UI 壳 | Swift/AppKit + WKWebView | WinUI 3 + WebView2（C#/.NET 建议） | GTK4 + WebKitGTK（Rust 或 C） |
| 终端 | forkpty + 自研 ANSI 模拟器 | ConPTY + 复用模拟器 | forkpty/posix_spawn + 复用模拟器 |
| 服务管理 | 端口探测/拉起/清理（Swift） | 共享核心（§9.5） | 共享核心 |
| 升级 | Sparkle（暂缓 F） | Squirrel.Windows / 自研 | AppImage / Flatpak / 自研 |
| 安装包 | `.pkg` / `.dmg` | MSI / Inno | `.deb` / `.rpm` / AppImage |
| 上游 dsh 支持 | ✅ | ✅（`dsh-pwsh-local`） | ✅（`dsh-terminal-bash`） |

### 9.2 为什么可行：上游 dsh 本身跨平台

`@deepseek-ai/dsh` 是 Node.js CLI，已内置 Windows PowerShell（`dsh-pwsh-local`）与 bash 终端插件；`dsh web` 是纯 Web UI。因此**只有壳层需要按平台实现**，且三端面对的是同一个 HTTP 服务与 Web UI——这是「各平台原生」路线可行的根本原因。

### 9.3 Windows 技术要点

- WinUI 3（Windows App SDK）+ [WebView2 控件](https://learn.microsoft.com/en-us/windows/apps/develop/ui/controls/webview2)：WebView2 使用系统级 Evergreen Chromium 运行时（Win11 预装、Win10 引导安装），体积小、随系统更新
- 语言建议 C#/.NET 8（开发效率优先）或 C++/WinRT（极致体积），待实施定夺
- 终端：ConPTY（Windows 伪终端）+ 复用自研 ANSI 模拟器（模拟器是纯逻辑、天然可移植——建议 P1 就把它抽进共享核心）

### 9.4 Linux 技术要点

- GTK4 + WebKitGTK（`WebKitWebView`，GTK4 支持自 WebKitGTK 2.40+）；备选 [webview/webview](https://deepwiki.com/webview/webview/2.1-installation-guide) 类封装
- 语言建议 Rust（gtk4-rs + webkit2gtk-rs）或 C，待实施定夺
- 终端：forkpty/posix_spawn（与 macOS 类似）；IME 用 GTK IM context
- 分发：先 `.deb` / `.rpm` + AppImage 覆盖主流发行版；Flatpak 作为 P4 上架通道

### 9.5 共享核心策略（原生路线下的复用最大化）

原生路线的最大风险是三端重复实现业务逻辑。建议：

- **共享核心**（P1 起抽取）：端口探测、服务拉起/监控/清理、npm 升级、registry/feed 配置、会话 RPC、**ANSI 终端模拟器**——抽成与 UI 无关的模块
- **实现载体候选**：
  - a) Rust/C++ 静态库 + FFI（性能好、三端可链接）
  - b) **Node 模块**：壳内已有 Node 运行时，逻辑用 JS 实现、壳以子进程/HTTP 调用——与「壳内嵌 Node」架构契合度最高，三端零编译差异
  - 建议优先评估 b，待实施定夺
- **UI 层**各平台原生实现（Swift / WinUI / GTK），只负责窗口、WebView、菜单、面板交互

### 9.6 平台差异风险

WebKit（macOS/Linux）与 Chromium（WebView2）对 dsh web 的渲染差异、PTY 行为差异（forkpty vs ConPTY）、IME 差异——纳入兼容性矩阵（§11.3）与 nightly 冒烟。

---

## 10. Issue 反馈与用户支持

### 10.1 GitHub Issues（已决策：公开仓库）

- **模板**（`ISSUE_TEMPLATE/`）：
  - `bug_report.yml`：平台（macOS/Windows/Linux + 版本）、App 版本、dsh 版本、Node 版本、复现步骤、日志附件路径（`~/Library/Logs/oh-my-dsh/app.log`）
  - `feature_request.yml`：功能、动机、验收想法
  - `crash_report.yml`（P1 后）：崩溃日志/上报 ID
- **标签体系**：`platform/macos`、`platform/windows`、`platform/linux`、`kind/bug`、`kind/feature`、`kind/regression`、`priority/*`、`good first issue`

### 10.2 反馈入口闭环

- App 内「反馈…」菜单（设置菜单下）：预填版本信息（App/dsh/Node/registry/语言）→ 打开 GitHub 新建 issue 页；支持一键打包最近日志
- 升级/崩溃后的自动引导反馈（可选）

### 10.3 社区

- GitHub Discussions：Q&A、想法、showcase（P1 开启）
- 响应 SLA：社区协作模式（维护者 + `good first issue` 引导贡献者）

### 10.4 崩溃上报与遥测（opt-in）

- Sentry（macOS SDK / Windows、Linux 用 sentry-native），首次启动弹窗征求同意（**默认关闭**）
- 上报内容最小化：版本、平台、崩溃栈；**不含**对话内容与 `~/.dsh` 数据
- 配套隐私说明页（P1 文档站内）

---

## 11. 质量保障与测试

### 11.1 分层测试

| 层 | 内容 | 位置 |
|---|---|---|
| 单元 | 终端模拟器（已有 `emulator-tests.swift`）、wiki 面板（已有）、共享核心逻辑 | `tests/`，CI 跑 `run.sh` |
| 集成 | 壳 ↔ dsh web 交互（RPC、端口复用/拉起/清理） | P1 新增，CI |
| 冒烟 | 干净环境「安装 → 启动 → 升级 → 卸载」 | P1 起：macOS 用 Tart 虚拟机；P2/P3 用 Windows/Linux runner |
| 手工 QA | 面板交互、双语、升级、退出清理（沿用 TERMINAL_PLAN.md 的 QA 清单模式） | 发布前 checklist |

### 11.2 发布验收清单（Release Checklist）

1. CI 全绿（构建矩阵 + 单测）
2. 签名 / 公证 / stapling 校验通过（`spctl --assess`）——F 阶段起执行，暂缓期跳过
3. 干净机器冒烟通过
4. appcast 生成且 EdDSA 校验通过——F 阶段起执行，暂缓期跳过
5. `SHA-256SUMS` + Release notes 就绪
6. 兼容性矩阵无新增回归（§11.3）

### 11.3 兼容性矩阵

| 平台 | 覆盖范围 |
|---|---|
| macOS | 13 / 14 / 15 × arm64 / x64（Universal） |
| Windows | 10 22H2 / 11 × x64（P2 起；arm64 评估） |
| Linux | Ubuntu 22.04 / 24.04、Fedora、Arch（AppImage 覆盖） |

### 11.4 性能目标

- 首窗显示 ≤ 2s（复用端口时 ≤ 1s）；面板切换 ≤ 300ms；终端 10k 行滚动无卡顿
- 内存：基线 ≤ 400MB（不含 WebView 峰值）；进程数 = 壳 + 服务 + 面板按需

---

## 12. 安全与隐私

### 12.1 升级安全

- App 层：Sparkle EdDSA 公钥校验（私钥仅存 CI）——F 阶段起生效
- dsh 层：registry TLS + npm 包来源固定；升级失败自动回滚
- Node tarball：构建期 SHA-256 校验（现有 `build-app.sh` 已具备，保留）
- 供应链：dsh 安装加 lockfile（`package-lock.json` 固化传递依赖），registry 与镜像双重校验

### 12.2 数据边界

- 会话/配置（`~/.dsh`）、运行时、日志均留在用户机器；App 不收集
- 崩溃上报 / 遥测 opt-in（§10.4）；隐私说明页公示

### 12.3 代码完整性

- 签名包密封（§6.3 迁出运行时后保持）；每次升级验证 App 包签名后再启动服务

---

## 13. 风险与依赖

| 风险 | 影响 | 缓解 |
|---|---|---|
| 上游 dsh 仍为 RC（`0.1.0-rc.6`） | API/行为可能变化 | 版本锁定 + 兼容矩阵 + nightly 冒烟；紧跟上游 Release |
| npm registry 可用性 | 安装/升级失败 | 国内镜像 + 官方回退（已具备）；缓存 |
| Apple 生态成本与流程（F 阶段） | $99/年 + 公证摩擦 | 暂缓期无此风险；进入 F 阶段时评估并 CI 自动化 |
| 三平台原生维护成本 | 人力翻倍 | 共享核心（§9.5）最大化复用；P2→P3 错峰 |
| WebView 引擎差异 | dsh web 渲染/交互差异 | 兼容矩阵 + 三端 nightly 冒烟 |
| PTY/IME 平台差异 | 终端体验不一致 | 模拟器共享 + 各端适配层；已知限制文档化 |
| 单人维护瓶颈 | 进度与响应 | 社区化（good first issue）、P4 引入贡献者 |

---

## 14. 里程碑与排期

> 粗略估算，单人维护口径；依赖关系：P2/P3 依赖 P1 的共享核心与 CI 基础设施。

| 里程碑 | 内容 | 周期 | 依赖 |
|---|---|---|---|
| M1（P1） | 开源 + CI + 共享核心 + 设置窗口/首次引导 | ≈1–2 周 | GitHub 仓库 |
| M2（P2） | Windows 壳 MVP + 终端/预览移植 + MSI + 自动升级 | ≈2–3 个月 | M1 共享核心 |
| M3（P3） | Linux 壳 MVP + deb/rpm/AppImage + 升级 | ≈1–2 个月 | M1 共享核心 |
| M4（P4） | winget/国内镜像 + 文档站 + 指标 + 社区运营 | 持续 | M1–M3 |
| M5（F） | Apple 生态（暂缓）：注册账号 + 签名公证 + Sparkle + Homebrew Cask | 待定（需要时启动） | 独立，不阻塞 M1–M4 |

**关键路径**：M1 的「共享核心抽取」→ M2 Windows；**M5（Apple 生态）独立排在最后，M1–M4 完全不受影响**。

> 每个里程碑有独立**目标文档**（后续开发工作以此为准）：`docs/milestones/M1-productization-foundation.md`（产品化基础）→ `M2-windows.md`（Windows）→ `M3-linux.md`（Linux）→ `M4-ecosystem-growth.md`（生态增长）→ `M5-apple-ecosystem.md`（Apple 生态，暂缓）。

---

## 15. 附录：现状核对表

> 核实时间：2026-08-15 21:53 CST；依据：git `80dedfa`（feat(wiki) … v1.7.1, build 63）、`README.md`、`build-app.sh`、`make-pkg.sh`、`.dsh/wiki/index.md`。

| 项 | 现状 | 依据 |
|---|---|---|
| App 版本 | 1.7.1 / build 63 | `build-app.sh` VERSION/BUILD |
| 源码规模 | `src/` 5 个 Swift 文件约 7.6k 行（main 2236 / TerminalPanel 1875 / WikiPanel 1928 / PreviewPanel 1445 / MakeIcon 104） | `wc -l` |
| 内嵌运行时 | Node v24.19.0 + npm + dsh 0.1.0-rc.6 | 运行时实测 |
| 上游 | deepseek-ai/deepseek-harness，MIT，npm 发布，RC 阶段 | `@deepseek-ai/dsh` package.json |
| 构建 | `build-app.sh`：下载 Node（SHA-256 校验）+ npm install dsh，国内镜像默认，`.cache/` 缓存 | `build-app.sh` |
| 打包 | `make-pkg.sh`：pkgbuild `.pkg` + hdiutil `.dmg`，preinstall 清旧版 | `make-pkg.sh` |
| 签名 | ad-hoc（`codesign --force --deep --sign -`） | `build-app.sh` |
| 平台 | 仅 macOS 13+ arm64 | Info.plist `LSMinimumSystemVersion` + 产物命名 |
| 升级 | 仅 dsh 包（npm 原地升级，手动 ⌘U + 自动 24h 节流）；App 无自动升级 | README |
| 已知限制 | 终端无 IME 直输 / DECSTBM 未实现 / 会话不持久；Wiki 仅标题搜索；预览无音视频/Office | README |
| git | 本地 main，2 commits，无 remote/tag；无 LICENSE | git 实测 |
| 测试 | `tests/terminal-emulator`、`tests/wiki-panel`（run.sh + swift 单测） | `tests/` |
| 文档 | README、TERMINAL_PLAN、`docs/`（repo-wiki-design 等）、`.dsh/wiki/`（代理维护） | 目录实测 |
| 工程约定 | 不改 dsh 源码、conventional commits、L10n 中英、registry 默认国内镜像 | README / `.dsh/wiki/` |
| Apple 开发者账号 | 未持有（决策：相关事项暂缓 → F 阶段） | 2026-08-15 产品决策 |
| 历史发布 | 本地构建产物 1.5.7 / 1.6.23 / 1.6.28 等（`dist/`，无 git tag、无 Release） | `dist/` 实测 |

---

## 参考资料

- [Sparkle Integration Guide（sparkle-project/Sparkle）](https://deepwiki.com/sparkle-project/Sparkle/5-integration-guide)
- [Apple：Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [GitHub Changelog 2024-01：macOS 14 (Sonoma) runner 可用](https://github.blog/changelog/2024-01-30-github-actions-macos-14-sonoma-is-now-available/)
- [Microsoft Learn：WebView2 in WinUI 3](https://learn.microsoft.com/en-us/windows/apps/develop/ui/controls/webview2)
- [webview/webview（GTK4/WebView2 封装参考）](https://deepwiki.com/webview/webview/2.1-installation-guide)
- [homebrew-cask：cask_language_reference（appcast stanza）](https://github.com/phatblat/homebrew-cask/blob/master/doc/cask_language_reference/stanzas/appcast.md)
- [katrain#785：Homebrew 分发需要签名与公证](https://github.com/sanderland/katrain/issues/785)
