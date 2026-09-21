---
title: 模块：技能面板（Skills Manager）
tags: [module, skills, skill-md, registry, frontmatter, panel]
updated: 2026-09-21T09:43:26Z
sources: [platforms/macos/src/SkillsPanel.swift, platforms/macos/src/SkillsCore.swift, platforms/macos/src/SkillSources.swift, platforms/macos/src/SkillInstaller.swift, platforms/macos/src/main.swift, platforms/macos/src/PreviewPanel.swift, tests/skills-panel/, tests/skills/, docs/skills-manager-design.md, docs/dsh-version-impact.md, docs/builtin-skills-design.md, scripts/local-ci.sh, .github/workflows/ci.yml, README.md, CHANGELOG.md]
manual: false
---

# 模块：技能面板（Skills Manager）

在壳层内管理 agent 技能（SKILL.md）：**查找 / 安装 / 移除**与**调用开关**，不离开 App、不改 dsh 源码。合并自 **PR #50 `feature/skills-manager`**（2026-09-17，HEAD `a704ba1`），随 **v1.16.0**（2026-09-21）发布。设计文档：`docs/skills-manager-design.md`。

- 入口：活动栏「技能」图标（SF Symbol `puzzlepiece`）/ 视图菜单 / **⌥⌘S**；右栏插槽第 8 个成员 `RightPanel.skills`，`rightPanelKind` 持久化 `"skills"`；`SkillsPanelController.minWidth = 300`。

## 组成

| 文件 | 规模 | 职责 |
|---|---|---|
| `platforms/macos/src/SkillsPanel.swift` | 1667 行 | `SkillsPanelController` + 视图（`SkillsRootView`/`SkillCardView`/`SkillTabStrip`/`SkillRowView`/`SkillCandidateRowView`/`RegistryCardView`/`RegistryAddCardView`）+ 纯函数 `SkillHoverResolver` |
| `platforms/macos/src/SkillsCore.swift` | 742 行 | 纯 Foundation 模型：`SkillFrontmatterIO`（frontmatter 读写）、`SkillRoots`/`SkillScanner`（四根扫描 + 级别 + rank 去重）、`SkillStore`（壳层记录 `skills.json`）、`SkillNameRule`、`BuiltinSkillNames` |
| `platforms/macos/src/SkillSources.swift` | 919 行 | `SkillAddressParser`、`SkillTransport`（可注入假传输）、`SkillRegistryClient`（清单 / 搜索 / probe）、`SkillFetcher`（git clone / codeload tarball / well-known HTTP）、`SkillInstallService`（安装 / 移除 / 级别写权限） |
| `tests/skills-panel/` | 4 文件 | 无头测试：模型层 + 控制器冒烟 + 真实绘制回归，`run.sh` 一次跑完（本机实测 **121 项 ok**） |

**不改 `SkillInstaller.swift`**：内置技能由 App 启动时按内嵌内容同步，面板对内置级别只读，内嵌与已装文件的字节一致性（`tests/skills/`）不受影响。

## dsh 侧契约（面板据此判定，实测见设计文档 §2）

| rank | 根 | 面板级别 | 改开关 | 移除 | 安装目标 |
|---|---|---|---|---|---|
| 100 | `<projectRoot>/.dsh/skills` | 项目级 | ✅ | ✅ | ✅ |
| 200 | `<projectRoot>/.agents/skills` | 项目级 | ✅ | ✅ | — |
| 400 | `$DSH_HOME/skills`（跳过 `.system`） | **内置** / 用户级 | 内置❌ | 内置❌ | ✅（用户级） |
| 500 | `$DSH_AGENTS_HOME` 或 `~/.agents/skills` | 共享级 | ✅ | ❌ | ❌ |
| 600 | `$DSH_BUNDLED_SKILL_DIR` | App 未设置，忽略 | — | — | — |

- 目录束 = `<dir>/SKILL.md`，根下扁平 `*.md` 也算技能；rank 小者同名优先，其余标「被遮蔽」；
- `name` 须匹配 `^[a-z0-9]+(?:-[a-z0-9]+)*$` 且 `description` 必填，否则 dsh 忽略整个文件（面板安装前先校验）；
- **调用开关只认 frontmatter**：`user-invocable`（默认 true）、`disable-model-invocation`（默认 false）；旧驼峰键会让 dsh 忽略整个技能——面板只写规范键；
- **内置判定三者同时满足**：位于 `$DSH_HOME/skills/<name>` + `<name>` ∈ 内置名集合（`BuiltinSkill.dirName` ∪ 旧名）+ 存在 `.ohmy-dsh-managed` 标记（用户同名技能不会被误锁）；
- dsh 对这些根有 chokidar 监听，写盘即生效，无需重启。

## 开关的可逆写法（`SkillFrontmatterIO`）

- 目标值 == **基线** → **删除该键**（字节还原）；否则写 `key: true|false`；
- 基线 = 面板安装时源文件取值（随 `installed` 记录），或外部技能首次改动前的取值（随 `invocation` 记录）；
- 只增删改这两行——键序、注释、引号、CRLF/LF、正文全部原样保留（**不是 YAML 往返**）；
- 外部技能（共享级 / 仓库自带项目级）只改文件不记覆盖，被外部工具重新拉取可能重置开关（UI 已注明）。

## 让 dsh web 立刻看到改动（客户端缓存失效）

dsh 客户端按会话缓存技能目录，只在 `connection/reset` 或切换 agent preset 时失效，且技能文件变化不是会话事件、服务端不推送。壳层做法：面板 `onCatalogChanged`（改开关 / 安装 / 移除后触发）→ `AppDelegate.nudgeDSHWebCaches()`（`platforms/macos/src/main.swift`）向 web 页注入 JS 派发**浏览器 offline → online 事件**，触发客户端自身重连并发出 `connection/reset`，各客户端插件缓存随之清空重取——等效于手动刷新但不重载文档。1.5s 节流；`DSH_SKILLS_NO_NUDGE=1` 关闭。边界：重连会中断正在流式输出的那条流（客户端自行重连，服务端那一轮不受影响）。

## registry 模型与「可安装」页签

`SkillRegistryRecord { id, label, enabled, searchURL?, catalog: {kind: none|wellKnown|githubRepo, url}, popularQueries }`，存 `$DSH_HOME/shell/skills.json` 的 `registries`（默认预置一条 skills.sh，base 可被 `SKILLS_API_URL` 覆盖）。

- `wellKnown` → 拉 `<base>/.well-known/skills/index.json`；`githubRepo` → `git clone --depth 1` 后本地扫描（避开 GitHub API 限流）；`none` → 提示「未配置清单来源」并转为关键字搜索；
- 添加 registry 自动探测：`owner/repo` 或 GitHub 地址 → `githubRepo`；well-known 索引可达 → `wellKnown`；其余视为 skills.sh 兼容搜索接口（`{q}`/`{limit}` 模板）；
- **默认视图是热门列表**：只有搜索接口的 registry 用 `popularQueries`（默认 `["sk","ag"]`）做宽查询合并去重、按 installs 降序取前 30，状态栏显示「热门 · 按安装量」；输入关键字即切换为搜索结果；
- **skills.sh 只有搜索接口**（实测 `/api/leaderboard`、`/api/skills` 均 404），**不做 HTML 抓取**；
- 候选卡交互：**整卡可点 = 看详情**（系统默认浏览器，只接受 http(s)；URL 按来源推导：skills.sh 型 → `https://www.skills.sh/<source>/<skill>`、GitHub → 仓库内技能目录、well-known → 该技能 SKILL.md、裸 git → 远端、本地路径 → Finder），**「安装」按钮仅在鼠标移入时出现**；
- **滚动时的 hover 自己重算**：tracking area 只在指针移动时触发，内容从静止指针下滚过不会触发 `mouseExited`（划过的卡片会一直高亮）。面板监听 clip view 滚动通知，每次滚动用纯函数 `SkillHoverResolver.hoveredIndex(cardFrames:clipBounds:mouse:)` 按当前指针位置重算唯一 hover（4 条单测：命中 / 卡片间隙 / 已滚出可视区 / 指针在列表外）。

## 地址形态与取回（对齐开源 skills CLI 的 `parseSource`）

`owner/repo`、`owner/repo/<subpath>`、`owner/repo@skill`、GitHub/GitLab 地址、`*.git`、well-known 地址（`…/SKILL.md`）、本地目录或 `SKILL.md`。取回优先 `/usr/bin/git clone --depth 1`（禁用凭据提示：GUI 无 tty，私有仓库应快速失败并提示改用 SSH 或 CLI）；git 不可用且源是 github.com 时退化为 `codeload.github.com` tarball + `/usr/bin/tar`；well-known 逐文件 HTTP。技能目录**整目录复制**（SKILL.md + references/scripts 等），跳过隐藏文件与 `node_modules/.git/dist/build/__pycache__`，单文件 ≤ 2 MB、总数 ≤ 400，拒绝绝对路径与 `..`。

## 磁盘布局（壳层自有，`$DSH_HOME/shell/skills.json`）

```
registries: [{id,label,enabled,searchURL?,catalog:{kind,url},popularQueries}]
invocation.<name>: {baselineUserInvocable, baselineDisableModelInvocation,
                    userInvocable, disableModelInvocation, updatedAt}
installed.<name>:  {source, sourceType, sourceUrl, ref, path, level,
                    baseUserInvocable, baseDisableModelInvocation,
                    contentHash, installedAt, updatedAt}
```

与 `shell/config.json` 同目录但不走 `ShellConfig`（值是结构化对象、成批变更，独立文件避免每个键一次 node 子进程）；缺失/损坏按空配置处理（不抛错）。

## 边界与失败模式

网络不可达 → 明确错误可重试、清临时目录、不留半成品；仅接受 https（`127.0.0.1`/`localhost` 例外），否则 `insecureURL`；非法技能名安装前拒绝；同名冲突先确认，同名目标是内置则拒绝（`builtinProtected`）；`SkillInstallService` 对 `builtin` / `shared` 分别抛 `builtinReadOnly` / `sharedNotRemovable`；项目级安装/改开关会写用户仓库（确认框提示 git diff）；权限/删除失败报错且不改 store；大仓库克隆在后台队列 `com.ohmydsh.skills` 进行、UI 不阻塞。

## 测试与 QA

- `tests/skills-panel/run.sh`（三阶段，本机实测 121 项 ok）：① 模型层（地址解析、frontmatter 增删改保字节含 CRLF、四根扫描与级别/rank 去重、内置与共享级写拒绝、安装/移除/store、registry 存储与默认预置、searchURL 模板与编码、well-known 索引校验、catalog 分派、probe）；② 控制器冒烟（`NSApplication.shared` + 临时 fixture home：注入开关落盘、安装按钮 hover、卡片点击、hover 解析）；③ **真实绘制回归**（`PreviewPanel.swift` 的 `DynamicFillView`/`HeaderLabel` 离屏渲染，钉住 2119bb1 的越界填充修复）；
- 已接入 `scripts/local-ci.sh` 与 `.github/workflows/ci.yml`（swift job）；`tests/skills/` 的内置技能字节断言不变；
- QA 钩子：`DSH_SKILLS_TEST=1` 启动即开面板（**放在 `DSH_REVIEW_TEST` 之后**，可压过 `DSH_UI_DEBUG` 的浏览器面板）；`DSH_SKILLS_TEST_ROOT=<dir>` 把用户根指向 fixture home（`SkillsPanel.swift` 内读）；`DSH_SKILLS_NO_NUDGE=1` 关闭缓存失效 nudge。

## 明确不做（v1）

已装技能的检查更新 / 回滚（记录已含 `source` 与 `contentHash`，后续可加）、对内置技能的任何写操作、skills CLI 的 agent 目录同步与 `~/.agents/skills` 写入、skills.sh 的 HTML 抓取与组织级（`owner/*`）清单枚举、技能签名/来源审计（仅在安装确认处提示「技能以完整代理权限运行」）、MCP / plugin 管理。
