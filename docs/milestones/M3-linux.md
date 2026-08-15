# 里程碑 M3 · Linux 版（P3）

> 状态：📋 待启动（依赖 M1，复用 M2 共享核心经验）
> 周期：≈1–2 个月（单人维护口径）
> 来源：`docs/productization.md` —— §2 P3、§7.1、§8.4、§9（9.1 / 9.4 / 9.5）、§11.3、§14 M3
> 更新：2026-08-15

## 目标

覆盖开发者主力发行版：原生 Linux 壳（GTK4 + WebKitGTK），复用共享核心，首个**三平台统一版本** v2.0.0。

## 验收标准（全部达成即里程碑完成）

- [ ] Ubuntu 22.04 / 24.04 与 Fedora 上「安装 → 运行 → 升级」全流程通过
- [ ] GTK4 + WebKitGTK 壳可运行 dsh web；端口探测 / 拉起 / 清理与 macOS 行为一致（复用 core）
- [ ] 终端面板（forkpty + core 模拟器）与预览面板可用；双语（中 / 英）
- [ ] `.deb` / `.rpm` / AppImage（或 Flatpak）分发；升级机制（AppImage 增量 / Flatpak 自动 / 自研校验）闭环
- [ ] CI `ubuntu-24.04` 产出 Linux 产物；兼容矩阵（Ubuntu 22.04 / 24.04、Fedora、Arch）建立
- [ ] 与 macOS / Windows 同 tag 发布 v2.0.0（Linux 无签名，发布 SHA-256SUMS）

## 范围与交付物

| 类别 | 交付物 | 参考 |
|---|---|---|
| 平台骨架 | `platforms/linux/`（源码 + 构建脚本 + README） | §4.5 |
| 壳 | GTK4 + WebKitGTK（Rust 建议，或 C） | §9.4 |
| 共享核心 | 消费 `core/`（Node 模块建议） | §9.5 |
| 功能 | 终端（forkpty）、预览、设置窗口、双语 | §3.1 / §3.3 / §3.4 |
| 打包 | `.deb` / `.rpm` / AppImage（或 Flatpak） | §7.1 |
| 升级 | AppImage 增量 / Flatpak 自动 / 自研校验更新 | §8.4 |
| CI / QA | ubuntu-24.04 矩阵、容器/VM 冒烟、兼容矩阵 | §5.2 / §11.3 |

## 现状基线

- M1 完成后：`core/` 就绪；M2 复用后共享核心更稳
- 上游 dsh 已内置 Linux 支持（`dsh-terminal-bash`）；`dsh web` 为纯 Web UI → 只需实现壳层
- WebKitGTK 2.40+ 提供 GTK4 支持（实施前核实发行版打包版本）

## 实施步骤（任务分解）

1. **选型决策**（0.5 天）：语言（Rust gtk4-rs + webkit2gtk-rs vs C）；升级方案；与 core 载体确认
2. **平台骨架**（1 天）：platforms/linux/ + 构建脚本 + .gitignore 条目
3. **壳 MVP**（1–2 周）：GTK4 窗口 + WebKitWebView 加载 dsh web；端口探测 / 拉起 / 清理（调 core）
4. **终端面板**（2 周）：forkpty / posix_spawn + core 模拟器渲染 + 多标签
5. **预览面板移植**（1–2 周）
6. **设置窗口 + 双语**（1 周）
7. **打包**（1 周）：deb（debuild）/ rpm（rpmbuild）/ AppImage（appimagetool）
8. **自动升级**（1 周）：AppImage 增量更新 / Flatpak / 自研校验和更新
9. **CI Linux 矩阵 + 冒烟 + 兼容矩阵**（1 周）
10. **统一发布 v2.0.0**（0.5 天）：三平台同 tag

## 依赖与前置

- M1：`core/`、CI 基础；M2 完成后共享核心已在两个平台验证
- 无签名要求（Linux 无强制签名），但必须发布 SHA-256SUMS
- **决策点**（实施前定夺）：语言、升级方案、core 载体（§9.5）

## 风险与注意点

| 风险 | 缓解 |
|---|---|
| GTK IM（终端中文输入） | §3.1 已知限制延续，粘贴兜底 |
| WebKitGTK 版本碎片化（发行版打包差异） | 兼容矩阵覆盖主流发行版；AppImage 自带运行时 |
| deb / rpm 打包规则差异 | 分别用 debuild / rpmbuild，CI 内验证 |
| 无人值守升级（无系统级更新框架） | 自研校验和更新 + 文档引导 |

## 测试与验收

- CI 全绿 + 干净 Ubuntu / Fedora 容器或 VM 冒烟（安装 → 运行 → 升级）
- 与 macOS / Windows 同 tag 发布；对照 §11.2 清单（Linux 侧跳过签名 / 公证项）
- 完成标志：本文件「验收标准」全勾选 + productization.md §2 P3 退出标准达成

## 关联文档

- `docs/productization.md`：§2 P3、§7.1、§8.4、§9、§11.3
- `docs/milestones/M1-productization-foundation.md`（core/ 契约与骨架）
- 上游：`@deepseek-ai/dsh`（dsh-terminal-bash / dsh web）
