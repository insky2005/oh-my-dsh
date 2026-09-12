---
title: 模块：审查面板（Review / 变更审计）
tags: [module, review, audit, session-log, zstd, read-only]
updated: 2026-09-12T06:40:00Z
sources: [platforms/macos/src/ReviewPanel.swift, platforms/macos/src/ReviewLogModel.swift, platforms/macos/src/main.swift, core/lib/review-log.js, core/bin/ohmy-core.js, core/index.js, core/tests/review-log.test.js, tests/review-panel/, docs/review-panel-design.md, README.md]
manual: false
---

# 模块：审查面板（Review / 变更审计）

**完全只读**，回答「这个会话里代理到底改了哪些文件、改成什么」：直接读 dsh 自己落盘的会话日志，**不写任何文件、不调写接口、不改 dsh 源码**。按 **会话 → 对话(turn) → 文件 → 变更内容** 树展示，每层可展开/收起。合并自 PR #44 `feature/review-panel`（2026-09-12，v1.15.0 开发线）；设计与覆盖矩阵见 `docs/review-panel-design.md`。

不做回滚/接受拒绝：只读数据里没有可回滚的完整信息（顶层 `write`/`edit` 的工具结果只留「Updated file」，落盘的 `meta.diffs` 是带 3 行上下文的 hunk，新建文件更是空数组）。

## 组成

| 文件 | 规模 | 职责 |
|---|---|---|
| `core/lib/review-log.js` | 655 行 | 审计折叠：会话日志定位、Zstandard 多帧扫描/解码、三类记录合并、turn 归属、shell 启发式、诊断收集（经 `core/index.js` 导出） |
| `core/bin/ohmy-core.js` | — | CLI 入口 `review sessions` / `review audit` / `review audit-file`（与面板共用同一 core 实现） |
| `platforms/macos/src/ReviewLogModel.swift` | 353 行 | 纯 Foundation 展示模型：JSON 解码 + 文件分组 / turn 分组 / diff 折叠 / 过滤 / 标签（无 AppKit，可无头测试） |
| `platforms/macos/src/ReviewPanel.swift` | 1031 行 | `ReviewPanelController`：右栏 UI、按需审计、缓存、跟随 dsh web、主题与 L10n |

## 数据来源：dsh 会话日志的三类记录

日志位于 `$DSH_HOME/sessions/<workspace-slug>/<session-id>/session.jsonl[.zstd]`（一行一事件），审计只读其中三类（详见设计文档 §2–§3）：

| # | 记录 | 提供什么 |
|---|---|---|
| 1 | `tool/result` → `data.meta.diffs` | 已应用 hunk（`{path, oldText, newText}`，3 行上下文）——**仅顶层** `write`/`edit` |
| 2 | 顶层 `tool/call` / 嵌套 `tool/code-dispatch-start` → `arguments` | 精确请求参数（`edit` 的 old/new string、`write` 全文），覆盖顶层 + 嵌套 |
| 3 | `tool/call name=bash`（含嵌套） | 仅命令文本（**没有**前后内容），按「可能写文件」启发式标记 |

展示标签：`已应用`（结果 hunk）/`参数还原`（由参数还原，如 `run_code` 嵌套调用）/`全文写入`、`新建`（只记录写入内容）/`嵌套调用`；`bash` 直改与**失败/被拒调用**各自单列（不计入变更统计）。

## 为什么审计逻辑在 core（Node）而不是 Swift

dsh 的 JSONL 后端把日志写成**多个独立可解压的 Zstandard 帧拼接**（每批落盘一帧）：一次性解压只拿得到第一帧；Apple Compression 框架在这套 SDK 上无 zstd 算法，Swift 侧无法解码；而内置 Node 运行时（v24）提供 `zlib.zstdDecompressSync`。因此 `core/lib/review-log.js` 自带 `scanZstdFrames()` 只走帧头/块头逐帧解码，**不依赖 dsh 私有模块**（少一个升级耦合面）；壳层经 `CoreBridge.run(…, preferBundledNode: true)`（main.swift）**优先用内置 node** 调用——用户自装 Node 18/20 没有 zstd。

## 契约（core CLI）

```
node core/bin/ohmy-core.js review sessions [--workspace <dir>] [--limit <n>] [--dsh-home <dir>]
node core/bin/ohmy-core.js review audit <sessionId> [--workspace <dir>] [--dsh-home <dir>] [--max-entries <n>]
node core/bin/ohmy-core.js review audit-file <path.jsonl[.zstd]> [--workspace <dir>] [--max-entries <n>]
```

- `sessions` → `{sessions:[{id, dir, file, cwd, createdAt, parentSession, delegationDepth, compressed, sizeBytes, mtimeMs}], total, diagnostics}`（只解第一帧读会话头，很快）；
- `audit` → `{session, turns, entries, stats, diagnostics}`；entry 字段：`tool`/`surface`（`top`|`nested`）/`status`（ok|error|unknown）/`category`（diff|args|content|bash|null）/`path`/`pathAbs`/`hunks`/`added`/`removed`/`command`/`suspicion`/`note`；`stats` 含 files/added/removed/nested/bashCalls/bashSuspect/failed；
- **读取失败一律显式化**：帧解压失败、尾部未完成帧、无法解析的 JSONL 行都进 `diagnostics`，面板原样列出（沿用 `[workspace-store]` 约定的「读不懂要报出来」）。

## 面板行为

- **按需审计**：会话列表只读日志头——打开面板便宜；某个会话第一次展开时才跑一次 `review audit`（超时 180s），结果进内存缓存（`audits`），不重复读；
- **跟随 dsh web**：web 切会话 → 面板按 **sessionId** 展开同一会话（不按工作区过滤，跨工作区也能定位）并标为当前会话；工作区变化只重列会话，**不清审计缓存**；同工作区内切换会话不再重列（消除闪烁）；加载中的再次 reload 会排队重跑（不再丢弃请求）；
- **会话标题**：经 `DshWebRPC` 的 `session.list` 读 dsh web 标题（打开面板时读取，带失败重试；无标题显示 dsh web 的「新会话 / New Session」占位，再不行回退短 id）；
- 工具栏：全部展开 / 全部收起 / 只看可疑命令（默认开）；`⌥⌘R` 与活动栏「审查」图标（symbol `doc.text`）切换，`rightPanelKind` 持久化 `"review"`；
- 内容区与圆角块跟随浅/深主题（配方同 Channel 面板项目视图），diff 用 systemGreen/systemRed；单条 diff 上限 200 行（超出提示「…还有 %d 行」）；
- 主线程外的 core 调用 + `prewarm()`（页面加载完/工作区就绪即预热会话列表），避免首次打开空面板。

## 已知边界

`bash` 直改（`sed -i`/`>`/`rm`/`git checkout`）内容不可得，只标注「需人工核对」；日志尚未落盘的尾部（批处理窗口内）看不到；`meta.diffs` 为空时保守标 `新建`；dsh 之外的手段改的文件不在日志里；不提供跨会话/跨工作区汇总。

## 测试与 QA

- `node --test core/tests/review-log.test.js`：**17 用例**（帧扫描、多帧解码、撕裂帧、三类记录合并、失败条目、shell 启发式、路径相对化、会话发现；无 zstd 的 Node 上相关 3 项自动 skip——本机 Node v20.19.6 实测 14 通过 / 3 跳过）；
- `tests/review-panel/run.sh`：Swift 模型层无头单测（64 项通过，JSON 解码 / 文件分组 / turn 分组 / diff 折叠 / 过滤 / 标签）；已接入 `.github/workflows/ci.yml` 与 `scripts/local-ci.sh`；
- QA 钩子：`DSH_REVIEW_TEST=1` 启动即打开面板（**故意放最后**，`DSH_UI_DEBUG=1` 下也生效）；`DSH_REVIEW_TEST_PATH=<dir>` 固定审计的工作区；`--ui-debug` 下面板层级 dump 深度 8（与浏览器面板同级）+ 渲染完成后二次快照 `panel-review-loaded-debug.png`。
