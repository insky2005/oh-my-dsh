# 里程碑 M4 · 生态与增长（P4）

> 状态：📋 待启动（依赖 M1–M3 产品稳定）
> 周期：持续
> 来源：`docs/productization.md` —— §2 P4、§3（功能路线图 backlog）、§7.2 / §7.3、§10.3 / §10.4、§14 M4
> 更新：2026-08-15

## 目标

从「能用的工具」到「有社区的生态」：渠道上架、国内镜像、文档站、指标闭环、社区运营，并持续交付功能路线图 P2/P3 项。

## 验收标准（持续达成）

- [ ] **渠道**：winget 上架（Windows）；国内镜像（OSS/CDN + Gitee 兜底）同步产物与 appcast
- [ ] **文档站**：GitHub Pages（下载 / FAQ / 上手教程 / 隐私说明）上线
- [ ] **指标闭环**：下载 / 崩溃 / opt-in 使用统计（Sentry，默认关闭）定期回顾
- [ ] **社区**：Discussions 运营；≥2 个外部贡献者合入 PR
- [ ] **功能 backlog**：§3 功能路线图 P2/P3 项转 issue 并持续交付

## 范围与交付物

| 类别 | 交付物 | 参考 |
|---|---|---|
| 渠道 | winget 清单；国内 OSS/CDN 镜像（产物 + appcast）+ Gitee Releases 兜底 | §7.1 / §7.2 |
| 文档 | GitHub Pages 文档站（下载 / FAQ / 上手 / 隐私说明） | §7.3 |
| 指标 | Sentry opt-in（macOS / Windows / Linux SDK）+ 隐私说明页 | §10.4 |
| 社区 | Discussions 开通与运营规范、good first issue 引导 | §10.3 |
| 功能 | §3.5–§3.7 项（dsh 深度集成 / 协作生态）按优先级推进 | §3 |

## 现状基线

- M1–M3 完成后：三平台产品稳定、CI / release 流程可用
- 已知限制 backlog：终端 IME / 会话持久化、Wiki 语义检索、预览 Office 等（§3 各表）

## 实施步骤（任务分解）

1. **winget 上架**（0.5–1 天）：提交 winget-pkgs 清单 PR（需 MSI/Appx 与版本元数据）
2. **国内镜像**（1–2 天）：OSS/COS bucket + CI 同步步骤（产物 + appcast + 校验和）；Gitee Releases 兜底脚本
3. **文档站**（2–3 天）：GitHub Pages 单页 → 多页（下载 / FAQ / 上手教程 / 隐私说明 / 兼容矩阵）
4. **Sentry opt-in**（2–3 天）：三平台 SDK 接入 + 首次启动征求同意（默认关）+ 隐私说明页
5. **Discussions 与治理**（0.5 天）：开通 Discussions、运营规范、good first issue 标签常态化
6. **功能 backlog 管理**（持续）：§3 表转 GitHub issues（按优先级排序、里程碑关联），每迭代交付 1–2 项
7. **定期回顾**（每发布周期）：下载 / 崩溃 / issue 响应 / 发布节奏（§4.6）回顾并调整

## 依赖与前置

- M1–M3：产品与流程稳定
- 指标依赖 Sentry 接入；winget 上架依赖 Windows 安装包成熟
- Apple 侧渠道（Homebrew Cask）不在本里程碑——属 M5（暂缓）

## 风险与注意点

| 风险 | 缓解 |
|---|---|
| 单人维护瓶颈 | 社区化：good first issue、贡献指南、PR 响应 SLA |
| 国内镜像与主渠道版本不一致 | CI 同步步骤 + 校验和比对 + 发布后人工确认 |
| 遥测引发隐私疑虑 | 默认关闭 + 最小化字段 + 隐私说明公示（§12.2） |
| 功能 backlog 失控 | 按 §3 优先级表排序，每迭代小步交付 |

## 测试与验收

- 镜像产物与 GitHub Releases 校验和一致（自动化比对）
- 文档站链接与 FAQ 覆盖常见 issue 类型
- Sentry 上报仅含版本 / 平台 / 崩溃栈（不含对话与 `~/.dsh` 数据）
- 完成标志：本文件「验收标准」全勾选 + productization.md §2 P4 退出标准达成

## 关联文档

- `docs/productization.md`：§2 P4、§3、§7、§10、§12
- `docs/milestones/M1-productization-foundation.md`（CI / release 基础）
