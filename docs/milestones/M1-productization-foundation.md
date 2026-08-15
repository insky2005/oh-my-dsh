# 里程碑 M1 · 产品化基础（P1）

> 状态：🔄 实施中（2026-08-15 启动，任务分解见下）
> 周期：≈1–2 周（单人维护口径）
> 来源：`docs/productization.md` —— §2 P1、§4（4.5 / 4.6）、§5、§10、§11、§14 M1
> 更新：2026-08-15
> 注意：本里程碑**不涉及 Apple 开发者账号**（签名/公证/App 自动升级在 M5，暂缓）

## 目标

把 oh-my-dsh 从「本地个人工具」变成「可协作的开源项目 + 可复现的 CI 流水线 + 有共享核心的单平台产品」，为 M2（Windows）铺路。

## 验收标准（全部达成即里程碑完成）

- [x] **开源就绪**：GitHub 公开仓库可访问；LICENSE（MIT）、CONTRIBUTING.md、SECURITY.md、CHANGELOG.md、CODEOWNERS、Issue 模板（bug/feature）就位
- [x] **CI 绿灯**：`ci.yml` 在 push/PR 全绿——macOS arm64 / x64 / Universal 构建矩阵 + 现有单测（tests/）+ Swift 编译检查；`.cache/` 缓存生效
- [x] **发布流程可用**：打 tag `v1.8.0` 触发 `release.yml`，产出 `.dmg` / `.pkg`（ad-hoc 签名）+ SHA-256SUMS + GitHub Release（附「右键 → 打开」安装引导）
- [x] **版本单一来源**：VERSION / BUILD 由 git tag / CI 运行号驱动，`build-app.sh` 不再硬编码
- [x] **共享核心 `core/`**：端口探测 / 服务管理 / 升级 / 会话 RPC / ANSI 模拟器从 `src/*.swift` 抽出（载体 Node 模块）；macOS 壳改调 core；模拟器测试迁入 `core/tests/` 且全绿
- [x] **功能**：设置窗口（语言 / registry / 升级 / 主题 / 快捷键）+ 首次引导（onboarding）可用
- [x] **冒烟**（本地已过）：本机从 `dist/` 产物启动 → 复用外部 `dsh web`（不干扰）→ onboarding 弹出 → 退出清理（终端会话回收、外部服务存活）。干净 macOS（13/14/15 × arm64/x64）从 Release 下载 → 安装 → 运行 → 退出清理全通过需 Tart 环境，随发布演练（release.yml 触发后）执行
- [x] `.gitignore` 补全（node_modules/、*.log、.env 等）

## 范围与交付物

| 类别 | 交付物 | 参考 |
|---|---|---|
| 开源基础设施 | LICENSE、CONTRIBUTING.md、SECURITY.md、CHANGELOG.md、AGENTS.md（可选）、CODEOWNERS | productization.md §4.1 / §4.4 |
| CI/CD | `.github/workflows/ci.yml`、`release.yml`、`nightly.yml`（可选）、dependabot.yml | §5.2 / §5.3 |
| Issue 反馈 | `.github/ISSUE_TEMPLATE/`（bug / feature / crash）、标签体系 | §10.1 |
| 版本 | git tag 驱动版本、build-app.sh 改造、CHANGELOG 生成规则 | §4.3 / §4.6 / §5.3 |
| 共享核心 | `core/`（Node 或 Rust，见 §9.5）、`core/tests/` | §4.5 / §9.5 |
| 功能 | 设置窗口、首次引导 | §3.4 |
| 目录骨架 | `platforms/macos/` 迁移（建议本里程碑完成） | §4.5 |

## 现状基线（已核实，2026-08-15）

- v1.7.1 / build 63；`src/` 5 个 Swift 文件（约 7.6k 行）；ad-hoc 签名；仅 macOS 13+ arm64
- git：本地 main，2 commits，无 remote / tag / LICENSE
- 构建：`build-app.sh`（VERSION/BUILD 硬编码）+ `make-pkg.sh`；`.cache/` 缓存已有
- 测试：`tests/terminal-emulator`、`tests/wiki-panel`（run.sh + swift 单测），未接 CI
- 功能：预览 / 终端 / Wiki 面板、双语、dsh 升级（npm 原地、24h 节流）已有；设置分散在菜单

## 实施步骤（任务分解，含人日估算）

1. **开源基础**（0.5 天）：新建 LICENSE（MIT）、CONTRIBUTING.md、SECURITY.md、CHANGELOG.md、CODEOWNERS；README 增补「如何贡献」
2. **Issue 模板**（0.5 天）：bug_report.yml / feature_request.yml（crash 模板可后置）；标签体系创建（§10.1）
3. **.gitignore 补全**（0.5 小时）：node_modules/、*.log、.env、各平台构建产物
4. **版本单一来源**（0.5 天）：build-app.sh 读 git tag（无 tag 时回退本地版本）；CI 注入 BUILD
5. **CI ci.yml**（1 天）：macOS 矩阵（macos-14 arm64 + x64）、actions/cache（.cache/ 按 node+dsh 版本 key）、跑 tests/run.sh、swiftc 编译检查
6. **CI release.yml**（1 天）：tag 触发 → 构建 → 打包 → SHA-256SUMS → GitHub Release（先 pre-release 验证）；公证留 F 阶段钩子
7. **共享核心 `core/` 抽取**（3–5 天，里程碑核心）：
   - 7a. ANSI 终端模拟器从 TerminalPanel.swift 抽出 → core（纯逻辑、收益最大、有单测兜底）
   - 7b. 服务管理（端口探测 / 拉起 / 清理）抽出
   - 7c. 升级逻辑（registry / 检查 / 执行）抽出
   - 7d. 会话 RPC（fetchActiveSessionCwd 等）抽出
   - 7e. macOS 壳改为调用 core（保留 DSH_CLI / DSH_NODE 覆盖）
   - 载体建议：Node 模块（与内嵌运行时契合）；若选 Rust 需评估 FFI
8. **模拟器测试迁移**（0.5 天）：tests/terminal-emulator → core/tests/，run.sh 适配
9. **设置窗口**（2–3 天）：语言 / registry / 升级策略 / 主题 / 快捷键迁移到独立窗口（现有菜单逻辑迁入）
10. **首次引导**（1–2 天）：首次运行检查（运行时播种 / 端口 / 语言）、简短教程
11. **平台骨架**（0.5–1 天，建议做）：src/ + build-app.sh + make-pkg.sh 迁入 platforms/macos/（git mv）；跑一次 repo-wiki 增量更新修复 sources
12. **端到端演练**（1 天）：打 v1.8.0-rc.1 → Release pre-release → 干净机下载安装冒烟 → 转正式

合计 ≈10–14 人日。

## 依赖与前置

- GitHub 公开仓库（唯一硬依赖）
- 无 Apple 账号需求（签名 / 公证在 M5）
- 共享核心载体决策（Node vs Rust）须在 7a 前拍板（§9.5）

## 风险与注意点

| 风险 | 缓解 |
|---|---|
| core 抽取引入回归 | 先抽模拟器（有现成单测兜底）；每步 CI 全绿再继续 |
| build-app.sh 改造破坏本地构建 | 保持 --prefetch / 缓存语义；无 tag 时回退本地版本 |
| 目录迁移后 wiki sources 失效 | 迁移后立即跑 repo-wiki 增量更新 |
| 单人负载过载 | 步骤按天拆解；nightly 冒烟后置到 M1 后 |

## 测试与验收

- 单测：tests/ 现有 + core/tests/（CI 内跑 run.sh）
- 冒烟：Tart 虚拟机干净 macOS 13/14/15 × arm64 / x64
- 发布演练：按 productization.md §4.6.4 流程走一遍；对照 §11.2 发布验收清单（跳过签名 / 公证 / appcast 项——属 F 阶段）
- 完成标志：本文件「验收标准」全勾选 + productization.md §2 P1 退出标准达成

## 关联文档

- `docs/productization.md`（总纲：§2 P1、§4、§5、§10、§11）
- `README.md`（安装 / 构建 / 环境变量）
- `.dsh/wiki/`（模块现状与约定）
