# 功能分析：工程脚手架（Scaffold Workbench）

> 文档性质：**功能分析（现状版）** —— 描述 oh-my-dsh「工程脚手架」面板当前已实现的功能能力。
> 来源基线：platforms/macos/src/ScaffoldPanel.swift（约 5.4k 行）+ scaffold-stages/ 内置环节库 + main.swift 集成点，均按分支 feature/scaffold-workbench 当前代码。
> 上游设计稿：docs/scaffold-workbench-design.md（M0 评审稿；本文件是它的「现状功能」视角姊妹篇，两者配合阅读）。
> 目标定位：**企业工程规范落地** —— 本功能首要价值是把企业级工程规范（git 提交/分支、文档、CI/CD、容器化、部署、Agent 协作指令）沉淀为**可勾选、可复用、确定性落盘的文件**，而不是随项目临时复制粘贴。
> 撰写：2026-08（现状核对于分支 feature/scaffold-workbench）

---

## 0. 一文速览

「工程脚手架」是右侧活动栏的一个面板（图标 puzzlepiece.extension，中英文案「脚手架 / Scaffold」）。它把「为一个（通常全新的）项目搭建工程骨架」拆成一组**相互独立、可任意组合的「环节（stage）」**。每个环节 = 一份 stage.yaml 清单 + 一组文件模板；用户在面板里勾环节、填参数，壳层在**本地**（Swift 引擎，零 token、可复现）**确定性渲染**出目标目录下的规范文件（AGENTS.md / Makefile / .gitignore / Dockerfile / Jenkinsfile / 部署脚本 / 文档骨架等），可预览冲突、覆盖备份、执行 git init，并把新项目**幂等登记为 dsh web 工作区**。

当前实现比 M0 设计稿更进一步：除了「新建项目向导」，还支持 **「初始化当前目录」**、**「更新已有配置（重生成）」**，以及一个 **「当前项目/工作区」首页**（展示已由脚手架初始化的项目的环节与参数，可一键打开/显示）；环节与项目预设都升级为**一等可管理资源**（用户库覆盖/恢复/删除/排序/结构化编辑器）。「Agent 深化」（M3，设计稿 G4）**尚未实现**，属规划项。

---

## 1. 功能定位

### 1.1 一句话定位
> 面向**企业/团队工程规范沉淀**：把分散在旧仓库里复制粘贴的工程约定（git 规范、文档骨架、CI/CD、容器、部署、Agent 指令）做成**可勾选的环节库**，在 oh-my-dsh 壳层**本地确定性生成**为项目骨架文件——壳层负责规范落盘（确定、可复现），Agent 负责创造（未来深化）。

### 1.2 在 oh-my-dsh 产品族中的坐标
右侧活动栏是一组按工程任务拆分的工具面板，脚手架站在这条链路的**「从 0 起项目」入口**：

| 面板 | 服务时刻 | 分工 |
|---|---|---|
| **脚手架（本功能）** | 项目**尚未形成**：起骨架 / 规范落地 | 确定性壳层渲染 |
| Repo Wiki / 文件 / 终端 | 项目**已存在**：建知识库 / 看改文件 / 跑命令 | 壳层操作 + 代理生成 |
| issue-runner / 浏览器 / 通道 | 既有项目上：跑 issue / 调页面 / 接任务 | 壳层编排 |

与「Repo Wiki」是互补分工：Wiki 是「内容全代理」；脚手架是「**确定性壳层先落骨架，代理只做深化**」（深化为 M3 规划）。这让产物**可复现、规范稳定、可审计**——区别于「口头让 Agent 现场起项目」。

### 1.3 定位侧重（本文件口径）
产品内置的环节库**全部是企业工程规范类（category: foundation）**：agents-md / git-init / git-conventions / docs-standards / coding-conventions / docker / makefile / ci-cd / deploy / repo-knowledge。因此本功能当前的实际价值重心是**「企业工程规范的落地与复用」**，而非「生成某种语言业务代码」（示例栈 java-backend / vue3-frontend 尚未随内置库发布，M3 深化也未实现）。

---

## 2. 目标（以 M0 G1–G6 对照现状）

| 目标 | 内容 | 现状 |
|---|---|---|
| G1 环节库 | 内置相互独立、可任意组合的环节 | ✅ 内置 10 个 foundation 环节（随 scaffold-stages/ 分发）；M1.x 已支持**用户环节库**覆盖/新建 |
| G2 组合搭建 | 面板勾选+填参 → 本地确定性渲染骨架，含预览/冲突 | ✅ 向导式新建/初始化/重生成全链路已实现 |
| G3 协作就绪 | 骨架自带 AGENTS.md 等，Agent 进入即遵守 | ✅ agents-md 环节产出 AGENTS.md，随所选环节自洽 |
| G4 Agent 深化 | 生成后一键触发 dsh 代理补实现/测试/构建 | ⚠️ **规划（M3）**：代码中 serverReady 门控与 workspace RPC 已预留链路；深化按钮/会话尚未实现 |
| G5 可扩展 | 用户环节库 + 坏清单隔离 | ✅ M1.x 已落地（用户库搜索链优先 + 坏清单隔离 + 排序） |
| G6 一致 | 不改 dsh 源码、中英双语、与既有面板一致 | ✅ 已贯彻（L10n 双语、面板基件复用、右栏互斥切换/宽度记忆/持久化） |

> **相对 M0 的超前项**：M1.x 把「环节管理」与「项目预设管理」从设计稿里硬编码的 3 组快捷勾选升级为**可管理资源**（结构化编辑器、用户库覆盖/恢复/删除/排序），且向导读取预设目录（内置 + 用户自定义，可动态重建）。这使功能边界已宽于原 M0 的 G1/G5。

---

## 3. 功能全景（能力地图）

### 3.1 三条构建路径 + 一个工作区首页

面板结构为「向导式时间线 + 顶部工具栏」。头部工具栏提供三个入口（右下角齿轮进管理设置）：

| 入口 | 触发条件 | 语义 |
|---|---|---|
| **新项目** | 常显可用 | 进入**新建项目向导**：按「目标与位置 → 选择环节 → 参数配置 → 预览与生成」四步，在父目录下建 <projectSlug> 子目录并生成 |
| **初始化此目录** | 当前工作区为**空目录**时 | 把脚手架生成到**当前目录内**（不改名、不建子目录），从「选择环节」步开始 |
| **更新配置** | 当前目录含 .scaffold/state.json 时 | **重生成**：读回 state.json 的环节/参数载入向导，改选/改参后重新落盘（幂等） |

面板默认落在 **「当前项目 / 工作区」首页**：
- 解析 dsh **当前活动工作区路径**（activeWorkspacePath）；
- 若该目录带 .scaffold/state.json（曾被脚手架初始化）→ 展示「已由脚手架初始化 ✓」+ 生成文件数 + 每环节一张配置卡片（环节名 + 非空参数），并提供 **[打开目录] / [在 Finder 中显示]**；
- 若目录存在但未初始化 → 提示 + 视是否为空决定按钮态（空 → 「初始化此目录」可用；非空 → 引导用「新项目」）。
- 工作区切换（真正换了目录）→ 自动回到首页并清空向导；仅会话变化（同目录）→ 只刷新工具栏态。

### 3.2 新建向导四步

| 步骤 | 标题 | 内容与校验 |
|---|---|---|
| 1 | 目标与位置 | 项目名（必填）、项目简介一行（必填，标 * 红色；填入后带入 agents-md 的 techSummary）、父目录选择（NSOpenPanel，展示解析出的**目标根**）；顶部「按目的预设」预设卡片（读取内置+用户预设，可一键套用，套用后仍可改选）；必填项为空时下一步禁用、红框提示 |
| 2 | 选择环节 | 环节库分组列表（当前内置均在「工程基础 / Foundation」），每个环节一张**卡片**（勾选徽标 + 名称 + 描述），点击整卡切换；顶部显示「已选 N 个」；预设套用在此勾选对应环节并注入参数默认值 |
| 3 | 参数配置 | 按选中环节逐环节列出**参数表单**：控件类型随 stage.yaml 的 type 而定——string 文本框、select（选项少于 5 → radio 组，否则下拉）、bool 复选框、multiselect（多选纵向堆叠）；带校验器的**必填参数**标签标红，值为空红框高亮；未选环节时给占位引导 |
| 4 | 预览与生成 | 实时文件清单（N 文件）+ 冲突项标红并列出覆盖来源；校验/渲染错误行内列出（存在错误时生成禁用）；底部状态条：生成中… → 完成 / 生成失败：原因（含 git init 失败提示） |

每一步都通过**顶部时间线条目**（数字徽标 / ✓ 已完成 / ! 出错）可点击回退，底部 **[上一步] / [下一步]** 推进。

### 3.3 生成动作（runGenerate → ScaffoldApplier.apply）
- 后台队列执行（DispatchQueue.global userInitiated），避免卡 UI；状态条 spinner 指示；
- 落盘：先对冲突目标文件在 .scaffold-backup/ 做备份（受设置 scaffoldBackupConflicts 门控）再写；非空目标目录有确认弹窗（覆盖并继续）；
- 执行环节 commands（相对目标根，如 git init -b main；失败不阻断其余，状态条提示「未初始化 git」）；
- 写 .scaffold/state.json（项目名 / 目标根 / 环节含参数 / 生成文件清单）——重生成与工作区首页的依据；
- **best-effort 把新项目登记为 dsh web 工作区**（ScaffoldWorkspaceRPC.ensure：按 canonical path 匹配，已存在则复用；确实新建时顺带创建空 session），服务未就绪（serverReadyPort 为空）则静默跳过。

### 3.4 环节管理（设置）
齿轮进入设置，页签切换 **「环节管理」/「项目预设」**：
- **环节管理**：全量环节列表，类型徽标（内置 / 自定义·已修改 / 自定义·新建），操作：编辑 / 恢复（删用户拷贝回内置）/ 删除（仅自定义）/ 上移下移（排序持久化）；
- **环节编辑器**：多文件页签（stage.yaml + templates/ 下每个文件一个标签，CodeEditorView 行号/高亮/撤销，脏标记「文件名 + *」，新建模板）；stage.yaml 定义环节、templates/ 为 {{var}}/{{#if}} 模板；改内置保存即物化到用户库、可恢复；首次保存必须先把 stage.yaml 存了（确定 id）；
- 保存语义同文件面板：逐文件保存、保存后留在编辑器；footer 显示用户库路径。

### 3.5 项目预设管理（设置 · 项目预设页签）
- 列表：内置预设（backend/fullstack/foundation，来自 scaffold-presets/ 的 yaml）+ 用户覆盖，类型徽标，操作：编辑/恢复/删除/排序；
- **结构化编辑器**（非 YAML）：名称（中/英）+ 描述（中/英）+ 环节多选卡片（按勾选顺序入组）+ 每环节参数默认值（复用 StageEditor 控件，全类型 string/select/radio/bool/multi）；
- 用户库 $DSH_HOME/scaffold-presets/；内置首次保存即物化为自定义；
- 向导步骤 1 的预设卡片读取预设目录（内置 + 用户，按序排序、动态重建），缺失环节标注「（缺失环节 …）」。

### 3.6 与既有壳层 / dsh 的集成点（现状）
| 集成 | 实现 |
|---|---|
| 右栏面板系统 | RightPanel.scaffold，与其余面板互斥切换、宽度记忆、rightPanelKind 持久化恢复 |
| 活动栏/菜单 | 图标 puzzlepiece.extension（可经 scaffoldEnabled 在设置里隐藏）；「视图」菜单项 menu.toggleScaffold |
| dsh web 会话/工作区 | 生成后经 ScaffoldWorkspaceRPC（client-request 信封：workspace.list → workspace.create → session.create）幂等登记工作区 |
| 服务就绪门控 | serverReady(port:) 记录端口；M3 深化按钮预留 |
| 服务/工作区 Provider | serverPortProvider、workspacePath 闭包注入（复用 server.port、activeWorkspacePath） |

---

## 4. 引擎层（纯逻辑，可无头单测）

| 组件 | 职责 |
|---|---|
| MiniYAML | stage.yaml / preset.yaml 子集解析（map/list/scalar、行注释、内联 list、未闭合报错） |
| StageCatalogLoader | 搜索链加载：**用户库（$DSH_HOME/scaffold-stages，DSH_SCAFFOLD_USER_STAGES 可覆盖，同名覆盖内置）→ 内置（bundle Resources）→ DSH_SCAFFOLD_STAGES（追加不覆盖）**；坏清单隔离（逐环节报错不影响其余）；返回 builtinIDs、环节 isCustom 标记 |
| ScaffoldStageOrder / ScaffoldPresetOrder | 排序合并：用户 saved → 默认序 → 目录/库剩余；失效 id 过滤 |
| ScaffoldTemplateRenderer | {{var}} 替换、{{#if}}（含嵌套）、{{{{ }}}} 转义、文件名渲染、缺失变量报错、真值判定 |
| ScaffoldValidators | nonEmpty / slug / safePath / javaPackage；可选空参数放行（deploy.remoteHost 空=本机） |
| ScaffoldPlan | 默认值+用户参数合并；内置上下文（projectName/projectSlug/targetPath/year + 兜底 trunk/imageRepo/imageTag/jenkinsAgentLabel/techSummary）；派生标志 has<StageId>；select 选项标志 <key>.<opt>；跨环节引用兜底；文件冲突检测；渲染失败整环节跳过；参数自洽提示 |
| ScaffoldApplier | 落盘（备份 .scaffold-backup/ 再写、先删旧备份再复制）、环节命令执行、写 .scaffold/state.json；幂等重跑 |
| ScaffoldPreset + ScaffoldPresetYAML + PresetLibrary | 预设模型 / preset.yaml 序列化解析 / 用户预设库（加载覆盖/保存/删除/恢复/校验） |

**确定性原则**：壳层只做「确定性的文件落盘」，不解析业务代码、不做完整模板语言（{{var}}+{{#if}} 足够）；创造性部分（业务实现、深化）留给 Agent（M3 规划）。

---

## 5. 内置内容盘点（现状随包发布）

### 5.1 环节库（scaffold-stages/，当前 10 个，均 category: foundation）
| 环节 | 用途 | 关键产出 |
|---|---|---|
| git-init | 仓库初始化 | .gitignore、README 骨架、LICENSE（按参数）；命令 git init -b main |
| git-conventions | Git 提交/分支规范 | docs/conventions/git.md（Conventional Commits + 分支前缀）、.gitmessage、scripts/install-git-hooks.sh（enforce=true，纯 shell commit-msg 校验） |
| agents-md | Agent 协作入口 | AGENTS.md（结构/命令/规范引用/禁区/与 dsh 协作），随所选环节自洽 |
| docs-standards | 文档规范骨架 | docs/architecture.md、ADR 模板、conventions、ops runbook |
| coding-conventions | 开发规范落地 | .editorconfig、CONTRIBUTING.md（PR/DoD 清单） |
| makefile | 统一命令入口 | Makefile（dev/build/test/lint/clean，按参数展开） |
| ci-cd | CI/CD 模板 | GitHub Actions / GitLab CI / **Jenkinsfile**（lint→test→build + 参数门控发布 + 凭据占位不内联密钥） |
| docker | 容器化 | Dockerfile（多阶段）、.dockerignore、compose.yaml |
| deploy | 部署脚本 | deploy/deploy-docker.sh / deploy-k8s.sh / deploy-rancher.sh（本机/远程、--dry-run、失败回滚、无内联密钥） |
| repo-knowledge | 知识库准备 | .dsh/wiki/README.md 占位（引导用 repo-knowledge skill 生成） |

> 注：M0 设计稿 v1 拟含的示例栈环节（java-backend/vue3-frontend）与协作层 deepen-session（M3）**当前未随内置库发布**；react-frontend 明确暂缓。环节库可扩展，后续按需补入。

### 5.2 内置项目预设（scaffold-presets/ 数据文件，随 App 分发）
| id | 名称 | 环节组合 | 参数默认值 |
|---|---|---|---|
| backend | 纯后端 API | 全部 10 个 foundation | ci-cd: hasBackend=true、hasFrontend=false；docker: runtime=java |
| fullstack | 前后端兼备 | 全部 10 个 | ci-cd: 双 true；makefile: frontendInstall/frontendBuild |
| foundation | 文档+规范 | agents-md / git-init / git-conventions / docs-standards / coding-conventions / repo-knowledge | 无 |

预设 = **有序环节组合 + 每环节参数默认值**；套用仅勾选当前库仍存在的环节。

---

## 6. 数据模型与渲染约定

- **stage.yaml**：id / name{zh,en} / category / description{zh,en} / params[] / files[] / commands[]。files[] 条目支持条件产出 if: <key> / if: <key>=<value>（LICENSE 按 license、Jenkinsfile 按 platform、hook 脚本按 enforce、deploy 脚本按 deployDocker/K8s/Rancher）。
- **模板语法**：{{key}} 变量替换（参数 + 内置变量 projectName/projectSlug/targetPath/year + 派生 has* 标志）；{{#if key}}…{{/if}} 条件；{{{{ }}}} 转义字面量 {{（GitHub Actions ${{ }} 需转义）；文件名也参与渲染。渲染器不转义模板原文。
- **state.json**：写于 <目标根>/.scaffold/state.json，记录 projectName / targetRoot / stages[{id, params}] / files[]——「更新配置」重生成与工作区首页的数据源。
- **搜索链**（环节与预设相同语义）：用户库（覆盖同名）→ 内置（bundle Resources）→ DSH_SCAFFOLD_STAGES（追加不覆盖）。
- **目标目录**：新建 = <parentDir>/<projectSlug>（项目名中文 → ASCII slug，保底 project）；初始化当前目录 = 直接当前目录；非空目录仅确认 + 备份覆盖（不做增量合并，v2）。

---

## 7. 失败处理与边界（现状语义）

| 场景 | 现状处理 |
|---|---|
| 目标目录已存在且非空 | 确认弹窗「覆盖并继续」+ .scaffold-backup/ 备份（设置可关备份）；不做增量补环节（v2） |
| 项目名中文/非法字符 | slugify 转 ASCII；面板显示解析出的目标根 |
| 参数缺失/校验失败 | 必填空值红框 + 标签红 *；校验/渲染错误阻止生成；渲染失败整环节跳过并报「环节 X 渲染失败」 |
| git 不可用 / init 失败 | 不阻断；状态条提示「未初始化 git（命令失败：…）」 |
| 多环节写同一路径 | 预览冲突标红 + 列出来源（后写覆盖）；可调序/取消环节 |
| 用户环节清单损坏 | 加载隔离：列表报「环节 X 加载失败」，内置不受影响 |
| 目标无写权限 / 中断重跑 | 落盘前整体校验；幂等重跑，备份同名覆盖不堆积 |
| 环节库随 App 升级 | 内置整体随版本替换；state.json 记录版本兼容提示（设计上） |
| L10n 缺失键 | 回退英文（与既有面板同策略） |
| Jenkins/deploy 密钥 | 模板只引用 credentialsId/占位，**绝不内联密钥**；脚本 set -euo pipefail、默认交互确认 + --dry-run |

---

## 8. 非功能特性

- **确定性 & 零成本**：骨架由壳层 Swift 引擎本地渲染，无 token 消耗、可复现；
- **不改 dsh 源码**：一切经壳层面板 + dsh 既有 RPC/工作区能力；
- **L10n**：scaffold.* 全键中英双语（main.swift L10n 表）；
- **幂等与备份**：.scaffold/state.json + .scaffold-backup/；
- **可测性**：引擎层（MiniYAML/loader/renderer/validators/plan/applier/preset）不依赖面板与网络，tests/scaffold-panel/run.sh 无头跑（镜像 wiki-panel 范式）；
- **QA 钩子**：DSH_SCAFFOLD_TEST=1 启动直开面板、DSH_SCAFFOLD_TEST_DIR=<dir> 预填父目录并直达新建向导、DSH_SCAFFOLD_STAGES 追加环节目录、DSH_SCAFFOLD_USER_STAGES 覆盖用户库目录（均 env，测试/调试用）；
- **设置键（UserDefaults）**：scaffoldEnabled（活动栏显隐，默认 true）、scaffoldLastDir（记忆上次父目录）、scaffoldBackupConflicts（默认 true）、scaffoldStageOrder / scaffoldPresetOrder（排序）。

---

## 9. 现状边界与后续（诚实标注）

**本期明确不做 / 未实现**：
- **Agent 深化（G4 / M3）未实现**：无「深化」按钮、无 deepen-session 环节；仅预留 serverReady 门控与 workspace RPC 登记链路。文档口径：**规划项**。
- 示例栈环节 java-backend / vue3-frontend 未随内置库发布（内置库当前仅 foundation 10 个）。
- 不做「环节市场/社区分享」；不做跨环节自动联动（仅参数自洽提示）；不做完整模板语言（{{#each}} 为 v2）；不做云厂商专有部署模板（deploy 为云无关 manifests / 通用脚本）。
- 「对既有项目增量补环节」为 v2；非空目录仅确认 + 备份覆盖。

**（相对 M0 已实现但未在原始 §7 描述的）**：向导式四步时间线 UI、工作区首页、「初始化当前目录」「更新配置」重生成、环节/预设管理设置（详见 §3）。

---

## 10. 附录：相关文档与线索

- 设计稿（评审/技术细节）：docs/scaffold-workbench-design.md
- 代码：platforms/macos/src/ScaffoldPanel.swift、集成点 main.swift、内置环节 scaffold-stages/、单测 tests/scaffold-panel/
- 面板 UI/布局活文档：docs/appkit-ui-layout-guide.md（本功能所有 AppKit 布局需遵循）
- UI 交互文档：见 docs/scaffold-panel-ui.md（另行成文）
