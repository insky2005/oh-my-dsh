# dsh 0.1.5-rc.2 升级兼容审计与实测（壳层 ↔ dsh web）

> 分支 `release/1.16`（v1.16.0 的补丁）。目标：把内置 dsh 从 `@deepseek-ai/dsh@0.1.2-rc.1` 升到
> `@deepseek-ai/dsh@0.1.5-rc.2`，逐面复核五个耦合面（`docs/dsh-version-impact.md`），并在**开发版**
> （`DSH_DEV_BUILD=1` + `DSH_HOME=~/.dsh-dev`，不碰 `~/.dsh`）上把八个面板跑一遍。
> 状态：**审计完成、升级暂缓**（2026-09-23 实测）。本次把内置 dsh 升到 0.1.5-rc.2 跑通了全流程，定位到唯一断裂点
> （会话日志世代命名，**修复已进 1.16.2 开发线**）；但 0.1.5 **会让会话日志换代、且无法回退到旧版 dsh**，
> 因此**暂不推进内置版本**——待「会话快照 + 回退」功能上线后再执行本记录中的升级动作。
> （曾经据此发布过 v1.16.1，随后**撤回**：GitHub Release 与 tag 均已删除，分支留档。）
> 前一次同类审计：`docs/plans/dsh-012rc1-compat-audit.md`（0.1.1 → 0.1.2-rc.1）。

## 一、这次上游变了什么（静态比对 0.1.2-rc.1 的 223 个 @deepseek-ai 包 vs 0.1.5-rc.2 的 233 个）

| 面 | 对比方式 | 结论 |
|---|---|---|
| RPC 端点 | `id: '@deepseek-ai/<pkg>#<endpoint>'` 全量提取后 `comm` | **只增不减**：新增 `workspaceFiles/{list,read,readBytes,readAll,readRelated,stat,changes}`、`fileUploads/upload`、`sessionFeedback/record`、`goals/get`；壳层用到的 74 个端点一个都没消失 |
| 参数包裹字段 | 逐个端点读 `typert.host.js` 的 `parameters[].name` | **完全一致**：`session/list` 用 `_request`，`create/rename/prompt/cancel/page/openWorkspacePath/modelCatalog` 用 `request`，`subagents/list` 用 `parentSessionId` |
| 鉴权 | `dsh-client-connection/lib/index.js` | `dsh-auth-` 前缀、cookie 名派生、`Max-Age`、门禁逻辑均未变 |
| 就绪协议 | `dsh-web-app/lib/index.js` | 仍是 `dsh web: <带 token 的 URL>`（`--no-open` 语义不变） |
| 工作区存储 | `dsh-workspace/lib/invariant.js` | 仍 `defineDomain({name:"workspace", version: 2})` |
| 技能 | `dsh-skill-filesystem/lib/index.js` | 四根与 rank（100/200/400/500）、规范 frontmatter 键、`rejectLegacyInvocationKey` 均未变 |
| 会话日志 | `dsh-session-format/lib/index.js` | ⚠️ **世代命名**：`session.jsonl`（世代 0）→ `session.v<N>.jsonl`；本版新建会话写 **`session.v3.jsonl.zstd`** —— **本次唯一断裂面** |
| 客户端传输 | `dsh-client-connection/lib/client.js` | 一元 RPC 仍是 `window.fetch` + `POST /api/<endpoint>` + `{type:"client-request",rpcId,method,payload}`；侧栏仍是 `[role="treeitem"]` + `sessionRow`；会话条目仍是 `projections.values.title` / `projections.asOfSeq` |
| 文件打开 | `dsh-client-ui-deliverables`、`dsh-api-session-controller` | 仍是 `session/openWorkspacePath`，路径在 `payload.args.request.path` |

## 二、五个耦合面实测（开发版，dsh 0.1.5-rc.2，端口随机）

| 面 | 核对项 | 实测证据 |
|---|---|---|
| A 启动 | 拉起 + 自报入口 + 不用外部实例 | `app.log`: `using node=/opt/homebrew/bin/node … port=64359`；`dsh web is up on http://127.0.0.1:64359/?token=…`；**无** `reusing existing dsh web` |
| A 鉴权 | token → cookie → `/api` | 壳层 core `callRpc(SESSION_LIST)` 首调即 200（内部完成 `GET /?token=` 换 cookie）；`dsh cookies: nothing stale (0 total, kept 127.0.0.1:64359)` |
| A 页面 | 首屏不是 401 | `page did finish loading`、`webview navigator.language=zh-CN`、`dsh viewport/sidebar: {"innerWidth":1100,…}` |
| B 注入 | tracker / opener / preview 装好 | `dsh injected bridges: {"tracker":true,"opener":true,"preview":true,"rows":0}`（`rows` 是**页面刚加载完**的快照，此时侧栏还没渲染；同一份窗口截图里侧栏会话行是有的） |
| B 跟随 | 切会话 → 项目目录跟随 | `active session changed: session-a8a10a47…` → `project directory followed session …: /…/helloharness` → `preview workspace switch` / `terminal workspace` / `tasks repo resolved`（tracker 桥接到了客户端的会话切换，B1–B4 在 0.1.5 上依然成立） |
| B 文件打开 | 两种形状都被拦截 | `preview debug probe: {…,"hitSync":"/tmp/dsh-preview-fetch-test.txt","hitSyncModern":"/tmp/dsh-preview-modern-test.txt"}` + 两条 `fakeResponse … {"ok":true,"value":{"opened":true}}`（现代形状 = `/api/session/openWorkspacePath` + `payload.args.request.path`） |
| C 读 | `session/list` | 200，`items` 含 `sessionId/running/cwd/projections` |
| C 写 | create → rename → prompt | `create -> session-a8a10a47… (26ms)` / `rename -> true` / `prompt -> true`（写操作字段 `requestId`+`mode`+`content[]` 未被上游改动） |
| C 回复 | `session/page` 读回复文本 | 对一条真实历史会话（迁移后的 `session.v3.jsonl.zstd`）`throughSeq=541` → 542 条记录，含 **58 条 `assistant/message`**；壳层的提取逻辑取到 749 字回复 |
| C 兜底 | `workspace/list` 仍不存在 → 磁盘兜底 | 端点 404/不可用 → `readWorkspaceStore(~/.dsh-dev)` 返回 `domain workspace v2`、工作区列表与面板一致 |
| D 布局 | `workspace.json` 仍是 v2 | `reason=ok version=2` |
| D 技能 | 根/rank/frontmatter | 面板「已安装」列出 `repo-wiki 项目级`、`issue-resolve 内置` 等并显示各自级别；规范键写入路径未受影响 |
| D 会话日志 | **世代命名** | 新会话目录只有 `session.v3.jsonl.zstd`（老会话迁移后 = 冻结的 `session.jsonl.zstd` + 活的 `session.v3.jsonl.zstd`）→ **断裂，已修**（§三） |
| E 分发 | npm 原地安装 + Node 门槛 | `npm install @deepseek-ai/dsh@0.1.5-rc.2` 装出 524 个包；运行时仍是 `runtime/dsh/lib/bin.js`；内置 node v24.21.0 |
| E 升级助手 | RC 判定 / 下一个候选 | `isReleaseCandidate('0.1.5-rc.2')=true`；`nextStepTarget('0.1.2-rc.1', [已发布列表])='0.1.5-rc.1'`、`nextStepTarget('0.1.5-rc.2', …)=null`（已是当前 latest 时不再提示升级） |

## 三、唯一断裂点与修复：会话日志的「世代命名」

**现象**（升级后立刻可见）：审查面板对**新建会话**完全空；对**被 dsh 迁移过的老会话**显示的是迁移前的内容。`app.log`：

```
review: follow web session session-a8a10a47-… (listed=false)
review: listed 0/4 sessions workspace=/…/helloharness first=- active=session-a8a10a47-…
review: audit FAILED for session-a8a10a47-…
```

**根因**：dsh 用**文件世代**表示 Session 格式版本（`@deepseek-ai/dsh-session-format`）：

```js
sessionFormatLogFilename(v) = v === 0 ? "session.jsonl" : \`session.v${v}.jsonl\`;   // 压缩 + ".zstd"
```

0.1.2-rc.1 写世代 0；**0.1.5-rc.2 写世代 3**。迁移过的会话把老文件留成归档，活日志换名。壳层读取器只认
`['session.jsonl.zstd','session.jsonl']`，于是「一条都列不出来 / 读到旧归档」——不报错、不崩溃，只是空或旧。

**修复**（`core/lib/review-log.js`）：

- 新增规范名解析 `parseSessionLogName()`：`^session(\.v([1-9][0-9]*))?\.jsonl(\.zstd)?$`（`.v0`、大写 `V`、前导零、`.tmp`、`.gz` 等非规范名一律不算）；
- 新增 `sessionLogCandidates(dir)`：枚举该会话目录里所有规范日志，**按世代降序**（活日志优先于冻结归档）、同代压缩优先；
- `sessionLogFile()` 改为取 `sessionLogCandidates()[0]`，`listSessionLogs()` / `auditSession()` 自动受益；
- 用例 6 条（`core/tests/review-log.test.js`）：新世代会话可发现并审计、迁移会话读活日志而非归档、非规范名忽略、世代 0 兼容、压缩与非压缩两种新世代文件。

修复后同一目录：`listSessionLogs` 从 4 条变 7 条，且 `b6dac7b3` 自动改读 `session.v3.jsonl.zstd`。

## 四、八个面板的功能可用性（开发版实测）

用新增的 QA 钩子一次跑完：`DSH_PANEL_TEST="files,terminal,wiki,tasks,browser,channel,review,skills"` + `DSH_UI_DEBUG=1`，
每个面板各落一张 `~/Library/Logs/oh-my-dsh/panel-<name>-debug.png`（1814×2396），逐张 OCR 抽查渲染内容：

| 面板 | 面板内实际渲染（OCR 摘录） | 结论 |
|---|---|---|
| 文件（preview） | `文件` / `打开项目` `打开文件` / 目录树 `repowikitest` + 条目 / 空态「点击对话中的文件链接，在此预览文件或文件夹」 | ✅ |
| 终端（terminal） | `终端` / `终端1` `终端2` 页签 / `+` | ✅ |
| 知识库（wiki） | `知识库` / 搜索框 / `index` `modules` 树 / `7 页 · 过期 0` / 页面清单 | ✅ |
| 任务（tasks） | `任务` / 空态「当前工作区不是 GitHub 仓库」（该工作区确实不是 GitHub 仓库，判定正确） | ✅ |
| 浏览器（browser） | `浏览器` / `about:blank` 页签（CEF 已初始化：`CDP 9433`、`browser api server listening on 127.0.0.1:4081`） | ✅ |
| 通道（channel） | `通道` / 平台卡片：微信 ClawBot、钉钉、飞书 | ✅ |
| 审查（review） | `审查` / `会话 2/3 · 对话… · 文件…` / 会话行（含迁移后的 v3 会话，`文件 +9 -0`） | ✅（修复后） |
| 技能（skills） | `技能` / 已安装…可安装 / `全部 共享级 内置 用户级 项目级` / `repo-wiki 项目级`、`issue-resolve 内置` 及各自路径与开关 | ✅ |

**与 dsh 强耦合的面板动作**另有直接证据：知识库扫描（`wiki scan: 18 pages`）、任务面板仓库解析
（`tasks repo resolved: insky2005/oh-my-dsh at …`）、审查面板审计（`review: listed 3/7 sessions … diagnostics=0`）、
文件/终端/预览随会话切换换目录（见 §二 B 跟随）。

## 五、怎么复跑这套验证（留档）

```bash
# 1) 构建：运行时（换 spec 会重建 .cache/runtime/<arch>）+ 开发版 App
DSH_ARCH=arm64 platforms/macos/build-app.sh --prefetch
DSH_DEV_BUILD=1 DSH_ARCH=arm64 platforms/macos/build-app.sh

# 2) 起开发版（DSH_HOME 显式指向 ~/.dsh-dev，绝不用 ~/.dsh）
DSH_HOME=$HOME/.dsh-dev DSH_UI_DEBUG=1 DSH_SESSION_DEBUG=1 DSH_PREVIEW_DEBUG=1 \
  DSH_PANEL_TEST="files,terminal,wiki,tasks,browser,channel,review,skills" \
  dist/oh-my-dsh.app/Contents/MacOS/oh-my-dsh

# 3) 看证据
grep -E "dsh web is up|injected bridges|project directory followed|preview debug probe" ~/Library/Logs/oh-my-dsh/app.log
#   每面板截图：~/Library/Logs/oh-my-dsh/panel-<name>-debug.png

# 4) 端点/会话链路（用 App 内置 node，≥22.15 才有 zstd）
TOK=$(sed -n 's#.*/?token=\([A-Za-z0-9_-]*\).*#\1#p' ~/Library/Logs/oh-my-dsh/server.log | head -1)
node -e "const c=require('./core'); c.callRpc(c.SESSION_LIST,{},{port:<port>,token:'$TOK'}).then(r=>console.log(r.result))"
```

## 六、未覆盖 / 遗留

1. **模型回复没有端到端复跑**：开发隔离目录 `~/.dsh-dev` 里没有 provider 凭据，`session/prompt` 之后的
   turn 以 `MISSING_CREDENTIAL` 结束（`assistant/attempt` 事件如实记录），所以「频道把答案回推给微信/钉钉」
   这一次没有真机复跑——链路里属于 dsh 的部分（create → prompt → turn → `session/page` 取回复文本）已
   用**真实历史会话**验证到文本提取这一步（见 §二 C 回复）。
2. **tasks 面板**只验到「空态判定正确 + 面板渲染」：它的数据面是 GitHub API（需要仓库与 token），与本次
   dsh 升级无关。
3. **channel 面板**在 dev 隔离目录里没有已配置通道，验到「引导卡片渲染」；通道→会话的 RPC 链路复用
   §二 C 的同一条 core 传输。
