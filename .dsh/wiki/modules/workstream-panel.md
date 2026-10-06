---
title: 模块：Workstreams*（事项面板）
tags: [module, workstreams, panel, ai-native-workflow, stage-gate]
updated: 2026-10-06T00:00:00Z
sources: [platforms/macos/src/WorkstreamsCore.swift, platforms/macos/src/WorkstreamsUI.swift, platforms/macos/src/WorkstreamsAPI.swift, platforms/macos/src/WorkstreamsPanel.swift, platforms/macos/src/WorkstreamsQueues.swift, platforms/macos/src/WorkstreamsRunner.swift, platforms/macos/src/WorkstreamsPrompts.swift, platforms/macos/src/WorkstreamsStageGate.swift, platforms/macos/src/WorkstreamsDelivery.swift, platforms/macos/src/WSCardView.swift, platforms/macos/src/WSInlineForms.swift, platforms/macos/src/main.swift, tests/workstreams-panel/, docs/design/panels/workstream-panel-design.md, docs/design/panels/requirements-workstream-store-design.md, docs/design/panels/workstream-handoff-prompt-design.md, docs/usage/panels.md, .dsh/skills/workstream-panel/SKILL.md]
manual: false
---

# 模块：Workstreams*（事项面板）

事项面板是右栏**第 11 个原生面板**（活动栏第 6 位、`⌥⌘K`、图标 `square.stack.3d.up`），是当前工作区的事项（Workstream）中心。按设计 A1/A6/A10 **clean-room** 实现——不复用任务面板代码，队列 / 交付 / 视图基件都是自有 `WS*` 文件，配色只用 `PanelSurface` / `PanelControl`（无新令牌）。设计与用户说明见 `docs/design/panels/workstream-panel-design.md`、`docs/usage/panels.md`。

## 三级卡片与视图

- 一级 **事项主卡**：`WS-*.md` 一张卡，展开是五张阶段卡；
- 二级 **阶段卡**：规划 / 设计 / 执行 / 验收 / 交付**永远各一张、固定顺序**，`WS.queues [q-...]`（一事项一队列，0..1）挂在主卡当前阶段（旧卡 `[{id, stage}]` 只取 id，阶段丢弃），验收段显示 `covered`（paths / base / head）、交付段显示 `pr / outcome / url`；
- 三级 **任务卡**：该事项队列内的条目，按任务自带 `stage` 归到对应阶段卡；显示状态徽标与 dsh **会话**（运行态随 3s 定时器自动刷新）；
- 顶部**扁平页签** `全部 / 规划 / 设计 / 执行 / 验收 / 交付`（`WSStageFilter`），空态三态（无工作区 / 池空 / 筛选无命中）。

纯视图模型在 `WorkstreamsUI.swift`（Foundation-only），UI 在 `WorkstreamsPanel.swift`（`WorkstreamsPanelController` + `WSBoardRootView`）；从任务面板复制并重命名的自有基件 `WSCardView.swift`（`WSInk` / `WSBadgeView` / `WSCardView` …）与 `WSInlineForms.swift`。

## 模型与 API

- `WorkstreamsCore.swift`：`WS-*.md` frontmatter 解析（自写缩进式 YAML 子集，剥离行内注释）、固定键序序列化、**原子写**、`create/update/setStage/setQueues/setCovered/setDelivery`、**六位零填充 id** `WS-%06d`、`validate()`（含 `covered` 必填等），错误码 `evidence-missing` / `stage-changed` / `missing-reason`（前两者 409）；
- `WorkstreamsAPI.swift`：纯路由 `/api/workstreams/*`——`list` / `create` / `update` / `stage` / `plan` / `queues` + 人工门 `stage/confirm`、`stage/reject`，外加 **`task/list` / `task/create` / `queue/start` / `queue/pause`**（A14；`task/create` 支持 `titles[]` 或仅 `body`，按阶段默认动作注入交接提示词；`queue/start` 带 `stage` = 阶段级启动）；错误码 / status 对齐 `/api/requirements/*`，由 `BrowserAPI` 前缀拦截并桥接到主线程（`WorkstreamsAPIDelegate`，面板是唯一写者）；
- 写权反转（Phase B，D5b）：面板是 `WS-*.md` 唯一写者，agent 经 API 改事项、不直接改 `.dsh`；配套内置技能 `workstream-panel`（见 [skill-installer](skill-installer.md)）。

## 阶段队列引擎与阶段门

- `WorkstreamsQueues.swift`：事项面板**自有**队列 / 三级任务模型 + 存储（`WSTaskItem` / `WSQueue` / `WSBoard` / `WSStore`），队列落 `.dsh/workstreams/queues.json`、会话 / 汇报落 `local.json`（**ignored**）；**绝不读写 `.dsh/tasks/*`**；
- `WorkstreamsRunner.swift`：按 A10 复制任务面板的串行相位机（idle / starting / active / finishing），「建会话 → 命名 `WS: ` → prompt → 轮询 → 取消 / 重试」，重启恢复（running→interrupted、active→paused、不自动起跑）；`createStageQueue` / `appendStageTasks` 追加到该事项**唯一**队列（没有才建）、任务带 `workstreamId` + `stage`；`startWorkstream(_:stage:)` = 事项级 / 阶段级启动（A3 / A9 / D18，阶段级用 `stageFilter` 只跑该阶段、跑完暂停队列）；`WSPrompts` 委托 `WorkstreamsPrompts`；
- `WorkstreamsPrompts.swift`：`WSStageAction`（五阶段六个动作）+ `WorkstreamHandoff` 提示词生成器（公共头 / 动作段 / 模型规则 / 回归门行）；`injectingCompletionMarker` 统一注入完成 marker；
- `WorkstreamsStageGate.swift`：五阶段**机检证据谓词 + 人工确认门**（R10）——规划四件套、设计文档 + Q 关闭、执行队列 `.done` 且任务有证据、验收 `covered`、交付 PR + outcome；`.done` + 谓词通过 → `awaitingConfirmation`，缺证据 → `evidenceMissing`（confirm 被拒、不推进）；退回写 `## 阶段确认` 留痕（可带 `target` 回边）；
- `WorkstreamsDelivery.swift`：交付 git 流水线 / GitHub PR / token 文件读取（`WSGitProbe` / `WSGitHubPR` / `WSTokenStore`，**只读文件、不读 Keychain**），准入卡 `stage == .delivery`，失败有稳定码 `WSDeliveryBlocker`，PR 状态派生 `delivery.outcome`。

## 接线与边界

`main.swift` 接线：`RightPanel.workstreams`、活动栏槽位紧邻「需求池」之后、`⌥⌘K` 视图菜单、`DSH_WORKSTREAMS_TEST=1` 自测钩子、`workspaceChanged()`、`onOpenCard`、`serverPortProvider`（dsh RPC 端口）；面板实现 `WorkstreamsAPIDelegate`（含任务 / 队列路由）与阶段门确认 / 退回。

**队列引擎已接线**（2026-10-06）：面板按工作区各持一个 `WorkstreamsRunner`，3s `step()` 定时器推进、工作区切换重建、首次加载对账（reconcile 一次）；主卡「启动事项」、阶段卡「＋创建任务」/「启动阶段」，三级任务卡显示状态 / 会话；阶段门读 runner 的实时板。

**仍未接线**（与设计 §10 一致）：交付模块 `WorkstreamsDelivery` 尚未接入面板，`covered` / `delivery` 没有写路由；阶段提示词与技能仍示例 `/task-todo`，未改指事项面板自有 API。

## 测试

`tests/workstreams-panel/run.sh`（**780 项**）：model 77 + API 196 + ui 95 + runner 105 + prompt 136 + delivery 111 + stage-gate 60，另含 A6 视图命名空间 / 配色 / 引擎隔离 / main.swift 接线 / 阶段门 / 阶段提示词 / 写权反转等源码守卫；接入 `scripts/local-ci.sh` 与 `.github/workflows/ci.yml`。
