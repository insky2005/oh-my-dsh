# 📚 文档索引

oh-my-dsh 的设计、调研、排查与流程文档，按 **开发环节** 分目录存放。
安装 / 构建 / 使用请看仓库根目录的 [README](../README.md)；代理工作指引见 [AGENTS.md](../AGENTS.md)。

## 常用入口

- [右栏面板详细说明](usage/panels.md) — 十个原生面板的功能、边界与截图
- [产品化总纲](research/productization.md) — 路线图 / 分发 / 升级 / 多平台 / 开源治理
- [dsh 升级影响清单](process/dsh-version-impact.md) — 五个耦合面 + 每次升级的执行 SOP
- [发布流程](process/release-process.md) · [分支与提交规范](process/git-workflow.md)
- [CHANGELOG](../CHANGELOG.md) · [CONTRIBUTING](../CONTRIBUTING.md) · [SECURITY](../SECURITY.md)

## research/ — 调研 · 选型 · 策略

- [productization.md](research/productization.md) — 产品化总纲：P0 现状 → P1 开源/CI → P2 Windows → P3 Linux → P4 生态增长
- [ai-native-workflow-architecture.md](research/ai-native-workflow-architecture.md) — AI 原生研发工作流的**产品能力架构与目标**：需求池 → 拆解 → 事项的两层状态图 / 并行条件 / 载体与角色分工 / 工具缺口（草案）
- 在途草案（尚未提交，暂不建链）：`agent-driver-research.md`（统一驱动 AI coding agent 的接口选型调研）、`agent-driver-protocols.md`（协议对比勘误稿，ACP 为准）、`agent-enterprise-research.md`（企业能力可复用开源方案调研）、`multi-agent-host-design.md`（多 Agent 宿主 + 企业治理架构提案草案）

## design/shell/ — 壳层共性设计

- [session-snapshot-rollback-design.md](design/shell/session-snapshot-rollback-design.md) — 会话快照与回退：触发时机、隔离区、事务与边界
- [storage-layout-refactor.md](design/shell/storage-layout-refactor.md) — 壳层工作数据收敛到 `$DSH_HOME/oh-my-dsh/`
- [ui-color-scheme.md](design/shell/ui-color-scheme.md) — 面板配色令牌与取色 API（单一事实来源 `PanelSurface.swift`）

## design/panels/ — 面板设计

- [projects-panel-design.md](design/panels/projects-panel-design.md) — 项目面板：工作区注册、当前目录单一真相
- [repo-wiki-design.md](design/panels/repo-wiki-design.md) — Repo Wiki 知识库面板
- [review-panel-design.md](design/panels/review-panel-design.md) — 审查面板：只读会话日志审计
- [issue-runner-design.md](design/panels/issue-runner-design.md) — 任务面板（IssueRunner）
- [tasks-queue-session-loop-design.md](design/panels/tasks-queue-session-loop-design.md) — 任务队列 × 会话回传
- [skills-manager-design.md](design/panels/skills-manager-design.md) — 技能面板：四档级别、registry 与调用开关
- [builtin-skills-design.md](design/panels/builtin-skills-design.md) — 内置 Skill 全局化 + 重命名
- [task-todo-skill-design.md](design/panels/task-todo-skill-design.md) — `task-todo` 技能与 `/api/tasks/*` 契约
- [multi-repo-workspace-design.md](design/panels/multi-repo-workspace-design.md) — 多仓库工作区：根目录非 git 时的仓库集合识别与 git 工作流（草案）
- [task-completion-verification-design.md](design/panels/task-completion-verification-design.md) — 任务完成校验：会话结束≠任务完成，marker + 待确认（草案）
- [workstream-handoff-prompt-design.md](design/panels/workstream-handoff-prompt-design.md) — 事项交接提示词：指针 + (stage, action) + 模型规则，供面板生成（草案）
- [requirements-workstream-store-design.md](design/panels/requirements-workstream-store-design.md) — 需求 / 事项 / 回归门卡片 schema、committed/ignored 分界与写入所有权反转（草案）
- [requirements-pool-panel-design.md](design/panels/requirements-pool-panel-design.md) — 需求池面板（含想法收件箱与拆解器）：REQ/WS 读写、拆解提案与人工确认、`/api/requirements/*`（已实现）
- [planning-template-design.md](design/panels/planning-template-design.md) — 规划模板（四件套）与「无证据不进设计」门禁判据（草案）
- [file-panel-composer-reference.md](design/panels/file-panel-composer-reference.md) — 文件面板「添加到对话」`@` 引用

## design/channels/ — 通道设计

- [channel-design.md](design/channels/channel-design.md) — 通道统一抽象：适配器 / 状态机 / 路由 / 配置模型
- [channel-association-model.md](design/channels/channel-association-model.md) — Channel–Message–Session 关联模型
- [channel-commands.md](design/channels/channel-commands.md) — 已实现指令清单（改动须同步维护）
- [channel-ui-commands.md](design/channels/channel-ui-commands.md) — 面板 UI 与指令设计
- [channel-status.md](design/channels/channel-status.md) — 面板 + core 完成状态总览
- [channel-storage.md](design/channels/channel-storage.md) — 消息 / 会话存储全局化
- [channel-project-switch.md](design/channels/channel-project-switch.md) — 「项目开关」与未启用门控
- [channel-dingtalk-stream.md](design/channels/channel-dingtalk-stream.md) — 钉钉 dingtalk-stream 原生适配器
- [channel-web-session-link.md](design/channels/channel-web-session-link.md) — 通道面板与 dsh web 会话双向联动

## fixes/ — 排查与修复

- [terminal-header-fix.md](fixes/terminal-header-fix.md) — 终端 header / 半高显示的 layer-backed 合成问题
- [terminal-input-fix.md](fixes/terminal-input-fix.md) — 终端粘贴乱码 & 方向键失效
- [devtools-drag-fix.md](fixes/devtools-drag-fix.md) — DevTools 拖动条导致 CEF 视图上移
- [browser-blank-panel-fix.md](fixes/browser-blank-panel-fix.md) — 浏览器面板内容区空白 + 右键菜单错位
- [channel-issues.md](fixes/channel-issues.md) — Channel 消息重复回复排查记录

## process/ — 流程 · 发布 · 升级

- [git-workflow.md](process/git-workflow.md) — 分支与提交规范（main 只合并 / 只打主版本 tag）
- [release-process.md](process/release-process.md) — 发布流程（CHANGELOG → tag → local-release → 版本推进）
- [dsh-version-impact.md](process/dsh-version-impact.md) — dsh 升级影响清单（五耦合面 + 执行 SOP + 复盘）

## feedback/ — 使用反馈

- [ux-feedback.md](feedback/ux-feedback.md) — 日常使用问题与改进点，逐条跟踪到实现与验收

## plans/ — 实施计划

- [BROWSER_PLAN-browser-panel.md](plans/BROWSER_PLAN-browser-panel.md) — 浏览器面板设计
- [PREVIEW_PLAN-file-panel.md](plans/PREVIEW_PLAN-file-panel.md) — 文件面板预览 / 编辑
- [TERMINAL_PLAN-terminal-panel.md](plans/TERMINAL_PLAN-terminal-panel.md) — 终端面板
- [APP_SLIM-app-size.md](plans/APP_SLIM-app-size.md) — App 体积精简
- [dsh-012rc1-compat-audit.md](plans/dsh-012rc1-compat-audit.md) · [dsh-015rc2-compat-audit.md](plans/dsh-015rc2-compat-audit.md) · [dsh-017rc2-compat-audit.md](plans/dsh-017rc2-compat-audit.md) — dsh 兼容审计

## milestones/ — 里程碑

- [M1-productization-foundation.md](milestones/M1-productization-foundation.md)（产品化基础）
- [M2-windows.md](milestones/M2-windows.md) · [M3-linux.md](milestones/M3-linux.md)
- [M4-ecosystem-growth.md](milestones/M4-ecosystem-growth.md) · [M5-apple-ecosystem.md](milestones/M5-apple-ecosystem.md)

## usage/ — 使用说明

- [panels.md](usage/panels.md) — 右栏十个面板的完整说明
- [ai-native-workflow-manual.md](usage/ai-native-workflow-manual.md) — 手动模式闭环：需求 → 拆解 → 事项，配合任务面板的提示词与操作

## raw/ — 素材

- [RAW_APPEARANCE.md](raw/RAW_APPEARANCE.md) — 外观相关原始素材

## screenshots/ — 截图

- 文档配图（README 与 `usage/panels.md` 引用）

> 新增文档请按开发环节放入对应目录，并在此索引登记；使用说明类归入 `usage/`，面板设计类归入 `design/panels/`。
