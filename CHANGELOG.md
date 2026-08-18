# Changelog

All notable changes to this project are documented in this file. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). Versions below
`v1.8.0` are summarized from the git history (conventional commits).

## [Unreleased]

### Added

- **浏览器面板（Chromium/CEF 内核）**（活动栏 globe / `⌥⌘B`）：多标签浏览器，每标签一个 Chromium 渲染进程（五 helper app：base/Alerts/GPU/Plugin/Renderer，名字承重）；地址栏导航（无 scheme 自动补 `https://`）、后退/前进/刷新·停止；控制台抽屉（CDP 捕获 console/异常/全部网络请求 + JS 求值 + 清空）；DevTools 按钮在系统浏览器打开完整 Chromium DevTools；`use-mock-keychain` 不弹钥匙串密码框；profile 收在 `~/.dsh/browser/`。
- **浏览器 REST API**（`127.0.0.1:3081`，`DSH_BROWSER_PORT` 覆盖，端口文件 `~/.dsh/browser-api.port`）：`status`/`open`/`tabs`/`back`/`forward`/`reload`/`stop`/`eval`/`console`/`console/clear`/`screenshot`/`hide`，CORS 放行；Agent 驱动自动展开面板；配套技能 `.dsh/skills/shell-browser/SKILL.md`（modelInvocable）。
- **CEF 构建管线**（`platforms/macos/build-cef.sh`）：版本固定 + sha1 校验 + `.cache` 缓存；wrapper/shim/helper 编译；五 helper 组装与由内向外签名；`build-app.sh`/CI 接入。
- 测试：`tests/browser-panel/`（日志缓冲/URL 规范化/HTTP 解析/REST 路由，56 断言）；CI 编译清单与浏览器测试步骤登记。
- 设计文档：`docs/plans/BROWSER_PLAN-browser-panel.md`（含根因修正：CEF 148+ 需五 helper，缺 `(Renderer)` 导致 renderer 静默失败——曾误判为签名问题）。

## [1.10.0] - 2026-08-18

### Added

- **系统优先 node 选择策略**：`dsh web` 启动优先使用操作系统安装的 node（PATH → nvm current → nvm default → nvm 最新 → Homebrew），内置 node 仅作兜底；`DSH_NODE` 显式覆盖仍无条件优先（无回退）。
- **About 面板显示实际 node**：显示实际运行 dsh web 的 node 版本与路径，合并为一行。
- **dsh web 环境合并登录 shell PATH**：App 启动时经 `/bin/zsh -ilc` 读取一次登录 shell PATH（8s 超时兜底、失败保留继承值）赋给 dsh web，使其 bash 会话能使用用户全局工具（nvm bin、`~/.local/bin` 等，如 `agent-browser`）；不再向 PATH 注入内置目录。
- **GitHub token 按仓库作用域**：解析优先级 Keychain 专属（`<owner>/<repo>`）→ `~/.dsh/tokens/<owner>-<repo>` → Keychain 通用 → `~/.dsh/gh-token`；多工作区各用各的 token（App 与外部工具/代理共用同一份）。
- **GitHub token 双写保存**：面板保存时 Keychain + `~/.dsh/tokens/<owner>-<repo>` 文件（chmod 600）双写，清空时双清。
- **GitHub token 文件优先读取**：token 读取改为文件优先（免 Keychain 密码提示），Keychain 写入设 `kSecAttrAccessibleAfterFirstUnlock` 免每次弹密码。
- **issue 处理按统一分支规范**：feature 类 issue 切 `feature/issue-N`，bug/其他切 `fix/issue-N`（按 label 判定）；issue-fix skill 分支说明同步。
- **issue-fix skill 自动安装**：任务开始时 `ensureIssueFixSkillInstalled` 写入 `<repoRoot>/.dsh/skills/issue-fix/`（内嵌副本与仓库字节一致、幂等），全新工作区也能处理 issue。
- **`scripts/git-remote.sh`**：push 前检测 remote 名（github 优先，origin 兜底），`release-fix.sh` 不再硬编码 origin。
- **文档**：`docs/git-workflow.md`（统一分支与发布规范：main 只合并/只打主版本，feature/fix/release 分支模型，patch 版本同步回 main 走 PR）；AGENTS.md 补充分支提交强制规范与 GitHub token 位置；`.dsh/wiki` 知识库同步刷新。

### Changed

- **Node 选择策略反转（系统优先、内置兜底，含版本门槛）**：`dsh web` 启动优先使用操作系统安装的 node（PATH → nvm current → nvm default → nvm 最新 → Homebrew），但**低于版本门槛（默认 22.0.0，`DSH_NODE_MIN` 可覆盖）的系统 node 会被跳过**——dsh rc.6 实际需要 Node ≥ 22（`node:zlib` 的 zstd ESM 导出、`Promise.withResolvers`、`node:module.stripTypeScriptTypes`，Node 20 全部缺失，实测 v20 启动 dsh web 会崩在插件树加载）；仅当系统 node 缺失/过旧、或用它启动 dsh web 失败时才回退内置 node；`DSH_NODE` 显式覆盖仍无条件优先（无回退）；启动轮询增加 1s 沉降校验，避免"引导页含 `__DSH_BOOT__` 但随后崩溃"的假就绪。
- **dsh web 环境不做 PATH 注入，但合并登录 shell PATH**：移除启动与升级路径的内置目录 PATH 置顶；App 启动时经 `/bin/zsh -ilc` 读取一次登录 shell PATH（8s 超时兜底、失败保留继承值）赋给 dsh web，使其 bash 会话能使用用户全局工具（nvm bin、`~/.local/bin` 等，如 `agent-browser`）；About 面板的 Node 版本显示实际运行 dsh web 的 node。
- **CI action 升级**（dependabot）：`actions/upload-artifact` 4→7、`actions/setup-node` 4→7、`actions/cache` 4→6、`actions/download-artifact` 4→8。
- **版本 fallback 推进到 1.10.0**（v1.9.0 发布后的开发线版本）。

### Fixed

- **Tasks 面板跟随工作区切换**：dshSession 切换时无条件触发 `tasksPanel.workspaceChanged()`（不再依赖 ProjectDirectory 变化）；切换顺序修正为先 `ProjectDirectory.set` 再触发；`workspacePath` 非空时严格按当前会话判断（GitHub 仓库→显示 issues，非 GitHub→诚实显示 not a GitHub repo，不再 fallback 到其他 workspace），仅启动早期 ProjectDirectory 未解析时才用 `workspace.list` 兜底；Ungrouped 会话切回也能正确识别。
- **token 读取文件优先**（免 Keychain 密码提示）：顺序为文件专属 → 文件通用 → Keychain 专属 → Keychain 通用；配置框文案更正为按仓库双写（`~/.dsh/tokens/<owner>-<repo>`），配置按钮图标改齿轮。
- **壳层内嵌 repo-wiki skillMarkdown 同步**：补规则 8 提交指令（与仓库 SKILL.md 字节一致），修复 `ensureInstalled` 每次用旧内嵌版覆盖仓库文件导致提交规则丢失。
- **nvm 解析**：系统 node 解析 honor nvm default alias、prefer nvm current（最后一次 `nvm use`）。
- **git remote 名检测**：`git push` 前检测 remote 名（github 优先，origin 兜底），`release-fix.sh` 不再硬编码 origin。

## [1.9.0] - 2026-08-16

### Added

- **IssueRunner 任务面板**（活动栏「任务 / Tasks」、⌥⌘J）：GitHub issue 驱动的串行任务流水线——
  - 仓库自动识别（git remote）+ open issues 拉取（REST，过滤 PR；私有仓库 Keychain token）；
  - 处理流程：切分支 `fix/issue-N` → 新建 dsh 会话（归主工作区）→ 会话改名可追溯 → issue-fix skill 修复 → 推送 → 开 PR；
  - 串行队列、行内展开详情（状态/标签/分支/PR/正文，滚动区 + 底部按钮）、取消/重试/打开 PR；
  - 完成后的 issue 支持「评论并关闭」（用户触发，POST comment + PATCH close）；
  - 任务关联索引落地 `.dsh/tasks/`（index.json 随仓库提交，local.json 本机 session 映射），重启可恢复；
  - 共享核心：`core/lib/issues.js`（issues/PR/comment-close/remote 检测）、`core/lib/jobqueue.js`（串行队列）、`core/lib/tasks.js`（关联索引）；
  - skill：`.dsh/skills/issue-fix/SKILL.md`。
- **Wiki 自动提交**：更新完成后由代理（repo-wiki skill 规则 8）`git add .dsh/wiki` + commit（不 push，message 概括实际变更）；面板 `WikiAutoCommit` 兜底。

### Changed

- 版本单一来源：`scripts/version.sh` fallback 推进到 1.9.0（发布后立即推进开发线版本，避免与已发布版本混淆）。

### Fixed

- IssueRunner：仓库识别兜底（workspace.list 解析）、gitBranchPushed 按 remote 名解析、恢复任务标题/正文显示、行内详情滚动与按钮固定。

## [1.8.0] - 2026-08-15

### Added

- 里程碑 M1（产品化基础，P1）全部交付（详见本里程碑文档 `docs/milestones/M1-productization-foundation.md`）：
  - 开源就绪：MIT LICENSE、CONTRIBUTING.md、SECURITY.md、CHANGELOG.md、CODEOWNERS、AGENTS.md、Issue 模板（bug/feature）；
  - CI：`.github/workflows/ci.yml`（macOS arm64/x64/Universal 矩阵 + 单测 + swiftc 编译检查 + `.cache/` 缓存）、`nightly.yml`、dependabot；
  - 发布：`.github/workflows/release.yml`（tag 触发 → 构建 → `.dmg`/`.pkg` + SHA-256SUMS → GitHub Release）；
  - 版本单一来源：`build-app.sh` 的 VERSION/BUILD 由 git tag / CI 运行号驱动（`scripts/version.sh`）；
  - 共享核心 `core/`（Node 模块）：ANSI 模拟器（42 用例全绿）/ 端口与服务管理 / 升级 / 会话 RPC 从 Swift 抽出，`core/bin/ohmy-core.js` CLI；
  - 设置窗口（语言 / registry / 升级 / 主题 / 快捷键，⌘, 打开）与首次引导（onboarding）；
  - 平台骨架 `platforms/macos/` 迁移（src/ + build-app.sh + make-pkg.sh，git mv 保留历史）。

### Changed

- `build-app.sh` 支持 `DSH_ARCH=arm64|x86_64|universal` 交叉构建（swiftc `-target` + universal lipo）。

### Fixed

- 构建脚本 `TMPDIR` 在清理 `.build` 后未重建导致 swiftc 失败的隐患。

## [1.7.1] - 2026-08-15

### Added

- Repo Wiki 知识库面板：生成/维护/浏览 + 多工作区跟随（`feat(wiki)`）；
- `docs/productization.md` 产品化方案与里程碑目标文档；
- 知识库增量更新流程与 `.dsh/wiki/` 结构。

### Fixed

- 终端多字节输入乱码（`docs/terminal-input-fix.md`：`Darwin.write` 传数组缓冲区必须用
  `withUnsafeBytes`）；
- 终端/Wiki 面板 header 合成溢出（`docs/terminal-header-fix.md`：父容器 `wantsLayer` +
  `masksToBounds`）。

## [1.6.28] - 2026-08-14

### Added

- 原生 macOS 壳首个可分发版本（`b4bceba`）：自包含运行时（内置 Node + dsh）、
  端口探测/复用/自拉起、预览面板、集成终端面板（PTY + ANSI 模拟器）、中英双语、
  dsh 手动/自动升级、registry 配置、退出清理。

---

[Keep a Changelog]: https://keepachangelog.com/en/1.1.0/
[Semantic Versioning]: https://semver.org/spec/v2.0.0.html
