---
title: 模块：Workstreams*（事项面板）
tags: [module, workstreams, panel, ai-native-workflow, stage-gate]
updated: 2026-10-07T18:00:00Z
sources: [platforms/macos/src/WorkstreamsCore.swift, platforms/macos/src/WorkstreamsUI.swift, platforms/macos/src/WorkstreamsRunState.swift, platforms/macos/src/WorkstreamsAPI.swift, platforms/macos/src/WorkstreamsPanel.swift, platforms/macos/src/WorkstreamsQueues.swift, platforms/macos/src/WorkstreamsRunner.swift, platforms/macos/src/WorkstreamsPrompts.swift, platforms/macos/src/WorkstreamsStageGate.swift, platforms/macos/src/WorkstreamsDelivery.swift, platforms/macos/src/WSCardView.swift, platforms/macos/src/WSInlineForms.swift, platforms/macos/src/main.swift, tests/workstreams-panel/, docs/design/panels/workstream-panel-design.md, docs/design/panels/requirements-workstream-store-design.md, docs/design/panels/workstream-handoff-prompt-design.md, docs/usage/panels.md, .dsh/skills/workstream-panel/SKILL.md]
manual: false
---

# 模块：Workstreams*（事项面板）

事项面板是右栏**第 11 个原生面板**（活动栏第 6 位、`⌥⌘K`、图标 `square.stack.3d.up`），是当前工作区的事项（Workstream）中心。按设计 A1/A6/A10 **clean-room** 实现——不复用任务面板代码，队列 / 交付 / 视图基件都是自有 `WS*` 文件，配色只用 `PanelSurface` / `PanelControl`（无新令牌）。设计与用户说明见 `docs/design/panels/workstream-panel-design.md`、`docs/usage/panels.md`。

## 三级卡片与视图

- 一级 **事项主卡**：`WS-*.md` 一张卡，展开是五张阶段卡；
- 二级 **阶段卡**：规划 / 设计 / 执行 / 验收 / 交付**永远各一张、固定顺序**，`WS.queues [q-...]`（一事项一队列，0..1）挂在主卡当前阶段（旧卡 `[{id, stage}]` 只取 id，阶段丢弃），验收段显示 `covered`（paths / base / head）、交付段显示 `pr / outcome / url`；
- 三级 **任务卡**：该事项队列内的条目，按任务自带 `stage` 归到对应阶段卡；显示状态徽标与 dsh **会话**（运行态随 3s 定时器自动刷新）；
- 顶部**扁平页签** `全部 / 规划 / 设计 / 执行 / 验收 / 交付`（`WSStageFilter`），空态三态（无工作区 / 池空 / 筛选无命中）。

**运行态徽标（A13 / D18）**：`WorkstreamsRunState.swift` 的 `WSRunState.stage` / `WSRunState.workstream` 从**队列与任务状态**派生**未开始 / 进行中 / 待确认 / 完成 / 阻塞**，显示在主卡与各阶段卡；**权威 `stage` 不变**（仍只由人工确认门推进；退回返工后按 `## 阶段确认` 末条 `reject` 判返工）。

纯视图模型在 `WorkstreamsUI.swift`（Foundation-only），UI 在 `WorkstreamsPanel.swift`（`WorkstreamsPanelController` + `WSBoardRootView`）；从任务面板复制并重命名的自有基件 `WSCardView.swift`（`WSInk` / `WSBadgeView` / `WSCardView` …）与 `WSInlineForms.swift`。

## 模型与 API

- `WorkstreamsCore.swift`：`WS-*.md` frontmatter 解析（自写缩进式 YAML 子集，剥离行内注释）、固定键序序列化、**原子写**、`create/update/setStage/setQueues/setCovered/setDelivery`、**六位零填充 id** `WS-%06d`、`validate()`（含 `covered` 必填等），错误码 `evidence-missing` / `stage-changed` / `missing-reason`（前两者 409）；
- `WorkstreamsAPI.swift`：纯路由 `/api/workstreams/*`——`list` / `create` / `update` / `stage` / `plan` / `queues` + 人工门 `stage/confirm`、`stage/reject`，外加 **`task/list` / `task/create` / `queue/start` / `queue/pause`**（A14；`task/create` 支持 `titles[]` 或仅 `body`，按阶段默认动作注入交接提示词；`queue/start` 带 `stage` = 阶段级启动）；错误码 / status 对齐 `/api/requirements/*`，由 `BrowserAPI` 前缀拦截并桥接到主线程（`WorkstreamsAPIDelegate`，面板是唯一写者）；
- **focus 通道**：任何路由可带 `focus`（写操作 body 字段、读操作 `?focus=`，接受 `true` / `1` / `yes` / `on`，默认 `false`）；仅在请求被处理（HTTP 200）时触发，经 `WorkstreamsAPIDelegate.apiWorkstreamsFocus` → `BrowserAPIBridge.workstreamsFocus`（主线程）亮起面板并按 `id`（create 取新建卡 id）高亮。面板内 `focus(onWorkstream:)` 加**强调色描边**并滚动到可见，被阶段筛选隐藏时回落「全部」；需求池子事项主 `↗` 走该通道（次级 `doc.text` 打开卡文件，D6）；
- 写权反转（Phase B，D5b）：面板是 `WS-*.md` 唯一写者，agent 经 API 改事项、不直接改 `.dsh`；配套内置技能 `workstream-panel`（见 [skill-installer](skill-installer.md)）。

## 阶段队列引擎与阶段门

- `WorkstreamsQueues.swift`：事项面板**自有**队列 / 三级任务模型 + 存储（`WSTaskItem` / `WSQueue` / `WSBoard` / `WSStore`），队列落 `.dsh/workstreams/queues.json`、会话 / 汇报落 `local.json`（**ignored**）；**绝不读写 `.dsh/tasks/*`**；
- `WorkstreamsRunner.swift`：按 A10 复制任务面板的串行相位机（idle / starting / active / finishing），「建会话 → 命名 `WS: ` → prompt → 轮询 → 取消 / 重试」，重启恢复（running→interrupted、active→paused、不自动起跑）；`createStageQueue` / `appendStageTasks` 追加到该事项**唯一**队列（没有才建）、任务带 `workstreamId` + `stage`；`startWorkstream(_:stage:)` = 事项级 / 阶段级启动（A3 / A9 / D18，阶段级用 `stageFilter` 只跑该阶段、跑完暂停队列）；`WSPrompts` 委托 `WorkstreamsPrompts`；
- `WorkstreamsPrompts.swift`：`WSStageAction`（五阶段六个动作）+ `WorkstreamHandoff` 提示词生成器（公共头 / 动作段 / 模型规则 / 回归门行）；`injectingCompletionMarker` 统一注入完成 marker；
- `WorkstreamsStageGate.swift`：五阶段**机检证据谓词 + 人工确认门**（R10）——规划四件套、设计文档 + Q 关闭、执行队列 `.done` 且任务有证据、验收 `covered`、交付 PR + outcome；`.done` + 谓词通过 → `awaitingConfirmation`，缺证据 → `evidenceMissing`（confirm 被拒、不推进）；退回写 `## 阶段确认` 留痕（可带 `target` 回边）；
- `WorkstreamsDelivery.swift`：交付 git 流水线 / GitHub PR / token 文件读取（`WSGitProbe` / `WSGitHubPR` / `WSTokenStore`，**只读文件、不读 Keychain**），准入卡 `stage == .delivery`，失败有稳定码 `WSDeliveryBlocker`，PR 状态派生 `delivery.outcome`。

## 接线与边界

`main.swift` 接线：`RightPanel.workstreams`、活动栏槽位紧邻「需求池」之后、`⌥⌘K` 视图菜单、`DSH_WORKSTREAMS_TEST=1` 自测钩子、`workspaceChanged()`、`onOpenCard`、`serverPortProvider`（dsh RPC 端口）；面板实现 `WorkstreamsAPIDelegate`（含任务 / 队列路由）与阶段门确认 / 退回。

**队列引擎已接线**（2026-10-06）：面板按工作区各持一个 `WorkstreamsRunner`，3s `step()` 定时器推进、工作区切换重建、首次加载对账（reconcile 一次）；主卡「启动事项」（面板唯一启动入口）、阶段卡「＋创建任务」，三级任务卡显示状态 / 会话；阶段门读 runner 的实时板。

**交付接线与事实写路由**（2026-10-07）：交付模块 `WorkstreamsDelivery` 已接入面板——阶段卡「交付」按钮用 `WorkstreamsDelivery.resolve` 收集 git / GitHub / token 事实，准入失败给明确原因（`WSDeliveryBlocker`），成功则 `WorkstreamsRunner.enqueueDelivery` 建 delivery 阶段任务并只启动该阶段；新增 `POST /api/workstreams/covered`（`paths` + `base` / `head` 事实）与 `POST /api/workstreams/delivery`（`pr` / `url` 事实）；**`delivery.outcome` 是派生缓存**，API 拒绝手写（`outcome-derived`）；阶段提示词与技能均已改指事项面板自有 API。

**事项 ↔ 主场会话绑定 / 拆分任务**（2026-10-07，A16）：`.dsh/workstreams/local.json` 的 `workstreamSessions`（WS-id → sessionId，ignored）保存每个事项**至多一条「主场会话」**，由任何带 `session` 的写请求记忆（`WSStore.rememberWorkstreamSession`），**后写覆盖先写**（last-writer-wins，运行时绑定、不是永久契约）；`list` 的每张卡随带 `session`；反查路由 **`GET /api/workstreams/bound?session=$DSH_SESSION_ID`** 返回该会话绑定的 WS（未绑定返回空列表）。**只有真正在推进该事项的对话才应带 `session`**；阶段 runner / 临时会话带上会覆盖主场会话（技能正文有显式警示）。**主卡「拆分任务」**（2026-10-07，UX）解析该事项**首个未处理阶段**（canonical 顺序里第一个 `runState != 完成` 的阶段，A13 派生态；全部完成则无可拆分阶段），经 `WorkstreamHandoff.splitPrompt` 把该阶段的拆分提示词发进主场会话（点名事项 + 阶段、`task/create` 建等待态任务、不自签 / 不启动 / 停下等人）；阶段卡去掉重复入口。会话选择对齐需求池「细化」：复用绑定会话 / 新建并绑定 / 回退当前会话，决策为纯函数 `WorkstreamsCore.sessionTarget`（`WorkstreamTarget.reuse / created / fallback`）。**需求拆解确认继承**（2026-10-07）：`RequirementsCore.confirm` 建 `WS-*.md` 时把该需求在 `.dsh/requirements/local.json` 的绑定会话合并写进 `workstreamSessions`（显式 `session` 优先，无绑定则不发明），新事项在面板可直接续同一条对话；`requirements.notify.confirmed` 同步改指事项面板并附 focus 提示。

**对话内阶段推进**（2026-10-07）：人工确认门通过、`stage` 真的前移后，面板按钮与 `POST /api/workstreams/stage/confirm` 两条路径共用 `continueToNextStage`，经 `onStageConfirmed` 把更新后的卡片交给 `main.swift`；后者读该事项的**绑定主场会话**并复用 `WorkstreamHandoff.nextStagePrompt`（下一阶段 + 该阶段默认动作提示词）发送，对话自然续到下一阶段。**无绑定会话则不发**（不凭空起会话）、**交付是终态**不续发。

**焦点 + 主场会话切换矩阵**（2026-10-07，A15 / A16，设计 §6.1）：面板 ↔ 对话由两条正交通道承载——`focus`（注意力单向往面板：任意路由带 `focus`，仅 200 触发置前 + 高亮 + 滚动，目标被阶段筛选隐藏时回落「全部」，默认 `false`；`bound?focus=true` 高亮反查到的第一张卡）与 `workstreamSessions`（每事项至多一条主场会话）。方向：对话→面板（技能 `bound + focus`）、需求池→面板（子事项 `↗`）、面板→对话（主卡「拆分任务」：首个未处理阶段的拆分提示词发进主场会话，复用/新建/回退）、阶段确认→对话（向主场会话发下一阶段提示词）、需求池确认→对话（继承需求绑定会话）。

**三件事：拆分 / 确认 / 启动**（2026-10-07，设计 §5.1）：同一张卡上的「推进」是三件互不替代的事——**拆分任务 = 会话提示词**（主卡按钮按**首个未处理阶段**发 `WorkstreamHandoff.splitPrompt` 进主场会话；agent 据此 `task/create` 建**等待态**任务）、**确认 = 阶段上的人工门**（阶段卡「确认 / 退回」，只有人能点）、**启动 = 事项卡「启动事项」/ 技能 `queue/start`**（面板唯一入口；事项级按**阶段 canonical 顺序**取任务、同阶段内按入队序；带 `stage` = 阶段级、只跑该阶段、跑完自动暂停）。拆分 ≠ 启动（先建等待态、人确认后才起跑）、确认 ≠ 启动（确认前移 `stage`、启动不改 `stage`）；设计 A3 / A14 / D19 与 §4 / §6 同步交叉明确。`workstream-handoff-prompt-design.md` §4.1 固化拆分提示词措辞；`workstream-panel` 技能补「对话中发起拆分 / 启动」入口。

**默认展开首个未处理事项卡**（2026-10-07，UX）：面板加载 / 重绘时只展开首个 `runState != 完成`（A13 派生态：未开始 / 进行中 / 待确认 / 阻塞）的事项卡，其余收起；全部完成时不展开任何卡。纯谓词 `wsDefaultExpandedID` / `wsApplyingDefaultExpansion`（`WorkstreamsUI.swift`）由 `WSBoardModel.build` 每次构建时应用（在阶段筛选后的可见列表内取首个未处理）。

## 测试

`tests/workstreams-panel/run.sh`（**1042 项**）：model 93 + API 266 + ui 174 + runner 132 + prompt 190 + delivery 127 + stage-gate 60，另含 A6 视图命名空间 / 配色 / 引擎隔离 / main.swift 接线 / 阶段门 / 阶段提示词 / 写权反转 / **运行态派生** / **交付接线与 covered / delivery 写路由** / **事项会话绑定与拆分任务（首个未处理阶段）** / **focus 通道（面板高亮滚动 + API focus + 需求池跳转）** / **对话内阶段推进（确认 → 向主场会话发下一阶段提示词）** / **默认展开（首个未处理卡）** / **启动收口（阶段卡无启动按钮 + 事项启动按阶段 canonical 顺序）** 等源码守卫；接入 `scripts/local-ci.sh` 与 `.github/workflows/ci.yml`。
