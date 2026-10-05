# 需求池「拆解确认清单」标准化设计

> 状态：**已实现**（`feature/requirements-breakdown-standard`）· 日期：2026-10-05
> 关联：`docs/design/panels/requirements-pool-panel-design.md`（面板体例 / API / 拆解器）、`docs/design/panels/requirements-workstream-store-design.md`（REQ/WS schema 与派生）、`docs/usage/ai-native-workflow-manual.md`（事项阶段闭环）
> 实现：`platforms/macos/src/RequirementsCore.swift`（表格契约 + 解析）、`platforms/macos/src/RequirementsUI.swift`（合并展示模型）、`platforms/macos/src/RequirementsAPI.swift`（响应形状）、`platforms/macos/src/RequirementsPanel.swift`（渲染）、`platforms/macos/src/main.swift`（L10n）；测试 `tests/requirements-panel/`

---

## 1. 背景与问题

需求池面板的「已拆解事项」区此前只渲染 **WS 卡的摘要**（`WorkstreamSummary`：id / title / stage / outcome / path），而 **REQ 卡 `## 拆解` 里确认后的清单内容（边界 / 依赖）在确认那一刻就从 UI 消失了**：

- 确认前，提案项卡显示 `[依赖 N]` 与展开的「内容（边界）」；
- 确认后，提案块被替换成 REQ 正文里的映射表，但面板不解析、不渲染它；
- 结果：事项的「边界 / 依赖」只能打开文件看，面板里看不到。

此外，REQ 的确认清单长期由**人手写**，列不一致（`REQ-001` 为 `事项 | 边界 | 状态`，`REQ-004` 为 `事项 | 边界 | 状态 | 依赖`，面板生成为 `事项 | 边界 | 依赖`），机器无法稳定读取。

## 2. 决策

| # | 决策 | 说明 |
|---|---|---|
| C1 | **标准列**：`标识 | 事项 | 边界 | 依赖` | `confirm` 生成与解析都以这四列为契约；`状态` 不落盘 |
| C2 | **内容以 REQ 为准** | 事项的标题 / 边界 / 依赖取自 REQ 卡 `## 拆解` 确认表 |
| C3 | **状态以 WS 为准、不落 REQ** | 阶段（`stage`）与结果（`delivery.outcome`）只从 WS 卡读取；REQ 确认表**不含状态列**（T1：派生字段不落盘） |
| C4 | **成员关系仍按 `WS.requirement`** | 「哪些事项属于该需求」以 WS 卡正向指针为准，REQ 表不作为成员权威（沿用存储设计）；两边不一致时**显式标注**，不静默隐藏 |
| C5 | **兼容历史列** | 解析按**列名**识别，容忍缺列 / 多列（`状态`）/ 无 ID 的候选行 / 自由文本 |

> C3 是「派生不落字段」（存储设计 D2）的直接实现：状态不写进 REQ 卡，面板渲染时由 WS 实时 join（选项 T1）。

## 3. 表格契约

### 3.1 标准格式（`confirm` 生成）

```markdown
## 拆解（agent 提案 / 人工确认）

| 标识 | 事项 | 边界 | 依赖 |
|---|---|---|---|
| WS-000009 | 架构模型修订 | 只改架构文档 + 索引 | — |
| WS-000010 | 拆解器设计 | 1 需求 → 1..N 事项 | WS-000009 |

确认记录（2026-10-05）：人确认拆解，生成 WS-000009、WS-000010。
```

- `标识`：`WS-<n>`；未建卡的候选行为 `—`；
- `事项`：标题；
- `边界`：提案 `boundary`（`|` 转义为 `/`）；
- `依赖`：**WS 标识**列表（提案里是标题，写盘时按 标题→id 映射；映射不到保留原文），无则 `—`；
- **不含 `状态` 列**：状态只存在于 WS 卡，面板渲染时实时 join（T1）。

### 3.2 解析（`RequirementsCore.parseConfirmed`）

- 从 `## 拆解` 段（`sectionText`）取第一条 markdown 表格；
- 表头按规范化列名匹配：`标识/id`、`事项/title`、`边界/boundary`、`依赖/depends`；多余的列（如旧卡的 `状态`）**忽略**；
- 行：`|` 分列，跳过 `---` 分隔行；`—` / `-` / 空 → 空；
- `事项` 若以 `WS-\d+` 开头，则拆出 ID（兼容旧表把 ID 并进事项列）；
- `依赖` 用正则抽取所有 `WS-\d+`（兼容 `WS-007 之后` 这类自由文本）；
- 无表格 → 空数组（未确认 / 待确认提案仍在 `json proposal` 围栏里）。

## 4. 合并展示模型（`WorkstreamDisplay`）

纯模型（`RequirementsUI.swift`，可无头断言）把两侧拼成一行：

```swift
struct WorkstreamDisplay: Equatable {
    var id: String?       // 标识（候选行可为空）
    var title: String
    var boundary: String  // REQ
    var dependsOn: [String] // REQ
    var stage: String?    // WS
    var outcome: String?  // WS
    var path: String?     // WS
    var missingCard: Bool // REQ 有行、WS 卡缺失
    var notInPlan: Bool   // WS 卡存在、REQ 表未记录
}
```

`merge(confirmed:children:)`：先按 REQ 表顺序出行并 join WS；再把不在表里的 WS 子事项追加（`notInPlan = true`）；REQ 表为空时直接回退为「全部子事项」（`notInPlan = false`，避免旧卡噪声）。

## 5. 面板渲染

- 「已拆解事项」区改为渲染 `WorkstreamDisplay`：
  - 头部：`doc.text` + `标识` + 标题 + **本地化阶段徽标** + `↗`（有 WS 路径才出现）；
  - 展开：`边界` / `依赖` / `阶段` / `结果` / `路径`；
  - `missingCard` → 追加「WS 卡缺失」中性提示；`notInPlan` → 追加「REQ 表未记录」中性提示；
  - 候选行（无 ID、无状态）只展示内容。
- 顶部 `[N 个事项]` 徽标仍按 `children`（WS 成员关系）；分区标题按实际渲染行数。
- 阶段徽标本地化：`planning/design/task/acceptance/delivery` → 规划 / 设计 / 任务 / 验收 / 交付（未知值回退原文）。

## 6. API

`GET /api/requirements/list` 的每个需求增加 `confirmed`：

```json
{
  "id": "REQ-000001",
  "children": [ { "id": "WS-000009", "title": "…", "stage": "planning" } ],
  "confirmed": [ { "id": "WS-000009", "title": "…", "boundary": "…", "dependsOn": [] } ]
}
```

`confirmed` 与 `children` 是**两种权威**：前者是 REQ 的拆解记录，后者是 WS 的实际成员与状态。

## 7. 测试

`tests/requirements-panel/model-tests.swift` 新增：

- `confirm` 后 REQ 正文含标准四列、无状态列，且依赖写成了 WS 标识；
- `parseConfirmed` 往返；兼容 3 列（`REQ-001`）、4 列（`REQ-004`）、候选行、自由文本依赖；
- `WorkstreamDisplay.merge`：join 状态、`missingCard`、`notInPlan`、空表回退。

## 8. 手工验收清单

- [ ] 对一个需求「确认拆解」→ REQ 卡的 `## 拆解` 出现标准五列表，依赖是 `WS-*`；
- [ ] 面板「已拆解事项」区显示每行的 `边界 / 依赖`，阶段徽标为中文本地化；
- [ ] 改 WS 卡的 `stage` 后刷新面板 → 显示随之变化（状态来自 WS，不读 REQ 快照）；
- [ ] 手工在 REQ 表里加一行无 WS 的行 → 面板显示该候选行且不报错；
- [ ] 手工建一张不在 REQ 表里的 WS 卡 → 面板显示它并标注「REQ 表未记录」；
- [ ] 旧卡（`REQ-001` / `REQ-004`）不崩、按列名解析出可用内容。

## 9. 决策记录

| # | 决策 | 理由 |
|---|---|---|
| 1 | `状态` 不落 REQ（T1） | 派生字段不落盘；避免第二份会过期的状态源，面板 join WS |
| 2 | `依赖` 落盘为 WS 标识而非标题 | 稳定、可解析；标题会随编辑漂移 |
| 3 | 成员关系不改为「REQ 表为准」 | 与 `derive-status.mjs` / 存储设计的正向指针保持一致，避免漏事项 |
| 4 | 分歧显式标注而非隐藏 | 旧卡与并发编辑都会产生不一致，静默吞会掩盖问题 |
