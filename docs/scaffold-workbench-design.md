# 功能设计：oh-my-dsh「工程脚手架」（Scaffold Workbench）

> 状态：📋 设计稿（M0）· 待评审 · 2026-08
> 范围：基于 oh-my-dsh（DeepSeek Harness 的 macOS 原生壳）新增「工程脚手架」功能——把**项目开发拆解为相对独立的「环节」（stage）**，开发者按工作目的**任意组合**、搭建项目的基础架构，并在此基础上**顺畅地与 Agent 协作**。
> 原则：与壳层既有约定一致——**不改动任何 DeepSeek Harness 源码**，一切通过壳层面板 + dsh 既有能力（session RPC / skill / AGENTS.md 指令加载 / 本地命令执行）实现。

---

## 1. 背景与现状调研

### 1.1 功能是什么

「工程脚手架」把「从零起一个新项目」这件事拆成一节节**相互独立、可任意组合**的「环节」。每个环节是**一份清单（manifest）+ 一组文件模板**，描述它要把哪些文件、按什么参数、生成到目标目录的什么位置。开发者按工作目的（纯后端 API / 前后端兼备 / 内部工具…）勾选环节、填参数，脚手架在本地确定性地渲染出项目骨架；骨架内自带 `AGENTS.md`、命令入口、文档与规范文件，**Agent 一进来就知道规则、命令和边界**——这就是「顺畅协作」的工程基础。骨架生成后还可选一键让 dsh 代理「深化」骨架（补实现、补测试、跑通构建）。

它和我们上一轮聊的「企业子系统蓝图」（仓库布局 / 文档规范 / 脚手架 / 开发规范 / CI/CD / 发布部署）是**同一件事的两种形态**：蓝图是文本，脚手架把它变成可执行、可组合、可复用的环节库。

### 1.2 行业现状

| 方案 | 做法 | 与本设计的差异 |
|---|---|---|
| cookiecutter / degit / create-\* | 拉一个**整体**模板仓库 | 整体模板不好组合：「要文档和 CI、不要前端」做不到 |
| Spring Initializr / Vite 脚手架 | 官方生成器 | 只管自家技术栈，不管工程规范（AGENTS.md/CI/Docker/文档） |
| Nx generators / Turborepo | 生成器可组合 | 绑定 Nx/Turbo 生态，工程规范仍需另配 |
| Backstage Software Templates | 平台级「模板编排 + 发布」 | 需部署平台、服务端编排；本设计是**桌面壳内嵌 + 本地渲染 + dsh 代理协作**，零平台依赖 |
| Claude Code / Codex 等「口头起项目」 | 让代理现场写一切 | 产物不可复现、规范随代理心情；本设计的骨架是**确定性渲染**，代理只做「深化」 |

**共性结论**（本设计依据）：
1. 「可组合的单元」是比「整体模板」更好的抽象——粒度越细、复用面越宽，这也是 Nx/Backstage 已验证的方向；
2. 工程规范要**落成文件**（AGENTS.md 类指令、Makefile、规范文档），Agent 才可遵守——这直接决定「与 Agent 协作是否顺畅」；
3. 企业项目的骨架内容高度趋同（git/文档/CI/Docker/测试规范），值得一次沉淀、处处复用。

### 1.3 用户痛点（oh-my-dsh 场景）

- 每次起新项目，工程规范都要**重新发明**：文档骨架、CI 模板、Dockerfile、AGENTS.md、测试规范，散落在各个老仓库里复制粘贴；
- 规范不落成文件，**Agent 无从遵守**：没有 AGENTS.md、没有 make 入口、没有机器可读的 DoD，代理干活靠「猜」；
- dsh 代理很擅长「在既有骨架里干活」，但**从零搭骨架**（尤其规范类文件）又慢又不稳定——这和「壳层不解析代码、一切交给代理」的原则正好互补：**确定性的事壳层做，创造性的事代理做**；
- 已有 `docs/` 蓝图（上一轮讨论）没有工具化载体。

### 1.4 与 oh-my-dsh / dsh 的契合点（已核实）

**dsh 运行时侧已具备的能力：**

| 能力 | 出处（dsh 包） | 用途 |
|---|---|---|
| `AGENTS.md`/`CLAUDE.md` 逐目录指令加载 | `dsh-agent-instructions` | 骨架里的 AGENTS.md 就是「与 Agent 协作」的入口 |
| skill 注册表 + 文件系统提供者（`$DSH_HOME/skills`、`.dsh/skills` 等 5 级根） | `dsh-skill` / `dsh-skill-filesystem` | 深化流程（M3）可分发为 skill；`.dsh/wiki` 准备可对接 `repo-knowledge` |
| 会话 HTTP RPC：`session.create` / `session.prompt`（`mode: queue`）/ `session.list`，`client-request` 信封 | `dsh-host-apiproxy` | 壳层**编程触发**代理「深化」骨架（WikiRPC 已验证同款链路） |
| workspace 注册表（session 归属工作区） | `dsh-workspace` | 深化会话归入新项目工作区，web UI 可见、可继续对话 |

**oh-my-dsh 壳层侧已具备的基础设施：**

| 能力 | 位置 | 用途 |
|---|---|---|
| 右侧活动栏面板系统：`RightPanel { none, preview, terminal, wiki, tasks, browser, channel }`、互斥切换、宽度记忆、`rightPanelKind` 持久化 | `src/main.swift`（1279 行起） | 新增 `.scaffold` 面板 |
| `DSHSessionRPC` / `WikiRPC`：`createSession(port:cwd:workspaceId:)` / `promptSession(...)` + `sessionRunning` 轮询 | `src/main.swift`、`src/WikiPanel.swift`（642-721 行） | Agent 深化链路直接复用 |
| 内置 skill 安装：App 启动时安装到 `$DSH_HOME/skills/`（缺失即装、托管更新） | `src/SkillInstaller.swift` | 深化 skill / 协作层环节可沿用该模式 |
| 本地进程与文件操作：`Process` 执行命令（git init 等）、`FileManager` 读写、目录树懒加载 | `src/TerminalPanel.swift`、`src/PreviewPanel.swift` | 渲染引擎、git init、Finder 打开 |
| 面板 UI 基件：`HoverButton` / `DynamicFillView` / `PanelIconButton`、中英 L10n 表、`DSH_*_TEST` QA 钩子、`serverReady(port:)` 门控 | `src/main.swift`（98 行 L10n 表；1441-1466 行 QA 钩子） | 面板 UI、文案、测试钩子、服务门控 |
| 资源打包先例：highlight.js 资源复制进 `Contents/Resources` | `build-app.sh`（303 行） | 环节库目录打包进 `Contents/Resources/scaffold-stages` |
| macOS 源码清单单一事实来源（glob 自动收录 `src/*.swift`） | `platforms/macos/swift-sources.sh` | 新增 `ScaffoldPanel.swift` 无需登记 |
| 无头单测范式：拷贝面板源文件 + stubs 编译独立二进制 | `tests/wiki-panel/run.sh` | 引擎单测同款 |

---

## 2. 目标与非目标

### 2.1 目标

- **G1 环节库**：内置一组相互独立、可任意组合的「环节」（v1 清单见第 13 节），每个环节 = `stage.yaml` 清单 + 文件模板，随 App 分发（`Contents/Resources/scaffold-stages/`）；
- **G2 组合搭建**：面板中按工作目的勾选环节、填参数，本地**确定性渲染**出项目骨架（无 token 成本、可复现），含文件清单预览与路径冲突提示；
- **G3 协作就绪**：骨架默认包含 `AGENTS.md`（结构/命令/规范/禁区）、编辑器规范（`.editorconfig`）、命令入口（Makefile）、文档骨架——**Agent 进入即遵守**；
- **G4 Agent 深化**（M3）：骨架生成后一键让 dsh 代理「深化」——按所选环节参数补实现、补测试、跑通构建，深化会话在 web UI 可见、可继续对话；
- **G5 可扩展**：环节库支持用户扩展目录（`$DSH_HOME/scaffold-stages/`），坏清单隔离提示，不拖垮内置环节；
- **G6 一致**：全部通过壳层面板 + dsh 既有能力实现，不改任何 DeepSeek Harness 源码；中英双语文案；与既有面板视觉/交互一致。

### 2.2 非目标（v1 明确不做）

- 不做「环节市场/社区分享」；
- 不做跨环节**自动联动/依赖解析**（选了 java-backend 不自动改 docker 参数）——只做基于参数的冲突提示（9.7）；
- 不做「对既有项目补环节」的增量合并模式（非空目录仅确认 + 覆盖备份，9.1）；增量补环节为 v2；
- 不做模板渲染的完整模板语言（`{{var}}` + `{{#if}}` 足够，`{{#each}}` 为 v2）；
- 壳层不解析代码、不做代码生成器——Java/Vue 3 示例环节只产出**最小可运行骨架**，业务实现交给「Agent 深化」（G4）与开发者；React 示例环节（`react-frontend`）**暂缓**（见 13.2 注）；
- 不内置**云厂商专有**（AWS EKS / GCP GKE / 阿里 ACK 等）模板——`deploy` 环节的 k8s 模板为**云无关通用 manifests**；`docker` 环节只负责镜像构建与本地编排，生产部署归 `deploy` 环节。

---

## 3. 总体架构

### 3.1 组成

```
┌─────────────────────────── oh-my-dsh (macOS 壳) ───────────────────────────┐
│  RightPanel.scaffold 面板 (ScaffoldPanel.swift)                             │
│  ├─ ScaffoldPanelController: 目标目录/环节列表/参数表单/预览/状态条 UI        │
│  ├─ StageCatalogLoader: 加载内置 + 用户扩展环节库（stage.yaml 解析/校验）     │
│  ├─ ScaffoldTemplateRenderer: {{var}} / {{#if}} 渲染（Swift 实现，无依赖）    │
│  ├─ ScaffoldPlan: 组合规划（文件清单、冲突检测、模拟）                        │
│  ├─ ScaffoldApplier: 写文件 / 备份 / git init / Finder 打开                  │
│  └─ ScaffoldDeepenRPC (M3): session.create/prompt 触发代理深化               │
└──────────────┬──────────────────────────────────────────────────────────────┘
               │ 渲染（本地，确定性）                    │ session.create/prompt (M3)
               ▼                                        ▼ (mode: queue)
┌─────────────────────── 目标项目目录 ────────┐   ┌────────── dsh web (源码不动) ──────────┐
│ 骨架文件（AGENTS.md / Makefile / docs/…）   │   │ 深化会话：按参数补实现/补测试/跑通构建    │
└────────────────────────────────────────────┘   └───────────────────────────────────────┘
```

**关键决策**：骨架的**确定性部分**（规范文件、目录结构、最小骨架代码）由壳层本地渲染——快、可复现、零 token；**创造性部分**（业务实现、深化）交给 dsh 代理——能力随 dsh 演进自动受益。这与 Repo Wiki「壳层触发 + 代理生成」的分工互补：wiki 是「内容全代理」，脚手架是「确定性壳层 + 深化代理」。

### 3.2 组件职责与归属

| 组件 | 归属 | 职责 |
|---|---|---|
| 环节库（内置） | `Contents/Resources/scaffold-stages/`（构建时复制，见 4.3） | 一组 `stage.yaml` + 模板文件，随 App 分发 |
| 环节库（用户扩展） | `$DSH_HOME/scaffold-stages/`（v2 或 M3，见 11） | 用户自定义环节，优先于内置同名环节 |
| `StageCatalogLoader` | 壳层新文件（ScaffoldPanel.swift 内） | 扫描/解析/校验 stage.yaml；坏清单隔离 |
| `ScaffoldTemplateRenderer` | 壳层新文件 | `{{key}}` 替换 + `{{#if key}}…{{/if}}`，文件名也参与渲染 |
| `ScaffoldPlan` | 壳层新文件 | 按选中顺序规划文件清单；冲突检测（同路径多环节写）；参数校验汇总 |
| `ScaffoldApplier` | 壳层新文件 | 落盘（备份冲突文件）、`git init`（环节命令）、目录打开 |
| `ScaffoldDeepenRPC` | 壳层新文件（M3） | 复用 WikiRPC 信封：`createSession` → `promptSession`（queue）→ 轮询 → 打开会话 |
| `ScaffoldPanelController` | 壳层新文件 | 面板 UI、状态机、L10n、QA 钩子 |
| 深化触发文案 | 壳层内嵌（中英） | 「按所选环节与参数完善骨架…」薄壳提示词（见 6.3） |

---

## 4. 数据模型

### 4.1 环节清单 `stage.yaml`

```yaml
id: java-backend                # 全局唯一（内置 ns: builtin.<id>）
name: { zh: Java 后端脚手架, en: Java Backend Scaffold }
category: examples               # foundation | examples | collaboration
description:
  zh: 最小可运行 Spring Boot 3 后端骨架（Maven，含健康检查与单测）
  en: Minimal runnable Spring Boot 3 backend skeleton (Maven, health check + tests)
params:
  - key: groupId
    label: { zh: Maven GroupId, en: Maven GroupId }
    type: string                 # string | select | bool
    default: com.example
    validate: javaPackage        # 内置校验器：javaPackage | slug | safePath | nonEmpty
  - key: javaVersion
    type: select
    options: ["17", "21"]
    default: "17"
files:                           # 每个条目 = 一个产出文件
  - path: "{{artifactId}}/pom.xml"          # 路径参与渲染（目录名可参数化）
    template: "templates/pom.xml.tmpl"
  - path: "{{artifactId}}/src/main/resources/application.yml"
    template: "templates/application.yml.tmpl"
commands:                        # 渲染落盘后执行（相对目标根；git init 放这里）
  - "git init -b main"
```

### 4.2 模板语法（v1 刻意最小）

| 语法 | 含义 | 示例 |
|---|---|---|
| `{{key}}` | 变量替换（参数值或内置变量 `projectName` / `projectSlug` / `targetPath`） | `groupId: {{groupId}}` |
| `{{#if key}}…{{/if}}` | 条件块（`bool` 参数或空串判断） | `{{#if withOpenapi}}…{{/if}}` |
| 文件名 | 同样参与 `{{key}}` 替换 | `{{projectSlug}}/README.md` |

- 渲染器**不转义**模板原文（模板作者负责）；渲染失败（参数缺失/非法）→ 该环节报错、不落盘（9.4）；
- 特殊字符（`{{` 字面量）用 `{{{{` 转义（v1 支持，模板内极少用到）。

### 4.3 环节库存放位置

```
内置（随 App，构建期复制，参照 highlight.js 资源先例）:
  <app>/Contents/Resources/scaffold-stages/<id>/stage.yaml + templates/
用户扩展（可覆盖内置同名 id）:
  $DSH_HOME/scaffold-stages/<id>/stage.yaml + templates/
开发覆盖（QA/调试）:
  DSH_SCAFFOLD_STAGES=<dir> 时仅加载该目录（含内置模拟？不 —— 仅追加或仅覆盖，见 9.12）
```

- 加载顺序：用户扩展优先（同名 id 覆盖内置）；`DSH_SCAFFOLD_STAGES` 指向的目录**追加**到搜索链最末（v1 用于开发/测试，不覆盖）；
- 每个环节在面板中按 `category` 分组展示。

### 4.4 目标目录规范

```
目标根 = <parentDir>/<projectSlug>
projectSlug 生成规则: 项目名（可中文）→ ASCII slug（去重音/空格→-，保底 project）；校验 9.2
```

- 目标根**为空目录或不存在**为理想输入；非空 → 9.1 确认 + 备份策略；
- 生成完成状态记录：`<目标根>/.scaffold/state.json`（所选环节清单 + 参数 + 时间）——幂等重跑与 v2 增量补环节的依据（9.10）。

---

## 5. 生成工作流

```
勾选环节(+参数) → 校验（参数/路径/冲突）→ 预览（文件清单+冲突标记）
  → [生成] → 渲染全部模板 → 冲突文件备份 → 落盘 → 执行环节 commands（git init 等）
  → 写 .scaffold/state.json → 完成态（[打开目录][在 Finder 中显示][Agent 深化▾(M3)]）
```

1. **校验**：每环节参数过内置校验器；路径安全（拒绝 `../`、绝对路径，9.8）；同路径多环节写 → 冲突清单（后写覆盖 + 标红，9.12）——**可预览、可返回改选**，不直接落盘；
2. **渲染**：按用户点选顺序逐环节渲染到内存；渲染失败的环节整环节跳过并报告（9.4）；
3. **落盘**：先对冲突目标文件做 `.scaffold-backup/` 备份（仅当目标已存在且内容不同）再写；
4. **命令**：`git init -b main` 等环节命令相对目标根执行；失败不阻断其余（9.5 语义）；
5. **状态**：`state.json` 记录本次组合，供重跑/审计；面板状态条显示进度与结果。

---

## 6. Agent 协作层

「顺畅协作」不是搭完骨架才想的事，而是骨架的**出厂设定**：

### 6.1 `agents-md` 环节（协作入口）

产出项目根 `AGENTS.md`（模板生成，内容含）：

```md
# AGENTS.md — <项目名>
## 项目是什么（一句话，来自参数 techSummary）
## 目录结构（随所选环节生成，如 backend/ frontend/ docs/ deploy/）
## 常用命令（引用 Makefile：make dev / build / test / lint；未选 makefile 环节则省略）
## 工程规范（提交/分支规范、代码风格、DoD——对应 git-conventions / conventions 环节所选内容；未选则不写）
## 禁区（密钥不入仓库、不越过所选环节边界等）
## 与 dsh 协作（若含 repo-knowledge 环节：先读 .dsh/wiki/index.md；按需读取，见 6.2）
```

- 内容由**所选环节组合决定**：选了 `makefile` → 命令段写实际目标；选了 `conventions` → 规范段引用实际文件；没选就不写——**AGENTS.md 与骨架永远自洽**（G3 的核心机制）；
- 该文件会被 `dsh-agent-instructions` 自动加载，**每个新会话自动可见**（已核实的 dsh 机制）。

### 6.2 `repo-knowledge` 环节（知识库准备，与 Repo Wiki 的 `repo-knowledge` skill 同名对齐）

- 产出 `.dsh/wiki/` 占位（`README.md` 说明：「用 repo-knowledge skill 生成知识库」）；不调用代理生成（保持确定性）——生成留给用户/后续会话一键触发（复用算法与文案见 `docs/repo-wiki-design.md`）。

### 6.3 Agent 深化（M3，触发链路复用 WikiRPC）

骨架完成后的「深化」按钮（`Agent 深化 ▾`，可选动作：补全骨架 / 补测试 / 跑通构建）→

```
POST /api/session.create  { "type":"client-request", …, "method":"session.create",
                            "payload":{ "cwd":"<目标根>" } }            // 归入工作区：优先 workspaceId
POST /api/session.prompt  { …, "method":"session.prompt",
                            "payload":{ "sessionId":"…", "mode":"queue",
                            "content":[{ "type":"text", "text":"<深化文案>" }] } }
轮询 session.list running → 完成 → 提示 [在浏览器中查看]（会话可见可继续）
```

- 深化文案（薄壳，中英随壳语言）：「请按所选环节与参数完善 <目标根> 的骨架：栈=java-backend({{params}}), vue3-frontend({{params}})。要求：补全可运行的最小实现与单测、前后端示例联调；确保 <make dev/build/test> 可跑；遵守项目根 AGENTS.md。完成标准：构建与测试本地通过。」；
- `mode: "queue"` 不抢占用户当前对话、不阻塞 UI；深化会话在 dsh web 左侧会话列表可见、可点击查看全过程、可中途取消——**透明度保证**（与 wiki 生成同款）；
- 服务未就绪时按钮置灰（`serverReady` 门控）。

---

## 7. UI 设计（ScaffoldPanel）

### 7.1 入口与面板容器

- 活动栏新增图标（SF Symbol `puzzlepiece.extension`，文案「脚手架 / Scaffold」），`RightPanel` 增加 `.scaffold` 分支；切换/宽度记忆/持久化沿用既有 `setRightPanel` 机制；
- 菜单「视图」→「工程脚手架」`⌃⌥S`（选中态跟随）；QA 钩子 `DSH_SCAFFOLD_TEST=1` 启动即开面板、`DSH_SCAFFOLD_TEST_DIR=<dir>` 预填目标目录、`DSH_SCAFFOLD_STAGES=<dir>` 追加环节目录；
- 面板根容器镜像 `WikiPanelController` 结构：40pt 头部 + 内容区 + 状态条，复用 `DynamicFillView`/`HoverButton`/`PanelIconButton`；**沿用已知的 layer 合成规避约定**（opaque 视图独立 layer，见 `docs/terminal-header-fix.md` 与 Wiki 面板修复记录）。

### 7.2 布局

```
┌─ 头部 40pt: [脚手架] 状态徽标 …… [在 Finder 中显示] [生成 ▾(二次确认)] [✕]
├─ 目标区: 项目名 [输入框]  →  位置 [目录选择…]（NSOpenPanel 选父目录, 显示解析出的目标根）
├─ 环节库: 分组列表（工程基础 / 示例栈 / 协作层）
│    每项: [checkbox] 环节名 + 一句话描述 + [参数]（选中后展开参数表单）
├─ 预览区: 将生成文件清单（N 文件, 冲突项标红 + 覆盖来源标注）+ 校验错误行
└─ 状态条: 生成中（环节 x/y）/ 完成 / 失败（原因 + 重试）
```

- 空态：未选环节时预览区显示「选择环节后将显示生成清单」；生成失败显示错误与「重试」；
- 生成完成后目标区变为「打开目录」「在 Finder 中显示」「Agent 深化 ▾（M3，服务就绪时可用）」；
- 预设组合（v1 便利）：顶部「按目的预设」（纯后端 API / 前后端兼备 / 文档+规范）一键勾选对应环节组——**预设只是快捷勾选，不限制组合**（可再改选）。

### 7.3 设置（壳层 UserDefaults，中英文案）

| 键 | 默认 | 含义 |
|---|---|---|
| `scaffoldEnabled` | true | 活动栏是否显示脚手架入口 |
| `scaffoldLastDir` | 无 | 上次选择的父目录（下次打开预填） |
| `scaffoldBackupConflicts` | true | 覆盖冲突文件前是否写入 `.scaffold-backup/` |

---

## 8. 代码改动落点

> 以下为**实现时**的改动清单（按子系统分组；新 Swift 文件由 `swift-sources.sh` 自动收录，无需登记）。

| 文件 | 改动 |
|---|---|
| `src/ScaffoldPanel.swift`（新增） | `StageCatalogLoader` / `ScaffoldTemplateRenderer` / `ScaffoldPlan` / `ScaffoldApplier` / `ScaffoldDeepenRPC`(M3) / `ScaffoldPanelController`（头部/目标区/环节列表/参数表单/预览/状态条） |
| `src/main.swift` | `RightPanel` 增加 `.scaffold`；活动栏图标按钮（SF Symbol `puzzlepiece.extension`）；`setRightPanel` 各调用点与 `rightPanelKind` 持久化扩展；「视图」菜单 `⌃⌥S`；`DSH_SCAFFOLD_TEST=1` / `DSH_SCAFFOLD_TEST_DIR` / `DSH_SCAFFOLD_STAGES` QA 钩子；`serverReady` 门控接线；L10n 新增 `scaffold.*` 键（中/英，见 7.3） |
| `scaffold-stages/`（新增，仓库根、跨平台共享） | v1 环节库（第 13 节）：`git-init` / `git-conventions` / `agents-md` / `docs-standards` / `conventions` / `makefile` / `ci-cd` / `docker` / `deploy` / `repo-knowledge` / `java-backend` / `vue3-frontend`，每个 `<id>/stage.yaml` + `templates/` |
| `build-app.sh` | 复制 `scaffold-stages` 到 `Contents/Resources/scaffold-stages`（参照 303 行 highlight.js 资源先例）；版本号递增（M3 收尾如 1.14.0） |
| `README.md` | 「特性」新增「工程脚手架」小节；「目录」补充本文档 |
| `tests/scaffold-panel/`（新增） | 无头单测：`run.sh` + `scaffold-tests.swift`（范式同 `tests/wiki-panel/`，见 10.1） |

**L10n 新键草案（中/英）**：`scaffold.title`（脚手架 / Scaffold）、`scaffold.presetBackend`（纯后端 API / Backend API only）、`scaffold.presetFullstack`（前后端兼备 / Full-stack）、`scaffold.presetFoundation`（文档+规范 / Docs & conventions）、`scaffold.projectName`、`scaffold.parentDir`（位置 / Location）、`scaffold.pickDir`（选择… / Choose…）、`scaffold.stageCategory.foundation|examples|collaboration`、`scaffold.previewCount`、`scaffold.conflict`（冲突 / Conflict）、`scaffold.generate`（生成 / Generate）、`scaffold.generating`（生成中… / Generating…）、`scaffold.done`、`scaffold.failed`、`scaffold.openDir`（打开目录 / Open Folder）、`scaffold.viewInFinder`、`scaffold.deepen`（Agent 深化 / Deepen with Agent）、`scaffold.emptyTarget`（选择环节后将显示生成清单 / Select stages to preview）等。

---

## 9. 边界情况与失败处理

| # | 场景 | 处理 |
|---|---|---|
| 9.1 | 目标目录已存在且非空 | 生成前确认弹窗；开启「覆盖 + `.scaffold-backup/` 备份」后继续（`scaffoldBackupConflicts` 关闭则不备份直接覆盖提示）；「仅补缺失」增量模式 v2 |
| 9.2 | 项目名为中文/含非法字符 | slugify 生成目录名（ASCII，保底 `project`）；面板显示解析后的实际目录 |
| 9.3 | Java 包名非法 | 内置校验器 `javaPackage`（合法段 + 不以数字开头 + 无保留字）；错误行内联显示 |
| 9.4 | 模板渲染失败（参数缺失/非法/模板损坏） | 该环节跳过不落盘，预览/状态条报「环节 X 渲染失败：原因」；其余环节照常；可修复后重跑（幂等覆盖，9.10） |
| 9.5 | `git` 不可用 / `git init` 失败 | 命令失败仅记日志 + 状态条提示「未初始化 git」；不阻断文件生成 |
| 9.6 | 服务未就绪（深化按钮） | `serverReady` 门控：置灰 + 提示（与 wiki 生成按钮同款） |
| 9.7 | 参数自洽性（选 docker 但 runtime=java 而没选 java-backend） | 仅提示不强制（v1 无自动联动）；提示文案固定「该组合可能需要 X，请确认」 |
| 9.8 | 路径穿越（`{{artifactId}}` 含 `../` / 绝对路径） | `safePath` 校验器拒绝 + 环节报错 |
| 9.9 | 目标位置无写权限 | 错误态 + 建议换目录；不残留半成品（落盘前先整体校验可写） |
| 9.10 | 生成中断 / 重复生成 | 幂等：按 state.json 重跑全量覆盖（备份在先）；中断后重跑不产生 `.scaffold-backup` 重复堆积（同名备份覆盖） |
| 9.11 | 用户扩展环节清单损坏 | 加载时隔离：跳过并列出「环节 X 加载失败：原因」，内置环节不受影响 |
| 9.12 | `DSH_SCAFFOLD_STAGES` 与内置环节同名 | 追加语义：同名不覆盖，仅用于开发/测试注入新环节（文档注明） |
| 9.13 | 环节库随 App 升级 | 内置环节整体随版本替换；`.scaffold/state.json` 记录版本，重跑时兼容提示 |
| 9.14 | 多环节写同一路径 | 预览冲突清单（后写覆盖 + 标红 + 列出来源环节）；用户可调整顺序或取消某环节 |
| 9.15 | L10n 缺失键 | 回退英文（与既有面板同一兜底策略） |
| 9.16 | Jenkins 凭据引用 | 模板只生成 `withCredentials(credentialsId: '<占位>')` 引用 ID，**绝不内联密钥**；凭据 ID 与 agent label 均参数化，并注释说明在 Jenkins Credentials/Node 里如何配置（与仓库自用 `Jenkinsfile` 惯例一致）；浅克隆无 tag 的坑由 `Checkout` 阶段的 `git fetch --tags` 吸收 |
| 9.17 | Git hook / `.gitmessage` 与目标已有文件冲突 | 安装脚本**非破坏**：目标已存在 `commit-msg` hook 或 `.gitmessage` 时先备份（`.scaffold-backup/`）再写入，或跳过并提示手动合并；**绝不覆盖用户已有 git 配置** |
| 9.18 | 远程部署失败（SSH 不可达 / 密钥未配 / kubeconfig 缺失） | 脚本**前置检查**给明确错误与修复指引（`ssh -o BatchMode=yes` 探活、`kubectl config current-context` 校验）；执行前先校验（docker：远端 `docker compose config` dry-run；k8s：`kubectl apply --dry-run=client`）避免半部署态；失败输出错误码与日志位置，可按 `state.json` 重跑 |

---

## 10. 测试与验收

### 10.1 自动化（本环境可做）

- **编译验证**：`swiftc -O -swift-version 5 -module-cache-path .build/module-cache -framework AppKit -o /tmp/scaffold-test src/main.swift src/PreviewPanel.swift src/TerminalPanel.swift src/WikiPanel.swift src/ScaffoldPanel.swift` 零错误（仅既有 WebKit Sendable 警告）；
- **引擎单测**（`tests/scaffold-panel/run.sh`，范式同 wiki-panel）：fixture 环节库 → 断言 ——
  - stage.yaml 解析（字段缺失/非法类型 → 隔离错误）；
  - 校验器（javaPackage / slug / safePath / nonEmpty 正反例）；
  - 渲染器（`{{var}}` 替换、`{{#if}}` 真假分支、文件名渲染、`{{{{` 转义、缺失变量报错）；
  - 规划（多环节文件清单合并、同路径冲突标记、顺序语义）；
  - 落盘（fixture 目标目录：文件内容字节级断言、冲突备份 `.scaffold-backup/`、state.json 内容）；
- **端到端 fixture 组合**：内置环节库 + 「纯后端 API」预设参数 → 断言产物树（AGENTS.md 含项目名与 make 命令、`backend/pom.xml` 含 groupId、Makefile 含用户命令、docs 骨架齐）；「前后端兼备」预设 → 断言 `frontend/` 产物与 Makefile 双目标；`platform=jenkins` 组合 → 断言根目录 `Jenkinsfile` 含 lint→test→build 阶段、`withCredentials` 凭据占位且无内联密钥、`post.always` 归档；`git-conventions`（enforce=true）组合 → 断言 `docs/conventions/git.md` 含 Conventional Commits type 枚举与分支前缀、`.gitmessage` 存在、`scripts/install-git-hooks.sh` 为纯 shell 校验（无 node 依赖）；`deploy`（deployDocker+deployK8s+deployRancher 全选、`remoteHost` 非空）组合 → 断言 `deploy/deploy-docker.sh` 含 rsync/ssh 远程分支与健康检查回滚、`deploy/deploy-k8s.sh` 含 `KUBE_CONTEXT` 参数与 `rollout undo`、`deploy/deploy-rancher.sh` 存在且复用 k8s manifests、三脚本均含 `--dry-run` 且无内联密钥。**渲染器/规划器/落盘器不依赖面板与网络**，可在 CI 无头跑。

### 10.2 手动 QA 清单（用户运行 App 验收）

1. `DSH_SCAFFOLD_TEST=1` 启动直开脚手架面板，`DSH_SCAFFOLD_TEST_DIR` 指向临时目录；
2. 空态 → 勾选「文档+规范」预设 → 预览出现文件清单 → 生成 → 目录结构与内容正确；
3. 「纯后端 API」预设（含 java-backend）→ 填 groupId/artifactId → 生成 → `mvn -q test` 可跑（若本机有 JDK；
4. 「前后端兼备」预设 → 生成 → `make build` 目标在 Makefile 中正确展开；
5. 冲突：同路径两环节（如两个都写 README）→ 预览标红 + 覆盖提示；
6. 非空目录 → 确认弹窗 + `.scaffold-backup/` 出现；
7. 中文项目名 → slug 正确、目录可建；非法包名 → 行内错误；
8. 中断/重跑幂等；state.json 记录正确；
9. 与既有面板互斥切换、宽度记忆、重启恢复（`rightPanelKind`）；
10. 中英文界面文案齐全；退出 App 无残留；
11. 选 `git-conventions`（enforce=true）生成到临时目录 → 运行 `scripts/install-git-hooks.sh` → 提交一条违规消息被拦截、合法消息通过；已有同名 hook 时先备份不覆盖（9.17）；
12. 选 `ci-cd`（platform=jenkins）→ 生成根目录 `Jenkinsfile` → 内容含 lint/test/build 阶段、凭据占位（无真实密钥）、`post.always` 归档；发布动作默认门控不触发。
13. 选 `deploy`（deployDocker+deployK8s）→ `--dry-run` 只打印预期命令且不实际部署；`bash -n` 语法校验通过；docker 脚本本机部署到临时 compose：健康检查失败路径触发回滚提示；
14. 远程部署（有可用 SSH 环境）：`deploy-docker.sh` 指定 `remoteHost` 后能把 `deploy/` rsync 到远程并远程执行；k8s 脚本对测试集群 `--context` 走通 apply → rollout → undo 全路径（CI/手动各一次）。

---

## 11. 里程碑

| 里程碑 | 内容 | 验收 |
|---|---|---|
| **M0** | 本文档评审通过 | 设计决策闭环、无开放问题 |
| **M1** | `StageCatalogLoader` + `ScaffoldTemplateRenderer` + `ScaffoldPlan` + `ScaffoldApplier` + `ScaffoldPanelController`；`RightPanel.scaffold`、菜单 `⌃⌥S`、L10n、QA 钩子；**工程基础 10 环节**（git-init / git-conventions / agents-md / docs-standards / conventions / makefile / ci-cd / docker / deploy / repo-knowledge）；预设 3 组；10.1 编译 + 引擎单测通过 | 能组合生成**栈无关骨架**端到端；10.2 的 1-2、5-10 通过 |
| **M2** | **示例栈环节** java-backend（Spring Boot 3 + Maven 最小骨架 + 健康检查单测）与 vue3-frontend（Vue 3 + Vite + TS 最小骨架 + 示例 API 调用 + 单测）；6.1 的 AGENTS.md 与所选环节自洽性完整覆盖 | 「纯后端 API」「前后端兼备」两种典型组合全链路生成；10.2 的 3-4 通过；`build-app.sh` 产出新版本（如 1.13.0 → 1.14.0） |
| **M3** | **Agent 深化链路**：`ScaffoldDeepenRPC`（createSession/prompt queue/轮询/打开会话，归入工作区）+ 深化文案模板（中英）+ 深化按钮态（`serverReady` 门控）；**用户扩展环节库**（`$DSH_HOME/scaffold-stages/` 扫描与坏清单隔离，9.11）；`state.json` 审计增强；README 特性说明 | 生成后一键深化端到端跑通（dsh web 可见会话、可继续对话）；用户放置自定义环节 → 面板出现并可组合；10.2 全过 |

> 注：`docs-standards` 中的 QMD/语义检索之类增强不涉及本功能；「增量补环节」（v2）与「环节市场」（非目标）不在 M1-M3 内。

---

## 12. 明确假设

1. 面板沿用右侧活动栏槽位；切换/宽度记忆/持久化沿用既有机制；
2. 骨架确定性部分**由壳层 Swift 引擎本地渲染**（快、可复现、无 token）；「深化」由 dsh 代理执行（M3）——两者互补，不互相替代；
3. 不修改任何 DeepSeek Harness 源码；**不碰**用户已有项目文件（仅写入用户确认的目标目录，冲突走备份）；
4. v1 环节库 = 内置 12 个环节（第 13 节），环节 = `stage.yaml` + 模板文件，随 App 版本化分发；模板语法为 `{{var}}` + `{{#if}}`（v1 刻意最小）；
5. `session.create` / `session.prompt`（`mode: queue`）复用 WikiRPC 已验证链路；若 dsh 接口变化，按新 schema 适配；
6. 环节库内置路径 `Contents/Resources/scaffold-stages`（构建期复制）；开发期用 `DSH_SCAFFOLD_STAGES` 追加；
7. v1 不做跨环节自动联动（9.7 只提示）；「预设」只是快捷勾选，不限制自由组合；
8. 生成以「全新目录」为主；非空目录仅确认 + 备份覆盖（9.1），增量补环节为 v2。

---

## 13. 环节库 v1 清单

### 13.1 工程基础（category: foundation，栈无关）

| id | 名称（中/英） | 参数 | 产出 |
|---|---|---|---|
| `git-init` | 仓库初始化 / Git Init | `license`（none/MIT/Apache-2.0）、`gitIgnorePreset`（通用/java/node） | `.gitignore`、`README.md` 骨架（项目名/一句话/快速开始占位）、`LICENSE`（按参数）；命令 `git init -b main` |
| `agents-md` | Agent 协作层 / AGENTS.md | `techSummary`（一句话项目说明）、`primaryLang`（主语言） | `AGENTS.md`（项目是什么/目录结构/常用命令/规范引用/禁区/与 dsh 协作说明），内容随所选环节自洽（6.1） |
| `docs-standards` | 文档规范骨架 / Docs Standards | `docsLang`（zh/en/双语） | `docs/architecture.md`（模板）、`docs/adr/ADR-0001-template.md`、`docs/conventions.md` 骨架、`docs/ops/runbook.md` 模板 |
| `conventions` | 开发规范落地 / Conventions | `vcs`（github/gitlab）、`docsLang` | `.editorconfig`、`CONTRIBUTING.md`（PR 规范/DoD 检查清单；提交/分支规范**简版内置**，完整版引用 `docs/conventions/git.md`——未选 git-conventions 环节时简版即兜底） |
| `git-conventions` | Git 提交与分支规范 / Git Conventions | `enforce`（bool：附带 commit-msg 校验脚本）、`trunk`（main/master，默认 main） | `docs/conventions/git.md`（**提交规范**：Conventional Commits——type 枚举 feat/fix/docs/refactor/perf/test/chore/build/ci/revert、scope、示例、Why（自动 changelog/可追溯）；**分支规范**：feature/\<slug\> 新功能、fix/\<slug\> 修复、release/X.Y 已发布修复、主干受保护/禁 force-push/PR 合入规则——模板内容参照本仓库 `docs/git-workflow.md` 既定约定）、`.gitmessage`（git commit 模板）、`scripts/install-git-hooks.sh`（enforce=true：纯 shell commit-msg 校验，**无 node 依赖**；已有 hook 备份不覆盖，见 9.17） |
| `makefile` | 统一命令入口 / Makefile | `backendBuild`、`backendTest`、`frontendInstall`、`frontendBuild`、`testCmd`、`lintCmd`（均可空，空则生成注释占位） | `Makefile`（dev/build/test/lint/clean 目标，按参数展开；未选对应栈则注释说明） |
| `ci-cd` | CI/CD 模板 / CI & CD | `platform`（github-actions/gitlab-ci/**jenkins**）、`hasBackend`、`hasFrontend` | `.github/workflows/ci.yml`+`cd.yml`（或 `.gitlab-ci.yml`、或根目录 `Jenkinsfile`）：lint→test→build 门禁 + 镜像/部署占位 |
| `docker` | 容器化 / Docker | `runtime`（java/node/static）、`exposePort`、`healthzPath` | `Dockerfile`（多阶段、按 runtime 分支）、`.dockerignore`、`compose.yaml`（本地起服务 + 占位依赖） |
| `deploy` | 部署规范 / Deploy | `deployDocker` / `deployK8s` / `deployRancher`（bool，可多选）、`imageRepo`、`imageTag`、`remoteHost`（空=本机）、`sshUser`、`namespace`（k8s，默认 production）、`kubeContext`（空=当前 context）、`rancherServer`（空=仅内网说明）、`servicePort`、`healthzPath` | **可执行部署脚本**（非文档）：`deploy/deploy-docker.sh` + `docker-compose.prod.yml` + `.env.example`；`deploy/deploy-k8s.sh` + `deploy/k8s/{deployment,service,configmap}.yaml`；`deploy/deploy-rancher.sh`（复用 k8s manifests + `deploy/rancher/README.md`）。脚本支持**本机 / 远程**部署、`--dry-run`、默认交互确认、失败自动回滚（设计要点见下） |
| `repo-knowledge` | 知识库准备 / Wiki Prep | 无 | `.dsh/wiki/README.md` 占位（引导用 repo-knowledge skill 生成知识库），不与生成代理（保持确定性） |

> **Jenkins 模板说明**（`platform=jenkins`）：产出根目录 `Jenkinsfile`，**声明式 pipeline**——形态与工程惯例对齐本仓库自用 `Jenkinsfile`（见仓库根的活样本，含标签/凭据/归档等企业约定）：
> - `agent { label '<占位>' }` 参数化，头部注释说明 agent 需安装的工具链；`options` 含 `timestamps()` / `disableConcurrentBuilds()` / `timeout`；
> - 阶段划分：`Checkout`（含 `git fetch --tags --force || true` 教训——Jenkins 浅克隆可能无 tag）→ `Lint` → `Test` → `Build` → `Package / Publish`（发布/部署用 `when { expression { params.<X> } }` 参数门控，**默认不触发**外部动作）；
> - 凭据一律 `withCredentials([… credentialsId: '<占位>', variable: '<X>'])` 引用 ID，**绝不内联密钥**（9.16）；镜像推送/部署步骤输出为注释占位 + TODO 标记；`post.always` 归档产物（`archiveArtifacts`）。

> **部署脚本设计要点**（`deploy` 环节，产出**可执行脚本**而非仅文档）：
> - **本机 / 远程双模式**：`remoteHost` 为空 → 本机直接执行；非空 → docker 部署经 `rsync` 把 `deploy/` 同步到远程 + `ssh` 远程执行 compose（健康检查也在远程 curl）；k8s / Rancher 天然支持远程（kubectl 以 `--context` / KUBECONFIG 指向远程集群，`rancherServer` 用于登录/取 kubeconfig 指引）；
> - **安全基线**：脚本 `set -euo pipefail`；密钥只引用不内联（SSH key 路径 / KUBECONFIG / Rancher token 均为参数或环境变量占位）；默认交互确认 + `--yes` 跳过；`--dry-run` 只打印将执行命令；
> - **可回滚**：docker 健康检查失败 → 切回上一镜像 tag 重启；k8s 用 `kubectl rollout undo`；Rancher 同 k8s（UI 回滚点为补充说明）；
> - **与 `docker` 环节分工**：`docker` = 镜像构建 + 本地开发编排（Dockerfile / compose.yaml）；`deploy` = 生产部署脚本与生产编排 / manifests（`deploy/` 目录）——互不写同一路径。
>
> **各脚本执行流程**：
> - **`deploy/deploy-docker.sh`**：前置检查（docker 可用 / `remoteHost` 探活 / `.env` 存在）→ `--dry-run` 打印将执行命令 → 本机 `docker compose -f deploy/docker-compose.prod.yml up -d --pull`（远程：先 `rsync` 同步 `deploy/` 到远端，再 `ssh` 远程执行）→ 健康检查轮询（curl `healthzPath`，N 次 × 间隔）→ 失败自动切回**上一镜像 tag** 重启 → 成功输出访问地址；
> - **`deploy/deploy-k8s.sh`**：前置检查（`kubectl config current-context` 校验 `KUBE_CONTEXT`；namespace 不存在则 `create`）→ `--dry-run`（`kubectl apply --dry-run=client`）→ `kubectl apply -f deploy/k8s/`（顺序 configmap → deployment → service）→ `kubectl set image deployment/<app> app=$IMAGE_REPO:$IMAGE_TAG`（镜像覆盖，**免改 yaml**）→ `kubectl rollout status deployment/<app> -n $NS` 等待就绪 → 失败 `kubectl rollout undo` + pod 事件/日志指引 → 成功输出服务暴露地址；
> - **`deploy/deploy-rancher.sh`**：`RANCHER_SERVER` / kubeconfig 前置校验（缺失则打印从 Rancher 获取 kubeconfig 的指引）→ **复用 `deploy/k8s/` manifests 执行与 deploy-k8s.sh 相同流程** → Rancher 项目 / 命名空间映射与 UI 回滚点说明见 `deploy/rancher/README.md`。

### 13.2 示例栈（category: examples）

| id | 名称 | 参数 | 产出 |
|---|---|---|---|
| `java-backend` | Java 后端脚手架（Spring Boot 3 + Maven） | `groupId`、`artifactId`、`packageName`（可推导）、`javaVersion`（17/21）、`springBootVersion`（默认锁定） | `{{artifactId}}/pom.xml`、`src/main/java/<pkg>/Application.java`、`HealthController.java`（`/healthz`）、`src/main/resources/application.yml`、`src/test/java/<pkg>/HealthControllerTest.java`（示例单测）——**最小可运行**，业务留待 Agent 深化 |
| `vue3-frontend` | Vue 3 前端脚手架（Vite + TypeScript） | `packageName` | `package.json`、`vite.config.ts`、`tsconfig.json`、`index.html`、`src/main.ts` / `App.vue`、`src/api/client.ts`（示例 fetch 封装）、`src/App.spec.ts`（vitest 示例）、`.gitignore` 片段（node）——**最小可运行**，页面联调留待 Agent 深化 |

### 13.3 协作层（category: collaboration）

| id | 名称 | 参数 | 产出 |
|---|---|---|---|
| `deepen-session`（M3） | 骨架深化 / Deepen with Agent | 无（读取用户所选全部环节与参数生成深化文案） | 不产出文件；生成完成后出现在「Agent 深化 ▾」动作中，触发 dsh 会话 |

> 原则：示例栈环节**不隐式依赖**工程基础环节（可单独选），参数自洽性只做提示（9.7）；`git-init` 的 `.gitignore` 与 `vue3-frontend` 的 `.gitignore` 片段在预览中标记冲突（9.14），由用户取舍。
>
> 注：`react-frontend`（Vite + React + TS）示例环节**暂缓**——命名模式与 `vue3-frontend` 同构（`<技术>-frontend`），后续按需补入即可（环节库可扩展，9.11/用户扩展目录）。

---

## 14. 实施记录

> 本节点仅在 M1-M3 实施后追加（对齐 `docs/repo-wiki-design.md` 第 14 节的写法：每里程碑记录实现、验证、修复经验）。

### M1（2026-08，feature/scaffold-workbench）

**实现**：

- 新增 `platforms/macos/src/ScaffoldPanel.swift`：`MiniYAML`（stage.yaml 子集解析器）、`StageCatalogLoader`（搜索链：内置 Resources → `DSH_SCAFFOLD_STAGES` 追加，同名先到先得不覆盖；坏清单隔离）、`ScaffoldTemplateRenderer`（`{{var}}`/`{{#if}}`/`{{{{ }}}}` 转义、文件名渲染、缺失变量报错、嵌套 if）、`ScaffoldValidators`（nonEmpty/slug/safePath/javaPackage）、`ScaffoldPlan`（默认值+用户参数合并、派生标志 has* / select 选项标志 / 空值 Empty 标志、CI 派生命令、冲突检测、渲染失败整环节跳过、参数自洽提示）、`ScaffoldApplier`（写文件/备份 .scaffold-backup/ /环节命令/state.json，幂等）、`ScaffoldPreset`（3 组预设）、`ScaffoldPanelController`（头部 40pt + 目标区 + 环节分组列表 + 参数表单 + 预览 + 状态条，复用 DynamicFillView/HeaderLabel/CustomIconButton 基件）；
- `main.swift`：`RightPanel.scaffold`、活动栏 `puzzlepiece.extension`（`scaffoldEnabled` 可隐藏）、视图菜单 `⌃⌥S`、`rightPanelKind` 持久化、`DSH_SCAFFOLD_TEST=1`/`DSH_SCAFFOLD_TEST_DIR` QA 钩子、`serverReady` 门控接线（M3 深化预留）、设置菜单「覆盖冲突前备份」开关、L10n `scaffold.*` 键（中英）；
- 工程基础 10 环节：`scaffold-stages/`（仓库根，跨平台复用）（git-init / git-conventions / agents-md / docs-standards / conventions / makefile / ci-cd / docker / deploy / repo-knowledge），每环节 `stage.yaml` + `templates/`；文件条目支持 `if: <key>` / `if: <key>=<value>` 条件产出（LICENSE 按 license、Jenkinsfile 按 platform、hook 脚本按 enforce、deploy 脚本按 deployDocker/K8s/Rancher）；
- `build-app.sh` 把 `scaffold-stages` 复制进 `Contents/Resources/scaffold-stages`（参照 highlight.js 资源先例）；
- `tests/scaffold-panel/`（run.sh + scaffold-tests.swift）：147 例引擎单测 + 端到端组合（纯后端 API 预设 / platform=jenkins / git-conventions(enforce=true) / deploy 全选+remoteHost）；
- `scripts/local-ci.sh` 阶段 2 接入 `tests/scaffold-panel/run.sh`；README 特性与目录更新。

**验证**：`scripts/local-ci.sh swift` 全绿（各面板单测 + swiftc 全量编译检查，仅既有 WebKit Sendable/Highlightr 警告）；`tests/scaffold-panel/run.sh` 147 passed / 0 failed。

**修复经验**：

- `ScaffoldApplier` 备份逻辑：先 `removeItem` 再 `copyItem` 在**首次备份**时因备份文件不存在而抛错，导致整文件写入被跳过——改为 `fileExists` 判断后删除再复制；
- 校验器对**可选空参数**（如 `deploy.remoteHost` 空 = 本机）放行：仅 `nonEmpty` 视为缺失，slug/safePath/javaPackage 对空串返回通过；
- 模板与 GitHub Actions `${{ }}` 语法冲突：模板内用 `${{{{ X }}}}` 转义（渲染为 `${{ X }}`），引擎单测覆盖 round-trip；
- YAML 子集解析器对「未闭合内联 list」等坏清单的报错路径，由测试 fixture 固化（`files: [unclosed` → 隔离报错）。
