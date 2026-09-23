# 会话快照与回退（Session Snapshot & Rollback）设计

> 状态：设计定稿（2026-09-23）。按「保命线」节奏实施——**1.16.2 只做安全网，内置 dsh 保持 0.1.2-rc.1**；
> 内置 dsh 的升级（0.1.2 → 0.1.5）推迟到快照/回退上线之后再执行（审计见 `docs/plans/dsh-015rc2-compat-audit.md`）。
> 关联：`docs/dsh-version-impact.md`（R7 会话日志世代命名、§4.5 复盘）、`docs/release-process.md`。

## 1. 为什么需要它（问题陈述）

新版 dsh 会给**会话日志**按 **Session 格式世代**命名：世代 0 是 `session.jsonl`，之后每代带 `.vN`（`session.v3.jsonl`），
压缩再加 `.zstd`。**dsh 0.1.5 起新建会话直接写 `session.v3.jsonl.zstd`**；被迁移过的老会话会把原来的 `session.jsonl.zstd`
留成**冻结归档**、活日志换成新世代名。实测（0.1.2-rc.1 → 0.1.5-rc.2）：

| 事实 | 证据 |
|---|---|
| 老 dsh 只认世代 0 | `SESSION_FORMAT_VERSION = 0`、`logPath() = session.jsonl[.zstd]` |
| 0.1.5 新建会话写世代 3 | 新会话目录里**只有** `session.v3.jsonl.zstd` |
| 迁移由「打开/写入」触发，不是启动触发 | 启动、`session/list`、`session/page` 都不迁移；一次 `session/prompt`（哪怕失败）立刻出现 v3；代码里会话以 snapshot 模式打开会补写 `session/end-seed`（`dsh-session/lib/index.js`） |
| 回退后：新会话完全不可见 | 同一 home：新 dsh 列出 7 条会话，老 dsh 只列出 5 条 |
| 回退后：老会话停在迁移点 | 老 dsh 的 cursor = 17（冻结归档），活日志已到 20 |
| 回退后继续用老 dsh → 世代分叉 | 它追加到旧世代文件（16 KB → 32 KB）；再升回 0.1.5 时该会话读出**空**（`asOfSeq = -1`） |
| 上游没有降级通道 | 只有 `v0→v1→v2→v3` 的升级链，无 `v3→v2` |

**结论**：升级 dsh 是不可逆的数据迁移。要用户敢升级，壳层必须提供「升级前自动快照 + 出问题一键回退」。

## 2. 目标与非目标

**目标**
- 内置 dsh（或 App）版本变化时，**在新 dsh 第一次启动之前**自动留下可回退的快照；
- 用户点「回退并退出」后，会话数据（必要时连内置 dsh）回到目标快照的状态，且**回退本身可撤销**；
- 全流程离线、秒级、原子，且**永不删除用户数据**（用隔离代替删除）。

**非目标**
- 不是备份系统（同卷、有配额、不替代 Time Machine）；
- 不回退 App 二进制（pkg 装不了旧版；App 版本回退仍需重装旧 pkg，UI 负责告知版本与下载链接）；
- 不合并或自动搬回隔离区会话（第二期再评估）；
- 不动 dsh 源码，不改 dsh 的任何数据格式。

## 3. 资源模型

| 资源 | 内容 | 位置 | 生成时机 | 实测成本 |
|---|---|---|---|---|
| **数据快照** | `sessions/` + `storages/` | `$DSH_HOME/shell/snapshots/<id>/` | 启动前（组合变化）、升级事务、回退前现场 | 306 MB / 246 文件 → clonefile **0.124 s**、实占≈0 |
| **树池** | `runtime/dsh` 整棵树，**按 dsh 版本去重** | `$DSH_HOME/shell/snapshots/trees/<dshVersion>/` | 每次启动自查：当前版本不在池里则 clone | 256 MB / 24,872 文件 → **5–6 s**、实占 ~14 MB（**每个版本只一次**） |
| **回退现场** | 回退前的 `sessions/storages`（使回退可撤销） | 同数据快照，reason=pre-rollback | 回退事务第 ② 步（rename，瞬时） | 0 |
| **隔离区** | 快照里不存在的会话目录（新世代新建的） | `$DSH_HOME/shell/snapshots/quarantine/<ts>/sessions/…` | 回退事务第 ③ 步 | 0（rename） |
| **状态** | dataCombo / history / rollback | `$DSH_HOME/shell/dsh-state.json` | 每次快照/回退 | 几十字节 |

**明确排除**（不进快照、不回退）：`shell/`（我们自己的配置，含 `dsh-web.json` 里的 **launch token**，绝不复制）、
`credentials*` / `profiles` / `settings.yaml`（密钥与账号）、`channels/`（通道绑定与消息状态，回退会丢绑定）、
`browser/`、`browser-dev/`（CEF profile，约 292 MB 且与世代无关）、`skills/`（无世代耦合）、`attachments/`、`tokens/`。

## 4. 文件布局与结构

```
$DSH_HOME/shell/
  dsh-state.json                      # 唯一参与判断的状态文件
  snapshot.lock                       # 快照/回退互斥锁
  rollback-journal.json               # 回退事务日志（完成后删除）
  snapshots/
    <ts>-app<A>-dsh<D>-<reason>/      # 数据快照（reason: bootstrap|combo-change|dsh-upgrade|pre-rollback）
      meta.json
      sessions/…                      # clonefile
      storages/…
    trees/<dshVersion>/               # 树池（每个 dsh 版本一份）
    quarantine/<ts>/sessions/…        # 回退时移出的「新世代」会话，只增不删
```

**meta.json**

```json
{
  "id": "20260923-101500-app1.16.2-dsh0.1.2-rc.1",
  "createdAt": "2026-09-23T10:15:00Z",
  "reason": "combo-change",
  "fromCombo": { "app": "1.16.0", "dsh": "0.1.2-rc.1" },
  "forCombo":  { "app": "1.16.2", "dsh": "0.1.2-rc.1" },
  "dshTree": null,
  "counts": { "sessions": 246 },
  "logicalBytes": 322122547,
  "restoredFrom": null
}
```

- `dshTree`：**只有 `fromCombo.dsh != forCombo.dsh` 时才非 null**（纯 App 版本变化不需要树）；
- `restoredFrom`：这份快照若是「回退产生的基线」，记录它由哪份快照回退而来（UI 标注用）。

**dsh-state.json**

```json
{
  "version": 1,
  "dataCombo": { "app": "1.16.2", "dsh": "0.1.2-rc.1" },
  "lastLaunch": { "combo": { "app": "1.16.2", "dsh": "0.1.2-rc.1" }, "at": "…" },
  "rollback": { "snapshot": "<id>", "at": "…", "pending": false },
  "upgradePinned": { "dsh": "0.1.2-rc.1", "at": "…", "reason": "rollback" },
  "history": [
    { "at": "…", "action": "snapshot", "snapshot": "<id>", "fromCombo": {…}, "forCombo": {…} },
    { "at": "…", "action": "rollback", "snapshot": "<id>", "toCombo": {…} }
  ]
}
```

**判断规则只有一条：**

```
启动前：currentCombo != dataCombo  ->  打快照  ->  dsh 起来后 dataCombo = currentCombo
回退时：dataCombo = 目标快照的 fromCombo（+ rollback 记录 + 钉住自动升级）
```

> 为什么不用「组合栈」：栈在「回退到非最近一份」「回退后装回旧版 App」「写到一半崩了」三种情况下都会与数据错位；
> 单字段 + 快照自身的 fromCombo/forCombo 才是幂等的。history 只追加、只给人看。

## 5. 触发时机

| 触发 | 条件 | reason |
|---|---|---|
| 引导 | 不存在 `dsh-state.json`（功能上线后第一次启动） | bootstrap |
| 组合变化 | `currentCombo != dataCombo`（含只变 App 版本） | combo-change |
| 升级事务 | App 内升级 dsh 前（`DSHUpdater.apply()` 之前） | dsh-upgrade |
| 回退现场 | 用户点「回退并退出」时 | pre-rollback |

**顺序铁律**：`回收上次残留的 dsh web -> 打快照 -> 再 spawn dsh web`。dsh 一起来就可能写盘（打开会话写 `session/end-seed`），
晚一步就抓不到干净状态。**不做「每次启动都打」**：那会把「升级前那一份」很快挤出 3 份配额。

## 6. 树池的填充与补齐

- **惰性填充 + 装机时机**：每次启动自查 `trees/<当前 dsh 版本>` 是否存在，缺则 `cp -cR` clone（5–6 s / ~14 MB，每版本一次）。
  必须这样做，因为**装新 pkg 会把旧 bundle（含旧 `runtime/dsh`）整体替换掉**，「升级前抓旧树」来不及。
- **只收"已经证明能启动"的树**（2026-09-23 实测踩坑后加）：抓树**不在 spawn 之前**，而是**页面加载完成之后**
  （`captureRuntimeTree()` 挂在 `didFinish`，一次/启动；`snapshot launch` 用 `--no-tree` 只做数据快照）。
  否则"构建坏了但 App 起来了"的状态下，池里会存下**从没启动成功过**的树，回退时把坏树换回 bundle —— 表现就是回退后启动报同一个错。
- **闭包校验（`--expected-lock`）**：仓库为每个受支持 spec 提交一份已知可启动的闭包锁
  （`platforms/macos/runtime-locks/<spec>/package-lock.json`，随 App 分发到 `Contents/Resources/runtime-locks/`）。
  抓树时：与提交 lock 指纹不一致的树**拒绝入池**，池里已有的不一致副本会被替换；
  换树时：池中那棵若与提交 lock 不一致则**拒绝换入**，回报 `needsTreeInstall`，让壳层用 lock 重新 `npm ci`。
  根因是 dsh 用 caret 范围声明 cordis 工具链（见 `docs/dsh-version-impact.md` R8）。
- **补齐（针对跳版本用户）**：升级/回退事务里若目标版本不在池里（例如用户从 1.16.0 直跳带 0.1.5 的版本），
  用 `npm ci` 从提交的 lock 装一份进池（联网约 20 s；没有 lock 的版本退回 `npm install`）；失败则该快照标「仅可回退数据」。

## 7. 回退事务（原子性）

```
① 停自拉起的 dsh web（含回收上次残留）；取 snapshot.lock
② 现场快照：rename sessions/ -> snapshots/<pre-rollback id>/sessions（瞬时，使回退可撤销）
③ 恢复：从目标快照 clone sessions/ + storages/ 到 sessions.restoring/
        -> 目标快照里不存在的会话移入隔离区 -> rename 交换到位（原子）
④ 换树（仅当目标快照的 dshTree != 当前树）：
        当前树 rename 回池（若该版本缺） -> trees/<目标版本> rename 成 runtime/dsh
        池里没有 -> npm install 兜底；再失败 -> 只完成数据回退并明确告知
⑤ 写 dsh-state.json：dataCombo = 目标 fromCombo；rollback 记录；history 追加；钉住自动升级
⑥ 删 journal、释放锁，退出 App
```

**journal 与崩溃恢复**：每步写入 `rollback-journal.json`。启动自检发现 journal 未完成，或
`dataCombo.dsh != 实际 runtime/dsh 版本`，则显示「上次回退未完成」+ 两个按钮（**完成回退** / **撤销回退**），绝不静默继续。

## 8. 回退的两种路径与兼容闸门

| 路径 | 内容 | 适用 |
|---|---|---|
| **B｜数据 + 内置 dsh** | 恢复数据 + 换回旧树（rename） | 目标快照的 dsh 版本在池里（或有网可补），且**不低于壳层最低支持版本** |
| **A′｜只回数据** | 恢复数据 + 提示重装旧版 App（给出该快照的 app 版本与 release 链接） | 问题是 App 侧、或树不可得、或低于兼容闸门 |

**兼容闸门**：目标 dsh 低于壳层声明的「最低支持版本」时禁用 B（只允许 A′）——壳层的双面适配与全世代日志读取只保证向后**一代**。

**钉住自动升级**：回退后必须写 `upgradePinned` 并把 `autoUpgradeDsh` 置 false，否则 24 h 后自动升级会把刚降下来的 dsh 又升回去；
设置面板显示「已固定在 dsh X（回退中）」并提供「恢复自动升级」。

## 9. 隔离区语义

- 回退时，目标快照里**不存在**的会话目录（快照之后新建的、属于新世代的会话）**移入 `quarantine/<ts>/`，不删除**；
- 目标快照里存在的老会话：还原其文件（v0 归档），并删除其新世代文件——否则会留下「世代分叉」那种两边都读不全的状态；
- 隔离内容**不会自动回灌**；第二期可提供「导入隔离会话」（把 `session.vN.*` 搬回 `sessions/`，dsh 直接可读）。

## 10. 裁剪与保护

- 保留最近 **3** 份数据快照；裁剪时**保护**：
  1. `dataCombo` 引用到的（最近一次回退目标）；
  2. `forCombo == 当前运行组合` 的那一份（当前版本出事时最该回退到的点）；
  3. 正在被回退进程使用的目标快照。
- 树池：保留「被保留快照引用到的版本 + 当前安装版本」，其余删除；
- 隔离区：默认不限额（安全优先），设置里显示占用并提示手动清理；
- 磁盘不足或 clonefile 不可用（跨卷）：**不阻塞启动**，记 `app.log` 警告 + UI 提示「本次未创建快照，回退能力暂不可用」。

## 11. 关键场景（实施与测试对照表）

| # | 场景 | 数据 | 树 | 状态 | 下次启动 |
|---|---|---|---|---|---|
| 1 | 功能上线（1.16.0 -> 1.16.2，dsh 不变） | 打 bootstrap 快照 | 池新增当前版本 | data=1.16.2/D0.1.2 | 一致 -> 不打 |
| 2 | App 变、dsh 不变 | 纯数据快照（dshTree=null） | **不动** | 更新 data | 一致 -> 不打 |
| 3 | 升级 dsh（0.1.2 -> 0.1.5） | dsh-upgrade 快照（引用 T0.1.2） | 升级后补 T0.1.5 | 更新 data | 一致 -> 不打 |
| 4 | 出问题 -> B 回退 | 现场快照 + 恢复 + 隔离 | 换回 T0.1.2 | data=fromCombo + 钉住 | 一致 -> 不打 |
| 5 | 怀疑 App 问题 -> A′ | 同上 | 保持 | data=fromCombo | 重装旧 App 后一致 -> 不打；仍用新版 -> 打一份基线 |
| 6 | 回退到非最近一份（跨级） | 现场快照 + 恢复该份 | 换回该份的树 | data=该份 fromCombo | 同上（不 pop 栈，故不错位） |
| 7 | 回退中途崩溃 | 半完成 | 可能半完成 | journal 未完成 | **自检提示 + 一键续做/撤销** |
| 8 | 池里无目标树（跳版本 / 手动删池） | 正常 | npm 补齐；失败则标「仅数据」 | 正常 | 正常 |
| 9 | dev 隔离 | `~/.dsh-dev` 独立 snapshots/池/state | 同左 | 同左 | 与正式版互不影响 |

## 12. UI 与文案（中英双语，遵循 L10n.table）

- 设置菜单 →「会话快照…（Session Snapshots…）」
  - 列表：时间 / App 版本 / dsh 版本 / 原因 / 大小 / 是否可回退内置 dsh；
  - 操作：**回退到此快照并退出（Roll Back to This Snapshot and Quit）**、在 Finder 中显示、删除快照；
  - 顶部状态：如「已回退到 …；内置 dsh 已固定在 0.1.2-rc.1」。
- 回退确认框：列出「将被恢复 / 将被移入隔离区 / 将换回的内置 dsh 版本」三行摘要 + 二次确认。
- 回退后首次启动提示条：`上次已回退到 <快照>；如需完全回到旧版请安装 oh-my-dsh <版本>`
- 升级前提示（手动/自动共用）：`升级会改写会话日志格式，本应用会先自动创建快照；回退可将会话数据与内置 dsh 一并还原`
- 快照失败/不可用时：`本次未创建快照，回退能力暂不可用（详见日志）`

## 13. 测试清单

**core（无头，node --test）**
1. 快照 id / meta 命名与解析（含 reason，与 `dshTree=null` 的纯数据快照）；
2. 组合比较与触发判定（`currentCombo != dataCombo`、bootstrap、只变 App）；
3. 回退计划计算：给定目标快照 + 当前目录树 -> 输出「clone / 删除新世代文件 / 移入隔离 / 换树」的操作清单（纯函数，不落盘）；
4. 裁剪与保护（3 份 + 三条保护规则）；
5. journal 状态机：每步进退、崩溃点恢复（「完成回退」/「撤销回退」的目标状态）；
6. 排除清单：`shell/`（含 token 文件）、`credentials*`、`channels/`、`browser*/` 一律不进快照；
7. 树池命中判定与「缺版本 -> 需 npm 补齐」的降级路径。

**壳层（tests/*/run.sh，真实 AppKit / 真实文件系统）**
8. 启动时序：组合变化时快照**先于** spawn dsh web（用假 dsh 断言调用顺序）；
9. 「回退并退出」按钮：执行事务 -> 写 state -> 退出（假 dsh + 临时 home）；
10. 启动自检：journal 未完成 / dataCombo 与树版本不一致 -> 显示提示条而不是静默启动。

**开发版端到端**
11. `DSH_HOME=~/.dsh-dev`：打快照 -> 升级 dsh（npm）-> 会话被迁移 -> 回退 -> 重开：老会话可读、新会话在隔离区、dsh 树回到旧版本。

## 14. 实施分期

| 期 | 内容 |
|---|---|
| P1（本次） | core 纯模型 + 单测（第 13 节 1–7）；壳层菜单 / 状态条 / 启动时序（8–10）；开发版端到端（11） |
| P2 | 「导入隔离会话」、快照落外部卷、占用统计与配额、回退备注 |
| P3 | 快照功能稳定后执行内置 dsh 升级（0.1.5+），并把「升级前强制快照」作为升级路径的唯一实现 |

## 15. 与 release 节奏的关系

| 版本 | 线 | 内容 | 内置 dsh |
|---|---|---|---|
| ~~1.16.1~~ | patch | 已撤回（Release + tag 已删） | — |
| **1.16.2** | `release/1.16` | **本设计实现** + 会话日志世代命名适配 + QA 钩子 | **0.1.2-rc.1（不变）** |
| 1.16.3 | `release/1.16` | 内置 dsh 推进（建议等上游 0.1.5 转正式版） | 0.1.5 |
| 1.17.0 | `main` | composer 引用 + 本功能回并 + 开发线其余改动 | 跟随 1.16.3 |

铁律：**`main` 的 `DSH_PACKAGE_SPEC` 在本功能并入 main 之前保持 0.1.2-rc.1**。

## 16. 开发版实测记录（2026-09-23，`DSH_DEV_BUILD=1`）

环境：开发版 App（内置 dsh `0.1.2-rc.1`）× **工作区内的独立 home**（`DSH_HOME=<repo>/.tmp/…/dsh`），fixture 只从开发隔离目录
`~/.dsh-dev` 复制 2 条会话 + `workspace.json`——**未指向也未修改 `~/.dsh` 的生产数据**（实测结束时其"新世代会话数"仍为 0）。

| 步 | 动作 | 观测结果 |
|---|---|---|
| 1 | 首次启动开发版 | 启动钩子打出 `bootstrap` 快照（2 条会话 / 663 KB）+ 树池 `trees/0.1.2-rc.1`；`dsh-state.json` 写入 `dataCombo = 1.16.2 / 0.1.2-rc.1` |
| 2 | 把 bundle 内置 dsh 升到 `0.1.5-rc.2`（模拟装新 pkg / 应用内升级） | —（旧树此刻从磁盘消失，但已在池里） |
| 3 | 再次启动 | 组合变化 → **升级前快照** `combo-change`（`from 0.1.2-rc.1 → for 0.1.5-rc.2`，`dshTree = trees/0.1.2-rc.1`）；树池补齐 `0.1.5-rc.2`；`dataCombo` 更新为新组合 |
| 4 | 通过 RPC 打开老会话（迁移的触发点） | 该会话出现 `session.v3.jsonl.zstd`，v0 归档保留 |
| 5 | 停 App → 执行回退（等同"回退并退出"） | 计划 `mode=B / 恢复 2 条 / 删新世代 2 个 / 换树 swap`；执行后 **bundle 内的 dsh 被物理换回 `0.1.2-rc.1`**、会话恢复为仅 `session.jsonl.zstd`、`dataCombo` 回旧组合且 `upgradePinned = 0.1.2-rc.1`、journal 清空，并留下 `pre-rollback` 现场快照（可撤销） |
| 6 | 再次启动 | **不新增快照**（组合与 `dataCombo` 一致）；树池自动补回 `0.1.2-rc.1`（另有 `.displaced-*` 保留被换下来的那棵树）；审查读取器仍能列出两条会话 |

**结论**：「快照 → 升级 dsh → 会话被迁移 → 回退 → 重开」在真实开发版上闭环，且回退把**内置 dsh 一起带回旧版本**（path B，离线 rename）。

### 16.1 用户真机复测（2026-09-23，同一开发版）

- **第一次**：启动 → 升级 dsh 到 0.1.5 → 重启（正常）→ 回退到升级前快照 → 重启 → **失败**（`user patch-layer watching requires the Cordis HMR service`）。
  根因见 §6：回退把池里那棵**从没启动成功过的漂移树**换回了 bundle（池是在"构建坏了但 App 起来了"时抓的）。
- **修复后**（提交 `4c13f8f`：抓树改到页面加载后 + `--expected-lock` 闭包守卫 + 补装走 lock）：
  用户复测「启动 → 升级 → 重启 → 回退 → 重启」**全部正常**。
- 结论：树池的信任模型必须是「**这棵树启动成功过**」+「**闭包等于提交的 lock**」，两者缺一都会把一次污染变成永久故障。
