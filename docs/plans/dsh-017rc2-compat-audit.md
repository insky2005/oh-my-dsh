# dsh 0.1.7-rc.2 升级兼容审计（壳层 ↔ dsh web）

> 分支 `feature/dsh-017rc2-upgrade`。目标：把内置 dsh 从 `@deepseek-ai/dsh@0.1.5-rc.3` 升到
> `@deepseek-ai/dsh@0.1.7-rc.2`，逐面复核五个耦合面（`docs/dsh-version-impact.md`）。
> 本文件是**开工前的静态审计**，实测记录随执行追加到 §六。
> 前序同类审计：`docs/plans/dsh-015rc2-compat-audit.md`（0.1.2-rc.1 → 0.1.5-rc.3）。

## 〇、结论（先看两条）

1. **存在 1 个确定的断裂**：会话切换跟踪（B1–B4 / R3）。0.1.7-rc.2 删除了
   `subagents/list` 端点，并把会话流改到 **WebSocket** 承载；壳层 `sessionTrackerScript`
   的 fetch 钩子因此**再也看不到会话切换**，项目目录（终端 / 预览 / wiki / tasks）不再跟随。
   **必须在升版本前修复。**
2. **其余四个面静态核对通过**，但会话日志已换代到 **v4**，且文件链接/归档/workspaceFiles
   等 UI 行为有世代变化，需按 §五 的 SOP 实测。

## 一、这次上游变了什么（静态比对 0.1.5-rc.3 vs 0.1.7-rc.2）

比对方法：两棵树全量提取 `typert.host.js` 的 `id: '<pkg>#<endpoint>'` 与
`parameters[].name`，再逐包 `diff -rq`。脚本与结果：`.tmp/dsh017/extract_endpoints.py`、
`.tmp/dsh017/endpoints.json`（新版树 `.tmp/dsh017/node_modules`）。

| 面 | 对比方式 | 结论 |
|---|---|---|
| RPC 端点 | 全量端点 id `comm` | **84 → 135**：删除 10、新增 61。删除项见下 |
| 参数包裹字段 | 逐端点读 `parameters[].name` | 壳层用到的端点包裹字段**全部未变**（`session/list`=`_request`，其余=`request`）；变化仅在壳层不用的 `credentials/unset`、`settings/*`、`workspaceFiles/*`、`subagents/interruptByParent` |
| 鉴权 | `dsh-client-connection/lib/index.js` | `dsh-auth-` 前缀、`sha256(authority)` 派生、`Max-Age`、`SameSite`、`/api` 门禁**未变** |
| 就绪协议 | `dsh-web-app/lib/index.js` / `startup.js` | 仍是 `dsh web: <带 token 的 URL>`；`--host` / `--port` / `--no-open` / `--trusted-host` 参数仍在 |
| 工作区存储 | `dsh-workspace/lib/invariant.js` | 仍 `defineDomain({name:"workspace", version:2})` |
| 技能 | `dsh-skill-filesystem/lib/index.js` | 四根与 rank（100/200/300/400/500）、规范 frontmatter 键（`user-invocable`/`disable-model-invocation`）、legacy 键拒绝**未变**；仅新增 `realpath` 解析并回传解析后的 `path` |
| 会话日志 | `dsh-session/lib/index.js` | ⚠️ **世代 3 → 4**（`SESSION_FORMAT_VERSION = 4`，文件名 `session.v4.jsonl[.zstd]`）；`dsh-session-format` 包本身逐字节相同 |
| 嵌套派发事件 | 全树事件名 | `tool/code-dispatch[-start]` 与 `tool/ptc-dispatch[-start]` **两代都在** |
| 客户端传输 | `dsh-client-connection/lib/client.js` | 一元 RPC 仍是 `window.fetch` + `POST /api/<endpoint>` + `{type:"client-request",rpcId,method,payload:{args:{…}}}`；**但所有 Typert Remote 流（含 `session/follow`/`session/control`）改由 WebSocket 承载** |
| 文件打开 | `dsh-client-ui-chat` / `dsh-client-ui-deliverables` | `openFile` 仍走页面内 `ctx.sidebarRight.openResource`；**`[data-produced-files-row]` 已移除**，产出文件改为内联 `fileMention`（带 `title`）；`fileLink`（工具行，无 title）、`[data-presented-files-row]` 仍在 |
| 分发闭包 | 版本直方图 | **完全自洽**：272 个 `@deepseek-ai/dsh-*` 全部 `0.1.7-rc.2`（不再有 0.1.5-rc.2 那种"顶层 rc.2、子包 rc.3"混版） |

### 1.1 删除的 10 个端点（0.1.5-rc.3 → 0.1.7-rc.2）

```
@deepseek-ai/dsh-agent-presets#agentPresets/copy
@deepseek-ai/dsh-agent-presets#agentPresets/deletePreset
@deepseek-ai/dsh-agent-presets#agentPresets/list
@deepseek-ai/dsh-agent-presets#agentPresets/read
@deepseek-ai/dsh-agent-presets#agentPresets/select
@deepseek-ai/dsh-api-settings-controller#settings/canOpenAgentPresetDirectory
@deepseek-ai/dsh-api-settings-controller#settings/openAgentPresetDirectory
@deepseek-ai/dsh-api-workspace-files#workspaceFiles/readAll
@deepseek-ai/dsh-api-workspace-files#workspaceFiles/readRelated
@deepseek-ai/dsh-subagent#subagents/list          <-- 壳层依赖（B4）
```

其中 `agentPresets/*` 换包重注册到 `@deepseek-ai/dsh-agent-preset-registry`（方法名不变）；
其余壳层均不直接使用。**只有 `subagents/list` 命中壳层。**

## 二、确定断裂：会话切换跟踪（B1–B4 / R3）

### 2.1 壳层依赖的是什么

`platforms/macos/src/main.swift` 的 `sessionTrackerScript`（约 3574 行起）拦截 `window.fetch`，
从 `client-request` 体里读 `method` 与 `sessionId`，把「当前会话」经 `dshSession` 消息回传壳层。
其设计注释写得很清楚：

> `session.history` alone is NOT enough: the client's session open() is idempotent … Every session
> switch DOES run followCurrent → refreshSubagents(current) → **subagent.list { parentSessionId }**,
> which is non-idempotent — so `subagent.list` is the reliable per-switch signal.

白名单（`main.swift:3582`）：

```js
session.history/prompt/rename/selectModel + subagent.list / subagents.list
（同时认点号与斜杠两套）
```

### 2.2 0.1.7-rc.2 为何打断它

1. **端点消失**：全树已无 `subagents/list`（删除项，且未以任何包名重注册）。
2. **传输换代**：0.1.7 的 `@deepseek-ai/dsh-api-gateway/lib/client.js` 用**一条物理 WebSocket**
   复用所有 Remote 流（源码注释：`Exact WebSocket route carrying every Typert Remote stream`）。
   打开一帧的形状是：

   ```js
   { type: "open", streamId, endpoint, payload }
   // payload = { args: prepared.args }（见 dsh-api-gateway/lib/client.js invokeStream）
   ```

   会话打开走 `SessionEventStream.follow()` → `remote.session.follow({address, assistantStream:true, …})`
   → WS `open`，**不产生任何 fetch 请求**。`session/page`（unary fetch）只在「向上翻历史」时触发，
   不随切换。

因此：仅切换会话时，白名单里没有任何方法触发 → tracker 静默失效。**后果**：dsh web 切会话后，
壳层的项目目录（终端 cwd / 预览树 / wiki 根 / tasks 仓库）不跟随（`app.log` 不再出现
`project directory followed session …`）。

### 2.3 修法（施工依据）

1. **hook `WebSocket.prototype.send`**（不要换构造函数，保留 `WebSocket.OPEN` 等静态量）：
   只在参数是字符串时尝试 `JSON.parse`；命中 `{type:'open', endpoint, payload}` 且 endpoint 在
   白名单内时，从 `payload.args.request` 取会话身份，去重后 `postMessage({sessionId})`，
   再调用原始 `send`。
2. **地址提取**（`SessionAddress` 是判别联合）：
   - `{kind:'session', sessionId}` → `sessionId`
   - `{kind:'subagent', parentSessionId, childSessionId}` → 取 `parentSessionId`（壳层跟随父会话的项目目录）
   - `session/projections` 请求是顶层的 `{sessionId}`。
3. **fetch 白名单同步补**：加入 `session/follow`、`session/page`、`session/projections`，
   并让 sid 提取同时看 `req.address.{sessionId,parentSessionId,childSessionId}`、`req.sessionId`
   （保留旧路径兼容）。
4. **回归用例**：给 `tests/` 增最小用例（构造一段 WS open 帧与 fetch 体，断言提取出的 sessionId）。
   另在开发版实测（§五 B 面）。

> 备注：`session/control` 是 host 级快照流（无会话身份），不入白名单。

## 三、其余四个面：静态核对通过

### A 进程 / 就绪 / 鉴权

- 自拉起命令仍是 `node <dsh>/lib/bin.js web --no-open --port <N>`；`dsh-web-app/lib/startup.js`
  仍注册 `--host`/`--port`/`--no-open`/`--trusted-host`。
- 就绪自报行未变：`dsh web: http://127.0.0.1:<port>/?token=…`。
- cookie 名 `"dsh-auth-" + base64url(sha256(authority))`、`Max-Age`、`HttpOnly; SameSite=Strict` 未变。
- 内置 Node `v24.21.0` 满足新闭包 `@earendil-works/pi-telemetry` 的 `>=22.19.0` 与 `which-command` 的 `>=22`。

### C 一元 RPC

- 壳层用到的端点全部仍在：`session/{list,create,rename,prompt,cancel,page,search,openWorkspacePath}`、
  `workspace/create`（`workspace/list` 本就无）。
- 请求形状未变：`session/page` 仍是 `{address, throughSeq, …}`；`session/create|rename|prompt|cancel`
  仍用顶层 `sessionId`；`SessionPromptRequest` 仍需 `requestId+mode+content[]`。`SessionAddress` 仅
  `mode` 联合多了一个 `'unknown'`。
- 返回形状：`SessionSummary` 仅新增 `agentAvailable`，`projections.values.title/asOfSeq` 仍在；
  `SessionPage` 未变；`tool/result` 仍带 `data.meta.diffs`（`dsh-tool-fs` 的 `presentationMeta` 未变）。
- ⚠️ `SessionProjectionHints` 新增 `kind:'cached'|'sequenced'`。`lastMessage()` 用
  `projections.asOfSeq` 作 `throughSeq`；按定义 `cached` 的 `asOfSeq` 是该持久化记录自身的水位，
  仍应是该会话合法日志切点，但需在 §五 C 面实测确认（尤其冷会话）。

### D `$DSH_HOME` 磁盘布局

- `storages/workspace.json` 仍 domain `workspace` v2 → `workspace-store.js` / `DshWorkspaceStore.swift`
  无需改。
- 会话日志：`SESSION_FORMAT_VERSION = 4`。壳层 `review-log.js` 的 `parseSessionLogName` 规则
  `^session(?:\.v([1-9][0-9]*))?\.jsonl(\.zstd)?$` + 「取最大世代」**天然覆盖 v4**，无需改代码；
  但 **v4 的事件内容必须实测审计出改动**（§五 D 面）。
- 技能：四根 / rank / frontmatter 键未变；面板的安装与开关逻辑不受影响。

### E 分发 / 升级 / 运行时

- 仍是 npm 包 + 运行时整树嵌入 + `npm install` 原地升级；`lib/bin.js` 布局未变。
- 闭包自洽（272 个 dsh 子包全部 0.1.7-rc.2），R8 的 lockfile + `npm ci` + 冒烟流程照旧适用；
  需新增一份 `platforms/macos/runtime-locks/dsh-0.1.7-rc.2/`。

## 四、需实测确认的世代变化（不一定是断裂）

1. **会话日志 v4 审计内容**：新建会话后 `review audit` 必须 `stats.mutations > 0`、
   `hunks` 非空（R7/R7b 的教训：**能列出 ≠ 有内容**）。
2. **文件打开点击面**：`[data-produced-files-row]` 已移除，产出文件改为内联 `fileMention`（带
   `title`）。预览拦截器四类选择器里三类仍在，须真实点一次：内联链接 / 工具行 `fileLink` /
   交付卡片 `[data-presented-files-row]` / 工作区相对路径。
3. **归档会话**：0.1.7 新增归档/pin 与 `workspace/{pinSession,unpinSession,unarchiveSession}`；
   `SessionSummary` 无 archived 字段。需确认 `session/list` 是否返回归档会话——若是，
   `DshWorkspaceOps.newestSessionId` 可能挑到已归档项。
4. **workspaceFiles 换代**：`readAll`/`readRelated` 删除，`readBytes` 的 `range`→`options`，
   `changes` 增 `path`。壳层目前不直接用，确认无隐式依赖。
5. **Agent 预设端点换包**：`agentPresets/*` 由 `dsh-agent-presets` 移到
   `dsh-agent-preset-registry`（方法名不变），`settings/{canOpenAgentPresetDirectory,
   openAgentPresetDirectory}` 删除；壳层不直接用。

## 五、产品注意：`latest` 已是 0.2.0-rc.2

npm `dist-tags`：`latest = 0.2.0-rc.2`、`next = 0.2.0-rc.2`、`alpha = 0.1.7-alpha.2`。
推进到 `0.1.7-rc.2` 后，站内升级助手按 stepwise 语义
（`nextStepTarget` 取"严格更新的最小 rc"）会提示下一档 **`0.2.0-rc.1`**。
这是预期行为；若产品上要"停留 0.1.x"，需另做版本线策略（本审计不涉及）。

## 六、执行记录（本次，分支 `feature/dsh-017rc2-upgrade`）

### 6.1 已完成

| 项 | 结果 | 证据 |
|---|---|---|
| 静态比对 | 端点 84 → 135（删 10 / 增 61），壳层用到的端点除 `subagents/list` 外全部仍在 | `.tmp/dsh017/extract_endpoints.py` + `.tmp/dsh017/endpoints.json` |
| tracker 修复 | 新增 `WebSocket.prototype.send` 观察层 + fetch 白名单/`address` 提取 | `platforms/macos/src/main.swift`；`tests/session-tracker/run.sh` **12/12** |
| 注入脚本守卫 | 7 个脚本全部 parse、16 个 bridge 齐全 | `tests/injected-scripts/run.sh` 通过 |
| 闭包锁 | `runtime-locks/dsh-0.1.7-rc.2/`：611 包、**273 个 `@deepseek-ai/dsh-*` 全 0.1.7-rc.2** | `npm ci → added 521 packages`；`smoke: dsh web came up (kept the tree)` |
| Dev 版构建 | 成功；bundle 内 dsh 0.1.7-rc.2；嵌入 3 份 runtime-locks（rc.1/rc.3/rc.2） | `DSH_DEV_BUILD=1 build-app.sh` |
| core 单测 | **291 tests / 287 pass / 0 fail / 4 skipped** | `node --test core/tests/*.test.js` |
| 文档同步 | README / productization / version-impact（§3 B1/B2/B4、D8，新增 §4.6，§5 SOP，§7）/ CHANGELOG | 同分支提交 |

### 6.2 dsh 侧实测（A/C/D 面，工作区本地 home：真实会话从 `~/.dsh-dev` 拷入 + 新建会话）

运行时：构建产物内置 `node v24.21.0` + `dsh 0.1.7-rc.2`，`dsh web --no-open --port 50123`。

- **A 启动/鉴权**：就绪行 `dsh web: http://127.0.0.1:50123/?token=…`；core `callRpc(SESSION_LIST, token)` 直接 200（内部完成 token→cookie）。
- **C 读**：`session/list` 返回 31 项；新建会话的 `projections.kind='sequenced'`、`asOfSeq=17`、`values.title='dsh017 probe'`；`session/page`（`address` + `throughSeq`）返回 18 条记录。
- **C 写**：`session/create → rename → prompt` 全部 `ok`；`requestId+mode+content[]` 未变。
- **D 会话日志世代**：新建会话落盘 `session.v4.jsonl.zstd`（**v4**）；`listSessionLogs` 找到它；`auditSession` 能解析（`turns=[1:probe]`、`diagnostics=[]`）。
- **D 审计内容（v3 存量）**：对拷入的真实会话 `session-0c9e6fbf-…`（227 KB `session.v3.jsonl.zstd`）`auditSession` → `entries=39, mutations=14, files=3, added=709, removed=289, bashCalls=13`，`diagnostics=[]`。
- **D 布局**：`storages/workspace.json` 仍 `{"name":"workspace","version":2}`，3 个工作区。

### 6.3 八面板扫描与环境限制

- Dev 版带 `DSH_PANEL_TEST="files,terminal,wiki,tasks,browser,channel,review,skills"` 启动，**八个面板都被访问并产生 view-hierarchy dump**（`terminal/browser/review/skills/tasks/wiki/channel/preview`，其中 `review-loaded` 603 行）。
- **但 PNG 截图与 app.log 未落盘**：该 App 继承了工具侧的文件沙箱（workspace-write），写入 `~/Library/Logs/oh-my-dsh` 与 `~/.dsh-dev` 被拒（日志里是 `EPERM / Operation not permitted`）。因此本轮面板“是否渲染出内容”的判据退化为 **view-hierarchy dump + 6.2 的 RPC 实测**（会话列表 / 审计 / 工作区均真的读过数据）。无沙箱（正常 `open` App 或用户本机）下应复跑 §五 的八面板截图。

### 6.4 未复跑 / 后续

- **v4 下真实文件改动审计**：隔离 home 无 provider 凭据，agent turn 以 `MISSING_CREDENTIAL` 结束，故未产生 v4 的 write/edit 记录。已核：v4 与 v3 的 `tool/call|result|ptc-dispatch` 事件类型一致、`dsh-session-format` 两版逐字节相同、v4 解析与 turn 提取实测可用——**风险低**，但发布前建议在带凭据的 home 里走一条真实会话，确认 `mutations > 0`。
- **文件链接点击（B7）**：已在 **dev 版真实 DOM** 上核对并验证。0.1.7 的交付卡片新增「用系统应用打开 / 在 Finder 中显示」split 控件（`[data-open-target]`，主按钮 `data-open-path-open`、chevron `aria-haspopup=menu`），原 presented 分支会劫持主按钮；已放行该控件。用注入脚本对真实 DOM 验证：点击 open-in-app 主按钮 **不** 产生 `dshPreview` 消息，点击卡片遮罩仍发出 `{path:"/…/sm4_demo.py",source:"click"}`。回归 `tests/preview-interceptor` 16 项全绿。**改动审阅卡**：0.1.7 的 `[data-changed-files]`（header/行 `button[class*=hz8-rW_row]`）已改为路由到原生预览面板（不再打开 dsh 侧边栏）；读 `aria-describedby` 指向的隐藏 span 的绝对路径，toggle 放行。实测该卡依赖主机内存里的 `changes.summary`（`/api/changes.summary`）：**会话重开后服务端 404 → 卡片消失**（dsh 行为）；壳层的持久 diff 视图是「审查」面板（直读 v4 日志）。
- **归档会话**：未构造归档数据；`DshWorkspaceOps.newestSessionId` 是否可能挑到归档会话待真实数据核对。
