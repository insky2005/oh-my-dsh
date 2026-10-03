# 事项交接提示词（Workstream Handoff Prompt）设计

> 状态：草案 · 日期：2026-10-03 · 关联：`docs/research/ai-native-workflow-architecture.md`、`.dsh/requirements/README.md`、`docs/design/panels/requirements-workstream-store-design.md`（待建）

## 1. 目的

把一个「事项」交给**新会话**处理时，需要一段提示词把 agent 领到正确的卡片、说清本步动作与模型规则。本文定义这段提示词的**模板与生成规则**，供面板（或人）复用。

## 2. 原则

1. **提示词是指针，不是状态副本**：状态（stage / 规划 / 覆盖）只活在 `.dsh` 卡片里，提示词不复述细节，避免漂移。
2. **动作 = (stage, action) 的函数**：面板按钮不是「一个提示词」，而是「当前 stage → 本步 action」，各 stage 一份 action 段，共用公共头。
3. **变量从卡片注入**：`<WS-ID>` / `<REQ-ID>` / `<stage>` / `<REG-ID>` / 目标，全部读卡片。
4. **卡片必须自足**：薄提示词成立的前提，是卡片的「规划」有目标 / 边界 / 验收标准 / 裁剪声明。
5. **人保留 Own**：规划确认与验收 sign-off 必须停下问，agent 不自签。

## 3. 公共头（所有 stage 共用）

```text
你在 <repo> 处理一个事项。

事实来源（先读，别信转述）：
- 事项：.dsh/workstreams/<WS-ID>.md
- 需求：.dsh/requirements/<REQ-ID>.md
- 存储约定：.dsh/requirements/README.md
- 模型：docs/research/ai-native-workflow-architecture.md
- 仓库约定：AGENTS.md

当前 stage：<stage>      本步动作：<action>
目标：<卡片的规划.目标>
```

## 4. stage → action 段

| stage | action | 要点 |
|---|---|---|
| 规划 | 确认规划 | 补齐验收标准 + 裁剪声明后，**停下请人确认**，再进设计 |
| 设计 | 出设计 | 写 `docs/design/**`，不写实现 |
| 任务 | 实施 | 切分支；按队列 / 任务执行，提交走 conventional commits |
| 验收 | 校验 | 跑回归门 `<REG-ID>` + 机检证据；**人 sign-off**，agent 不自签 |
| 交付 | 交付 | push / PR；在卡片写 covered / 交付 PR |

每个 action 段都附**模型规则**（强制）：

- 回边合法但留痕；跳过 / 裁剪必须在「规划」声明；
- **只拆不胀**：范围外 → 新需求卡片（R5），不就地吸收；
- 裁决是点记录；覆盖锚变更；终态是派生谓词（**不写** `closed` / `outcome`）；
- 回归门 `<REG-ID>`：若改动其覆盖路径，交付前运行；
- 不改其它会话的在途文件。

## 5. 生成示例：WS-002

```text
你在 oh-my-dsh 仓库工作。处理事项 WS-002「需求 / 事项落盘 .dsh 落地」。

先读：.dsh/workstreams/WS-002.md、.dsh/requirements/REQ-002.md、
      .dsh/requirements/README.md、docs/research/ai-native-workflow-architecture.md、AGENTS.md。

当前 stage：规划 → 确认规划后进设计。
目标：产出 docs/design/panels/requirements-workstream-store-design.md。
规则：……（同 §4）
结束前停下问：规划确认 / 验收 sign-off。不要自签。
```

## 6. 变量来源

| 变量 | 来源 |
|---|---|
| `<repo>` | 工作区根 |
| `<WS-ID>` / `<REQ-ID>` | 面板选中的事项卡片 |
| `<stage>` | 卡片的 `stage` |
| `<action>` | 由 §4 按 `stage` 映射 |
| `<REG-ID>` | 卡片的 `regression`（无则省略该条） |
| 目标 | 卡片的「规划.目标」 |

## 7. 依赖与待办

- 可靠生成的前提是**存储 schema 定稿**（WS-002 / `requirements-workstream-store-design.md`）；
- `outcome` / `closed` 改为派生后，本模板不再出现「写 closed」这类动作；
- stage → action 的映射（§4）需随模型演进同步。