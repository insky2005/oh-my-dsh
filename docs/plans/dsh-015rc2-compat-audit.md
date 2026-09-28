# dsh 0.1.5-rc.2 升级兼容审计与实测（壳层 ↔ dsh web）

> 分支 `release/1.16`（v1.16.0 的补丁）。目标：把内置 dsh 从 `@deepseek-ai/dsh@0.1.2-rc.1` 升到
> `@deepseek-ai/dsh@0.1.5-rc.2`，逐面复核五个耦合面（`docs/dsh-version-impact.md`），并在**开发版**
> （`DSH_DEV_BUILD=1` + `DSH_HOME=~/.dsh-dev`，不碰 `~/.dsh`）上把八个面板跑一遍。
> 状态：**已在 `release/1.16` 执行完毕**（2026-09-27）——内置 dsh 推进到 `0.1.5-rc.3` 并随附闭包锁
> （下方 §一–§六 是 2026-09-23 针对 rc.2 的审计原文，作为历史留档；为何最终钉 rc.3 见 §七），
> 执行与验证记录见 §七。原先「暂缓」的理由（0.1.5 **会让会话日志换代、且无法回退到旧版 dsh**）已由
> **v1.16.2 的「会话快照 + 回退」**解除，因此本记录中的升级动作现已落地。
> 审计本身（2026-09-23 实测）：把内置 dsh 升到 0.1.5-rc.2 跑通了全流程，定位到唯一断裂点
> （会话日志世代命名，**修复已进 1.16.2 开发线**）。
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

## 七、执行记录（2026-09-27，`release/1.16`）

原「暂缓」的唯一前提是**没有回退通道**（0.1.5 会让会话日志换代且上游只有升级链）。**会话快照 + 回退已在
v1.16.2 上线**，前提解除，本次把审计中的升级动作落地。

**改了什么**：`build-app.sh` 的 `DSH_PACKAGE_SPEC` 默认值（两处）与打印行 → `@deepseek-ai/dsh@0.1.5-rc.3`；
新增闭包锁 `platforms/macos/runtime-locks/dsh-0.1.5-rc.3/{package.json,package-lock.json}`（锁内依赖写**精确版本**
而非 caret）；README / `docs/productization.md` / `docs/dsh-version-impact.md` §4.5 与 `CHANGELOG` 同步。
**壳层代码零改动**——本次唯一断裂面（会话日志世代命名）的修复已随 v1.16.2 落地。

### 7.1 为什么最终钉 rc.3 而不是审计当时的 rc.2

先按审计写的 `0.1.5-rc.2` 做了一轮（构建/冒烟/端到端都通过），但发现这个 spec 有两个实操坑：

1. **闭包不自洽**：dsh 用**同族 caret 范围**声明自己的子包（`@deepseek-ai/dsh-*: ^0.1.5-rc.2`），所以顶层是 rc.2 时，
   解出的闭包里 **230 个子包其实是 `0.1.5-rc.3`**（rc.3 发布于 2026-09-22，**早于**审计当日 09-23，故审计当时
   走的就是同一条解析路径——现存 rc.2 树里的 `dsh-skill-filesystem` 确实已经写着 `0.1.5-rc.3`）。
2. **留下一个永远消不掉的升级提示**：壳层的版本事实读**顶层** `package.json`（=`0.1.5-rc.2`），而 npm 的
   `latest` 是 `0.1.5-rc.3` —— 实测 `nextStepTarget('0.1.5-rc.2') = '0.1.5-rc.3'`，于是站内升级助手会一直提示
   「有新版可升级」，而那次升级几乎是个空操作（闭包本来就已经是 rc.3）。

改用 **rc.3** 后闭包**完全自洽**（243 个 `@deepseek-ai/*` 里 231 个是 `0.1.5-rc.3`，其余是 cordis 工具链等
非 dsh 包；**没有任何一个 `@deepseek-ai/dsh-*` 落在别的版本**），提示随之消失，而且**风险不升反降**：

- rc.3 把 cordis 工具链**钉成精确版本**（`@deepseek-ai/cordis 4.0.2`、`@deepseek-ai/cordis-plugin-hmr 1.0.17`、
  `cordis-plugin-include 1.0.7`、`cordis-plugin-loader 1.0.3`、`cordis-plugin-timer 1.1.4`、`schemastery 3.18.2`），
  **rc.2 用的却是 caret**（`^4.0.2` / `^1.0.17` / …）——那正是 **R8「运行时闭包漂移」**（HMR 插件漂移导致 dsh
  启动即抛）的成因。换句话说，rc.3 上游自己把 R8 这个坑堵上了。
- **rc.3 不是"野生"版本**：上游仓库 `dsh-v0.1.5-rc.3` **有 tag**、npm 上它就是 `latest`，且 0.1.7-rc.1 的发行说明
  以 `v0.1.5-rc.3` 作比较基线（`Full Changelog: dsh-v0.1.5-rc.3...dsh-v0.1.7-rc.1`）——**只是漏发了 GitHub
  Release 页面**（Releases 列表从 `0.1.6-alpha.1` 直接跳到 `0.1.5-rc.2`，这一视觉差容易被误读成"rc.3 不存在/被撤回"）。

### 7.1b rc.2 ⇄ rc.3 的逐项比对（端点面：零影响；文件链接面见 7.1c 修正）

| 比对项 | 方法 | 结论 |
|---|---|---|
| RPC 端点集合 | 三棵树（rc.1 / rc.2 / rc.3）的 `typert.host.js` 全量提取 `id: '<pkg>#<service>/<method>'` | **rc.2 → rc.3：零增、零删**；rc.1 → rc.3 与审计记录一致（**0 删 / 10 增**：`workspaceFiles/*`、`fileUploads/upload`、`sessionFeedback/record`、`goals/get`） |
| 参数包裹字段 | 逐端点读 `parameters[].name` | **rc.2 → rc.3：零变化**；壳层用到的每个端点都是老样子（`session/list`=`_request`、`create/rename/prompt/cancel/page/openWorkspacePath/selectModel/workspace/create`=`request`、`subagents/list`=`parentSessionId`） |
| 六个耦合面所在的包 | 在两棵树间 `diff -rq` 整包目录 | **逐字节相同**：`dsh-client-connection`（鉴权 cookie + 客户端传输）、`dsh-web-app`（就绪自报行）、`dsh-workspace`（domain v2）、`dsh-session-format`（世代命名）、`dsh-skill-filesystem`（四根/rank/frontmatter）、`dsh-client-ui-sidebar`（侧栏 DOM）、`dsh-session-persistence-jsonl` |
| 依赖闭包 | 版本直方图 | rc.3：自洽（见上）；rc.2：顶层 rc.2 + 230 个子包 rc.3（混合） |

**所以本次从 rc.2 换到 rc.3 不需要任何壳层适配**——两者对壳层可见的行为是同一份代码。
> ⚠️ **但「不需要任何壳层适配」这个整体结论已被 7.1c 推翻**：rc.2/rc.3 确实同码，可它们相对
> **0.1.2-rc.1** 却换了文件链接的 UI 行为，而它落在上面六个包之外。

### 7.1c 修正：rc.2/rc.3 相对 0.1.2 换掉了文件链接（2026-09-28，用户实测暴露）

执行落地后收到实测反馈：**点会话里的文件链接不再在 oh-my-dsh 的文件面板打开。** 定位结论如下。

- **行为差异**：0.1.2-rc.1 的 `dsh-client-ui-chat`：
  `openFile = async (path) => remote.session.openWorkspacePath({ path: resolveWorkspacePath(cwd, path) })`
  —— 走一元 RPC，壳层的 `window.fetch` 拦截脚本能抓到绝对路径。
  0.1.5 的同一函数：
  `openFile = async (path) => ctx.sidebarRight.openResource(fileAddressFor(sessionId, cwd, path))`
  —— **dsh 自带文件面板，纯页面内动作，不发任何 HTTP 请求**，fetch 拦截脚本永远不触发；原生面板收不到路径。
  内联文件链接与「Files changed」产出行的 DOM 都是 `<button title="<原样路径>">`。
- **为什么静态审计没发现**：端点集合没变（`session/openWorkspacePath` 仍在，只是不再由这条 UI 路径调用），
  六个耦合面包逐字节相同——但 `dsh-client-ui-chat` / `dsh-client-ui-deliverables` **不在那六个包里**，
  7.1b 的比对根本没覆盖「点击链接的客户端行为」。
- **为什么 7.2 的预览探针没发现**：探针自己构造两种 `fetch` 请求，验证拦截器**请求层**正确；
  它没有模拟一次真实点击，因此对「点击路径根本不发请求」这一类回归完全无感。
- **修法**：`previewInterceptorScript` 增加点击捕获层——在 document 捕获阶段识别内联文件链接
  （`<code>` 内的 `button` 或 `class*=fileMention`）与产出行（`[data-produced-files-row] button[title]`），
  把 `title` 发给原生面板并吞掉事件；相对路径由原生侧按当前项目目录解析（等价于 0.1.2 的
  `resolveWorkspacePath(cwd, path)`）。回归用例见 `tests/preview-interceptor/`。
- **教训（并入 §5 SOP）**：升级后必须**真的点一次会话里的文件链接**（绝对路径与相对路径各一次），
  不能只看端点、DOM 探针或合成 RPC 探针。

### 7.2 验证证据

| 项 | 命令 / 做法 | 结果 |
|---|---|---|
| 运行时构建 | `DSH_ARCH=arm64 build-app.sh --prefetch` | `using committed runtime lock: platforms/macos/runtime-locks/dsh-0.1.5-rc.3` → `added 520 packages in 4s` → **`smoke: dsh web came up (kept the tree)`** |
| App 构建 | `DSH_DEV_BUILD=1 build-app.sh` | 成功；bundle 内 `dsh/package.json → 0.1.5-rc.3`；`runtime-locks/` 同时嵌入 **rc.1 与 rc.3 两份**（回退仍可用）；锁指纹 `e4d8b1302508` |
| core 单测 | `node --test core/tests/` | 261 tests / **257 pass / 0 fail** / 4 skipped |
| swift + 面板套件 | `scripts/local-ci.sh swift` | **577 ok / 0 fail**（含 `tests/dsh-rpc`、`tests/review-panel`、`tests/snapshot-rollback`、全套面板 + swiftc 编译检查） |
| A 启动 | 用 **App 内置运行时**起 `dsh web`（工作区内隔离 `DSH_HOME`） | `dsh web: http://127.0.0.1:<port>/?token=…`，进程存活 |
| C 会话链路 | core `callRpc` 直连（token→cookie 由传输层完成） | `session/list` 200；`session/create` 90 ms；`rename → true`；`prompt → true`；`session/page` 游标 `asOfSeq=17`；`projections.values.title` 正确回读 |
| **D 会话日志世代（本次唯一断裂面）** | 看真实新建会话目录 | 活日志 = **`session.v3.jsonl.zstd`**（世代 3） |
| **D 壳层读取器** | `core.listSessionLogs({dshHome})` + `auditSession` | 该会话**被发现**：`file=session.v3.jsonl.zstd compressed=true size=19724`，`auditSession ok=true`（折叠出 turn 1 的真实 prompt，`diagnostics=[]`）——即 v1.16.2 的世代命名修复在 0.1.5 上**确实生效** |
| D `workspace.json` | 读 `storages/workspace.json` | `{"name":"workspace","version":2}` —— **仍为 v2**，R4 护栏无需改动 |
| 快照树池 | 开发版启动日志 | `snapshot tree: {"ok":true,"action":"cloned","dir":"…/trees/0.1.5-rc.3","lock":"e4d8b13025089771"}` —— 池收录的新树**指纹与提交的 lock 一致**（R8 的闭包校验按预期工作） |
| 八面板扫描 | `DSH_PANEL_TEST="files,terminal,wiki,tasks,browser,channel,review,skills"` + `DSH_UI_DEBUG=1`，**且 `DSH_HOME` 里预置了上面那条 rc.3 新建的会话** | 八个面板**都被访问并发觉落图**（preview / terminal / wiki / tasks / browser / channel / review / skills，各自 `panel-<name>-debug.png`）。**review 面板这次真的渲染出了内容**（截图可见会话 "…verification"、19 KB、`sessions 1/1`）：日志 `review: listed 1/1 sessions workspace=… first=session-f6254729… diagnostics=0` + `review: audit session-… entries=0 files=0 turns=1 diagnostics=[]`——**0.1.5-rc.3 写出的 `session.v3.jsonl.zstd` 在真实 GUI 里被列出并审计**，即 v1.16.2 那条世代命名修复端到端成立 |
| B 预览拦截 | 见 `DSH_PREVIEW_DEBUG=1` 的探针 + 文件面板截图 | 文件面板出现 **两个页签**（`dsh-preview-fetch-test.txt` / `dsh-preview-modern-test.txt`）= 新旧两种 **fetch 请求形状**都被拦截。**但这只证明 fetch 层可用，不等于用户点文件链接可用**：探针是脚本自己 `fetch()`，没触发真实点击；0.1.5 的链接已改走页面内面板（7.1c），所以探针全绿、真实点击仍失效 |

### 7.3 本次未复跑的（与审计遗留一致）

沿用 §六：模型回复仍端到端未复跑（隔离 home 无 provider 凭据，turn 以 `MISSING_CREDENTIAL` 结束）；
tasks 面板的数据面是 GitHub API，与本升级无关；channel 面板验到引导卡片。

八面板扫描第一次跑用了**空 home**，结果是 review 面板 `review: titles 0 of 0 sessions` 且它和 terminal 都不落图；
**把一条真实会话预置进 `DSH_HOME/sessions/` 后重跑**，八个面板全部落图且 review 渲染出内容（见 7.2 末两行）。
**教训（下次照做）**：跑升级 SOP 的八面板扫描前，先往 `DSH_HOME` 放至少一条真实会话——否则 review/terminal
这类"没内容就没什么可截"的面板会静默缺席，看起来像回归。
