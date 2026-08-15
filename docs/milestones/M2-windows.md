# 里程碑 M2 · Windows 版（P2）

> 状态：📋 待启动（依赖 M1）
> 周期：≈2–3 个月（单人维护口径，MVP 裁剪）
> 来源：`docs/productization.md` —— §2 P2、§7、§8.4、§9（9.1 / 9.3 / 9.5 / 9.6）、§11.3、§14 M2
> 更新：2026-08-15

## 目标

覆盖最大桌面用户群：原生 Windows 壳（WinUI 3 + WebView2），复用 M1 共享核心，与 macOS **统一版本号**（v1.9.0）发布。

## 验收标准（全部达成即里程碑完成）

- [ ] Windows 10/11 x64 上「安装 → 运行 → 升级 → 卸载」全流程通过
- [ ] 壳可启动 dsh web；端口探测 / 拉起 / 清理与 macOS 行为一致（复用 core）
- [ ] 终端面板（ConPTY + core 模拟器）与预览面板可用；双语（中 / 英）
- [ ] MSI / Inno 安装包；自动升级（Squirrel.Windows 或自研）闭环
- [ ] CI `windows-2022` 产出 Windows 产物；兼容矩阵（Win10 22H2 / Win11 x64）建立
- [ ] 与 macOS 同 tag 发布（v1.9.0），产物含 SHA-256SUMS

## 范围与交付物

| 类别 | 交付物 | 参考 |
|---|---|---|
| 平台骨架 | `platforms/windows/`（源码 + 构建脚本 + README） | §4.5 |
| 壳 | WinUI 3 + WebView2（C#/.NET 建议，待定夺） | §9.3 |
| 共享核心 | 消费 `core/`（Node 模块建议） | §9.5 |
| 功能 | 终端（ConPTY）、预览、设置窗口、双语 | §3.1 / §3.3 / §3.4 |
| 打包 | MSI / Inno Setup；winget 清单（M4 上架用，可后置） | §7.1 |
| 升级 | Squirrel.Windows 或自研（下载 → 校验 → 替换） | §8.4 |
| CI / QA | windows-2022 矩阵、干净 VM 冒烟、兼容矩阵 | §5.2 / §11.3 |

## 现状基线

- M1 完成后：`core/` 就绪、macOS 壳改调 core、CI / release 流程可用
- 上游 dsh 已内置 Windows 支持（`dsh-pwsh-local`）；`dsh web` 为纯 Web UI → 只需实现壳层

## 实施步骤（任务分解）

1. **选型决策**（0.5 天）：语言（C#/.NET 8 vs C++/WinRT）；升级方案（Squirrel.Windows vs 自研）；与 core 载体（Node）确认
2. **平台骨架**（1 天）：platforms/windows/ + 构建脚本 + .gitignore 条目
3. **壳 MVP**（1–2 周）：WinUI 3 窗口 + WebView2 加载 dsh web；端口探测 / 拉起 / 清理（调 core）
4. **终端面板**（2–3 周）：ConPTY + core 模拟器渲染 + 多标签
5. **预览面板移植**（1–2 周）
6. **设置窗口 + 双语**（1 周）
7. **打包**（1 周）：MSI / Inno Setup
8. **自动升级**（1–2 周）：Squirrel.Windows 或自研
9. **CI Windows 矩阵 + 冒烟 + 兼容矩阵**（1 周）
10. **统一发布 v1.9.0**（0.5 天）：与 macOS 同 tag

## 依赖与前置

- M1：`core/`、CI 基础、release 流程
- Windows Authenticode 证书（可选：暂缓期可自签，SmartScreen 提示 + 文档引导；winget 正式上架在 M4）
- **决策点**（实施前定夺）：语言、升级方案、core 载体（§9.5）

## 风险与注意点

| 风险 | 缓解 |
|---|---|
| ConPTY 与 forkpty 行为差异 | 模拟器共享 + 适配层隔离（§9.6） |
| WebView2（Chromium）与 WebKit 渲染差异 | 兼容矩阵 + 冒烟 |
| Windows 终端中文输入（IME） | §3.1 已知限制延续，先 ⌘/Ctrl+V 粘贴兜底 |
| 单人负载（本里程碑投入最大） | MVP 裁剪：先壳 + 终端，预览后置 |

## 测试与验收

- CI 全绿 + 干净 Windows 10/11 VM 冒烟（安装 → 升级 → 卸载）
- 与 macOS 产物同 tag 发布；对照 §11.2 清单（Windows 侧无公证要求）
- 完成标志：本文件「验收标准」全勾选 + productization.md §2 P2 退出标准达成

## 关联文档

- `docs/productization.md`：§2 P2、§7、§8.4、§9、§11.3
- `docs/milestones/M1-productization-foundation.md`（core/ 契约与骨架）
- 上游：`@deepseek-ai/dsh`（dsh-pwsh-local / dsh web）
