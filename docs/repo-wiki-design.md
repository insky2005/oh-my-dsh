# 功能设计：oh-my-dsh「Repo Wiki」——仓库知识库的生成、维护与浏览

> 状态：📋 设计稿（M0）· 待评审 · 2026-08
> 范围：基于 oh-my-dsh（DeepSeek Harness 的 macOS 原生壳）新增「Repo Wiki」功能。本文档只做设计，不含实现；实现按「里程碑」一节分阶段推进。
> 原则：与壳层既有约定一致——**不改动任何 DeepSeek Harness 源码**，一切通过壳层面板 + dsh 既有能力（skill / session RPC / AGENTS.md 指令加载）实现。

---

## 1. 背景与现状调研

### 1.1 什么是「Repo Wiki」

「Repo Wiki」指为**单个代码仓库**维护的一份随代码演进的、结构化、可版本化的知识库：架构总览、模块地图、数据模型、工程约定、常见任务操作手册等。它同时服务两个消费方：

- **人**：快速了解仓库，代替翻阅大量源码；
- **AI 代理**：作为**跨会话的持久记忆**——新会话无需重新探索整个仓库，先读 wiki，再按需深入源码，从而减少 token 消耗、提升回答质量与一致性。

与「个人 Wiki / 知识管理」不同，Repo Wiki 的核心诉求是**跟着仓库代码走**：代码变了，知识要能增量更新、能标记陈旧、不能覆盖用户手改。

### 1.2 行业现状（两条路线）

**路线 A：IDE / 助手侧的文档与记忆能力（产品内置）**

| 产品 | 能力 | 机制 |
|---|---|---|
| [Cursor @Docs](https://cursor.com/help/customization/context.md)（[中文说明](https://cursor.zone/docs/context/docs.html)） | 对话中 `@` 引用文档 | 爬取/导入文档 URL 或代码片段，建索引后在对话中检索注入 |
| GitHub Copilot | 代码库索引 + 自定义指令 | 仓库级 embedding 索引 + 用户自定义说明文件 |
| Windsurf | Memories | 代理维护用户/工作区级记忆条目，跨会话读取 |
| Claude Code | `CLAUDE.md` / `AGENTS.md` | 项目根/目录级指令文件，会话自动加载（dsh 的 `dsh-agent-instructions` 正是同一模式） |
| Zed / Codex / Gemini CLI / Devin 等 | 项目上下文 / 自动探索 | 启动时把项目结构与关键文件注入上下文 |

**路线 B：社区「代理记忆」方案（与本设计的思路最接近）**

| 方案 | 思路 |
|---|---|
| [Roo Code / Claude Code 的 Memory Bank](https://killer-skills.com/fr/skills/Wellux/claude-code-deprecated/memory-bank) | 代理维护一组 markdown 文档（进度/架构/决策/约定），关键节点必须更新后继续 |
| [skill-memory-bank](https://www.awesomeskills.dev/zh-CN/skill/fockus-skill-memory-bank) | 以 skill 形式分发同一套 Memory Bank 流程，跨 Claude Code / Cursor / Codex / OpenCode / Windsurf 使用 |
| [LangChain OpenWiki Brains](https://www.langchain.com/blog/introducing-openwiki-brains-general-purpose-wiki-memory-for-agents) | 通用「wiki 记忆」代理：自动沉淀会话中的知识到 wiki 供后续会话读取 |
| [codealmanac](https://www.npmjs.com/package/codealmanac)、[codebase-memory](https://www.npmjs.com/package/codebase-memory)、[memwiki](https://www.npmjs.com/package/memwiki) | 社区 npm 包：从仓库/会话生成持久 markdown 记忆库 |
| [跨工具上下文痛点讨论](https://forum.cursor.com/t/how-are-people-handling-context-across-different-ai-coding-tools/159891/5)、[「代理会话间失忆」问题综述](https://dev.to/uratools/your-ai-agent-forgets-everything-between-sessions-i-fixed-that-3i0e) | 社区普遍痛点：会话级记忆不跨会话、每次重新探索、重复消耗 token |

**共性结论**（本设计的依据）：

1. 知识载体是**可版本化的 markdown 文件**，放在仓库内或仓库外配置目录，人可读、可审、可提交；
2. 注入方式分「**自动全量/摘要注入**」与「**按需读取**」两级，普遍倾向按需读取以控 token；
3. 维护方式分「**手动**」与「**代理自主增量更新**」，成熟方案都有陈旧检测与用户编辑保护；
4. 与产品既有机制正交：指令文件（AGENTS.md 类）、skill、会话记忆三者常组合使用。

### 1.3 用户痛点（oh-my-dsh 场景）

- dsh 代理在每次新会话都要重新读 README、扫目录结构、翻关键文件，才能回答「这个仓库怎么跑/某模块在哪」类问题——**重复探索、重复烧 token**；
- 会话结束即忘：上一会话摸清的架构结论、踩过的坑，下一会话完全不知道（dsh 虽有会话持久化与 `session.search` 全文检索，但**检索 ≠ 结构化知识**，代理不会主动去搜）；
- 人想快速浏览仓库结构时，现有预览面板只能看单个文件，**缺少仓库级的知识视图**；
- 仓库知识（约定、运行方式）通常散落在 README、文档、注释、会话里，没有一个统一入口。

### 1.4 与 oh-my-dsh / dsh 的契合点（已核实）

**dsh 运行时（`@deepseek-ai/dsh@0.1.1-rc.2`）侧已具备的能力：**

| 能力 | 出处（dsh 包） | 用途 |
|---|---|---|
| `AGENTS.md`/`CLAUDE.md` 兼容的逐目录指令加载（项目根 → cwd，含 `$DSH_HOME/AGENTS.md`） | `dsh-agent-instructions` | wiki 上下文注入的天然钩子 |
| skill 注册表 + 文件系统提供者（扫描 `<projectRoot>/.dsh/skills`、`<projectRoot>/.agents/skills`、`$DSH_HOME/skills` 等 5 级根，`SKILL.md` 格式） | `dsh-skill` / `dsh-skill-filesystem` | wiki 生成/维护流程以 **skill** 形式分发 |
| 会话 HTTP RPC：`session.list` / `session.create` / `session.prompt` / `session.search` / `session.history`（JSON-RPC 风格 `client-request` 信封，见 3.3） | `dsh-host-apiproxy` | 壳层**编程触发**代理执行 wiki 生成 |
| FTS5 会话全文检索 | `dsh-session-query-sqlite` | 生成时可参考历史会话沉淀的知识 |
| workspace 注册表、YAML/JSON 设置 | `dsh-workspace` / `dsh-settings-file` | 多仓库归属与代理侧参数 |

**oh-my-dsh 壳层侧已具备的基础设施：**

| 能力 | 位置 | 用途 |
|---|---|---|
| 右侧活动栏面板系统：`RightPanel { none, preview, terminal }`、互斥切换、宽度记忆、`rightPanelKind` 持久化 | `src/main.swift`（732 行起） | 新增 `.wiki` 第三个面板 |
| `DSHSessionRPC`（`session.list` → 活动会话 cwd）、`serverReady(port:)` 门控 | `src/main.swift`（653-707 行；`src/TerminalPanel.swift`） | 解析仓库根目录、延迟到服务就绪再加载 |
| 文件树 `TreeNode`/`NSOutlineView`、懒加载子节点、2s 变更轮询 | `src/PreviewPanel.swift`（18-33、952-1030 行） | wiki 页面树直接复用该模式 |
| `HoverButton`/`ActivityBarButton`/`DynamicFillView`/`PanelIconButton`、中英 L10n 表、`DSH_*_TEST` QA 钩子、UserDefaults 持久化 | `src/PreviewPanel.swift`、`src/main.swift` | 面板 UI、文案、测试钩子 |
| 已知限制：预览面板把 markdown 当**纯文本**显示（有意为之，避免软换行被合并） | `src/PreviewPanel.swift`（1266-1272 行） | wiki 面板需要**真正的 markdown 渲染**，与预览面板行为区分 |
| 构建：`build-app.sh` 显式列出编译源文件（约 196 行）；版本号递增 | `build-app.sh` | 新增 `WikiPanel.swift` 等需登记 |

---

## 2. 目标与非目标

### 2.1 目标

- **G1 生成**：一键（或自动）让 dsh 代理探索仓库，产出一套结构化 markdown 知识库（初始生成 + 增量更新），内容人可读、可提交、可审；
- **G2 维护**：增量更新只动受影响页面；陈旧页面可被标记；用户手改的页面不被覆盖；
- **G3 浏览**：壳层新增「Repo Wiki」右栏面板——页面树 + 渲染后的 markdown 内容 + 标题搜索 + 页面间链接/backlinks 跳转；
- **G4 注入**：让 dsh 代理**按需读取** wiki（通过 `AGENTS.md` 注册块 + skill 发现），新会话不再盲目重新探索；可选自动注入 index 摘要；
- **G5 一致**：全部通过壳层面板 + dsh 既有能力实现，不改任何 DeepSeek Harness 源码；中英双语文案；与既有面板视觉/交互一致。

### 2.2 非目标（v1 明确不做）

- 不做跨仓库共享/社区发布（个人仓库内闭环）；
- 壳层内置不做向量检索 / RAG / embedding（页面量级小，标题过滤 + 简单内容扫描足够）；QMD 语义检索**暂不整合**，仅保留为后续「检索能力增强」的候选（见第 13 节）；
- 不自己做代码静态分析器——分析全部交给 dsh 代理（bash/fs/subagent/workflow 工具）执行；
- 不做「代理每步都自动咨询 wiki」的强制注入（默认按需读取，注入开关可配）；
- 不改动、不隐式修改用户已有的 `AGENTS.md`/`CLAUDE.md`（注册块为**显式开关**，见 6.2）。

---

## 3. 总体架构

### 3.1 双组件 + 触发链路

```
┌─────────────────────────── oh-my-dsh (macOS 壳) ───────────────────────────┐
│  RightPanel.wiki 面板 (WikiPanel.swift)                                     │
│   ├─ 页面树 / 内容渲染 / 搜索 / 状态条 / 操作按钮                             │
│   ├─ WikiWatcher: 监听 <wikiRoot> 文件变更 → 刷新树与陈旧标记                 │
│   └─ WikiRPC: 触发生成 / 轮询状态（session RPC）                            │
└──────────────┬──────────────────────────────────────────────────────────────┘
               │ HTTP POST /api/session.create + session.prompt (mode: queue)
               ▼
┌─────────────────────────── dsh web (服务端，源码不动) ──────────────────────┐
│  新会话（标题「Wiki 生成」）→ 代理加载 repo-knowledge skill → 用工具探索/读写      │
│  ├─ 读: README / 包清单 / 目录 / git status / 关键源码 / session.search       │
│  └─ 写: <repo>/.dsh/wiki/** (index.md + 分节页面, frontmatter)              │
└──────────────────────────────────────────────────────────────────────────────┘
```

**关键决策**：wiki 的「内容」由 dsh 代理生成，壳层只做「触发 + 呈现」。壳层**不解析代码**，因此无需理解任意语言/框架，代理能力随 dsh 演进自动受益。

### 3.2 组件职责

| 组件 | 归属 | 职责 |
|---|---|---|
| `repo-knowledge` skill | dsh 侧（`SKILL.md`，见 5.1） | 定义生成/更新的完整提示词与页面规范——**单一事实来源** |
| 生成提示词（薄壳） | 壳层内嵌副本 | skill 缺失时回退；平时只是「调用 skill 执行 X」的薄指针 |
| `WikiPanelController` | 壳层新文件 | 面板 UI：树/渲染/搜索/状态/操作 |
| `WikiMarkdownRenderer` | 壳层新文件 | 轻量 Swift markdown → NSAttributedString（见 7.3） |
| `WikiWatcher` | 壳层新文件 | 监听 wiki 根目录变更（FSEvents 或轮询，见 4.4） |
| `DSHSessionRPC` 扩展 | 壳层 main.swift | `createSession(cwd)` / `promptSession(...)` / `sessionRunning(id)` |

### 3.3 触发链路（壳层 → 代理）

复用现有 `client-request` 信封（与 `session.list` 相同协议，见 `src/main.swift` 653-707 行）：

```
POST http://127.0.0.1:<port>/api/session.create
{ "type":"client-request", "rpcId":"…", "method":"session.create",
  "payload":{ "cwd":"<repoRoot>" } }
→ { "result":{ "ok":true, "value":{ "sessionId":"…" } } }

POST http://127.0.0.1:<port>/api/session.prompt
{ "type":"client-request", "rpcId":"…", "method":"session.prompt",
  "payload":{ "sessionId":"…", "mode":"queue",
              "content":[ { "type":"text", "text":"<触发文案>" } ] } }
→ { "result":{ "ok":true, "value":{ … } } }
```

- `mode: "queue"`：不抢占用户当前对话、不阻塞 UI（对应 `sessionPromptRequestSchema` 的 `queue|steer`，见 `dsh-host-apiproxy/lib/types/api/sessions.schema.js`）；
- 触发文案（薄壳，中英随壳语言）：「请加载 `repo-knowledge` skill 并执行【初始生成 / 增量更新 / 重建 index】。仓库根：<repoRoot>。若 skill 不存在，按内置说明执行。」；
- 状态轮询：`session.list` 里该 `sessionId` 的 `running` 标志 → 面板「生成中…」；完成后由 WikiWatcher 刷新；
- 该生成会话在 dsh web 左侧会话列表可见、可点击查看全过程、可中途取消——**透明度保证**。

---

## 4. 数据模型

### 4.1 wiki 根目录与存放位置

```
默认（随仓库，可版本化/共享，与 AGENTS.md 同类）:
  <repoRoot>/.dsh/wiki/
可配置（仓库外，私有）:
  $DSH_HOME/repo-wiki/<sha256(repoRoot 规范化路径)前 12 位>/
```

- 默认「随仓库」：方便 git 提交、团队共享、CI 复用；缺点是有可能被误提交进发布物（`.gitignore` 由用户自行决定，壳层**不修改**用户 `.gitignore`）；
- 迁移：设置项 `wikiRootMode = in-repo | dsh-home`，切换时面板跟随；
- 仓库根判定：复用 `DSHSessionRPC.resolveProjectDirectory`（活动会话 cwd），向上找 `.git` 最近祖先；无 `.git` 用 cwd。

### 4.2 目录结构规范

```
.dsh/wiki/
├── index.md                总索引：仓库一句话简介 + 分节页链接 + 统计 + 最后生成时间
├── overview.md             仓库概览（技术栈、目录布局、构建/运行方式、测试方式）
├── architecture.md         架构（分层、模块依赖、关键数据流、部署形态）
├── modules/
│   ├── auth.md             模块页（每个主要模块/包一页）
│   └── payments.md
├── data-model.md           核心数据模型/表结构/领域概念
├── conventions.md          工程约定（命名、提交规范、代码风格、工具链）
├── tasks.md                常见任务手册（「如何加一个接口/跑一次发布/排查 X」）
└── _meta/
    ├── backlinks.json      页面反向链接索引（壳层维护）
    └── lock                生成锁（见 9.4）
```

- 页面数量上限：初始生成 ≤ 20 页（超过时按重要性合并/折叠，见 5.2）；
- 单页上限：≤ 200 行 / 20 KB（超出截断并在页尾标注「已截断」）；
- wiki 总量上限：≤ 2 MB。

### 4.3 页面 frontmatter（YAML）

```yaml
---
title: 认证模块
tags: [auth, security]
updated: 2026-08-15T10:00:00Z      # 代理最近一次触碰该页的时间
sources:                            # 依据的源码/文件（供陈旧检测）
  - src/auth/                       # 目录或文件相对路径
  - package.json
manual: false                       # true = 用户手改，代理永不覆盖（见 9.5）
---
```

### 4.4 陈旧检测（壳层 + 代理双层）

- **壳层（展示层）**：面板对每个页面，比较 `updated` 与该页 `sources` 指向路径的最新 mtime——源码更新而页面未更新 → 树节点与页头显示「可能过期」徽标；
- **代理（生成层）**：增量更新时，代理按 `git status` + mtime 扫描变更文件，只重生成 `sources` 命中变更的页面；页面 `manual: true` 时跳过。

### 4.5 搜索（v1）

- 标题过滤：树上方搜索框，按页面 title/文件名子串过滤（即时、零成本、始终可用）；
- v2（可选演进）：页面正文扫描（wiki 总量 ≤ 2 MB，简单子串扫描足够）；并可叠加 `session.search` 把历史会话知识带进 wiki 面板的「相关会话」区；QMD 语义检索**暂不整合**，仅保留为候选（见第 13 节）。

---

## 5. 生成工作流

### 5.1 `repo-knowledge` skill（单一事实来源）

安装位置（按 dsh skill 发现顺序，见 `dsh-skill-filesystem` README）：

- 全局（**推荐，App 启动时安装到 `$DSH_HOME/skills/`**）：`$DSH_HOME/skills/repo-knowledge/SKILL.md`（跨仓库生效）；
- 项目级：`<repoRoot>/.dsh/skills/repo-knowledge/SKILL.md`（仓库自带副本，可覆盖全局）；
- 壳层内嵌一份同内容副本作回退（见 3.2）。

`SKILL.md` 内容要点（frontmatter + 正文，正文即代理指令）：

```
---
name: repo-knowledge
description: 为当前仓库生成/增量维护 .dsh/wiki/ 知识库（初始生成、增量更新、重建 index）
user-invocable: false
---
（正文：生成流程、页面规范、frontmatter 规则、脱敏规则、覆盖规则、字数/页数上限）
```

### 5.2 初始生成流程（代理视角）

1. **侦察**：读根 README、包清单/依赖文件、目录结构（`find`/fs 工具）、`.gitignore`、CI 配置；用 `git status`/`git log` 了解活跃度；
2. **规划**：按 4.2 规范列出页面清单（≤ 20 页），重要模块单独成页，次要模块并入 overview；
3. **收集**：对每个页面，读对应源码/文档（可用 `dsh-tool-subagent` 并行、`dsh-tool-workflow` 编排；超大纲领性内容可直接读）；
4. **写作**：每页按 frontmatter 规范写入；**只写事实**（可从代码/README 证实的），不确定处标注「待确认」，不得编造；
5. **脱敏**：跳过 `.env*`、密钥、口令、个人数据；示例一律用占位符（见 9.6）；
6. **收尾**：写 `index.md`、更新统计；不触碰 `_meta/backlinks.json`（壳层维护）。

### 5.3 触发方式（按保守程度递增，均可在设置关闭）

| 触发 | 默认 | 说明 |
|---|---|---|
| 手动按钮（面板右上 / 菜单） | 开 | 「生成」「更新」「重建 index」三态 |
| 首次打开面板且无 wiki | 开 | 提示「仓库尚无 wiki，是否生成？」（不自动跑，避免惊吓） |
| 会话结束自动更新 | 关 | 需监听会话结束事件（v2，见里程碑） |
| 文件变更后自动更新 | 关 | 变更量 ≥ 阈值（如 30 个文件/24h）且距上次更新 > 1h 才触发（防抖动） |

### 5.4 增量更新

- 代理重读 `index.md` 与各页 `sources`，用 `git status --short` + mtime 对比定位变更面；
- 只重写受影响页面，`updated` 刷新；未变页面保持原样（**字节不变**，便于 git diff 审查）；
- `manual: true` 页面永不改写（见 9.5）；
- 页面删除：源码删除后，页面标记「已失效」而不是直接删除（人审后再删），`_meta` 记录失效列表。

### 5.5 幂等与锁

- 同一 wiki 同时只允许一个生成会话（`_meta/lock` 记录 sessionId + 时间；壳层在 running 时禁用触发按钮）；
- 代理在生成失败/中断时可重入：先读 lock，超时（如 30 分钟无心跳）视为孤儿，可接管。

---

## 6. 上下文注入

### 6.1 原则

- **按需读取为主**：代理需要架构/约定信息时，读 `index.md` 再按链接打开对应页（token 可控，不污染每轮请求）；
- **不强注入**：默认不把 wiki 全文塞进每轮上下文（与 `dsh-agent-instructions` 的「更具体指令优先、不覆盖系统/开发者指令」语义一致）。

### 6.2 注册块（默认关闭，显式开关）

- 开启「注册到 AGENTS.md」后，生成流程在项目根 `AGENTS.md`（或 `CLAUDE.md`，按 dsh-agent-instructions 的候选名）末尾幂等追加：

```md
<!-- repo-wiki:managed -->
本仓库维护有知识库 `.dsh/wiki/index.md`。涉及架构、模块、约定、常见任务时，先读取 index.md 并按需打开相关页面；不确定时再深入源码。以源码为准，wiki 仅作指引。
<!-- /repo-wiki:managed -->
```

- 幂等：已存在该标记块则不重复追加；关闭开关或一键「移除注册块」时整块删除；
- 前提：项目根目录的 `AGENTS.md`/`CLAUDE.md` 会被 `dsh-agent-instructions` 自动加载（已核实该机制），因此注册后**每个新会话自动可见**。

### 6.3 自动注入 index 摘要（可选，默认关闭）

- 设置项「会话开头注入 wiki 摘要」开启后，壳层在用户**新建**会话时不做任何注入（壳层无法改代理上下文）——正确做法是**在生成流程里把摘要写进注册块**（如注册块内附 index 的一句话摘要），随指令文件自动进入会话。v1 不实现独立注入通道。

### 6.4 代理侧可达性

- 代理随时可读 `.dsh/wiki/**`（普通 fs 工具即可）；skill 注册后代理也能通过 `dsh-tool-skill` 发现并加载 `repo-knowledge` 维护流程——「读」与「维护」两条路径都无需改源码；
- **QMD 整合暂不实施**（见第 13 节）：v1 代理的「按需读取」= 读 index.md 跟链接 + `session.search`（FTS5）；若后续启用，代理可经 `mcp__qmd__structured_search` / `mcp__qmd__get` 对 wiki 做语义检索。

---

## 7. UI 设计（WikiPanel）

### 7.1 入口与面板容器

- 活动栏新增第三个图标（SF Symbol `book.closed`，文案「Wiki」），与预览/终端互斥：`RightPanel` 增加 `.wiki` 分支（`src/main.swift` 732 行枚举扩展），切换逻辑/宽度记忆/加宽窗口/`rightPanelKind` 持久化全部沿用既有 `setRightPanel` 机制；
- 菜单「视图」→「显示/隐藏 Wiki 面板」`⌥⌘W`（选中态跟随）；QA 钩子 `DSH_WIKI_TEST=1` 启动即开面板；
- 面板根容器镜像 `PreviewPanelController` 结构：40pt 头部 + 内容区，复用 `DynamicFillView`/`HoverButton`/`PanelIconButton`。

### 7.2 布局

```
┌─ 头部 40pt: [Wiki] 状态徽标(生成中/过期/错误) …… [在 Finder 显示] [在默认应用打开] [生成▾] [✕]
├─ 工具行: 搜索框（标题过滤）  已过期: n  页面: m  最后生成: …
├─ NSSplitView
│  ├─ 左: 页面树（index/overview/architecture/modules/… 分组展示，过期徽标，双击打开）
│  └─ 右: 内容区（渲染后的页面 + 页脚 backlinks 区）
└─ 状态条: 生成进度（sessionId / 阶段 / 取消按钮）
```

- 树复用 `TreeNode` 懒加载模式（`PreviewPanel.swift` 18-33 行），根为 wiki 根目录；空态（无 wiki）显示「仓库尚无知识库」+「生成」按钮；
- 生成中：头部与状态条显示进行中（轮询 `session.list` 的 running 标志），按钮禁用；可「在浏览器中查看」跳转该生成会话。

### 7.3 Markdown 渲染（与预览面板的关键差异）

预览面板刻意把 markdown 当纯文本（软换行合并会让用户觉得「换行坏了」）——**wiki 面板必须真正渲染**，且渲染规则要规避该问题：

- v1 轻量 Swift 渲染器 `WikiMarkdownRenderer`（markdown → NSAttributedString，无外部依赖）：
  - 标题 `#`–`######`（分级字号/加粗）、粗体 `**`/斜体 `*`、行内代码 `` ` ``、围栏代码块 ```` ``` ````（等宽字体 + 背景块）、无序/有序列表、链接 `[t](u)`、引用 `>`、分隔线 `---`；
  - **软换行策略**：单换行按 `\n` 保留（与源码一致的可读性），空行才分段——与预览面板的「逐行保真」精神一致；
  - 表格、脚注、图片嵌入 → **v2**（v1 内联渲染为纯文本占位并提示）；
- 链接行为：wiki 内相对链接（`./modules/auth.md`）→ 面板内导航；外部链接 → 默认浏览器（沿用现有外部链接策略）；
- 页脚自动渲染「反向链接」区（读 `_meta/backlinks.json`）：哪些页面引用了本页，可点击跳转；
- 页面顶部渲染 frontmatter 摘要条（tags / updated / 过期徽标 / manual 标记）。

### 7.4 设置（壳层 UserDefaults，中英文案）

| 键 | 默认 | 含义 |
|---|---|---|
| `wikiEnabled` | true | 活动栏是否显示 Wiki 入口 |
| `wikiRootMode` | `in-repo` | `.dsh/wiki/` 或 `$DSH_HOME/repo-wiki/<hash>/` |
| `wikiAutoRegenerate` | false | 文件变更阈值触发自动更新（见 5.3） |
| `wikiAutoInjectIndex` | false | 生成流程是否在 AGENTS.md 注册块中附 index 摘要（见 6.3） |
| `wikiRegisterAgentsMd` | false | 是否向项目根 AGENTS.md 追加注册块（见 6.2） |

---

## 8. 代码改动落点

> 本次为设计稿，以下为**实现时**的改动清单（按子系统分组）。

| 文件 | 改动 |
|---|---|
| `src/main.swift`（新增 `WikiRPC` 或并入 `DSHSessionRPC`） | `createSession(cwd:)`、`promptSession(sessionId:text:mode:)`、`sessionRunning(id:)`（复用 653-707 行信封模式）；`RightPanel` 增加 `.wiki`；活动栏第三个按钮；`setRightPanel` 各调用点与 `rightPanelKind` 持久化扩展；「视图」菜单 `⌥⌘W`；`DSH_WIKI_TEST=1`；L10n 新增 `wiki.*` 键（中/英） |
| `src/WikiPanel.swift`（新增） | `WikiPanelController`（头部/工具行/树/内容/状态条）、`WikiMarkdownRenderer`、`WikiWatcher`（FSEvents 或 2s 轮询，参照预览树 watcher）、生成触发与轮询 |
| `src/PreviewPanel.swift` | 不改（行为不变）；`TreeNode`/`HoverButton`/`DynamicFillView` 等为**复用**而非迁移 |
| `build-app.sh` | 编译列表追加 `WikiPanel.swift`；版本号递增（如 1.7.0）；产物名同步 |
| `README.md` | 「目录」一节补充本文档；特性描述新增「Repo Wiki 面板」小节 |

**L10n 新键草案（中/英）**：`wiki.title`（知识库 / Wiki）、`wiki.generate`（生成 / Generate）、`wiki.update`（更新 / Update）、`wiki.rebuildIndex`（重建索引 / Rebuild Index）、`wiki.empty`（仓库尚无知识库 / No wiki yet）、`wiki.generating`（生成中… / Generating…）、`wiki.stale`（可能过期 / Possibly stale）、`wiki.staleCount`、`wiki.manual`（手动维护 / Manual）、`wiki.openSession`（在浏览器中查看 / View in Browser）、`wiki.viewInFinder`、`wiki.openInDefaultApp`、`wiki.searchPlaceholder`、`wiki.backlinks`（反向链接 / Backlinks）、`wiki.registerAgentsMd`（写入 AGENTS.md 注册块 / Register in AGENTS.md）等。

---

## 9. 边界情况与失败处理

| # | 场景 | 处理 |
|---|---|---|
| 9.1 | 仓库无 `.git` | 用 cwd 作根；`git status` 类命令不可用时退化为 mtime 扫描 |
| 9.2 | 超大仓库（> 5 万文件） | 初始生成侦察阶段只扫顶层 + 指定深度（≤ 3 层）；页数/字数上限收紧（见 4.2）；提示用户可手动指定重点目录 |
| 9.3 | 单仓多模块（monorepo） | 每个主要包/模块一页（`modules/<name>.md`），overview 描述包间依赖 |
| 9.4 | 重复生成 / 并发 | `_meta/lock` + 壳层禁用触发按钮；孤儿锁超时接管（见 5.5） |
| 9.5 | 用户手改页面 | `manual: true` 永不覆盖；用户改完若再生成，页头提示「手动维护，已跳过」 |
| 9.6 | 敏感信息 | 生成指令硬性脱敏：跳过 `.env*`/密钥/口令/个人数据，示例用占位符；`index.md` 标注「已按策略脱敏」 |
| 9.7 | 二进制/超大文件 | 只读文本类（按扩展名白名单）；其余仅记录路径与大小，不读内容 |
| 9.8 | 非 UTF-8 / 损坏编码 | 读取失败记入日志并在页面标注「源文件编码不可读」，不中断生成 |
| 9.9 | symlink 循环 | 遍历时记录已访问目录（realpath 去重） |
| 9.10 | `.dsh/wiki/` 被删 | 面板显示空态，可一键重新生成 |
| 9.11 | `session.prompt` 失败/超时 | 重试 1 次；仍失败 → 状态条「生成失败」+「重试」按钮；日志记录（`~/Library/Logs/oh-my-dsh/app.log`） |
| 9.12 | 服务未就绪 | 沿用 `serverReady(port:)` 门控，未就绪时按钮置灰并提示 |
| 9.13 | 生成会话被用户在 web UI 取消 | `session.list` running=false 且 wiki 未完成 → 面板「已取消」态，可重试 |
| 9.14 | 用户改了 `wikiRootMode` | 面板重新解析根目录并重建树；不迁移旧内容（提示手动处理） |

---

## 10. 测试与验收

### 10.1 自动化（本环境可做）

- **编译验证**：`swiftc -O -swift-version 5 -module-cache-path .build/module-cache -framework AppKit -framework WebKit -framework PDFKit -o /tmp/t src/main.swift src/PreviewPanel.swift src/TerminalPanel.swift src/WikiPanel.swift` 零错误（仅既有 WebKit Sendable 警告）；
- **渲染器单元测试**：仿 `tests/terminal-emulator` 无头模式，覆盖 `WikiMarkdownRenderer` 全部语法（标题/粗斜体/行内与围栏代码/列表/链接/引用/分隔线/软换行策略）与 frontmatter 解析、陈旧标记计算、backlinks 索引读写；
- **skill 产出验证**：在 fixture 仓库（含 README、多模块、`.env.example`、一个大目录）上以 headless 模式执行「初始生成」，断言：页面数 ≤ 20、frontmatter 合法、`sources` 指向真实路径、无密钥内容、`manual:true` 页面未被覆盖、增量更新后未变页面字节不变。

### 10.2 手动 QA 清单（用户运行 App 验收）

1. `DSH_WIKI_TEST=1` 启动直开 Wiki 面板，指向 fixture wiki 目录；
2. 空仓库：面板空态 → 点「生成」→ 右上角出现生成中状态 → 完成后树出现页面；
3. 浏览：页面渲染正确（标题/代码块/列表/链接）；wiki 内链接面板内跳转；外部链接走浏览器；backlinks 区可跳转；
4. 搜索：标题过滤即时生效；
5. 陈旧：改一个 `sources` 指向的源码文件 → 对应页出现「可能过期」徽标；
6. 手改保护：把某页 `manual: true` 后点「更新」→ 该页不被改写；
7. 互斥与持久化：Wiki/预览/终端三图标互斥切换；重启后恢复上次面板；宽度拖拽记忆；
8. 注册块：开启「写入 AGENTS.md 注册块」后生成 → 项目根 AGENTS.md 出现幂等标记块；关闭/移除后整块消失；
9. 失败路径：断开服务（或端口占用）时按钮置灰；`session.prompt` 失败 → 状态条错误 + 重试；
10. 中英文界面文案齐全；退出 App 无残留生成会话进程（生成会话在服务端，属 dsh 管理，退出时按既有服务清理逻辑处理）。

---

## 11. 里程碑

| 里程碑 | 内容 | 验收 |
|---|---|---|
| **M0** | 本文档评审通过 | 设计决策闭环、无开放问题 |
| **M1 查看器** | `WikiPanel.swift`：面板 + 树 + `WikiMarkdownRenderer` + 搜索 + backlinks + 陈旧徽标 + 空态；`RightPanel.wiki`、菜单、L10n、QA 钩子 | 能浏览**任意现有 markdown 目录**（fixture 即可），10.1 编译 + 渲染器单测通过 |
| **M2 生成链路** | `repo-knowledge` skill（SKILL.md 完整指令）+ 壳层 `WikiRPC`（create/prompt/轮询）+ 生成状态 UI + 脱敏/上限/锁 | headless 生成产出合规页面；面板一键生成端到端跑通；10.2 的 1-3、9、10 通过 |
| **M3 维护与设置** | 增量更新、`manual` 保护、AGENTS.md 注册块（开关）、自动触发（关闭默认）、`wikiRootMode`、陈旧提示增强 | 10.2 全部通过；`build-app.sh` 产出新版本（如 1.7.0） |

> 注：QMD 整合（第 13 节）**暂不排期**——v1 里程碑止于 M3；其 P1/P2/P3 候选方案保留在 13.2，待 13.4 触发条件满足后再另行立项。

---

## 12. 明确假设

1. 面板沿用右侧活动栏槽位，与预览/终端互斥；宽度记忆沿用既有机制；
2. 生成/更新**全部由 dsh 代理执行**（壳层不解析代码、不内置分析器），代理能力随 dsh 升级自动增强；
3. 不修改任何 DeepSeek Harness 源码；不修改用户已有 `AGENTS.md`/`CLAUDE.md`（注册块为显式开关且幂等）；
4. v1 壳层不做向量检索；搜索 = 标题过滤 + `session.search`（FTS5），正文子串扫描为 v2 备选；QMD 语义检索**暂不整合**（见 13）；
5. `session.create` / `session.prompt`（`mode: queue`）为已核实可用的 dsh web API；若后续版本接口变化，触发链路按新 schema 适配；
6. 默认 wiki 根为 `<repoRoot>/.dsh/wiki/`，可配置迁移到 `$DSH_HOME/repo-wiki/`；
7. 本文档只产出设计，M1-M3 按评审结果另行排期实施；
8. QMD（`@tobilu/qmd`）**暂不整合**（见第 13 节）：不捆绑、不接入，v1 检索以标题过滤 + `session.search` 为准；第 13 节仅记录候选方案与触发条件，供后续「检索能力增强」立项时参考。

---

## 13. 与 QMD 的整合分析（暂不整合，检索增强候选）

> 结论：QMD（Query Markdown Documents）负责「本地 markdown 集合的索引与检索」，Repo Wiki 负责「内容生成 + 面板浏览 + 上下文注入」——两者互补、无重叠、无冲突，QMD 不替代 `repo-knowledge` skill 的生成职责，技术上**可以整合**。**但当前决策：暂不整合**——本节仅保留分析结论与候选接入方案，作为后续「检索能力增强」的备用设计（何时启用见 13.4 触发条件）。v1 的检索能力以 4.5 的标题过滤 + `session.search`（FTS5）为准。

### 13.1 QMD 是什么（已核实事实）

- `@tobilu/qmd` 全局 npm CLI（**本机当前未安装**；`npm install -g @tobilu/qmd`）：为本地 markdown 目录（notes/docs/wikis/transcripts）建立索引并提供检索；
- 检索能力：`qmd search`（BM25 词法）、`qmd query`（结构化字段 `intent:`/`lex:`/`vec:`/`hyde:` 的混合检索——词法 + 向量语义 + 假设文档向量）、`qmd get`/`multi-get`（按 docid/路径取原文，带行号与区间切片）；
- 索引生命周期：`qmd collection add <dir> --name <n>` → `qmd update`（增量重索引）→ `qmd embed`（生成向量，**依赖本地模型/GPU**；官方用法明确：模型不可用时回退 BM25）；
- 自带 MCP server：`qmd mcp`（stdio）或 `qmd mcp --http`（默认 8181），暴露 `structured_search`、`get` 等工具；
- 本会话内已有 `qmd` skill 说明（检索工作流、结构化 query 写法、回退规则），可直接套用其用法约定。

### 13.2 三条整合路径（候选方案，未实施）

**P1 面板搜索后端（查看器侧，体验增强）**

- 把 wiki 根注册为 QMD collection（如 `--name <repo>-wiki`）；面板搜索框的「语义搜索」模式 → `qmd query --format json` → 命中页在树中定位并打开；
- 现有「标题过滤」保留为即时过滤层（始终可用、零成本）；QMD 负责概念级回忆（「我们怎么处理超时重试」这类非字面匹配的问题）；
- 依赖：壳层能调用 `qmd`（检测系统安装，或构建期可选装入内置运行时）；**每次生成/更新完成后壳层触发 `qmd update`** 同步索引；
- 成本：中（外部依赖 + 索引生命周期 + 模型/GPU 不确定性）；收益：搜索从字面匹配升级为语义匹配。

**P2 代理侧 MCP 检索工具（引擎侧，推荐，收益/成本比最高）**

- dsh 已内置 MCP 客户端 `dsh-mcp-client`：一个插件实例 = 一个 MCP server，工具注册为 `mcp__<server>__<tool>` 原生工具（已核实其 README 与配置方式，含 stdio/HTTP 两种 transport）；
- 接入方式：在**用户 patch 层** `$DSH_HOME/cordis.patch.yml`（已核实：dsh 配置叠加层之一，当前文件尚不存在，按需创建）追加一个 `mcp-qmd` 插件实例（`transport: stdio`、`command: qmd`、`args: ['mcp']`）——**纯配置，不改任何 dsh 源码**；
  - 幂等写入由壳层「设置 → 启用 QMD 整合」开关负责（追加/移除均可一键完成，与 6.2 注册块的开关模式一致）；生效需重启 dsh web——App 已具备服务拉起/重启能力，可在面板提示或自动重启；
- 效果：
  - **生成时**：代理可先语义检索 wiki 与既有文档，避免重复内容、衔接已有知识（与 `repo-knowledge` skill 协同）；
  - **日常**：代理获得 `mcp__qmd__structured_search`/`get`，「按需读取」从「读 index.md 跟链接逐页翻」升级为「概念级提问」——与 6.2 的 AGENTS.md 注册块**正交互补**（注册块告诉代理「先查 wiki」，QMD 给代理「怎么查得更准」）；
  - 同一 MCP server 可挂多个 collection：wiki、仓库 docs/、以及导出的 dsh 会话（P3）；
- 回退链：qmd 缺失/模型不可用 → 代理退化为读 index.md + `session.search`（FTS5）——**现有能力不受影响**。

**P3 会话知识沉淀（v2，真正解决「会话间失忆」）**

- 定期把 dsh 会话导出为 markdown（dsh 侧 `dsh-session-log-export` 能力）→ 汇入一个 QMD collection → 跨会话语义检索（与社区 [OpenWiki Brains](https://www.langchain.com/blog/introducing-openwiki-brains-general-purpose-wiki-memory-for-agents) 同款思路）；
- 与 4.5 的「相关会话」区联动：面板可展示「检索到相关历史会话」；
- 成本较高（导出调度 + 索引维护 + 隐私考虑），列为 v2。

### 13.3 可行性评估

| 维度 | 评估 |
|---|---|
| 功能互补性 | 高：QMD 只做检索（不生成），Repo Wiki 管生成/浏览/注入；无重叠、无冲突 |
| 改动面 | P1：壳层（调用 qmd）+ 构建；P2：纯用户配置 + 壳层一个开关；P3：需导出链路 |
| 「不改源码」原则 | 满足：MCP 注册走用户 patch 配置层（`$DSH_HOME/cordis.patch.yml`），非 dsh 源码 |
| 依赖风险 | qmd 为第三方 npm 包（本机未装）；向量检索依赖本地模型/GPU；均有 BM25 / 现有能力回退 |
| 索引一致性 | wiki 变更 → 壳层在生成完成/文件监听时触发 `qmd update`；多仓库 = 多 collection，按 wiki 根命名 |
| 生效时机 | P2 需重启 dsh web；壳层可提示或自动重启（App 已具备服务管理能力） |
| 安全/隐私 | QMD 索引与 embedding 均为本地；会话导出（P3）涉及对话内容，需用户显式开启 |

### 13.4 结论与决策（暂不整合）

- **技术结论**：可以整合。QMD 补上 Repo Wiki 缺失的「语义检索」一环，且走 dsh 原生 MCP 通道，符合「不改源码」的壳层原则；
- **当前决策：暂不整合**。理由：
  - v1 检索需求（4.5）用标题过滤 + `session.search`（FTS5）即可覆盖，语义检索属体验增强而非必需；
  - qmd 为第三方 npm 包且本机未安装，向量检索依赖本地模型/GPU，存在环境不确定性——不引入未验证的依赖进入 v1 主链路；
  - Repo Wiki 首期聚焦生成/浏览/注入主闭环（M1-M3），避免范围膨胀；
- **若后续启用（触发条件，满足其一即可启动候选设计）**：用户明确反馈需要「概念级提问」式语义检索；或 qmd 在目标环境验证稳定（安装、索引、embed 全链路跑通）；届时按 **P2 → P1 → P3** 顺序实施（见 13.2）；
- 启用时的改动点已预留：设置项 `wikiQmdEnabled`（UserDefaults）、`$DSH_HOME/cordis.patch.yml` 幂等写入（P2）、生成后 `qmd update` 同步（P1），**不影响本设计其余部分**。

---

## 14. 实施记录（2026-08，v1.7.0）

**M1–M3 已实现**（对应第 11 节里程碑，全部落地）：
- 新增 `src/WikiPanel.swift`：模型层（frontmatter/扫描/陈旧/backlinks）、`WikiMarkdownRenderer`（软换行保真）、`WikiRPC`（`session.create`/`session.prompt` queue/轮询）、`repo-knowledge` skill（内嵌 + App 启动时安装到全局 `$DSH_HOME/skills/repo-knowledge/SKILL.md`）、`WikiAgentsMD`（幂等注册块）、`WikiPanelController`（头部/搜索工具行/分组树/阅读区/状态条/2s 变更监听/自动更新）。
- `src/main.swift`：`RightPanel.wiki`、活动栏书图标、`⌥⌘W`、设置菜单 wiki 组（自动更新 / AGENTS.md 注册块 / 根目录单选）、`wiki.*` L10n（中/英）、`serverReady` 门控、`DSH_WIKI_TEST=1` / `DSH_WIKI_TEST_PATH` QA 钩子。
- `build-app.sh`：编译清单 + VERSION 1.7.0 / BUILD 45；`README.md` 特性说明；`tests/wiki-panel/`（39 项无头单测）。

**验证**：全量 `swiftc` 编译零错误（仅既有 WebKit Sendable 警告）；39/39 wiki 单测、终端模拟器 46 项回归全过；`./build-app.sh` 产出 `dist/oh-my-dsh.app`（1.7.0 build 45）。

**v1.7.0 修复：Wiki 面板顶部按钮被遮住（合成问题）** —— 与终端面板同源（见 `docs/terminal-header-fix.md`）：
- 根因：面板根视图 `DynamicFillView` 为 `isOpaque = true` 且无独立 layer，内容区 opaque 视图（工具行/滚动视图）的绘制被合成进根 layer，覆盖了同级 header 的按钮；
- 修复（结合 Preview/Terminal 两面板既有模式）：
  1. 根视图改为 `WikiRootView`（`isOpaque = false`，自绘灰色背景，镜像 `TerminalRootView`）；
  2. 工具行 `toolbar.wantsLayer = true` + `masksToBounds = true`（隔离其 opaque 填充）；
  3. 内容区 `contentContainer.wantsLayer = true` + `masksToBounds = true`（镜像终端修复）；
  4. 页面树 `treeScroll.drawsBackground = false`（镜像预览面板）；
- 经验沿用：layer-backed 窗口中 opaque 视图 + 无独立 layer = 合成陷阱；隔离绘制用父容器的 `wantsLayer`。

**v1.7.0 修复 2：顶部区域与内容区之间补分割线、顶部背景色与其他面板统一（build 45 → 46）**
- 问题：工具行与内容区之间没有分割线；工具行背景用了 `.control`（深色 0.20），比 header 的 `.window`（0.28）深，顶部区域整体显得比预览/终端面板深；
- 修复：工具行 `toolbar.kind` 改为 `.window`（与 header 同色，顶部连成一条与其他面板一致的灰色带）；在工具行与内容区之间新增 `NSBox` 分隔线（`toolbarUnderline`，镜像预览/终端面板 tab 栏下划线），`contentSplit.top` 改为约束到分隔线下沿。

**v1.7.0 修复 3：生成体验优化（build 46 → 48）**
- 问题：点「生成」后内容区只剩空态 + 底部一条状态，长耗时生成期间整个面板显得「灰着卡住」，等很久才出内容；
- 优化（build 47 初版 → 48 简化版）：
  1. **保留原有布局**：header / 工具行 / 页面树 / 状态条全部保持可见，生成期间左侧树实时出现代理写出的页面（`refreshIfChanged` 生成中分支只刷树与统计，不打断内容区）；
  2. 内容区仅**居中显示「Generating…」**（新增 `WikiCenteredLabel`，Core Graphics 文本绘制——与 HeaderLabel 同款可靠渲染路径；build 47 的 spinner/提示/按钮版在 layer-backed 窗口未渲染出，已按用户要求简化为纯文本）；
  3. 底部状态条每秒刷新已耗时（`wiki.generatingElapsed`）；完成后自动打开 index.md；失败/取消后 `refresh()` 恢复内容区。

**v1.7.0 修复 4：生成会话归入当前工作区（build 48 → 49）**
- 问题：生成会话用 `session.create {cwd}` 创建，dsh web 里落在「未分组」——前端建会话的标准做法是传 `workspaceId`（已核实 `dsh-client-runtime` 的 `connectWorkspace`），由服务端从 workspace path 推导 cwd；
- 修复（`WikiRPC`）：
  1. `resolveWorkspaceId(port:cwd:)`：`workspace.list` 按规范化路径（`canonical`，standardized + 解 symlink）匹配当前仓库的工作区；
  2. `createSession(port:cwd:workspaceId:)`：有匹配工作区则传 `workspaceId`，否则回退 `cwd`——**新生成会话直接挂到工作区下**；
  3. `attachOrphans(port:cwd:workspaceId:)`：把该仓库**已存在的未分组会话**（cwd 匹配、非 blank、未被任何工作区认领）经 `workspace.insertSessionBefore` 归入工作区；面板加载/生成完成时调用（幂等，30s 节流防刷）。

**v1.7.0 修复 5：自动更新的询问机制（build 49 → 50）**
- **首次生成后弹窗询问**：初始生成成功且用户从未在「设置」里显式选过自动更新时，弹窗「开启自动更新知识库？」（开启 / 暂不）；选择后同步设置菜单勾选状态（`onAutoUpdateSettingChanged` → 重建菜单）；
- **业务会话期间也可触发**：
  - `serverReady` 时即使面板未打开也后台解析仓库根 → 2s 监控常驻；
  - 检测到「需要更新」（≥3 页过期且 index >1h）时：设置**开** → 静默自动增量更新（每小时至多一次）；设置**关** → 弹窗询问「检测到 %d 个页面可能过期，是否现在增量更新？」（更新 / 稍后），同样每小时至多一次防骚扰。

**v1.7.0 修复 6：项目目录跟随 dsh web 当前会话/工作区（build 50 → 51）**
- 问题：多工作区（指向不同目录）时，壳层只在面板打开时查一次 `session.list` 挑「最相关」会话，切换工作区/会话后预览树、终端初始目录、wiki 目录不会跟随；
- 机制：
  1. **注入 `sessionTrackerScript`**：复用预览拦截器的 `window.fetch` 挂钩路径（`callUnary → postJson("/api/${method}")`），监听 `session.history` / `session.prompt` / `session.rename` / `session.selectModel` 请求中的 `payload.sessionId`，id 变化时经 `dshSession` message handler 通知壳层（DOM 无会话 id 属性，走 RPC 信号最可靠）；
  2. **共享 `ProjectDirectory`**：壳层按收到的 sessionId 查 `session.list` 得 cwd 并更新共享目录；`DSHSessionRPC.resolveProjectDirectory` 优先返回共享目录（存在时），否则回退实时查询并缓存——预览树 / 终端新会话 cwd / wiki 根解析统一走它；
  3. **联动**：切换时 `previewPanel.setProjectDirectory`（只重设树根，不动已开页签）、`wikiPanel.reloadRoot()`（重解析 + 重扫）；终端新标签页启动目录自动取新目录（已开终端不受影响）。

**v1.7.0 修复 7：会话跟踪信号补强（build 51 → 53）**
- 问题：build 51 的 `session.history` 信号在「重开已加载会话」时因客户端 `session.open()` 幂等而不发，来回切换第二次即失效；
- 修复：核实 `followCurrent`（每次切换必走）→ `refreshSubagents(current)` → **`subagent.list {parentSessionId}`**（注意 wire 方法名是**单数** `subagent.list`，build 52 曾误写成 `subagents.list` 导致匹配失败）——作为每次切换的可靠信号，兼容 `payload.parentSessionId`；history/prompt/rename/selectModel 保留为补充信号；
- 诊断：`DSH_SESSION_DEBUG=1` 启动可在日志中 dump `window.__dshSessionSeen`（观察到的 session.*/subagent.list 请求序列）与跟踪器状态，便于后续排查。

**v1.7.0 修复 8：目录树初始宽度统一 160（build 53 → 54）**
- 问题：Wiki 面板内容区（树 | 阅读）未设置初始分隔条位置，`NSSplitView` 默认**等分**（树占面板一半）；预览面板默认 150 / 最小 100，与用户预期不符；
- 修复：两面板统一——树默认宽度 **160pt**、拖动最小值 **160pt**（预览面板 `applyInitialTreeWidthIfNeeded` 150→160、`constrainMin` 100→160；Wiki 面板新增 `applyInitialTreeWidthIfNeeded`（160，首次布局后应用，`scanAndReload` 触发）+ `constrainMin` 90→160）。

**v1.7.0 修复 9：markdown 渲染换行（build 54 → 55）**
- 问题：段落内多个源行用 `\n` 连接——`\n` 在 NSTextView 中是**段落边界**，每行都触发 `paragraphSpacing`，看起来一行一段、间距破碎；列表项之间漏了换行符，会挤在同一行；
- 修复：段落/引用内软换行改用 Unicode **`U+2028` 行分隔符**（紧排换行、不产生段落间距，保持「软换行保真」设计）；列表每项后补 `\n`；单测新增「软换行非段落边界」「列表项分行」断言（39 → 41 项）。

**v1.7.0 修复 10：生成中提示的渲染方式（build 56 → 57）**
- 问题：生成中视图用 `WikiCenteredLabel`（Core Graphics 自绘文本）在内容区**渲染不出来**——阅读区一片灰，只剩底部状态条显示 "Generating…"，观感像「整个面板内容被隐藏」；
- 修复：改为**空态已验证的渲染模式**（`NSTextField` 单标签放入居中 `NSStackView`，与 `showEmptyState` 完全同构）；布局保持不动（header/工具行/树/状态条全在），仅内容区居中显示 "Generating…"；删除不再使用的 `WikiCenteredLabel`。

**v1.7.0 修复 11：生成中提示改为叠加浮层（build 57 → 58）**
- 问题：历次实现（spinner 栈 / Core Graphics 自绘 / NSTextField 栈）都是**清空阅读区再显示提示**——一旦提示本身渲染失败，阅读区就整片空白，观感是「整个面板布局消失」；且安装包（build 55）用的仍是旧渲染方式，用户安装后测试到的是旧行为；
- 修复：`showGenerating` **不再清空任何内容**，改为在阅读区之上**叠加半透明浮层**（`WikiOverlayView`，随明暗的 0.82 透明度背景，非 opaque，背景绘制失败时自动退化为透明）+ 居中的 `NSTextField`「Generating…」（空态同款已验证渲染）。生成期间：页面与树全程可见，布局永不消失；完成/失败后 `scanAndReload` 清空子视图时浮层自动移除。诊断提醒：请以「关于」面板的 build 号为准（≥58 才含此修复）。

**v1.7.0 修复 12：真正根因——底部状态条的合成溢出（build 58 → 59）**
- 问题：历次「生成时整个面板内容消失、只剩底部 Generating…」——换提示实现均无效。对照 `docs/terminal-header-fix.md` 定位到真正元凶：**底部状态条 `statusBar` 是 opaque 的 `DynamicFillView` 且无独立 layer**，平时 `isHidden=true` 不绘制；一旦 `setStatus` 把它显示出来，其填充被合成进面板根 layer，**盖掉同级的 header/工具行/树/阅读区**（z 序最后添加、合成顺序最上），观感即「整个 Panel 内容都没了」；
- 修复：`statusBar.wantsLayer = true` + `layer?.masksToBounds = true`（终端修复同款：给 opaque 视图自身做 layer 隔离）；`showGenerating` 浮层本就非 opaque 且在已隔离的 `contentContainer` 内，不受影响。经验更新：**任何「平时隐藏、生成时显示」的 opaque 无 layer 视图都可能触发同类合成溢出**。

**v1.7.0 修复 13：生成状态按工作区目录关联（build 59 → 60）**
- 问题：生成状态原是面板全局布尔——切换工作区后，旧仓库生成仍在跑，遮罩被新内容顶掉，但「+」按钮仍禁用、底部状态条仍显示旧仓库的 "Generating…"，状态与当前工作区脱节；
- 修复（`generations: [canonicalRepo: Generation]`，可多仓库并发各一个生成）：
  1. **UI 只反映当前仓库**：`syncGenerationUI()`（每次扫描/切换/生成事件都调用）——当前仓库在生成 → 显示遮罩 + "Generating… Ns" + 禁用「+」；当前仓库不在生成但别处在生成 → 无遮罩、状态条显示「正在为「仓库名」生成知识库…」、「+」**可用**（可为当前仓库另起生成）；全部结束 → 隐藏状态条；
  2. 单个共享轮询定时器遍历所有在途生成，各自结算（AGENTS.md 注册、首次生成询问、失败提示仅作用于被结算且当前可见的仓库）；
  3. 切回生成中的仓库时，遮罩与状态自动恢复（`scanAndReload` → `syncGenerationUI`）。

**v1.7.0 修复 14：终端新会话目录跟随当前工作区（build 60 → 61）**
- 问题：终端 `newSession()` 用 `fetchActiveSessionCwd`（running/最近更新启发式）而非共享的 `ProjectDirectory.current`——切换工作区后，新终端仍按启发式落到旧目录；
- 修复：`newSession()` / `spawnWithCwd()` 改用 `DSHSessionRPC.resolveProjectDirectory`（优先 `ProjectDirectory.current`=当前查看的工作区，未设置时回退实时查询并缓存；home 兜底保留，completion 在主线程）。

**v1.7.0 修复 15：移除失效的「未分组会话归附」（build 61 → 62）**
- 问题：build 49 加的 `attachOrphans`（把已存在的未分组会话经 `workspace.insertSessionBefore` 挂入工作区）**无法工作**——已核实 RPC 层无 attach 接口，`insertSessionBefore` 只允许移动**已入账**会话（`workspace-move-invalid: not accounted`），对未分组会话必然失败（静默返回 0）；
- 修复：删除 `WikiRPC.attachOrphans` / `maybeAttachOrphans`（含 30s 节流与 `scanAndReload` 调用）；**保留唯一正确路径：创建会话时解析 `workspaceId` 传入 `session.create`**（build 49 起即生效，新会话直接归入工作区）。已存在的未分组会话无法经 API 移动（dsh 限制），UI 的 Ungrouped 仅为浏览器本地聚合。

**v1.7.0 修复 16：repo-wiki SKILL.md 优化（build 62 → 63）**
- 背景：会话内直接要求更新时，SKILL 没有约束「在当前会话执行」，且 `sources` 质量无要求（影响陈旧检测/增量准确性）；
- 新增/强化规则：
  1. **执行方式（强制）**：在当前会话内直接执行，**绝不新建顶层会话**（不得 session.create/fork、不得建议另开会话；可 subagent 并行）——杜绝「会话内更新产生未分组会话」；
  2. 仓库根 = 当前会话 `pwd`；wiki 输出 `<repoRoot>/.dsh/wiki/`；按 index.md 是否存在选择增量/初始；
  3. **sources 质量**：列全依据文件/目录（目录覆盖子树），决定陈旧检测与增量准确性；
  4. 增量更新先读 index.md；`git status --short` + mtime；未变页面字节不变；git 缺失退 mtime；
  5. 不删除页面（源码删除 → 标「已失效」）；完成更新 index 统计；汇报 ≤ 几行不贴正文。
- 已同步：壳层内嵌副本（`WikiSkill.skillMarkdown`）+ 本仓库 `.dsh/skills/repo-wiki/SKILL.md`（字节一致）。

**已知取舍**：`_meta/lock` 文件锁未实现（以面板内 `generating` 标志防重入，单窗口足够）；QMD 整合按第 13 节保持「暂不整合」；手动 QA（设计 10.2）待用户验收。

---

## 附：相关资源
- dsh 包（`@deepseek-ai/dsh@0.1.1-rc.2` 依赖树内）：`dsh-agent-instructions`（AGENTS.md 加载）、`dsh-skill` / `dsh-skill-filesystem`（skill 注册与 5 级根）、`dsh-host-apiproxy`（`sessions.schema.js`：session.create/prompt/list 请求/响应 schema）、`dsh-session-query-sqlite`（FTS5 会话检索）、`dsh-workspace`、`dsh-settings-file`
- 壳层：`src/main.swift`（`RightPanel` 732 行、`DSHSessionRPC` 653-707 行）、`src/PreviewPanel.swift`（`TreeNode` 18-33 行、树 952-1030 行、markdown 纯文本说明 1266-1272 行）、`src/TerminalPanel.swift`（`serverReady` 门控）、`build-app.sh`（编译清单约 196 行）
- 行业参考：[Cursor @Docs](https://cursor.com/help/customization/context.md) / [Cursor Docs 中文](https://cursor.zone/docs/context/docs.html)、[Roo/Claude Memory Bank](https://killer-skills.com/fr/skills/Wellux/claude-code-deprecated/memory-bank)、[skill-memory-bank](https://www.awesomeskills.dev/zh-CN/skill/fockus-skill-memory-bank)、[LangChain OpenWiki Brains](https://www.langchain.com/blog/introducing-openwiki-brains-general-purpose-wiki-memory-for-agents)、[codealmanac](https://www.npmjs.com/package/codealmanac)、[codebase-memory](https://www.npmjs.com/package/codebase-memory)、[memwiki](https://www.npmjs.com/package/memwiki)、[跨工具上下文讨论](https://forum.cursor.com/t/how-are-people-handling-context-across-different-ai-coding-tools/159891/5)
- QMD：[@tobilu/qmd（npm）](https://www.npmjs.com/package/@tobilu/qmd)、[Model Context Protocol](https://modelcontextprotocol.io/)、本机 skill `qmd`（`/Users/loie/.agents/skills/qmd`，含检索工作流与 `references/mcp-setup.md`）
