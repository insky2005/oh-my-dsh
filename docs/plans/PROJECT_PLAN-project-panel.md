# 项目面板（Project Panel）设计文档

> 状态：阶段一（设计文档）✅ 已评审定稿 · 2026-08 · 待阶段二实现（分支 `feature/project-panel`，PR 回 main）
> 版本：v1.1
> 原则：纯壳层能力，**绝不改动 DeepSeek Harness 源码**。已核实：内置 dsh CLI（`lib/bin.js`）仅有 `web/plugin/session/help/version`，无 project/init/template 能力 → 模板引擎自研；**工作区注册直接复用 dsh 既有 RPC**（见 §4.5）。

## 1. 背景与目标

现有右栏面板（文件/终端/浏览器/Wiki/任务/通道）缺项目生命周期起点：企业团队拿到空目录或新仓库时无统一初始化入口（`git init`、AGENTS.md、README/.gitignore/LICENSE、CI 等手工零散）。本面板解决：

1. **项目初始化**：向导式创建新项目，或把模板应用到**已有项目**；
2. **模板引导**：模板 = 一组可勾选步骤（初始化 git、初始化 AGENTS.md 等），按需组合，适配不同团队日常；
3. **模板按需扩展**：复制模板目录即得新模板，无需改代码/无需注册。

**核心交互决策（v1.1 · 回答「先 workspace 还是先初始化」）**：**项目优先 + 工作区自动注册**。理由：dsh 的 `WorkspaceRegistry.create(path)` 对路径做 `fs.realpath` + `isDirectory` 校验，**目录不存在即拒绝**——新建项目必须先落目录，才能注册 workspace；且 create 幂等（同 canonical 路径返回现有实体），既有目录重复注册自然无副作用。因此 workspace 不作为前置条件，而是执行流水线的**统一尾动作**（默认勾选、可关）。

**验收标准**：
- 新建项目：选模板 → 选/建目录 → 填变量勾步骤 → dry-run 摘要 → 落文件 + `git init`（+可选初始 commit）→ **自动注册 dsh web 工作区并新建会话、dsh web 切到该会话**，侧栏可见新工作区；
- 已有项目：应用模板仅补缺失文件（不覆盖，除非显式勾选），已是工作区的目录幂等解析为当前项目，非工作区目录自动注册；
- 复制模板：面板内「复制为新模板」后立即可选；改完清单/文件「重新扫描」即生效；
- 全链路本地执行无网络依赖；L10n 双语；模型层无头单测全绿、CI 接入。

## 2. 术语

| 术语 | 含义 |
|---|---|
| 模板 | 目录：`template.json` 清单 + `files/` 骨架；目录名 = slug/id |
| 步骤 | 清单声明的初始化动作：`files` / `git` / `command` |
| 变量 | 模板表单字段，以 `{{key}}` 出现在骨架文件中 |
| 项目模式 | 空/新建目录 = 完整生成；非空目录 = 「既有项目模式」只补缺失 |
| 工作区注册 | 尾动作：经 dsh RPC 把项目目录注册为 dsh web workspace（幂等）+ 建会话 |

## 3. 模板模型

### 3.1 目录结构

```
platforms/macos/project-templates/           # 内置 → App Resources/project-templates/
└── <slug>/
    ├── template.json
    └── files/
        ├── core/…                           # 步骤 files 的 source 子目录
        └── agents/AGENTS.md.tpl
```

### 3.2 清单 schema

```json
{
  "id": "agent-team",                          // 缺省 = 目录名
  "name": "通用代理工程",
  "description": "git + AGENTS.md + README/.gitignore/LICENSE/.editorconfig",
  "variables": [
    { "key": "projectName", "label": "项目名称", "default": "{{folderName}}", "required": true },
    { "key": "description", "label": "项目描述", "default": "", "required": false },
    { "key": "team",       "label": "团队",     "default": "", "required": false }
  ],
  "steps": [
    { "type": "files", "source": "core",   "label": "核心骨架文件", "overwrite": false },
    { "type": "files", "source": "agents", "label": "AGENTS.md（代理工作指引）", "overwrite": false },
    { "type": "git",   "branch": "main",   "initialCommit": true },
    { "type": "command", "label": "安装依赖 (npm install)", "program": "/usr/bin/env",
      "args": ["bash", "-lc", "npm install"] }
  ]
}
```

- `files`：`files/<source>/` 整树复制到项目根；UTF-8 且无 NUL 的文件做 `{{var}}` 替换，二进制原样；`overwrite:false` 已存在则跳过并计入摘要（幂等）；
- `git`：`/usr/bin/git init -b <branch>`（复用 IssueRunnerPanel 的 runProcess 模式）；已是仓库跳过；`initialCommit` 尝试 add+commit（无 git 身份仅告警不阻塞）；
- `command`：团队自定义（装依赖等）。安全约束：向导整行展示、可勾除、摘要页汇总全部将执行命令；执行 cwd=项目根；
- 占位符：模板变量 + 内建 `{{folderName}}`/`{{currentYear}}`；未知占位符原样保留并提示；替换仅限 UTF-8 文本；
- 健壮性：损坏 JSON/未知步骤类型跳过该模板/步骤并记 `AppLog`，缺省字段取默认值。

### 3.3 模板存储与合并

| 来源 | 位置 | 说明 |
|---|---|---|
| 内置 | `$APP/Contents/Resources/project-templates/` | build-app.sh 复制（对齐 highlightr 资源步骤） |
| 用户 | `$DSH_HOME/project-templates/`（默认 `~/.dsh/project-templates/`） | 复制/自建模板；`DSH_PROJECT_TEMPLATES` 覆盖（团队共享可做成 git 目录） |

合并：扫描两目录，**用户同名 slug 覆盖内置**，无注册表（目录即配置）。

**扩展（复制即新模板）**：卡片右键/「•••」→ 复制为新模板…（slug 冲突自动后缀）/ 在 Finder 中显示 / 重新扫描（打开面板时自动扫一次）。

## 4. 执行引擎（Swift，纯壳层）

新增 `ProjectTemplates.swift`（纯 Foundation 模型层，仿 ChannelStoreReader 定位，可无头单测）+ `ProjectPanel.swift`（UI/控制器）。

- 扫描解析：`ProjectTemplateStore.scan()` 两目录 → 合并 → `[ProjectTemplate]`；
- 变量：`fill(variables, folderName:)` 默认值渲染 + 必填校验；
- Dry-run：先算计划（创建/跳过/覆盖/命令/git 动作），摘要页确认后执行；
- 执行：后台队列逐步骤，逐行日志（成功/失败/跳过），可取消（已完成不回滚）；失败不阻塞后续；
- 安全：目标路径仅「项目根 + files/ 相对路径」（manifest 不携路径 → 无 `../` 穿越）；非空目录绝不删改现有文件。

### 4.5 工作区注册尾动作（dsh web 联动，调研结论）

**已核实能力**（dsh 运行时源码）：
- `WorkspaceRegistry.create(path, title)`：`fs.realpath` 规范化 → `isDirectory` 校验（**不存在/非目录拒绝**）→ 幂等（同 canonical 路径复用现有实体，不改 title）；新建者置顶；title 仅新建时生效（dsh 侧按目录名派生）；
- 客户端契约 `IWorkspaces`：`create({path})`、`connectWorkspace(id)→sessionId`（复用 blank 会话或新建）、`startSession(id)`、`rename/delete/insertBefore/insertSessionBefore`，及宿主能力 `pickDirectory/listDirectory/createDirectory/openPath`（dsh web「+ 添加工作区」= 选目录 → create({path})，均经宿主目录选择器插槽——**壳层未来可注入原生选目录桥接，属阶段三候选**）；
- core 已有 `workspace.list` 的 HTTP client-request 信封先例（channel/wiki 用）；`session.create` 支持 `workspaceId`（wiki 先例）。

**尾动作流水线（面板统一实现，模板不声明）**：
1. `workspace.create({path})` → workspaceId（已注册 → 幂等返回）；
2. `session.create({workspaceId})` → 新会话（首个消息前可为空会话，dsh web 正常显示）；
3. 壳层 `ProjectDirectory.current = path`，`openDSHSession(sessionId)` 切换 dsh web 到新会话（main.swift:2417 现成函数）。

> ✅ **冒烟验证已完成（2026-08，对运行中的 dsh web 实测）**：
> - `workspace.create({path})` → `{result:{ok:true, value:{workspace: WorkspaceView, created: Bool}}}`；重复调用幂等（同 canonical 路径返回同一 workspace，`created:false`）；不存在路径拒绝——**与设计一致的先落目录再注册**；
> - `workspace.delete({workspaceId})` → `{deleted:true}`（面板不依赖，清理用）；
> - `session.create({workspaceId})` → `{sessionId, agentPreset}`（空会话可直接创建，dsh web 正常显示）；
> - 信封：`POST /api/<method>`，body `{type:"client-request", rpcId, method, payload}`（与 core 的 rpc() 一致）；
> - WorkspaceView 形状：`{workspaceId, path, title, sessionIds, createdAt, updatedAt}`；`workspace.list` 响应 `{items:[…]}`（channel/wiki 同源）。
> 原兜底方案（冒烟失败时降级）不再需要，但保留为代码注释。

**尾动作时序**：

```
ProjectPanel                     dsh web (HTTP :3080)
     │                                │
     │ ① workspace.create({path})     │
     │ ──────────────────────────────▶│  校验: realpath + isDirectory
     │                                │  （目录不存在 → 拒绝，面板降级提示）
     │ ◀──────────────────────────────│  已注册？幂等返回现有 : 新建并置顶
     │         workspaceId            │
     │                                │
     │ ② session.create({workspaceId})│
     │ ──────────────────────────────▶│
     │ ◀──────────────────────────────│  新空会话 sessionId
     │                                │
     │ ③ ProjectDirectory.current = 项目路径
     │ ④ openDSHSession(sessionId)    │
     │ ──────────────────────────────▶│  侧栏切换 → 聚焦新会话
     │                                │
     │ ⑤ 完成视图：工作区状态 + 快捷打开按钮
```

**尾动作开关**：摘要页「注册 dsh 工作区并新建会话」勾选项（新项目默认开；既有目录已是工作区时勾选 = 设当前项目不新建会话）；关闭 = 纯文件落地。

## 5. 面板 UI 与交互

> 本节为 ASCII 线框/流程图，沿用仓库 docs 惯例（如 docs/channel-ui-commands.md）；实现阶段以 docs/screenshots/ 真实截图补充。

**交互总览**：

```
┌────────── 打开项目面板（活动栏「项目」/ ⌥⌘N） ──────────┐
│                                                       │
│   ① 新建项目        → 向导：①选模板 ②选/建目标目录       │
│   ② 应用到已有目录  → 选目录 → 向导（模式：只补缺失）     │
│   ③ 应用到当前项目  → 直接用 ProjectDirectory.current   │
│                        （取不到则回退 ②）               │
│                        │                              │
│                        ▼                              │
│   向导：③变量与步骤勾选 → ④摘要(dry-run) → [开始初始化]  │
│                        │                              │
│                        ▼                              │
│   执行：files → git → command（逐行日志，可取消，       │
│          失败不阻塞后续步骤）                           │
│                        │                              │
│                        ▼                              │
│   尾动作(默认开)：workspace.create → session.create    │
│                → 设为当前项目 → 切 dsh web 新会话       │
│                        │                              │
│                        ▼                              │
│   完成视图：工作区已注册 + 在 dsh/终端/文件面板/Finder 中打开│
└───────────────────────────────────────────────────────┘
```

右栏第七面板（`RightPanel` 加 `case project`）；活动栏置首（项目、文件、终端、浏览器、Wiki、任务、通道，main.swift:1524 一行调整）；View 菜单快捷键 **⌥⌘N**（N 未被占用、语义贴合 New）。

**入口（打开面板首屏 = 三选，回答「哪种更顺」）**：
1. **新建项目**（主 CTA）：进模板向导；目标目录可不存在（NSOpenPanel 新建文件夹）；
2. **应用到已有目录**：选目录 → 同向导简化版（跳过变量中的 folderName 推导，模式明示「只补缺失文件」）；
3. **应用到当前项目**：零选择，对 `ProjectDirectory.current` 直接跑（获取不到时回退到 2）。——企业日常「给现有代码库接入代理工作流」最顺的路径。

**首屏线框**（活动栏最左，面板默认宽 560pt）：

```
┌─ 活动栏 ─┬────────────── 项目面板 · 首屏 ──────────────┐
│ 项目  ●  │  ✕                                        │
│ 文件     │  ┌──────────────────────────────────────┐  │
│ 终端     │  │  ○ 新建项目（推荐）      [开始 → 向导] │  │
│ 浏览器   │  ├──────────────────────────────────────┤  │
│ 知识库   │  │  ○ 应用到已有目录      [选择目录 …]   │  │
│ 任务     │  ├──────────────────────────────────────┤  │
│ 通道     │  │  ○ 应用到当前项目                    │  │
│          │  │    当前：~/work/hello-world           │  │
│          │  └──────────────────────────────────────┘  │
│          │  内置模板 2 · 用户模板 3 · [↻ 重新扫描]     │
└──────────┴────────────────────────────────────────────┘
```

**向导四步**：① 选模板（卡片+搜索+右键菜单）→ ② 目标（NSOpenPanel 支持新建文件夹；空/新=新项目模式，非空=既有模式明示）→ ③ 变量 + 步骤勾选 → ④ 摘要与执行（dry-run 列表 + 工作区注册开关 + 开始 → 逐行日志 → 完成视图）。

**向导线框**（步进条 + 代表性两屏）：

```
步进:  ① 选模板 → ② 选目标 → ③ 变量与步骤 → ④ 摘要与执行

┌─ ① 选模板 ──────────────────────────────────────────┐
│ [搜索模板…                          ] [↻ 重新扫描]   │
│ ┌──────────────┐ ┌──────────────┐                   │
│ │ 通用代理工程  │ │ 最小 git 项目 │  卡片右键菜单:     │
│ │ git+AGENTS…  │ │ .gitignore…  │   复制为新模板…    │
│ │ README/LIC…  │ │              │   在 Finder 显示  │
│ └──────────────┘ └──────────────┘                   │
│                              [下一步 →] [取消]       │
└─────────────────────────────────────────────────────┘

┌─ ④ 摘要与执行 ──────────────────────────────────────┐
│ 项目: my-project（新建模式）   模板: agent-team      │
│ 将创建 8 个文件 · 跳过 0 · 覆盖 0                    │
│   ✓ README.md  ✓ .gitignore  ✓ LICENSE             │
│   ✓ AGENTS.md  ✓ .editorconfig  …                  │
│   git: init -b main + 初始提交（已勾选）             │
│   command: bash -lc "npm install"（可取消勾选）      │
│ ☑ 注册 dsh 工作区并新建会话                          │
│ [开始初始化]                                        │
│ ┌────────────────────────────────────────────────┐ │
│ │ ✓ 创建 README.md                                │ │
│ │ ✓ git init -b main                             │ │
│ │ ⏳ 注册工作区…                   [取消]          │ │
│ └────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────┘
```

**完成视图**：主结果 = 工作区已注册（名称 + 状态）+ 「在 dsh 中打开」（默认已切）/「在终端打开」（设 ProjectDirectory 后 `terminalPanel.newSession()`，新会话自动取该目录）/「在文件面板打开」（`previewPanel.setProjectDirectory` + 切 .preview）/「在 Finder 显示」（`NSWorkspace.activateFileViewerSelecting`）。

**完成视图线框**：

```
┌─ 项目面板 · 完成 ────────────────────────────────────┐
│  ✅ 项目初始化完成 · my-project                      │
│  ─────────────────────────────────────────────     │
│  工作区已注册：my-project                            │
│  会话 #s12 已在 dsh web 打开（当前项目已切换）        │
│  ─────────────────────────────────────────────     │
│  [在 dsh 中打开] [在终端打开] [在文件面板打开]         │
│  [在 Finder 显示]            [再建一个项目]           │
└─────────────────────────────────────────────────────┘
```

**QA 钩子**：`DSH_PROJECT_TEST=1` 启动即开面板（沿用现有 `DSH_*_TEST` 惯例）；`DSH_UI_DEBUG` dump 分支加 `project`（main.swift:1700 附近）。

### 5.5 UI 样式风格（Style Guide）

> 实现时与现有六个面板保持视觉与交互一致。依据：`.dsh/wiki/conventions.md`「面板 UI 约定」、preview-panel 模块页「共享 UI 组件」。

**基础原则**

- 全 AppKit（NSView 体系），不引入 SwiftUI——壳层可靠性取向（同 PREVIEW_PLAN 高亮选型结论）；
- **复用 `PreviewPanel.swift` 的共享 UI 组件，禁止重定义**：`HoverButton` / `DynamicFillView`（kind .window/.control）/ `ActivityBarButton` / `PanelIconButton` / `HeaderLabel` / `CustomIconButton`（`Glyph` 枚举 + `symbol(String)` SF Symbol，15pt 居中绘制、可配 `size`/`showsBackground`/`hoverColor`）；项目面板自有视图一律 `file-private`；
- 颜色只用**系统语义色**（`.textColor` / `.secondaryLabelColor` / `.textBackgroundColor` / `.controlBackgroundColor` / `.separatorColor` / `.systemRed`…）+ 动态填充背景（`DynamicFillView`），**不写死 CGColor/hex**，深浅色自动跟随；图标深浅色均可见（活动栏 `BakedIconView` 烘烤、面板内 `PanelIconButton` 按深浅刷新 tint）。

**布局与尺寸（贴齐现有面板）**

- 面板挂右栏 NSSplitView：`static let minWidth: CGFloat = 260`（与各面板一致，自动计入 main.swift:1266 的 `rightPanelMinWidth` 最大值链）；默认宽 560pt（`rightPanelDefaultWidth`）；拖拽宽度记忆复用**同一** `previewPanelWidth` 键（宽度是窗口级共享，无需新键）；
- 头部 **40pt**：`HeaderLabel` 标题 + 右侧操作区（Primary 按钮 / 重新扫描 / 更多）+ 最右 ✕（`onRequestHide`）；背景统一背景条（`DynamicFillView` .control）；
- 内容区：左右 padding 12–16pt、控件间距 8pt（NSStackView spacing）；底部操作条（上一步 / 下一步 / 开始初始化 / 取消）钉底，主 CTA = keyEquivalent 默认按钮（accent），次按钮默认 bevel 样式；
- 向导步进条（①→④）：`secondaryLabelColor` + 当前步 accent 高亮；
- 模板卡片：圆角 6pt（`wantsLayer` + `cornerRadius`）浅背景 + 名称（systemFont 13 semibold）+ 描述（12 secondaryLabelColor）+ 来源徽标（内置/用户）——参考 BrowserPanel 页签胶囊与 ChannelPanel 卡片风格；
- 变量表单：label + `NSTextField` 成行，必填项 label 加 `*`；步骤列表用 `NSButton(checkboxWithTitle:)`，`command` 步骤行内以 `monospacedSystemFont(11/12)` 展示完整命令；
- 执行日志区：等宽字体，状态着色（✓ 默认 / ✗ `systemRed` / 跳过 secondary）。

**行为一致性**

- tooltip / 文案全部走 L10n（键前缀 `project.*`，**中英双语成对**）；语言切换经 main.swift `:2949-2954` 的 `refreshTooltips` 同款模式刷新；
- 面板切换互斥（`setRightPanel`），`onRequestHide` 关闭；`DSH_UI_DEBUG` 可 dump + 截图（`:1700` 分支加 `project`）；
- 深浅色 / 语言切换即时生效：面板内**不缓存**固定颜色与文案。

## 6. 内置模板（v1 两个示例）

| slug | 名称 | 步骤 |
|---|---|---|
| `agent-team` | 通用代理工程 | files(core: README/LICENSE(MIT 占位)/.gitignore/.editorconfig) + files(agents: AGENTS.md 骨架) + git(main, 初始提交) |
| `minimal-git` | 最小 git 项目 | files(core: .gitignore+README) + git(main, 无提交) |

AGENTS.md 骨架沉淀团队代理协作约定（静态生成即 v1）；「代理按团队说明完善 AGENTS.md」（session.prompt+queue 模式、需新内置 skill）列**阶段三候选**。

## 7. 与现有系统集成（接线点已核实）

- main.swift:1257 `enum RightPanel` 加 `case project`；:1576-1585 `rightPanelKind` 映射加 `"project"`；:1741 走同一 `kind` 无需改；
- :1452 buildSplitView 创建 `projectPanel`（onRequestHide/serverPortProvider 同例）+ 注入完成操作闭包（openDSHSession、setProjectDirectory、newSession 均已有）；
- :1506-1524 活动栏 `makeActivityButton`（symbol 建议 `square.and.pencil`）置 barStack 首位；tooltip `bar.project`；
- :2788-2814 视图菜单 `menu.toggleProject`（keyEquivalent "n" + command+option → `projectEntryTapped`）；:1589/:1620/:1700 dump 分支随 case 模式；
- L10n.table 新增键：`bar.project`/`project.title`/`menu.toggleProject`/`project.*` 全套，**中英双语成对**；
- 构建：新 Swift 文件免登记（swift-sources.sh glob）；build-app.sh 增一步复制 project-templates 到 Resources；
- 工作区 RPC：经 `DSHSessionRPC` 同类 client-request 信封（core 先例），实现时以冒烟确定方法名（§4.5）；
- README 右栏段落 + 环境变量表（`DSH_PROJECT_TEMPLATES`/`DSH_PROJECT_TEST`）随实现更新；`.dsh/wiki` 由 repo-knowledge 增量刷新。

## 8. 测试计划

`tests/project-panel/run.sh` + `project-tests.swift`（无头：复制源文件 + 测试作 main.swift + swiftc，仿 tests/channel-panel/；CI ci.yml 加一行）：

1. 清单解析：完整/缺省/损坏 JSON/未知步骤类型（跳过不崩）；
2. 扫描合并：内置∪用户、用户覆盖内置、无效模板跳过；
3. 占位符：`{{projectName}}`/`{{folderName}}`/`{{currentYear}}`/未知原样；二进制不替换；
4. dry-run：创建/跳过/覆盖/命令列表正确；覆盖保护；
5. 执行：临时目录真实落地；`git init` 幂等；无 git 身份时初始提交告警不失败；
6. 幂等：二次执行结果一致；
7. 路径穿越：恶意条目拒绝；
8. 复制模板：slug 冲突自动后缀；
9. 工作区注册逻辑（模型层）：已知路径集合上的「幂等解析 + 需注册 + 不存在目录拒绝」决策表（RPC 本身留手工 QA/冒烟）。

## 9. 边界、风险与 Swift UI 开发避坑

- 纯壳层文件/进程能力 + dsh 既有 RPC，不改 dsh 源码、无网络依赖；`command` 步骤是唯一任意代码面（整行展示+可勾除+摘要确认；源限内置与用户目录）；
- 覆盖写仅显式勾选；既有模式绝不删改现有文件；
- 工作区 RPC 方法名冒烟未通过时降级（§4.5），不影响初始化主流程；
- 不新增 UserDefaults 状态键；模板即配置（全局目录可 git 管理成团队共享资产）。

### 9.5 Swift UI 开发避坑清单（本面板相关，均出自仓库实测教训）

1. **layer-backed 合成陷阱（高发，最优先）**（`docs/terminal-header-fix.md` + conventions.md）：
   - 根视图仿 `TerminalRootView`/`WikiRootView`：**root 用 `isOpaque = false` 的自绘背景视图**；
   - 「平时隐藏、执行时才显示」的视图（日志区 / 状态条 / 覆盖浮层）：**显示前**给视图自身 `wantsLayer = true` + `masksToBounds = true`（wiki 面板底部状态条同源修复）；
   - 隔离绘制溢出用**父容器** `wantsLayer + masksToBounds`（子视图自身 wantsLayer 不够，见 terminal-header-fix §4 实测）；头部 / 内容 / 日志容器全部 layer 隔离。
2. **共享类型符号重定义**：`PreviewPanel.swift` 的共享组件**只能复用、不得重新声明**（否则 swiftc 符号冲突编译失败，PREVIEW_PLAN「共享类型去重」实测）；本面板自有视图（模板卡片、步进条、日志行…）一律 `file-private final class`。
3. **Process 子进程模式**：复用 `IssueRunnerPanel.runProcess`（`/usr/bin/git` + `-C <path>`；**先 `readDataToEndOfFile()` 再 `waitUntilExit()`**——顺序不可反，防管道写满死锁）；长命令（command 步骤）必须后台队列执行、回调主线程刷 UI；失败返回 nil/错误由步骤日志告警，不崩溃。
4. **后台执行 + 主线程 UI**：执行引擎放 `DispatchQueue.global`，日志/进度经 `DispatchQueue.main.async` 增量刷；取消 = 步骤间检查标志，v1 不做进程强杀。
5. **文件原子写**：生成文件用 `Data.write(to:options:.atomic)`（CodeEditorView 同款）；目标已存在且未勾覆盖 → 跳过，绝不静默覆盖；失败 NSAlert 提示不崩溃。
6. **文本判定与编码**：占位符替换仅对 UTF-8 且无 NUL 字节的文件（FilePanel `looksLikeText` 同思路）；写回保持原 LF 换行，不归一化 CRLF。
7. **NSOpenPanel 用法**：`canCreateDirectories = true`（新项目模式）/ `allowsMultipleSelection = false` / `canChooseFiles = false`；路径取 `URL.path` + `standardized`（与 `ProjectDirectory` 规范化去重一致）。
8. **路径安全**：目标路径只由「项目根 + files/ 内相对路径」拼接；模板扫描/解包时校验条目不越出模板目录（防 `../`）；`FileManager.createDirectory(withIntermediateDirectories: true)` 幂等创建。
9. **视图层级问题排查**：先 `DSH_UI_DEBUG=1` 拿层级 dump + `panel-<label>-debug.png` 截图；对照 terminal-header-fix 检查 wantsLayer/masksToBounds（tasks.md「排查问题」同法）。
10. **模型层无头测试前置**：`ProjectTemplates.swift` 必须**纯 Foundation（不 import AppKit）**，否则 `tests/project-panel/` 无法仿 channel-panel 直编运行；UI 逻辑不进无头测试。
11. **macOS 13+ 兼容**：壳基线 macOS 13+（productization.md）；不用 macOS 14+ 独有 API（如 Observation 等新特性）。

## 10. 阶段划分

- **阶段一（本文档）**：✅ 已完成——设计文档落盘。
- **阶段二（实现，另行批准，分支 `feature/project-panel`，PR 回 main）**：
  1. `ProjectTemplates.swift`（模型层）+ `ProjectPanel.swift`（UI/控制器）；
  2. 内置模板 `project-templates/{agent-team,minimal-git}/`；
  3. main.swift 接线（§7）+ L10n；build-app.sh 资源复制；
  4. **工作区尾动作冒烟**：观察 dsh web 添加工作区请求确定 RPC 方法名 → `DSHSessionRPC` 扩展 `createWorkspace`/尾动作编排；
  5. `tests/project-panel/` + ci.yml；README；全量构建 + 手工 QA（三入口、复制模板、幂等、既有模式、工作区联动）。
- **阶段三（候选）**：agent 完善 AGENTS.md（新内置 skill）；宿主原生目录选择器桥（dsh web「+」按钮接 NSOpenPanel）；团队模板中心远程源。