# 会话快照与回退（Session Snapshots）

> 状态：1.16.2 开发线实现中（`release/1.16`）。内置 dsh 保持 `0.1.2-rc.1`，本功能是"升级 dsh 前的安全网"。
> 设计文档：`docs/session-snapshot-rollback-design.md`（含九类场景演绎与成本实测）。

## 为什么需要

dsh 按 **Session 格式世代**命名会话日志（世代 0 = `session.jsonl`，0.1.5 起新建会话写 `session.v3.jsonl`，压缩加 `.zstd`）。
升级 dsh 时，**打开/写入过的会话会被迁移**（以 snapshot 模式打开会补写 `session/end-seed`），而**上游只有升级链、没有降级通道**：
回退到旧 dsh 后，新世代会话对它完全不可见、被迁移的老会话停在迁移点，若继续用旧 dsh 还会造成"两个世代互相竞争、两边都读不全"。
所以壳层在任何版本组合变化**之前**留快照。

## 数据与状态

| 位置 | 内容 |
|---|---|
| `$DSH_HOME/shell/snapshots/<id>/` | 数据快照：`sessions/ + storages/` + `meta.json`（id = `<utc>_app<A>_dsh<D>_<reason>`） |
| `$DSH_HOME/shell/snapshots/trees/<dshVersion>/` | 树池：`runtime/dsh` 整树，按 dsh 版本去重 |
| `$DSH_HOME/shell/snapshots/quarantine/<stamp>/` | 回退时移出的"新世代"会话 + `quarantine.json` 清单（不删除） |
| `$DSH_HOME/shell/dsh-state.json` | `dataCombo`（唯一判断字段）+ 只追加 `history` + `rollback` + `upgradePinned` |
| `$DSH_HOME/shell/rollback-journal.json` | 回退事务日志（六步，完成后清除；崩溃后可续做/撤销） |

`shell/`、`credentials*`、`channels/`、`browser*/`、`skills/` 等**不进快照**。


## 踩坑与守卫（2026-09-23 实测，都是"一次污染 = 永久失效"型）

1. **只把"已经证明能启动"的树收进池**。抓树**不在 spawn dsh web 之前**，而是**页面加载完成之后**
   （`captureRuntimeTree()` 挂在 `didFinish`，一次/启动）。否则"构建坏了但 App 起来了"会把一棵**从没启动成功过**的树存进池，
   回退时再把坏树换回来（用户实测踩到：升级 0.1.5 正常 → 回退后启动报同一个错）。
2. **闭包校验（`--expected-lock`）**。仓库为每个受支持 spec 提交一份已知可启动的闭包锁
   `platforms/macos/runtime-locks/<spec>/package-lock.json`（随 App 分发）；抓树/换树时与它比对指纹：
   不一致的树**拒绝入池**（池里已有的会被替换），回退时**拒绝换入**并回报 `needsTreeInstall`（改用 lock `npm ci`）。
   根因是 dsh 用 caret 范围声明 cordis 工具链（`docs/dsh-version-impact.md` R8：hmr 1.0.19 会让 0.1.2-rc.1 起不来）。
3. **构建期启动冒烟**：`build-app.sh` 的 `smoke_runtime()` 装完树就起一次 `dsh web`，失败即构建失败——「构建成功」不等于「产物能用」。

## 代码锚点


- `core/lib/snapshot.js`：纯决策（触发判定 / 回退计划 / 裁剪保护 / 树池判定 / journal 状态机）；
- `core/lib/snapshot-io.js`：落盘（clonefile 优先、树池、隔离、裁剪、原子写）；
- `core/bin/ohmy-core.js` 的 `snapshot` 子命令（launch / list / status / create / plan-rollback / rollback / finish-rollback / delete）；
- `platforms/macos/src/main.swift`：`prepareSessionSnapshot()`（spawn dsh web 之前）、`snapshotBeforeUpgrade()` / `adoptComboAfterUpgrade()`（升级事务）、`openSessionSnapshots` / `confirmAndRollback`（菜单与回退并退出）；
- `platforms/macos/src/SnapshotModel.swift` + `SnapshotWindow.swift`：窗口与数据模型；
- `platforms/macos/src/main.swift` 另外三处：`captureRuntimeTree()`（页面加载后抓树）、`snapshotBeforeUpgrade()` / `adoptComboAfterUpgrade()`（升级事务）、`confirmAndRollback()`（回退并退出，含池缺失时用 lock 补装）；
- `platforms/macos/runtime-locks/`（提交的闭包锁）+ `build-app.sh` 的 `smoke_runtime()`（构建期启动冒烟）；
- 测试：`core/tests/snapshot.test.js`、`core/tests/snapshot-io.test.js`、`tests/snapshot-rollback/run.sh`、`tests/snapshot-panel/run.sh`。

## 相关

- `docs/dsh-version-impact.md` R7（会话日志世代命名）与 §4.5（0.1.5 升级复盘）；
- `docs/plans/dsh-015rc2-compat-audit.md`（0.1.5 兼容审计：升级待本功能上线后执行）。
