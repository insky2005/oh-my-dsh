# 壳层数据目录重构（收敛到 `$DSH_HOME/oh-my-dsh/`）

> 状态：✅ 已实现（2026-09-29，feature/storage-refactor）
> 关联：docs/projects-panel-design.md（projects 默认根的既有先例）、docs/dsh-version-impact.md（D3/D5/D6/D7）、docs/session-snapshot-rollback-design.md、docs/channel-storage.md
> 目标：把 **oh-my-dsh 壳层自己产生的工作数据** 从 `$DSH_HOME` 根目录收敛到 `$DSH_HOME/oh-my-dsh/` 下，和 `projects/` 并列；dsh 自有数据与上游契约路径保持不动。

## 1. 背景

壳层的 `projects` 默认根已是 `$DSH_HOME/oh-my-dsh/projects`（ProjectsCore.defaultSubpath），但其余壳层数据仍散落在 `$DSH_HOME` 根：`shell/`、`browser/`、`browser-dev/`、`repo-wiki/`、`channel-runtime/`、`channels/`、`tokens/`、`gh-token`、`browser-api.port`、`shell-api.port`，与 dsh 自有的 `sessions/`、`storages/`、`settings.yaml` 等混在一起，难以区分归属、备份与排障。本重构把这些壳层数据统一收进 `$DSH_HOME/oh-my-dsh/`。

## 2. 目标布局

```
$DSH_HOME/                          # 正式 ~/.dsh；开发版 applyDevIsolation() 注入 ~/.dsh-dev
├── oh-my-dsh/                      # ★ 壳层工作数据根（本重构新增收敛）
│   ├── projects/                   # 项目面板工作区（已就位）
│   ├── shell/                      # config.json / skills.json / dsh-web.json / dsh-state.json / rollback-journal.json / snapshots/
│   ├── browser/                    # CEF/Chromium profile（正式版与开发版统一，去掉 browser-dev）
│   ├── repo-wiki/                  # Wiki 面板「DSH_HOME 私有」根（按仓库 hash 分目录）
│   ├── channel-runtime/            # 通道 runner 运行目录
│   ├── channels/                   # 通道凭据/会话映射/消息分桶/state/workspaces
│   ├── tokens/                     # GitHub 按仓库 token
│   ├── gh-token                    # GitHub 通用 token
│   ├── browser-api.port            # 浏览器面板 localhost API 端口
│   └── shell-api.port              # 任务面板 localhost API 端口
├── sessions/ storages/ settings.yaml ...   # dsh 自有：不动
└── skills/                         # dsh 用户技能目录：不动（上游只认此路径）
```

### 不迁移（明确保持）
- `$DSH_HOME/skills/`：dsh 上游只扫描该路径，迁走会让技能失效；
- dsh 自有数据（`sessions/`、`storages/`、`settings.yaml`、`.credentials.yaml`、`profiles/`、`attachments/`、`scaffold-stages/`、`llm-deepseek/`、`.anonymous-user-id`）；
- `~/Library/Logs/oh-my-dsh/`、`~/Library/Caches/oh-my-dsh/`、Application Support 运行时：**本次不动**（macOS 规范）。

### browser-dev 的去留
`applyDevIsolation()` 已把开发版 `DSH_HOME` 指到 `~/.dsh-dev`，`startCEF()` 再追加 `/browser-dev` 属于双重隔离。本次统一为 `<DSH_HOME>/oh-my-dsh/browser`，删除 `browser-dev` 命名。

## 3. 单一事实来源

- core：`core/lib/shell-paths.js` —— 常量 `SHELL_ROOT = 'oh-my-dsh'` + 各子路径解析 + `migrateLegacyLayout(home)`；
- Swift：`platforms/macos/src/ShellPaths.swift` —— 同名字段/子路径 + `migrateLegacyLayout(home:)`（启动时调用，覆盖 `~/.dsh` 与 `~/.dsh-dev`）。

## 4. 迁移策略（一次性、幂等、不丢数据）

对每个旧路径 → 新路径：
1. 源不存在 → 跳过；
2. 目标已存在 → 保留目标、记 `app.log`，跳过（避免覆盖新数据）；
3. 否则同卷 `rename`（DSH_HOME → 其子目录，同卷、瞬时）；失败则保留源并记日志。

覆盖清单：`shell`、`browser`、`browser-dev`(→`browser`)、`repo-wiki`、`channel-runtime`、`channels`、`tokens`、`gh-token`、`browser-api.port`、`shell-api.port`。
- 开发版额外：`~/.dsh/browser-dev`（隔离前的共享 legacy）→ `~/.dsh-dev/oh-my-dsh/browser`，目标已存在则跳过。
- 触发点：Swift 启动（`applicationDidFinishLaunching`，且在任何 `ShellConfig` 读取之前，紧跟 `applyDevIsolation()`）；core CLI 入口 `core/bin/ohmy-core.js` 启动时调用一次（无头使用兜底）。

## 5. 改动面

| 层 | 文件 | 改动 |
|---|---|---|
| core | `core/lib/shell-paths.js` | 新增：路径解析 + 迁移 |
| core | `settings.js` / `snapshot-io.js` / `channel-store.js` / `channel-sessions.js` / `dingtalk-access.js` / `channel-runner.js` | shell/channels/channel-runtime 走新根 |
| core | `core/bin/ohmy-core.js` | CLI 启动迁移一次 |
| Swift | `ShellPaths.swift` | 新增 |
| Swift | `ShellConfig` / `SkillsCore` / `SnapshotWindow` / `WikiPanel` / `IssueRunnerPanel` / `ChannelStoreReader` / `ChannelPanel` / `main.swift` | 各路径改走新根；启动迁移；去掉 browser-dev |
| 技能 | `SkillInstaller.swift` 内嵌 SKILL.md + 仓库 `.dsh/skills/*/SKILL.md` | 端口/token 路径说明；两份保持字节一致 |
| 测试 | `core/tests/*`、`tests/snapshot-rollback`、`tests/shell-config`、`tests/skills-panel`、`tests/wiki-panel`、`tests/tasks-panel` | 路径断言更新 |
| 文档 | README / AGENTS / CONTRIBUTING / docs/* / CHANGELOG | 路径与新布局说明 |

## 6. 快照排除

`core/lib/snapshot.js` 的 `SNAPSHOT_EXCLUDES` 增加 `oh-my-dsh`（壳层状态不得进回滚快照）；原 `shell`/`browser`/`browser-dev`/`channels`/`tokens` 可保留以兼容旧 home。

## 7. 验收

1. `node --test core/tests/` 全绿；
2. `tests/snapshot-rollback/run.sh`、`tests/shell-config`、`tests/skills-panel`、`tests/wiki-panel`、`tests/tasks-panel` 全绿；
3. 真实 `~/.dsh` / `~/.dsh-dev` 启动后：旧路径消失、新路径出现，数据内容一致（`.dsh/oh-my-dsh/` 下），核心功能（项目/浏览器/通道/任务/技能/快照）可用；
4. `git status` 仅含本次改动。
