# 需求 / 事项存储（.dsh）设计

> 状态：草案（WS-002 已交付；WS-005 状态派生修订 2026-10-03）· 日期：2026-10-03 · 关联：`.dsh/workstreams/WS-002.md`、`.dsh/workstreams/WS-005.md`、`.dsh/requirements/REQ-002.md`、`.dsh/requirements/README.md`、`docs/research/ai-native-workflow-architecture.md`、`docs/design/panels/workstream-handoff-prompt-design.md`
> 修订（WS-005，2026-10-03）：需求 `state` 只留人工判断，`split` / `closed` 为派生；见 §3.1 / §5 / §6 / §10。

## 1. 目的与范围

把 `.dsh/requirements` / `.dsh/workstreams` / `.dsh/regression` 的**演练约定**固化成可实现的**设计**：
三类卡片的 schema、committed / ignored 分界、终态为派生谓词、需求关闭规则、写入所有权反转路径，
以及与 `.dsh/tasks` 的边界。它是**需求池面板 / 拆解器 / 交付结果派生**三件后续工具的存储地基。

**本设计做**：定义 schema 与不变量、给出复核命令、说明迁移路径。

**本设计不做**（范围外，见 §9，须按「只拆不胀」另起卡片）：

- 不建需求池面板、不建拆解器、不建交付追踪；
- 不改 `.dsh` 既有卡片内容、不改面板代码、不改 `.gitignore`；
- 不实现 linter 脚本（只给出可直接运行的复核命令）。

## 2. 实体与关系

```
需求 REQ ── 拆解（agent 出方案 / 人确认）──► 1..N 事项 WS ── 关联 ──► 0..N 队列 queue（.dsh/tasks）
   │                                              │
   │ 0..1（事项可无需求）                          ├─ 规划.验收标准 ── 长期不变量 ──► 回归门 REG
   └─ 池状态（人工 candidate/evaluating/…；派生 split/closed） └─ 覆盖 covered（点记录，锚变更）
```

**权威边（单一真相，原则 2）**：

- **WS → REQ**：`WS.requirement` 是权威正向指针（0..1）。`REQ.workstreams` 是**派生缓存**（由所有 `requirement == 本需求` 的 WS 反向聚合），可缺省、可重算，不得当作第二权威。
- **WS → REG**：`WS.regression` 指向它触及的回归门（0..1）。门定义在 REG 卡片内。
- **WS → queue**：`WS.queues`（committed）为权威；队列 JSON 里的 `workstream` 是运行时镜像（ignored，可重建）。
- **需求关闭**：**派生谓词**，不落字段（§5 / §6）。

## 3. Schema

三类卡片均为「YAML frontmatter + 正文」的 Markdown，一卡一文件。

- **必选**：缺省即卡片非法，写入方必须补齐；
- **派生**：可由其他卡片 / PR 状态重算，是缓存或视图，**不是权威**；
- **禁止**：不得作为字段出现（见 §5）。

### 3.1 需求卡片 `.dsh/requirements/REQ-<id>.md`

```yaml
---
id: REQ-002                 # 必选，REQ-<n>，不可变
title: ...                  # 必选
state: evaluating           # 可选；仅人工判断（拆分后不写）
source: 2026-10-03 会话      # 必选，来源（会话 / issue / 文档 / 人）
created: 2026-10-03         # 必选
updated: 2026-10-03         # 必选
workstreams: [WS-002]       # 派生缓存（由 WS.requirement 反向聚合）
---
```

- `state`（**仅人工判断**，不套事项阶段机，原则 12；**可选**，拆分后不写）：

  | 值 | 中文 | 含义 |
  |---|---|---|
  | `candidate` | 候选 | 收件箱里待评估 |
  | `evaluating` | 评估中 | 正在论证做法 / 边界 |
  | `suspended` | 挂起 | 主动搁置，可再启 |
  | `discarded` | 丢弃 | 人显式放弃（显式决定，不是派生） |

- **`split` / `closed` 是派生，不落字段**（同 §5）：`split(req) = children(req) ≠ ∅`；`closed` 见 §6。
- **有效状态（`effective_state`）**，供面板 / 工具显示，派生优先级：

  ```
  discarded          若 state == discarded（显式放弃，最高优先）
  closed             若 children ≠ ∅ 且全部终态
  split              若 children ≠ ∅
  state 或 candidate 否则
  ```

  拆分之后 `state` 不再作为权威，卡片里可以没有它。

- 正文：`## 诉求`（必选）、`## 决策`、`## 拆解`（拆解器未落地前以表格承载）、`## 关联`。

### 3.2 事项卡片 `.dsh/workstreams/WS-<id>.md`

```yaml
---
id: WS-002                  # 必选，WS-<n>，不可变
title: ...                  # 必选
requirement: REQ-002        # 可选（0..1）；不挂需求的顺手活可缺省
stage: planning             # 必选，planning/design/task/acceptance/delivery
covered:                    # 验收 / 交付阶段必选（点记录，不可变）
  - docs/...
  base: <blob/tree id>      # 不可变内容标识（非分支、非裸 commit）
  head: <blob/tree id>
regression: REG-001         # 可选（0..1）
queues: [q-...]             # 可选，关联执行载体（权威边）
delivery:                   # 交付阶段出现；只放事实，outcome 为派生缓存
  pr: 78
  url: https://github.com/...
  outcome: merged           # 派生缓存：由交付追踪依 PR 状态写入，禁止手写
created: 2026-10-03
updated: 2026-10-03
---
```

- `stage` 是**状态不是站点**（原则 5）：允许回边、跳过、停驻；裁剪必须在「规划」声明（R3）。
- 正文段落与阶段对应：`## 规划`（目标 / 边界 / 阶段裁剪声明 / 验收标准，**进设计的前提**）、`## 设计`、`## 任务`、`## 验收`（点记录）、`## 交付`、`## 终态（派生）`、`## 复盘`。
- `covered` 锚**变更**（不可变内容标识），不锚文件整体、不锚分支 / 裸 commit（原则 8，见 `REQ-005`）。摘要算法见 `REQ-005`「覆盖字段」。

### 3.3 回归门卡片 `.dsh/regression/REG-<id>.md`

```yaml
---
id: REG-001                 # 必选
title: ...                  # 必选
source: WS-001              # 必选，来源事项（其验收标准升格而来）
runs: node .dsh/regression/check-architecture-model.mjs   # 必选，可执行检查
created: 2026-10-03
updated: 2026-10-03
---
```

- 回归门是**长期不变量**：每次改动其覆盖路径都必须跑（原则 14）。`runs` 必须是一条能自证的命令（原则 9：能用负例证明它会失败）。
- 后事项打破门 → **后事项失败**，不是来源事项重开。

### 3.4 字段总表

| 实体.字段 | 类别 | 说明 |
|---|---|---|
| REQ.id / title / source / created / updated | 必选 | 需求定义 |
| REQ.state | 可选（拆分前） | 仅人工判断；拆分后不写 |
| REQ.split | 禁止 | 派生谓词：children ≠ ∅ |
| REQ.workstreams | 派生 | 由 WS.requirement 反向聚合的缓存 |
| REQ.closed / REQ.outcome | 禁止 | 终态派生谓词，不落字段 |
| WS.id / title / stage / created / updated | 必选 | 事项定义与阶段 |
| WS.requirement | 可选（0..1） | 权威正向指针 |
| WS.covered.paths/base/head | 验收起必选 | 点记录，锚变更 |
| WS.regression | 可选（0..1） | 回归门 |
| WS.queues | 可选（0..N） | 关联队列（权威边） |
| WS.delivery.pr / url | 交付阶段 | 事实字段 |
| WS.delivery.outcome | 派生缓存 | 交付追踪写入；禁止手写（§5） |
| WS.closed | 禁止 | 终态派生谓词 |
| REG.id / title / source / runs / created / updated | 必选 | 门定义 |

## 4. committed vs ignored 分界（AC2）

**规则**：**定义与阶段随仓库提交；运行时绑定只在本机**。判据——「换一台机器 clone 后仍然有意义」的进 git；「只对本机会话 / 进程有意义」的忽略。

| 路径 | 类别 | 是否提交 |
|---|---|---|
| `.dsh/requirements/README.md` | 存储约定（定义） | ✅ committed |
| `.dsh/requirements/REQ-*.md` | 需求定义 | ✅ committed |
| `.dsh/workstreams/WS-*.md` | 事项定义 + 阶段 | ✅ committed |
| `.dsh/regression/REG-*.md` + checker | 回归门定义 | ✅ committed |
| `.dsh/tasks/index.json` | 任务关联索引（跨机有意义） | ✅ committed |
| `.dsh/tasks/{manual,queues,local}.json` | 任务面板运行时 | ❌ ignored |
| `.dsh/workstreams/local.json` | 事项运行时绑定（会话 id 等） | ❌ ignored |

- 照抄 `.dsh/tasks` 的既有分界（`REQ-002` 决策）：`.gitignore` 已忽略 `.dsh/workstreams/local.json`。
- 需求级运行时绑定**已定另立** `.dsh/requirements/local.json`（与事项级 `.dsh/workstreams/local.json` 对称），须同步在 `.gitignore` 增加一行 `.dsh/requirements/local.json`；本设计只记录约定，`.gitignore` 的落地属任务阶段（§9）。
- **阶段迁移本身写进卡片**（committed）：`stage` 变化是对共享真相的编辑，必须可追溯、随仓库走。

## 5. 终态是派生谓词，禁止手写（AC4）

按架构原则 15：`closed = stage == delivery 且交付结果终结（merged / closed / abandoned）`；是**观察**不是**迁移**。

- 卡片**不得出现** `closed` 字段（REQ / WS 皆然）；
- `outcome` **只允许**作为 `delivery` 块内的**派生缓存**（由交付追踪依 PR 状态写入 / 重算），**禁止手写**；顶层 `outcome` 一律非法；
- 交付阶段允许写入的是**事实**：`delivery.pr`、`delivery.url`；由这些事实观察出 `outcome`。
- 同理，`split` 也不落字段（§3.1）：`split(req) = children(req) ≠ ∅`；派生器输出「有效状态」。

**复核命令**（交付前跑；可作为将来 `REG-002` 的雏形，见 §9）：

```sh
# 终态契约：卡片不得手写终态
bad=0
# 1) closed 绝不能作为字段出现
grep -rnE '^[[:space:]]*closed[[:space:]]*:' .dsh/requirements .dsh/workstreams && bad=1
# 2) outcome 只允许出现在 delivery: 块内
awk '
  /^[^[:space:]].*:/ { top=$0; sub(/:.*/, "", top) }
  /^[[:space:]]+outcome[[:space:]]*:/ {
    if (top != "delivery") { print FILENAME ": outcome 必须在 delivery 块内: " $0; bad=1 }
  }
  END { exit bad }
' .dsh/requirements/REQ-*.md .dsh/workstreams/WS-*.md || bad=1
# 3) split 绝不能作为字段出现
grep -rnE '^[[:space:]]*split[[:space:]]*:' .dsh/requirements && bad=1
[ "$bad" -eq 0 ] && echo 'PASS 终态未手写' || echo 'FAIL 终态被手写'
```

> 注：`WS-001` / `WS-003` 的 `delivery.outcome` 是交付追踪视角写入的派生缓存，符合本规则；
> 迁移时由面板重算即可，**不追溯修改既有卡片**（属范围外）。

## 6. 需求关闭规则（Q14，AC5）

**已确认**（规划确认 2026-10-03）：下列规则生效。在 `∀` 前保留「子事项非空」守卫，避免空子集被 ∀ 空真误判为关闭；`closed` 永为派生谓词、不落字段。

- **派生谓词**：`closed(req) = children(req) ≠ ∅ 且 ∀ ws ∈ children(req): terminal(ws)`，其中
  `terminal(ws) = stage == delivery 且 delivery.outcome ∈ {merged, closed, abandoned}`；
  或需求被显式 `discarded`（人的决定，不是派生）。
- **部分交付也算关闭**：只要「至少一个子事项」且「没有非终态子事项」即可（有的 merged、有的 abandoned / discarded 都满足）；`split` 只表示「已拆解」，**不等于关闭**。
- **不回弹**：关闭后不因后续改动重开、不要求重验；重开**另起需求并回指**（原则 15）。
- **空子集**：尚无子事项的需求**不满足** `closed`（前件要求子事项非空），不得自动关闭；它停在池状态（`candidate` / `evaluating` / `suspended`），除非人显式 `discarded`。
- 池状态取值见 §3.1：`state` 仅人工判断，`split` / `closed` 派生；需求卡不写 `split` / `closed`。

**派生复核命令**（示意，读盘即可算，不落字段）：

```sh
# 列出每个需求尚未终态的子事项（无子事项不自动关闭）
for r in .dsh/requirements/REQ-*.md; do
  rid=$(sed -n 's/^id:[[:space:]]*//p' "$r")
  kids=$(grep -l "^requirement:[[:space:]]*$rid\$" .dsh/workstreams/WS-*.md 2>/dev/null)
  if [ -z "$kids" ]; then echo "$rid 无子事项（不自动关闭）"; continue; fi
  open=$(printf '%s\n' "$kids" | xargs grep -L "^[[:space:]]*outcome:[[:space:]]*\(merged\|closed\|abandoned\)" 2>/dev/null)
  [ -n "$open" ] && echo "$rid 未关闭: $open" || echo "$rid 可关闭（子事项全部终态）"
done
```

## 7. 写入策略与所有权反转（AC3）

从「文件权威、agent / 人直接读写」反转为「面板单一写者 + 文件监听热重载」。分两阶段，**Phase A 的写法为 Phase B 铺路**。

### Phase A（当前，演练期）

卡片文件 = 权威；agent / 人直接读写。写文件必须：

1. **一卡一文件**：不把多个实体塞进一个文件；
2. **frontmatter 键序固定**：与 §3 一致，派生缓存可缺省（读方须能重算）；
3. **原子写**：临时文件 + `rename`，禁止半截 YAML；
4. **追加安全 / 幂等**：只改本卡；新增条目置末尾，既有条目**字节不变**；重复执行结果一致；
5. **不写别人的卡**：不改其它会话 / 事项的在途文件。

### Phase B（面板落地后）

**反转点**：面板的内存 board 会覆盖外部改动（见 `docs/design/panels/task-todo-skill-design.md:31`），因此落地后翻转写权。

1. **单一写者**：面板进程是唯一写者；agent **不再直接写文件**，改走壳层本地 API（沿用 `task-todo` 的 `BrowserAPIServer` + `/api/tasks/*` 形状，新增 `/api/requirements/*`、`/api/workstreams/*`）。
2. **内存是投影，不是第二权威**：面板不持有独立权威状态；任何写入前先按 §3 重读盘面（read-modify-write）。
3. **文件监听热重载**：监听 `.dsh/requirements`、`.dsh/workstreams`；变更事件先**重载**再应用下一次写，杜绝「内存覆盖外部改动」。
4. **串行化**：所有写入经同一线程（主线程）串行，与面板定时器同源，不存在两个写者。
5. **收尾**：API 与监听就绪后，把 agent 侧的「直接写文件」从 skill / `docs/design/panels/workstream-handoff-prompt-design.md` 中移除，改指 API——反转完成。

一句话：**Phase A 用「原子 + 追加安全 + 派生可重算」保证可迁移；Phase B 用「单一写者 + 监听重载 + 串行」保证不丢改动。**

## 8. 与 `.dsh/tasks` 的边界（AC6）

两者**不是同层实体**：事项是**追踪单元**，队列是**执行载体**。

| 维度 | 事项 WS | 队列 queue |
|---|---|---|
| 层级 | 追踪单元 | 执行载体 |
| 宿主 | `.dsh/workstreams/WS-*.md`（committed） | `.dsh/tasks/queues.json`（ignored） |
| 基数 | 1 事项 : 0..N 队列 | 1 队列 : 0..1 事项 |
| 关联权威 | `WS.queues`（committed） | 队列内 `workstream` 为运行时镜像（可重建） |
| 「完成」语义 | 终态由交付结果**派生** | `.done` 只表示队列跑完 |

- 事项**可以没有队列**（纯调研 / 文档类），也可以关联多个队列（多阶段执行）；
- **队列 `.done` ≠ 事项终态**：队列跑完只说明执行载体结束，事项是否终结仍由交付结果派生；
- 队列文件是运行时（ignored），事项卡片是共享真相（committed）——跨机可追溯的关联落在 `WS.queues`。

## 9. 范围外候选（只拆不胀，不就地吸收）

按 R5：以下工作**不并入 WS-002**，需要时各自另起需求卡片：

| 候选 | 说明 | 关联 |
|---|---|---|
| 需求池面板 | 需求的家：收集 / 评估 / 拆分 / 丢弃 | `REQ-001` 拆解表候选；架构 §4.1 |
| 拆解器 | agent 出「1 需求 → 1..N 事项」方案、人确认 | `REQ-001` 拆解表候选 |
| 存储 linter / `REG-002` | 把 §5 复核命令升级为回归门 | 本设计 §5 |
| 规划模板与门禁 | 规划四件套 + 「无证据不进设计」 | **已立项**：WS-007（模板）/ WS-008（门禁），见 `REQ-004` |
| 需求关闭规则正式立项 | §6 规则确认后落地 / 收口 Q14 | `REQ-003` |
| `.gitignore` 增 `.dsh/requirements/local.json` | **已定**另立需求级运行时文件，落地该忽略行 | 本设计 §4 |
| 迁移 `delivery.outcome` 为派生读取 | 面板交付追踪接管 | 本设计 §5 |

## 10. 验收对照（WS-002 AC1–AC7）

| AC | 落点 |
|---|---|
| AC1 REQ / WS / REG schema（字段 + 必选 / 派生） | §3（含 §3.4 总表） |
| AC2 committed vs ignored 分界 | §4 |
| AC3 单一写者 + 文件监听热重载的反转路径 | §7 |
| AC4 `outcome` / `closed` 派生、禁止手写（复核命令） | §5 |
| AC5 需求关闭规则（Q14） | §6 |
| AC6 与 `.dsh/tasks` 的边界 | §8 |
| AC7 `docs/README.md` 索引已登记 | `docs/README.md` design/panels 段 |

> WS-005 修订（2026-10-03）：§3.1 的 `state` 收窄为人工判断，`split` 改为派生；需求卡不再写 `split`。

## 11. 确认记录与遗留

**已确认**：

1. **规划确认**（2026-10-03）：WS-002 目标 / 边界 / AC1–AC7 与阶段裁剪声明确认。
2. **Q14 需求关闭规则**（§6，2026-10-03 确认）：有子事项且子事项全部终态 → 需求可关闭（部分交付并入终态即算）；`discarded` 为显式放弃。本设计保留「子事项非空」守卫，避免空子集被 `∀` 空真误判为关闭。
3. **运行时绑定落点**（§4，2026-10-03 确认）：需求级运行时绑定**另立** `.dsh/requirements/local.json`，与事项级 `.dsh/workstreams/local.json` 对称；`.gitignore` 增对应忽略行（落地属任务阶段）。
4. **WS-005 规划确认**（2026-10-03）：需求 `state` 仅人工判断，`split` / `closed` 派生；迁移 5 张需求卡（去掉 `state`）。

**待验收 sign-off**：交付物 = 本设计稿 + `docs/README.md` 索引登记。

**遗留待确认**（不阻塞 sign-off）：

4. **`delivery.outcome` 的定位**（§5）：确认「交付追踪写入的派生缓存、禁止手写」这一口径；既有 `WS-001` / `WS-003` 不追溯改。
