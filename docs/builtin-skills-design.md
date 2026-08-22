# 内置 Skill 全局化 + 重命名设计

> 状态：已实现（v1.13.0 开发线，feature/builtin-skills-global）
> 关联面板：Browser / Repo Wiki / Tasks（IssueRunner）
> 关联：docs/plans/BROWSER_PLAN-browser-panel.md、docs/repo-wiki-design.md、docs/issue-runner-design.md、docs/productization.md

## 1. 背景与目标

当前 oh-my-dsh 的三个内置 Skill 各按「按仓库安装」到工作区项目目录 `<repoRoot>/.dsh/skills/`，存在两个问题：

1. **安装时机/位置不明确**：靠面板动作触发、写入具体项目目录，何时装、是否需要装都模糊；只在跑过面板的仓库可见，跨仓库不生效。
2. **命名望文生义、不成体系**：`shell-browser` 像内部实现细节、`repo-wiki` 与面板名雷同、`issue-fix` 过于直白。

本设计将三个内置 Skill **重命名**并改为 **App 启动时安装到全局 dsh Home**，实现缺失检测、更新检测、旧名迁移，全局跨 workspace 生效。

### 成功标准

1. 全新环境（空 DSH_HOME）启动后，`$DSH_HOME/skills/{web-dev-tools,repo-knowledge,issue-resolve}/SKILL.md` 存在、内容与内嵌一致、各含托管标记。
2. 已装旧版本 → 启动自动覆盖为内嵌新版本；已装同版本 → 不重写。
3. 已装但被用户改动（无托管标记）→ 不覆盖、不删除，记日志。
4. 老用户 `$DSH_HOME/skills/{shell-browser,repo-wiki,issue-fix}` → 启动自动迁移为新名。
5. dsh web 在任意 workspace 都能发现这三个 Skill（user-dsh 根，rank 400）。
6. 仓库 `.dsh/skills/` 提交副本、内嵌常量、全局安装三者字节一致（有同步测试）。
7. 除迁移映射表与 CHANGELOG 外，不再出现旧名。

## 2. dsh web 加载 Skill 的机制（已确认）

来源：`@deepseek-ai/dsh-skill-filesystem/lib/index.js`（`FileSystemSkillProvider.roots()`）+ `@deepseek-ai/dsh-home-paths`。

dsh web 从多级根发现 Skill（`SKILL.md` 带 YAML frontmatter `name`/`description`，或根下扁平 `.md`），rank 越小优先级越高：

| rank | 根 | source | 说明 |
|---|---|---|---|
| 100 | `<projectRoot>/.dsh/skills` | project-dsh | 项目级 |
| 200 | `<projectRoot>/.agents/skills` | project-agents | 项目级 |
| 250 | runtime | runtime | 运行时提供者 |
| 300 | customSkillDirs | custom | 配置项 |
| 400 | `$DSH_HOME/skills` | user-dsh | 用户级全局（本设计安装位置） |
| 500 | `$DSH_AGENTS_HOME` 或 `~/.agents/skills` | user-agents | 用户级 |
| 600 | `$DSH_BUNDLED_SKILL_DIR` | bundled | 打包根 |

- `dshHome` = `$DSH_HOME`，否则默认 `~/.dsh`。
- dsh 提供者对上述根自带 chokidar 监听，写入后自动识别、无需重启。
- App 已在 `main.swift`（约 979 行）保证向 dsh web 传入 `DSH_HOME`（未设置时填 `~/.dsh`），安装器沿用同一解析即可保证目录一致。

**结论**：内置 Skill 安装到 **`$DSH_HOME/skills/<skill>/SKILL.md`**（user-dsh，rank 400）——最高优先级用户级全局根，高于 `~/.agents/skills`(500) 与 bundled(600)，所有 workspace 通用。

## 3. 设计

### 3.1 内置 Skill 清单（重命名后）

| 面板 | 旧名 | 新名 | 能力 |
|---|---|---|---|
| Browser | `shell-browser` | `web-dev-tools` | 驱动内嵌浏览器排查网页问题（开页/console/network/eval/截图） |
| Repo Wiki | `repo-wiki` | `repo-knowledge` | 生成/维护仓库知识库 `.dsh/wiki/` |
| Tasks/IssueRunner | `issue-fix` | `issue-resolve` | 端到端解决 GitHub issue（读题→改→测→提交→推送） |

命名统一为「领域词-能力词」双段 kebab 小写，符合 dsh 命名约束 `/^[a-z0-9]+(?:-[a-z0-9]+)*$/`。

### 3.2 全局安装位置

`$DSH_HOME/skills/<新名>/SKILL.md`（每个技能一个子目录，符合目录束格式）。

### 3.3 启动检测流程（SkillInstaller）

对每个内置技能，读取已安装 SKILL.md + 托管标记，按状态决策：

- **未安装**（无 SKILL.md）→ 写 SKILL.md + 写托管标记 `.ohmy-dsh-managed`。
- **已安装且托管**（`.ohmy-dsh-managed` 存在）：
  - 内容一致 → 跳过；
  - 不一致（存在更新）→ 覆盖 SKILL.md（保留标记）。
- **已安装但非托管**（有 SKILL.md、无标记，用户手工/外部安装）→ 不覆盖、不删除，记录 `skipped: user-managed`。

托管标记放旁路文件 `<skill>/.ohmy-dsh-managed`（不写入 SKILL.md 内），从而保持 SKILL.md 与仓库副本、内嵌常量**字节一致**。

### 3.4 旧名迁移

启动时对每个（旧名 → 新名）：若 `$DSH_HOME/skills/<新名>` 不存在且 `$DSH_HOME/skills/<旧名>` 存在 → rename 旧→新（顺带校验/写入新内容与托管标记）；若新名已存在 → 新名优先，旧名目录保留并记日志（不删用户数据）。

**不主动改动用户项目目录**里残留的旧名 `.dsh/skills/`（迁移只针对 `$DSH_HOME/skills/`）；项目中的旧名副本成为孤立旧名，仅日志提示，由用户自行清理。

### 3.5 更新语义

更新 = 内嵌内容 ≠ 已安装内容；仅当文件为 App 托管时才覆盖，避免破坏用户定制。

## 4. 实现（按子系统）

### 4.1 重命名（全局标识）

- 仓库：`git mv` 三个目录 `.dsh/skills/{shell-browser→web-dev-tools, repo-wiki→repo-knowledge, issue-fix→issue-resolve}`；同步改每个 `SKILL.md` frontmatter `name`。
- 内嵌常量：三个 markdown 迁入 `BuiltinSkill` 时改 `name` 为新名；`WikiSkill`/`IssueRunnerPanel` 中旧名引用与 prompt 文案一并改。
- 文档：BROWSER_PLAN / repo-wiki-design / issue-runner-design / README / CHANGELOG 中旧名替换为新名（保留一处「旧名→新名」映射表供迁移说明）。

### 4.2 新增 `platforms/macos/src/SkillInstaller.swift`（Foundation-only，可无头测试）

- `enum BuiltinSkill { case webDevTools, repoKnowledge, issueResolve; var dirName; var markdown }` —— 单一事实来源（收纳三份新名 markdown）。
- `enum SkillInstaller`：
  - `managedMarker = ".ohmy-dsh-managed"`；
  - `dshHomeDir() -> String`（`env["DSH_HOME"] ?? NSHomeDirectory() + "/.dsh"`）；
  - `legacyRenameMap = ["shell-browser":"web-dev-tools", "repo-wiki":"repo-knowledge", "issue-fix":"issue-resolve"]`；
  - `installBuiltinSkills() -> [InstallResult]`：先跑 3.4 迁移、再跑 3.3 状态机；写盘用 `FileManager` 原子写，失败不抛、记 `AppLog`，返回每项结果。

### 4.3 注册编译清单（强制）

- `platforms/macos/build-app.sh`（约 247 行）`SWIFT_SOURCES` += `"$SRC/SkillInstaller.swift"`。
- `.github/workflows/ci.yml`（约 92 行）swiftc compile check 清单同步加入。

### 4.4 接入启动流程

- `main.swift` `applicationDidFinishLaunching`（约 1281 行）：在 `buildWindow()`/`startServer()` 前调用 `SkillInstaller.installBuiltinSkills()`，保证 dsh web 发现前就绪；复用已有 dsh web 的路径同样生效（安装器独立于 spawn）。小文件同步 best-effort，失败不阻塞启动。

### 4.5 移除按仓库安装调用（收敛唯一事实来源）

- `WikiPanel.swift`：停用 `WikiSkill.ensureInstalled(repoRoot:)` 及其调用点（约 1478 行）。
- `IssueRunnerPanel.swift`：停用 `ensureIssueFixSkillInstalled` 及其调用点（约 618 行）；prompt 文案改引全局 `$DSH_HOME/skills/issue-resolve/SKILL.md`（或内嵌说明）。
- 保留仓库 `.dsh/skills/{web-dev-tools,repo-knowledge,issue-resolve}` 提交副本（productization 视为自带文档/自分发；该仓库自身项目仍以 rank100 命中）。

### 4.6 测试（新增 `tests/skills/`，仿 wiki-panel 无头模式）

- `tests/skills/run.sh` + `skills-tests.swift` + 复用 `tests/terminal-emulator/stubs.swift`：把 `SkillInstaller.swift` 拷入临时目录、设 `DSH_HOME` 指向临时空目录，无头 swiftc（Foundation）断言：
  1. 空 home → 三个新名技能各生成 SKILL.md + 托管标记，内容与内嵌一致；
  2. 已装同版本 → 不重写（mtime 不变）；
  3. 已装旧版本 + 托管标记 → 覆盖为内嵌新版本；
  4. 已装 + 无托管标记 → 不覆盖、内容保留；
  5. 迁移：`$DSH_HOME/skills/{shell-browser,repo-wiki,issue-fix}` 存在 → 启动后 rename 为对应新名；新名已存在时旧名保留；
  6. 幂等：重复执行稳定。
- 字节一致断言：全局安装 SKILL.md 与仓库 `.dsh/skills/<新名>/SKILL.md` 完全一致。

### 4.7 文档与发布

- `CHANGELOG.md` 顶部 `[Unreleased]`：重命名 + 启动安装到全局 + 更新检测 + 移除按仓库安装 + 旧名迁移。
- 文档同步新名与「安装位置 → 全局 `$DSH_HOME/skills/`，启动时管理」。

## 5. 边界情况与失败模式

- DSH_HOME 覆盖：安装器与 dsh web 同一解析；目录不存在先 `createDirectory`。
- 写失败/只读 home：best-effort，记 `AppLog`，不阻塞启动；dsh web 仍可用（内嵌说明兜底）。
- 用户定制保护：无托管标记不覆盖。
- 复用已有 dsh web：安装器启动时统一执行，不依赖 spawn/reuse 分支。
- 迁移冲突：新名已存在 → 不覆盖旧名、新名优先。
- 项目目录残留旧名：不动用户项目，仅日志提示。
- 并发/重复写：启动串行、幂等。

## 6. 明确假设/已定决策

1. **新名（已定）**：`web-dev-tools` / `repo-knowledge` / `issue-resolve`。
2. **安装位置**：`$DSH_HOME/skills/`（user-dsh rank 400）——机制确认。
3. **仓库副本**：保留仓库 `.dsh/skills/` 提交副本；仅移除面板按仓库安装调用。
4. **更新语义**：受管标记 + 内容比对，未修改覆盖、用户改过保留。
5. **迁移范围**：仅 `$DSH_HOME/skills/` 旧→新 rename；不主动改用户项目目录。
6. **不设 `DSH_BUNDLED_SKILL_DIR`**：全局安装已覆盖；bundled 根（rank600）最低、收益低，后续如需零写盘只读分发再评估。

