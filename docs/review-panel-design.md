# 审计面板设计（Review / change audit，只读）

> 目标：在**不修改 dsh 源码、不写任何文件**的前提下，回答「这个会话里代理到底改了哪些文件、改成什么」。
> 实现：`core/lib/review-log.js`（审计折叠）+ `platforms/macos/src/ReviewLogModel.swift`（展示模型）+
> `platforms/macos/src/ReviewPanel.swift`（右栏面板）。

## 1. 目标与非目标

| | 内容 |
|---|---|
| **目标** | 只读审计：按会话 → 文件 → 逐次改动列出变更内容与来源，并显式标出**没有**结构化记录的部分 |
| **非目标** | 接受/拒绝（回滚）、编辑、重新应用、任何写操作 |

**为什么不做回滚**：只读数据里没有可回滚的完整信息——顶层 `write`/`edit` 的工具结果里，模型侧只留
`<content>Updated file</content>`（`dsh-tool-fs` 的 `formatWriteOutput`），`before`/`after` 全文不落盘；
落盘的 `meta.diffs` 是**每个 hunk 带 3 行上下文**的片段，新建文件更是空数组。要支持回滚必须另加一层
文件快照（壳层 FSEvents 或 dsh 插件 hook `ctx.fs`），属于独立课题。

## 2. 数据来源：dsh 会话日志的三类记录

日志位于 `$DSH_HOME/sessions/<workspace-slug>/<session-id>/session.jsonl[.zstd]`，一行一个事件，事件类型见
`dsh-session/lib/types/known-event-types.js`。审计只读其中三类：

| # | 记录 | 提供什么 | 覆盖范围 |
|---|---|---|---|
| 1 | `tool/result` → `data.meta.diffs` | 已应用的 hunk（`{path, oldText, newText}`，3 行上下文） | **仅顶层** `write`/`edit`（`dsh-tools/lib/index.js` 的 `exec.parent === undefined` 判断） |
| 2 | `tool/call`（顶层）/`tool/code-dispatch-start`（`run_code` 嵌套）→ `arguments` | 精确的请求参数：`edit` 的 `old_string`/`new_string`、`write` 的全文 `content` | 顶层 + 嵌套的 `write`/`edit`/`str_replace_editor` |
| 3 | `tool/call name=bash`（+ 嵌套 `tool/code-dispatch-start name=bash`） | 命令文本（**没有**前后内容） | 所有 shell 调用，按「可能写文件」启发式标记 |

补充：嵌套调用的结果在 `tool/code-dispatch`（`isError` + `content`），顶层结果在 `tool/result`；两者都用于把
条目从「已发起」收敛为「成功 / 失败」。

## 3. 覆盖矩阵（面板实际能看到什么）

| 变更途径 | 记录形态 | 面板展示 |
|---|---|---|
| 顶层 `edit`（含 `str_replace_editor`） | hunk 或参数 | ✅ `已应用` / `参数还原`，含逐行 diff |
| 顶层 `write` 覆盖已有文件 | hunk | ✅ `已应用` |
| 顶层 `write` 新建文件 | `meta.diffs` 为**空数组**（dsh 在 `before === null` 时不投影 hunk） | ✅ 回退到调用参数里的全文，标 `新建` |
| `run_code` 嵌套 `edit`/`write` | 仅参数（无 hunk 元数据） | ✅ `参数还原` / `全文写入`，标 `嵌套调用` |
| subagent（独立子会话） | 子会话里是**顶层**调用 | ✅ 会话下拉里带 `sub` 的条目，hunk 齐全 |
| `bash` 直改（`sed -i` / `>` / `rm` / `git checkout` …） | 只有命令文本 | ⚠️ 单列「shell 命令（无前后内容记录）」，启发式标 `可能写文件` |
| 失败/被拒的调用 | `isError` | ⚠️ 单列「失败的调用（未改动）」，不计入变更统计 |

统计口径：`files`/`added`/`removed` 只累计**成功且带路径**的变更条目。

## 4. 为什么审计逻辑在 core（Node），而不是 Swift

dsh 的 JSONL 后端把日志写成**多个独立可解压的 Zstandard 帧的拼接**（每次落盘一批一帧），所以：

- 一次性解压只能拿到**第一帧**（实测 `zlib.zstdDecompressSync` 对真实日志只返回 214 字节的会话头）；
- Apple 的 Compression 框架在这套 SDK 上**没有 zstd 算法**（`compression_stream_init(…, 0x700)` 返回错误），
  Swift 侧无法自行解码；
- 内置 Node 运行时是 v24，提供 `zlib.zstdDecompressSync`。

因此 `core/lib/review-log.js` 自带 `scanZstdFrames()`（只走帧头/块头，不解压）逐帧解码，**不依赖 dsh 的私有
模块**（避免多一个升级耦合面）；壳层通过 `CoreBridge.run(…, preferBundledNode: true)` 调它——必须优先用内置
运行时，因为用户自装的 Node 18/20 没有 zstd。

## 5. 契约

```
node core/bin/ohmy-core.js review sessions [--workspace <dir>] [--limit <n>] [--dsh-home <dir>]
node core/bin/ohmy-core.js review audit <sessionId> [--workspace <dir>] [--dsh-home <dir>] [--max-entries <n>]
node core/bin/ohmy-core.js review audit-file <path.jsonl[.zstd]> [--workspace <dir>]
```

`review sessions` → `{sessions: [{id, dir, file, cwd, createdAt, parentSession, delegationDepth, compressed, sizeBytes, mtimeMs}], total, diagnostics}`
（只解第一帧读会话头，发现很快）。
`review audit` → `{session, entries, stats, diagnostics}`，其中每条 entry：

| 字段 | 含义 |
|---|---|
| `tool` / `surface` | 工具名；`top`（直接调用）或 `nested`（`run_code` 内部派发） |
| `status` | `ok` / `error` / `unknown`（日志里只有调用没有结果，例如被中断） |
| `category` | `diff`（结果 hunk）/ `args`（参数还原）/ `content`（只有写入全文）/ `bash` / `null`（读类或不识别的调用） |
| `path` / `pathAbs` | 相对工作区 / 绝对路径 |
| `hunks` | `[{oldText, newText}]`，纯新增时 `oldText` 为 `null` |
| `added` / `removed` | 行数（只读展示，不当作 diff 语义） |
| `command` / `suspicion` | shell 命令与其启发式判定（`write-like` / `unknown`） |
| `note` | 记录来源：`applied-hunks`、`args`、`nested-args`、`created-content`、`written-content` … |

**读取失败一律显式化**：帧解压失败、尾部未完成帧、无法解析的 JSONL 行都进 `diagnostics`，面板原样列出，
不静默丢数据（沿用 `[workspace-store]` 那条「读不懂要报出来」的约定）。

## 6. 面板行为（会话 → 对话 → 文件 → 变更内容）

内容区是一棵树，每一层都能展开/收起：

| 层级 | 行内容 | 展开后 |
|---|---|---|
| **会话** | 短 id · 时间 · 大小 ·（子代理/当前会话标记）· 审计后的 `N 文件 · +A −R · 嵌套 X` | 该会话的对话列表 |
| **对话**（turn） | `对话 N` · 该轮用户消息摘要 · `N 文件 · +A −R · shell N · 失败 N` | 文件块 + shell 块 + 失败块 |
| **文件** | 路径 · `+A −R` ·（新建/嵌套徽标） | 每次改动：来源标签 + 逐行 diff |
| **变更内容** | — | 删除行（红 −）/新增行（绿 +），单条上限 200 行 |

- **按需审计**：会话列表只读日志头（便宜）；某个会话第一次展开时才跑一次 `review audit`，
  结果进内存缓存，不重复读；
- **对话可区分**：turn 来自日志的 `turn/start` + `tool/call.turn`；`run_code` 的嵌套派发没有
  自己的 turn，**继承父调用的 turn**（`core/lib/review-log.js` 的 `contextByCallId`），
  轮次标题用 `user/message` 的用户消息做摘要；
- 工具栏：`全部展开` / `全部收起` / `只看可疑命令`（默认开）；**没有会话下拉**——会话在树的第一层；
- **跟随 dsh web**：web 切会话 → 面板展开同一 sessionId（按 id 解析，**不**按工作区过滤：
  跨工作区的会话也能定位），并把它作为当前会话标记；工作区变化只重列会话，不清审计缓存；
- 请求不会丢：加载中的再次 `reload` 会被排队重跑（此前用 `guard !isLoading` 直接丢弃，
  正是"面板显示别的会话数据"的根因）；
- 内容区与圆角块**跟随主题**（浅色：白底 + 浅蓝会话块；深色：深色表面 + 暗蓝会话块——配方与 Channel 面板项目视图一致）；
  正文与图标用 AppKit 语义色（`labelColor`/`secondaryLabelColor`/`tertiaryLabelColor`/`separatorColor`），diff 用 `systemGreen`/`systemRed`，
  切换主题即时生效（语义色在绘制时解析，视图无需重建）；
- 面板**完全只读**：没有按钮会写盘或调用写接口。

## 7. 测试与 QA

- `node --test core/tests/review-log.test.js`：帧扫描、多帧解码、撕裂帧、三类记录的合并、失败条目、
  shell 启发式、路径相对化、会话发现（zstd 相关用例在无 zstd 的 Node 上自动 skip，保证 CI Node 20 也能跑）；
- `tests/review-panel/run.sh`：Swift 模型层（JSON 解码、文件分组、diff 折叠、过滤、标签）无头单测；
- QA 钩子：`DSH_REVIEW_TEST=1` 启动即打开面板；`DSH_REVIEW_TEST_PATH=<dir>` 固定审计的工作区。

## 8. 已知边界

1. `bash` 直改只有命令文本，**内容不可得**——面板明确标注「需人工核对」；
2. 日志尚未落盘的尾部（`session-checkpoint-policy` 的批处理窗口内）看不到，撕裂帧只在 `diagnostics` 里提示；
3. `meta.diffs` 为空既可能是「新建」也可能是「内容与原文逐字节相同」，面板对后者会保守地标 `新建`；
4. 通过 dsh 之外的手段（其他进程、IDE）改的文件不在日志里；
5. 面板不提供跨会话/跨工作区的全局汇总（按需再加，数据源已经具备）。
