---
title: 模块：SkillInstaller.swift（内置 Skill 全局安装器）
tags: [module, skills, installer, provisioning, dsh-home]
updated: 2026-08-22T15:04:38Z
sources: [platforms/macos/src/SkillInstaller.swift, platforms/macos/src/main.swift, docs/builtin-skills-design.md, .dsh/skills/web-dev-tools/SKILL.md, .dsh/skills/repo-knowledge/SKILL.md, .dsh/skills/issue-resolve/SKILL.md, tests/skills/run.sh, tests/skills/skills-tests.swift]
manual: false
---

# 模块：SkillInstaller.swift（内置 Skill 全局安装器）

v1.13.0 开发线（PR #27 feature/builtin-skills-global）新增，Foundation-only 的**内置 Skill 供给器**：App 启动时把三个内置 agent skill 安装到全局 dsh Home（`$DSH_HOME/skills/`），支持缺失安装、受管更新、旧名迁移，用户定制不覆盖。无 UI，只经 `AppLog` 记日志。设计见 `docs/builtin-skills-design.md`。

## 背景：为何全局化

三个内置 skill 原按「面板动作触发 + 写入项目目录 `<repoRoot>/.dsh/skills/`」安装——安装时机/位置模糊、只在跑过面板的仓库可见。改为 **App 启动时安装到全局 `$DSH_HOME/skills/`**（dsh 的 user-dsh 根，rank 400，高于 `~/.agents/skills`(500) 与 bundled(600)），任何 workspace 都能发现，跨仓库生效。dsh 提供者对 skill 根自带 chokidar 监听，写入后自动识别、无需重启。

## 重命名映射（单一事实来源）

| 面板 | 旧名 | 新名 | 能力 |
|---|---|---|---|
| Browser | `shell-browser` | `web-dev-tools` | 驱动内嵌浏览器排查网页问题 |
| Repo Wiki | `repo-wiki` | `repo-knowledge` | 生成/维护仓库知识库 `.dsh/wiki/` |
| Tasks/IssueRunner | `issue-fix` | `issue-resolve` | 端到端解决 GitHub issue |

命名统一「领域词-能力词」双段 kebab，符合 dsh 命名约束 `/^[a-z0-9]+(?:-[a-z0-9]+)*$/`。

## 组成

| 类型 | 职责 |
|---|---|
| `enum BuiltinSkill` | `CaseIterable`；三个 case（`webDevTools`/`repoKnowledge`/`issueResolve`），`dirName`（新名）、`legacyName`（旧名，供迁移）、`markdown`（内嵌 SKILL.md，**与仓库 `.dsh/skills/<新名>/SKILL.md` 字节一致**，有同步测试断言） |
| `enum SkillInstaller` | `managedMarker = ".ohmy-dsh-managed"`；`dshHomeDir()`（`env["DSH_HOME"] ?? NSHomeDirectory()+"/.dsh"`，与 dsh web 同一解析）；`legacyRenameMap`；`installBuiltinSkills() -> [InstallResult]`——先跑旧名迁移、再跑安装状态机；`FileManager` 原子写，失败不抛、记 `AppLog` |

## 启动安装状态机（对每个内置 skill）

- **未安装**（无 SKILL.md）→ 写 SKILL.md + 托管标记 `.ohmy-dsh-managed`；
- **已安装且受管**（`.ohmy-dsh-managed` 存在）：
  - 内容一致 → 跳过（不重写）；
  - 不一致（有更新）→ 覆盖 SKILL.md（保留标记）；
- **已安装但非托管**（有 SKILL.md、无标记，用户手工/外部安装）→ **不覆盖、不删除**，记 `skipped: user-managed`。

托管标记放**旁路文件** `<skill>/.ohmy-dsh-managed`（不写入 SKILL.md 内），保持 SKILL.md 与仓库副本、内嵌常量字节一致。

## 旧名迁移（启动时）

对每个 `legacyName -> 新名`：若 `$DSH_HOME/skills/<新名>` 不存在且 `<旧名>` 存在 → rename 旧→新（校验/写入新内容 + 托管标记）；若新名已存在 → 新名优先、旧名目录保留并记日志（不删用户数据）。**不主动改用户项目目录**里残留的旧名 `.dsh/skills/`。

## 接入与移除

- **启动**：`main.swift` `applicationDidFinishLaunching` 在 `buildWindow()`/dsh web 启动前调用 `SkillInstaller.installBuiltinSkills()`（best-effort，失败不阻塞启动；复用已有 dsh web 同样生效）；
- **移除按仓库安装**：`WikiPanel.swift` 停用 `WikiSkill.ensureInstalled`、`IssueRunnerPanel.swift` 停用 `ensureIssueFixSkillInstalled`（及各自调用点）——收敛唯一事实来源；仓库 `.dsh/skills/{web-dev-tools,repo-knowledge,issue-resolve}` 提交副本保留（该仓库自身项目仍以 rank 100 命中）；
- **编译清单**：经 `platforms/macos/swift-sources.sh` 单一事实来源 glob 自动收录（无需登记）。

## 测试（`tests/skills/`，Foundation-only 无头）

`tests/skills/run.sh` + `skills-tests.swift` + 复用 `tests/terminal-emulator/stubs.swift`：把 `SkillInstaller.swift` 拷入临时目录、设 `DSH_HOME` 指向临时空目录，无头 swiftc 编译运行，断言：空 home 生成三新名 SKILL.md + 托管标记且与内嵌一致 / 已装同版本不重写（mtime 不变）/ 已装旧版本 + 受管标记 → 覆盖 / 无托管标记 → 不覆盖 / 旧名迁移 / 幂等。字节一致断言：全局安装 SKILL.md 与仓库 `.dsh/skills/<新名>/SKILL.md` 完全一致。CI（`ci.yml`）与 `scripts/local-ci.sh` swift 阶段均含 `tests/skills/run.sh`。

## 边界与失败模式

- `DSH_HOME` 覆盖：与 dsh web 同一解析；目录不存在先 `createDirectory`；
- 写失败/只读 home：best-effort，记 `AppLog`，不阻塞启动（内嵌说明兜底）；
- 用户定制保护：无托管标记不覆盖；迁移冲突：新名已存在不覆盖旧名、新名优先；
- 并发/重复写：启动串行、幂等。
