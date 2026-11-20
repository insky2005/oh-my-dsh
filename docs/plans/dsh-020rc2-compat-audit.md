# dsh 0.2.0-rc.2 升级兼容审计（壳层 ↔ dsh web）

> 分支 `feature/dsh-020rc2-upgrade`。目标：把内置 dsh 从 `@deepseek-ai/dsh@0.1.7-rc.2` 升到
> `@deepseek-ai/dsh@0.2.0-rc.2`，逐面复核五个耦合面（`docs/process/dsh-version-impact.md`）。
> 本文件是**开工前的静态审计 + 已完成的实测项**；未做的实测项在 §六 列明。
> 前序同类审计：`docs/plans/dsh-017rc2-compat-audit.md`（0.1.5-rc.3 → 0.1.7-rc.2）。

## 〇、结论（先看三条）

1. **没有发现确定的断裂点**。五个耦合面里 A / C / D / E 的契约**逐字节或逐字段未变**，
   B 面依赖的 DOM / 传输锚点全部仍在原位。本次推进的性质是「改版本号 + 新闭包锁 + 走 SOP 实测」，
   **不需要先修壳层再升级**。
2. **端点只增不减**：135 → 140（删 0 / 增 5 / 参数包裹字段变化 **0**）。壳层调用的 17 个端点
   逐个确认存在，`session/list` / `session/page` / `session/create` / `session/prompt` 的请求
   schema 段**逐字节相同**。
3. **闭包自洽且全部精确钉版**（278 个 `@deepseek-ai/dsh-*` 全为 0.2.0-rc.2；476 处 dsh 依赖
   0 个 caret）——不会再出现 0.1.2 那种「闭包漂移」。代价是依赖树 **360 MB → 504 MB**。

## 一、比对方法

| 手段 | 材料 |
|---|---|
| 两棵完整依赖树 | `.tmp/dsh017`（0.1.7-rc.2，283 个 `@deepseek-ai` 包）vs `.tmp/dsh020`（0.2.0-rc.2，289 个） |
| 端点 + 参数包裹字段 | 全量提取 `typert.host.js` 的 `id: '<pkg>#<endpoint>'` 与 `parameters[].name` |
| 关键包 `lib/` 逐字节 | `diff -ru`（结果见 §二） |
| 存储域 | 扫描 `defineDomain({name, version})` |
| 实机冒烟 | `DSH_HOME=.tmp/smokehome node …/lib/bin.js web --no-open --port 39123`（0.2.0）+ `--port 39231`（`npm ci` 装出的闭包树） |

## 二、逐面核对

### A 进程 / 就绪 / 鉴权 —— 无变化（实测）

- `dsh-web-app/lib`、`dsh-client-connection/lib` **逐字节相同** → 启动参数、`printUrl`、就绪行、
  `dsh-auth-*` cookie 派生与 `/api` 门禁、WebSocket 帧 `{type:"open", streamId, endpoint, payload}`
  全部不变；`SessionAddress` 仍是 `kind:"session"|"subagent"`。
- 实测就绪行：`dsh web: http://127.0.0.1:39123/?token=<43 字符>`。
- 实测鉴权：`GET /?token=…` → `303` + `set-cookie: dsh-auth-…`（`Max-Age=2592000; HttpOnly;
  SameSite=Strict`）；裸 `GET /` → `401`；带 cookie 后页面含 `__DSH_BOOT__`。
- Node：本机 v22.23.2 起得来；两版都**没有 `engines` 字段**（E2 的 ≥22 约束未变）。

### B 注入脚本 / DOM / 传输 —— 锚点全在（行为待实测）

| 锚点 | 0.2.0-rc.2 位置 |
|---|---|
| 会话行 `[role="treeitem"]` + `className` 含 `sessionRow` | `dsh-client-ui-workspace/lib/client.js` |
| 工作区行 `projectRow`，行内**最后一枚 button = 新建会话** | 同上（`ProjectRowItem` 结构未变） |
| `data-slot="sidebar.settings"` | `dsh-client-ui-sidebar` / `dsh-client-ui-settings-general` |
| `data-composer-input` / `__lexicalEditor` / `reference-chip` | `dsh-client-ui-conversation/lib/client.js` |
| `fileMention` / 内联文件按钮 | `dsh-client-ui-chat/lib/client.js` |
| `data-presented-files-row` / `data-changed-files`（路径在 `aria-describedby` 隐藏 span） | `dsh-client-ui-deliverables/lib/client.js` |
| `data-open-target` / `data-open-path-open`（0.1.7 的放行项） | `dsh-client-ui-open-in-app/lib/client.js` |
| `openFile` 仍走页面内 `ctx.sidebarRight.openResource`（不发 RPC） | 6 个 UI 包 |

`dsh-client-ui-chat`（451 行）、`ui-conversation`（187 行）的改动集中在 shimmer 装饰与提交尝试
（`submission`）等内部逻辑，**没有碰文件打开与引用 chip 两条路径**；`ui-deliverables` 的 6 行全是 CSS。

### C 一元 RPC —— 只增不减

- 新增（壳层不用）：`productAnalytics/{enabled,report,watchPolicy}`、`userQuestions/answer`、
  `userQuestions/attachWait`。
- 壳层使用的 17 个端点全部存在；`workspace/list` **仍 404**（磁盘兜底照旧）、`subagents/list`
  与 `session/history` 在 0.1.7 就已不在（注入脚本里的旧名只是兜底，无害）。
- 实测：`session/list` 带 `{"args":{"_request":{}}}` 返回 `ok:true`；`workspace/create` 返回
  `{workspace:{workspaceId,path,title,…}, created}`；`session/create` 返回
  `{sessionId, agentPreset}`（**新增 `agentPreset`，纯追加**）。
- `session/list` 条目字段仍是 `{sessionId, updatedAt, running, blank, parentSessionId?, origin?, cwd?,
  projections:{kind, asOfSeq, values:{title,…}}}`；`throughSeq` 语义与 `past cursor` 报错未变。

### D `$DSH_HOME` 磁盘布局 —— 未变（实测）

- 存储域与 0.1.7 完全一致：`workspace v2`、`session_projcache v7`、`schedule v1`。
- 实机 `workspace/create` 后 `storages/workspace.json` 仍是 `{"unit":{"name":"workspace","version":2},…}`。
- 会话格式仍 `SESSION_FORMAT_VERSION = 4`（`session.v4.jsonl[.zstd]`）→ `core/lib/review-log.js`
  的「规范名枚举 + 最大世代优先」无需改。
- `dsh-session` 有 471 行改动，但**没有新增/删除任何事件类型字符串**；`tool/ptc-dispatch[-start]`、
  `subCallId`/`rootCallId`/`parentCallId`、`tool/result.meta.diffs` 都在。
- `dsh-skill-filesystem/lib` **逐字节相同** → 技能四根与 rank、`user-invocable` /
  `disable-model-invocation` 规范键不变。

### E 分发 / 升级 / 运行时闭包

- 入口仍是 `lib/bin.js`，`web` 子命令实测可用。
- 闭包：278 个 `@deepseek-ai/dsh-*` 全 0.2.0-rc.2，另有 4 个固定旧版（格式迁移器，与 0.1.7 同）。
- 依赖声明 `@deepseek-ai/dsh-*` **476 处全部精确版本**（0 caret）；cordis 工具链用 `~`。
- **体积**：`node_modules` 360 MB → 504 MB（+144 MB，+40%），`@deepseek-ai` 包 283 → 289；
  新增顶层依赖 `@deepseek-ai/dsh-experimental-schedule-bundle`。与
  `docs/plans/APP_SLIM-app-size.md` 的体积目标直接相关。
- 已生成 `platforms/macos/runtime-locks/dsh-0.2.0-rc.2/`（`package.json` + `package-lock.json`，
  611 个包条目，resolved 全部 `registry.npmmirror.com`），并用 `npm ci` + 启动冒烟验证通过。

## 三、上游新增了什么（对壳层是观察项）

1. **产品分析 / 遥测两行**：`desktop-product-telemetry`（host OTel）与 `product-analytics`（客户端）
   新增，默认 `enabled: true`，上报 `https://dsh-otel-collector.deepseeksvc.com/v1/logs`。但两行都带
   `disabled: profileContext.name !== 'desktop'` → `dsh web` 下**不挂载、不上报**。壳层现状不需要处理；
   若将来改用 `desktop` profile 名，需要补隐私说明。
2. **`userQuestions` 会话投影 + `ask_user_question` 限时等待**：新增投影键与 `timeout` 参数，
   新增 `userQuestions/answer`、`attachWait` 端点。默认 preset 补丁与 0.1.7 **逐字节相同** ⇒
   工具可用性未变；频道驱动的会话若遇提问仍会停在等待回答（既有行为，不是本次回归）。
3. **`ui-settings-session-log`** 新增设置页；`schedule` / `ui-schedule` / `time-context` 从 web 组合移除
   （0.1.7 里本就是 `disabled: true`，壳层零引用）。
4. **会话标题口径**：客户端改用 `session.title`（不再 `displayTitle`），未命名会话侧栏显示
   「未命名 / Untitled」而不是空串。`sessionOpenerScript` 的「按标题精确匹配」对未命名会话本就依赖
   退路（组内第一行），逻辑不受影响；实测时请专门点一条未命名会话。
5. 会话重命名快捷键 `KeyR` → `KeyG`（壳层不依赖）。

## 四、版本口径（为什么是 rc.2，以及会看到什么提示）

- 用户决定：**钉 `0.2.0-rc.2`**（不追 latest `0.2.2-rc.5`）。
- 站内升级助手是 **stepwise**（`core/lib/upgrade.js` `nextStepTarget`），实测：
  `0.1.7-rc.2 → 0.2.0-rc.1`、`0.2.0-rc.2 → 0.2.1-rc.1`。因此**推进到 0.2.0-rc.2 后，
  站内会立刻提示「可升级到 0.2.1-rc.1」**——这是预期行为（与 0.1.5-rc.2 那次提示 rc.3 同类），
  不是构建错误。若要消除提示，只能把内置版本再往前推（0.2.2-rc.5 是当前 latest）。
- 闭包自洽：不像 0.1.5-rc.2 那样「顶层 rc.2、子包 rc.3」，本次 278 个子包全为 0.2.0-rc.2。

## 五、改动清单

| 项 | 位置 |
|---|---|
| 默认 spec（3 处 + 打印行 + 头注释） | `platforms/macos/build-app.sh` |
| 新闭包锁 | `platforms/macos/runtime-locks/dsh-0.2.0-rc.2/{package.json,package-lock.json}` |
| 兼容清单复盘 | `docs/process/dsh-version-impact.md` §4.7 |
| 版本矩阵 / 事实 | `README.md`、`docs/research/productization.md`、`.dsh/wiki/` |
| 变更记录 | `CHANGELOG.md` `[Unreleased]` |

## 六、实测状态

已做（本次）：

- [x] 两份依赖树静态比对（端点 / 参数 / 存储域 / 关键包 / DOM 锚点）
- [x] 新 lock `npm ci` 成功（542 包）且**冒烟起得来**（0.2.0-rc.2，端口 39231）
- [x] 就绪行 / 401 / 303 + cookie / `__DSH_BOOT__` / `session/list` / `workspace/create` 实机验证

待做（随构建 / 上机复核，见 `docs/process/dsh-version-impact.md` §5）：

- [ ] 开发版启动 → 切会话看 `app.log: project directory followed session`（B1–B4 / WS 观察层）
- [ ] 面板点会话行 / 点文件链接（绝对 + 相对路径）/ 交付卡片 / 变更卡 / 右键「添加到对话」
- [ ] 项目面板：新建工作区 → 侧栏出现；「新会话」→ 复用 blank 会话；「在 dsh 中打开」
- [ ] 审查面板：新会话的活日志是 `session.v4.jsonl`，且 `mutations > 0`（R7 / R7b）
- [ ] `node --test core/tests/`、`scripts/local-ci.sh swift`、八面板 `DSH_PANEL_TEST` 扫描
