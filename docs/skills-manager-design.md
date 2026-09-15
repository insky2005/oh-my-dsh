# 技能面板（Skills Manager）设计

> 状态：开发线（feature/skills-manager）
> 关联：`docs/builtin-skills-design.md`（内置技能全局安装）、`docs/dsh-version-impact.md`（D2 磁盘布局耦合面）
> 实现：`platforms/macos/src/SkillsCore.swift`（模型）、`SkillSources.swift`（网络/安装）、`SkillsPanel.swift`（UI）

## 1. 目标

在壳层内完成 Skill 的**查找 / 安装 / 移除**与**调用开关**管理，不离开 App、不修改 dsh 源码：

1. **registry 是可配置项**：每条 registry 描述「怎么搜（searchURL 模板）、从哪列清单（catalog）」；选中后「可安装」列表直接渲染该 registry 的技能清单；
2. **查找**：registry 清单（well-known index / GitHub 仓库）、关键字搜索（skills.sh 型）、已安装技能本地搜索 + 级别筛选；
3. **安装**：从清单勾选、输入地址、手动导入本地目录/SKILL.md；目标 = **用户级**（默认）或**项目级**；
4. **移除**：仅 用户级 / 项目级；
5. **开关**：非内置技能可设 `user-invocable` 与 `disable-model-invocation`，重启后保持；
6. **级别标注**：每行标 **内置 / 用户级 / 共享级 / 项目级**；**内置只读**；**共享级可改开关但不可移除**。

面板入口：活动栏「技能」（`puzzlepiece`）/ 视图菜单 / **⌥⌘S**；右栏面板槽第 8 个成员（`RightPanel.skills`）。

## 2. dsh 侧契约（实测，实施以此为准）

来源：`@deepseek-ai/dsh-skill-filesystem/lib/index.js`（`FileSystemSkillProvider.roots()` / `parseInvocationPolicy`）。

| rank | 根 | source | 面板级别 | 改开关 | 移除 | 安装目标 |
|---|---|---|---|---|---|---|
| 100 | `<projectRoot>/.dsh/skills` | project-dsh | 项目级 | ✅ | ✅ | ✅ |
| 200 | `<projectRoot>/.agents/skills` | project-agents | 项目级 | ✅ | ✅ | — |
| 400 | `$DSH_HOME/skills`（`.system` 跳过） | user-dsh | **内置** / **用户级** | 内置❌ | 内置❌ | ✅（用户级） |
| 500 | `$DSH_AGENTS_HOME` 或 `~/.agents/skills` | user-agents | 共享级 | ✅ | ❌ | ❌ |
| 600 | `$DSH_BUNDLED_SKILL_DIR` | bundled | App 未设置，忽略 | — | — | — |

- 目录束 = `<dir>/SKILL.md`；根下扁平 `*.md` 也是技能；rank 小者同名优先（项目级 > 用户级 > 共享级）；其余同名者标「被遮蔽」；
- frontmatter：`name`（须匹配 `^[a-z0-9]+(?:-[a-z0-9]+)*$`，否则**整个文件被 dsh 忽略**）+ `description` 必填；
- 调用开关**只认 frontmatter**：`user-invocable`（默认 true）、`disable-model-invocation`（默认 false）；旧的驼峰键（`userInvocable`/`modelInvocable`/`disableModelInvocation`）会让 dsh **抛错并忽略整个技能**——面板只写规范键；
- dsh 对这些根有 chokidar 监听，写盘即生效，无需重启。

**内置技能的判定**（三者同时满足）：位于 `$DSH_HOME/skills/<name>` **且** `<name>` ∈ 内置名集合（`BuiltinSkill.dirName` ∪ 旧名）**且** 存在旁路标记 `.ohmy-dsh-managed`。这样用户装的同名技能不会被误判为内置（也不会被误锁）。

## 3. 级别与可写性

| 级别 | 说明 | 开关 | 移除 |
|---|---|---|---|
| 内置 | App 随包安装、启动时与内嵌内容同步（`SkillInstaller`） | 只读（显示当前生效值） | 不提供 |
| 用户级 | `$DSH_HOME/skills` 下其余技能（面板安装的默认目标） | ✅ | ✅ |
| 共享级 | `~/.agents/skills`，由 skills CLI 等外部工具管理（同级还有 `~/.agents/.skill-lock.json`） | ✅（直接改文件） | 不提供（用外部工具管理） |
| 项目级 | 当前工作区的 `.dsh/skills`（或 `.agents/skills`） | ✅（仓库内会产生 git diff） | ✅ |

**内置只读是硬约束**：面板不给任何写入入口，`SkillInstallService` 对 `builtin` / `shared` 级别分别抛 `builtinReadOnly` / `sharedNotRemovable`，安装时同名目标是内置技能则抛 `builtinProtected`。因此 `SkillInstaller.swift` **无需改动**：内嵌 markdown 与已安装文件始终字节一致（`tests/skills` 的字节断言不受影响）。

## 4. registry 模型

```
RegistryEntry { id, label, enabled,
                searchURL?: "https://skills.sh/api/search?q={q}&limit={limit}",
                catalog: { kind: none | wellKnown | githubRepo, url } }
```

- 存储于 `$DSH_HOME/shell/skills.json` 的 `registries`；**默认预置一条 skills.sh**（`catalog.kind = none`；base 可被 `SKILLS_API_URL` 覆盖）；
- 两个工具栏都用**扁平标签**（`SkillTabStrip`）而不是下拉：registry 标签在左、级别筛选在左（顺序：全部 / 共享级 / 内置 / 用户级 / 项目级），搜索框统一右对齐；
- **「可安装」列表 = 当前 registry 的清单**：`wellKnown` → 拉 `<base>/.well-known/skills/index.json` 列出；`githubRepo` → `git clone --depth 1` 后本地扫描列出（避免 GitHub API 限流）；`none` → 提示「未配置清单来源」并转为关键字搜索；
- 添加 registry 时自动探测：`owner/repo` 或 GitHub 地址 → `githubRepo`；以 `/.well-known/skills/index.json` 结尾或该索引可访问 → `wellKnown`；其余 URL → 视为 skills.sh 兼容的搜索接口（`<base>/api/search?q={q}&limit={limit}`）；
- 组织级全仓枚举（`owner/*`）列为后续项。

### 默认视图：热门（按安装量）

进入「可安装」页签时列表**不会空白**：

- registry 有清单来源（`wellKnown` / `githubRepo`）→ 直接列出该 registry 的清单；
- registry 只有搜索接口（`skills.sh` 型）→ 拉**热门列表**：以 registry 的 `popularQueries`（默认预置 `["sk","ag"]`）做宽查询，合并去重后**按 installs 降序取前 30**。实测依据：`GET /api/search?q=sk&limit=100` 返回 100 条、按安装量降序（3.4M → 357K，覆盖 vercel-labs / anthropics / mattpocock / microsoft 等主力来源）；两个宽查询合并可提高覆盖面。状态栏显示「热门 · 按安装量」，用户输入关键字后即切换为搜索结果；「刷新」会重新拉取。

`popularQueries` 是 registry 配置项的一部分（可在 store 中改；管理页卡片会显示当前取值）。

### 详情页

候选卡上的「详情」按钮打开该技能的**人类可读页面**（在壳层浏览器面板内，不切系统浏览器），URL 按来源推导（`SkillCandidate.detailURL(registry:)`）：

| 来源 | 详情页 |
|---|---|
| skills.sh 型搜索命中 | `<registry host>/<source>/<skill>`，如 `https://www.skills.sh/vercel-labs/skills/find-skills` |
| GitHub 清单 | `https://github.com/<owner>/<repo>[/tree/<ref\|HEAD>/<subpath>]` |
| well-known 清单 | `<base>/.well-known/skills/<name>/SKILL.md` |
| 裸 git | 远端 URL（去掉 .git） |
| 本地路径 | 无页面 → 改为在 Finder 中显示 |

### 为什么 skills.sh 只能搜不能列

实测（`skills@1.4.5` 源码 + 线上 API）：skills.sh 公开接口只有 `GET /api/search?q=<≥2 字符>&limit=N` → `{skills:[{id, skillId, name, installs, source}]}`；`/api/leaderboard`、`/api/skills`、`/api/skill` 均 404；站点虽有 `/`、`/trending`、`/hot`、`/official`、`/topic/<x>`、`/<owner>/<repo>` 等页面，但没有对应 JSON API。**结论：不做 HTML 抓取**；想要「可浏览清单」，在该 registry 里补一个清单来源（`owner/repo` 或 well-known 地址）即可。

## 5. 地址形态（对齐开源 skills CLI 的 `parseSource`）

| 输入 | 解释 |
|---|---|
| `owner/repo`、`owner/repo/<subpath>` | GitHub 仓库（可先列清单再勾选） |
| `owner/repo@skill` | GitHub 仓库中的单个技能（直接安装） |
| `https://github.com/o/r[/tree/<ref>/<subpath>]` | GitHub 仓库/子目录/引用 |
| `https://gitlab.com/...`、任意 `*.git` | 通用 git 远端 |
| `https://host[/path]`、`.../SKILL.md` | well-known registry（`index.json`） |
| `/path/to/skill`、`~/skill`、`./skill` | 本地目录或单个 SKILL.md（手动导入） |

**取回方式**：优先 `/usr/bin/git clone --depth 1 [--branch <ref>]`（凭据提示被禁用：GUI 无 tty，私有仓库应快速失败并提示改用 SSH 地址或 CLI）；git 不可用且源是 github.com 时退化为 `codeload.github.com` tarball + `/usr/bin/tar`；well-known 逐文件 HTTP 取回。技能目录**整目录复制**（SKILL.md + references/scripts 等附件），隐藏文件与 `node_modules/.git/dist/build/__pycache__` 跳过，单文件 ≤ 2 MB、总数 ≤ 400。所有相对路径校验，拒绝绝对路径与 `..`。

## 6. 调用开关的落地方式

dsh 只认 frontmatter，所以开关必然写进 SKILL.md；为了**可逆**（切回默认即字节还原），规则是：

- 目标值 == **基线** → **删除该键**；否则写入 `key: true|false`；
- 基线 = 面板安装时源文件的取值（随安装记录保存），或外部技能首次改动前的取值（随 invocation 记录保存）；
- 只增删改这两行：键序、注释、引号、CRLF/LF、正文全部原样保留（不是 YAML 往返）；
- 记录写入 `$DSH_HOME/shell/skills.json` 的 `invocation`；面板重装/更新同一技能时按记录重放，用户的开关不会被源文件覆盖；
- 外部技能（共享级、仓库自带项目级）只改文件不记覆盖；其被外部工具重新拉取可能重置开关（UI 已注明）。

## 6.1 让 dsh web 立刻看到改动（客户端缓存失效）

改动写完 `SKILL.md` 后，**dsh web 的对话输入框（输入 `/` 的技能菜单）不会自动更新**——它按会话级缓存技能目录：

- `dsh-client-ui-skill` 用 `Map<sessionId, {promise, settled}>` 缓存 `skills/list` 的结果，**只在两种情况失效**：`agent-preset/selected`（切换 agent preset）与 `connection/reset`（客户端连接重连）；`connection/reset` 由 `dsh-api-gateway` 在连接进入 "connected"（含重连）时触发；
- skills 变化**不是会话事件**，服务端不会向客户端推送，所以外部改动（本面板、手改文件、CLI 安装）不会让这个缓存失效——这正是"必须刷新页面才生效"的原因。

壳层的处理：改动后向 web 页注入一小段 JS，派发**浏览器 offline → online 事件**；dsh 客户端自身的连接循环监听这两个事件（`window.addEventListener('online'/'offline')` → `setNetworkAvailable`），于是它会**重连并触发 `connection/reset`**，各客户端插件的缓存（含技能目录）随之清空并重取——效果与手动刷新一致，但不重载文档。

- 实现：`AppDelegate.nudgeDSHWebCaches()`（`platforms/macos/src/main.swift`），由面板的 `onCatalogChanged` 在**改开关 / 安装 / 移除**后触发；
- 1.5s 节流，避免连续改多个技能时反复重连；
- 逃生开关：`DSH_SKILLS_NO_NUDGE=1` 关闭该行为（此时与手动刷新前的表现一致）；
- 边界：重连会中断"正在流式输出"的那条流（客户端会自行重连并重新拉取会话状态，服务端那一轮不受影响）——这是客户端既有的恢复路径。

## 7. 磁盘布局（壳层自有）

```
$DSH_HOME/shell/skills.json        # 版本化 JSON，原子写
  registries: [{id,label,enabled,searchURL?,catalog:{kind,url}}]
  invocation.<name>: {baselineUserInvocable, baselineDisableModelInvocation,
                      userInvocable, disableModelInvocation, updatedAt}
  installed.<name>:  {source, sourceType, sourceUrl, ref, path, level,
                      baseUserInvocable, baseDisableModelInvocation,
                      contentHash, installedAt, updatedAt}
```

与 `shell/config.json` 同目录（App 自有），但不走 `ShellConfig`/`ohmy-core settings`：值是结构化对象、成批变更，独立文件避免每个键一次 node 子进程。缺失/损坏时按空配置处理（不抛错）。

## 8. 边界与失败模式

- **网络不可达**（skills.sh 在部分网络被墙）→ 明确错误 + 可重试，临时目录清理，不写半成品；
- **ATS**：仅接受 `https`（`127.0.0.1`/`localhost` 例外），其余报 `insecureURL`；
- **非法技能名**（大写/下划线）→ 安装前拒绝并提示（dsh 会静默忽略该技能）；
- **同名冲突** → 确认后覆盖；同名目标是内置 → 拒绝（提示改名或换目标级别）；
- **项目级安装/改开关** → 确认框提示会写用户仓库（git diff）；
- **共享级** → 无移除入口；改开关会与外部工具的 lock 无关联，重新拉取可能重置；
- **权限/删除失败** → 报错且不改动 store（保持记录与磁盘一致）；
- **大仓库克隆慢** → 状态行显示进行中，UI 不阻塞（后台队列 `com.ohmydsh.skills`）。

## 9. 测试

- `tests/skills-panel/run.sh`（无头，注入假传输）：地址解析 8 形态、frontmatter 解析/增删改保字节（含 CRLF）/无 frontmatter 报错/非法名、四类根扫描与级别判定 + rank 去重与「被遮蔽」、内置/共享级写操作拒绝、安装（附件复制/冲突/非法名/路径穿越/两种目标级别/store 记录）、移除、registry 存储与默认预置、searchURL 模板渲染与 URL 编码、well-known 索引校验（非法条目与穿越拒绝）、搜索响应解析、`catalog` 分派（well-known / githubRepo 假克隆 / none）、`probe` 三类探测；
- `tests/skills/run.sh`（既有）：内置技能安装/迁移语义不变（本面板不改 `SkillInstaller`）；
- `tests/l10n/run.sh`：新增文案中英成对。
- 已在 `scripts/local-ci.sh` 与 `.github/workflows/ci.yml` 注册。

## 10. 明确不做（v1）

- 已装技能的检查更新 / 回滚（安装记录已含 source 与 contentHash，后续可加）；
- 对内置技能的任何写操作；
- skills CLI 的 agent 目录同步；`~/.agents/skills` 的写入；
- skills.sh 的 HTML 抓取、组织级清单枚举；
- 技能签名/来源审计（只在安装确认处提示「技能以完整代理权限运行」）；
- MCP / plugin 管理。
