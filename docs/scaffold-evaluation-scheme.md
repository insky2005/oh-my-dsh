
# 脚手架生成物评估方案（对生成的 项目结构 / 文件 进行多维度评估）

> 文档性质：**评估方法论 / 评审方案** —— 面向「设计环节内容」「设计预设场景」「评审脚手架生成的项目骨架」三件事，给出**分维度、可勾选、可打分、可自动断言**的评估框架。
> 定位口径：**企业工程规范落地**（配套：docs/scaffold-panel-analysis.md · scaffold-stages-presets-audit.md）。
> 撰写：2026-08（按分支 feature/scaffold-workbench 现状与 scaffold-stages/ 真实内容）。
> 适用对象：任意「环节组合 → 生成到临时目录」的产物树；也可用于单个环节的 stage.yaml+模板，以及预设的默认参数。

---

## 0. 目的与三种使用场景

评估解决一个问题：**「这套环节/预设生成出来的文件，到底好不好、能不能用、自洽不自洽？」** 而不是只看「文件生成了没有」。

| 场景 | 你在评估什么 | 用第几节 |
|---|---|---|
| 设计/改一个新环节 | 该环节的 stage.yaml + 模板质量 | §2、§4（设计时门禁） |
| 设计一个预设场景 | 一组环节 + 参数默认值拼出的整体是否自洽、贴合场景 | §2、§4、§6 |
| 验收一次生成 | 对某个具体组合的实际产物树做体检 | §5（评审工作流）+ §6（自动断言） |

原则：
- **生成物优先**：一切评估以「实际渲染到临时目录的产物树」为对象，而不是只看模板文本；能跑命令就真跑（bash -n、--dry-run、make -n），能断言就写断言。
- **先正确，再自洽，再有效，最后讲整洁**：正确性（能生成、语法对）是所有评估的地基，跨环节自洽是脚手架区别于「随手起项目」的核心价值，可运行性决定骨架是否「最小可用」。
- **可量化**：每维度给到「检查项 / 证据 / 通过标准」，可转成自动化断言（§6）。

---

## 1. 评估分层框架（总览）

把「一个生成骨架好不好」拆成 8 个维度，归为 4 层：

| 层 | 维度 | 一句话 |
|---|---|---|
| L1 地基 | D1 正确性 | 能按所选环节生成、无坏引用、产物格式语法有效 |
| L1 地基 | D2 完整性 | 每个选中环节都产出该产出的文件，无静默丢失 |
| L2 自洽 | D3 自洽性（跨环节一致性） | 骨架内部互相引用一致：AGENTS 对得上结构、makefile 对上 CI、端口/镜像/探活统一 |
| L2 自洽 | D4 协作就绪 | 生成物让 Agent「进来自洽」：AGENTS.md 完整、命令可执行、有禁区与 DoD |
| L3 有效 | D5 可运行性（最小可用） | 落盘后关键路径能跑：make 目标有效、脚本 dry-run 通、hook 拦截违规 |
| L3 有效 | D6 场景与语言匹配 | 环节/预设与目标语言、部署形态、仓库类型匹配，参数默认贴合 |
| L3 有效 | D7 企业规范落地度 | 规范真的落成**可执行/可检查**的文件（git hook、editorconfig、DoD、门禁 CI），而非空话 |
| L4 整洁 | D8 确定性/简洁/可维护 | 同参数可复现；无死文件/占位过度；备份与幂等；便于 Agent 深化与后续维护 |

> 建议的评估序：D1→D2→D3→D4 是必过门槛（不达标的组合不应发布为内置预设）；D5–D8 决定质量档位与取舍说明。

---

## 2. 维度定义、检查项与通过标准

### D1 正确性（Correctness）
评估对象：所有生成文件的路径与内容是否合法、模板变量是否都解析成功。
- 检查项：
  - C1 路径安全且合法：无 ../ 或绝对路径穿越；路径经 {{var}} 渲染后非空；目录层级合理。
  - C2 无「死引用 / 坏标志」：模板里每个 {{key}} / {{#if key}} 都有来源（参数、派生键、兜底）——尤其 hasXxx 派生态必须命中真实环节（反例见 A1）。
  - C3 产物格式有效：生成出的 YAML / 脚本 / Makefile / Dockerfile / K8s manifest 语法有效（可分别用 yaml 解析 / bash -n / make -n / kubectl --dry-run=client 验证）。
  - C4 渲染确定性：同参数多次渲染结果字节级一致。
- 通过标准：全部满足；任一坏引用即判失败（不得「静默丢段」，静默丢段＝D2 也失败）。

### D2 完整性（Coverage / Completeness）
评估对象：选中环节集合 → 应产出文件清单。
- 检查项：
  - C1 每个选中环节按 stage.yaml files[] 与条件 if: 产出全部应产文件（缺一即漏）。
  - C2 条件文件正确跟随参数：license=Apache 才出 LICENSE-Apache；platform=jenkins 才出 Jenkinsfile；enforce 才出 hook 脚本等。
  - C3 跨环节「反向完整」：AGENTS.md / docs/conventions.md / README 引用的文件确实存在且反向匹配（如 AGENTS 说目录有 CI/CD，就得真生成了 .github 或 Jenkinsfile —— 反例见 A1 连引用都没有）。
  - C4 无「静默丢段」：任何模板片段因坏标志而不渲染都应被当成缺陷暴露，而不是悄悄消失。
- 通过标准：产出树与「预期文件清单」全等（可用 manifest 比对）。防静默丢段应加自动化断言（§6）。

### D3 自洽性（跨环节一致性 Self-consistency）
脚手架的核心价值。评估对象：骨架内部互引是否正确、统一。
- 检查项（每条都是一处「两处写同一语义，必须同值」）：
  - C1 命令链一致：makefile 的 build/test/lint 与 ci-cd 派生命令（ciBuild/ciTest/ciLint/ciFrontend）、与 AGENTS/README 的「常用命令」同源。
  - C2 分支一致：git-conventions 的 trunk（main/master）贯穿 ci.yml 的 push 分支、docs/conventions/git.md、README。
  - C3 端口/探活一致：docker 与 deploy 的 exposePort/servicePort、healthzPath、compose 端口映射、k8s probes、deploy 脚本 HEALTHZ 全部同值。
  - C4 镜像标识一致：imageRepo/imageTag 贯穿 Dockerfile、compose.yaml、deploy 脚本与 .env.example、ci cd 占位——且能被 .env 覆盖（见 A3 缺陷示例）。
  - C5 AGENTS ↔ 结构双向：AGENTS.md 罗列的目录/命令/规范文件都存在且与所选环节一一对应（反向不夸大、正向不遗漏）。
  - C6 主语言一致：agents-md primaryLang、makefile lang、docker runtime、ci 命令对同一后端语言不互相矛盾。
- 通过标准：所有同语义字段两两相等；存在矛盾必须在本组合被标为不自洽（至少给 hint/error）。

### D4 协作就绪（Agent / Collaboration readiness）
评估对象：AGENTS.md 与配套（Makefile、DoD、边界文件）能否让 Agent「进来就懂规则、命令、边界」。
- 检查项：
  - C1 AGENTS.md 含「项目是什么 / 目录结构 / 常用命令 / 工程规范 / 禁区 / 与 dsh 协作」六段，且无空段。
  - C2 目录结构段与真实产物一致（含 CI/docs 等，见 A1）、命令段指向真实 make 目标。
  - C3 有可执行的命令入口（makefile dev/build/test 等真实存在、能跑 make -n）。
  - C4 有边界：禁区明确「不越未选环节」「密钥不入库」。
  - C5 有 DoD/完成定义（CONTRIBUTING 或 AGENTS 内），便于 Agent 自检。
- 通过标准：六段齐全且全部与产物对应；任一「对不上/空引用」即不通过。

### D5 可运行性（Minimal-runnable）
评估对象：落到临时目录后「最小关键路径」能否跑通。
- 检查项（能跑就跑）：
  - C1 shell 脚本 bash -n 语法通过；deploy 脚本 --dry-run 只打印不执行、无内联密钥。
  - C2 Makefile make -n / make build -n 语法通过、目标存在且不互相循环。
  - C3 Dockerfile 按 runtime 分支结构有效（若本机有 docker 可 build；否则静态核对基础镜像/入口/HEALTHCHECK 工具存在，见 A5）。
  - C4 CI 文件结构有效：Actions yaml 可解析、Jenkinsfile 声明式块闭合、GitLab 阶段合法。
  - C5 git hook：commit-msg 校验能拦一条违规、放行一条合法（enforce 时）。
  - C6 k8s：kubectl apply --dry-run=client 通过（若可用）；否则核对 labels/selector/containerName/set image 一致性（见审计中 deployment 与脚本匹配点）。
- 通过标准：本机可验证项全绿；不可验证项给「静态核对 + 待人工」标记而非默认通过。

### D6 场景与语言匹配（Scenario & language fit）
评估对象：预设/环节参数与目标「企业工作场景」是否贴合。
- 检查项：
  - C1 语言覆盖：所选后端语言的容器化、构建、CI 命令都被环节支持（见 A4：docker 缺 go/python 即不匹配）。
  - C2 部署形态匹配：web 服务才带 docker/deploy；库/SDK/CLI/数据管道不带或按需带。
  - C3 仓库类型匹配：新项目 vs 存量初始化 vs 开源库，应导向不同环节组合。
  - C4 默认值有效：预设注入的默认参数能让骨架直接可用（不产生空 imageRepo、错 runtime 等）。
  - C5 无「过度生成」：给轻量场景塞了 docker+deploy+k8s 属过度，需能说明理由。
- 通过标准：预设的场景说明与产出语义一致；支持的场景都能用现有环节覆盖，覆盖不到的要显式列为缺口。

### D7 企业规范落地度（Conventions landing）
评估对象：规范是否落成「可执行/可检查」的东西，而非文档空话。
- 检查项：
  - C1 Git：commit-msg hook（enforce）真能拦；docs/conventions/git.md 与仓库既定惯例一致。
  - C2 编辑器：.editorconfig 存在且根/子正确。
  - C3 贡献/完成定义：CONTRIBUTING + DoD 清单可勾。
  - C4 CI 门禁：lint→test→build 阶段存在、发布动作默认门控不触发。
  - C5 文档/ADR：docs 骨架 + ADR 模板存在，便于记架构决策。
  - C6 密钥纪律：所有模板只引用占位、绝不内联（可 grep 敏感字眼断言）。
- 通过标准：每一项都是「文件 + 可执行/可检查」而非纯声明；占位/TODO 要有注释指引。

### D8 确定性 / 简洁 / 可维护（Determinism & cleanliness）
评估对象：整体整洁度与可维护性。
- 检查项：
  - C1 幂等与复现：同参数多次生成字节一致；state.json 记录环节/参数可重跑/审计。
  - C2 无死文件/占位失控：占位(TODO/注释)集中且有指引，不散落噪音。
  - C3 无坏备份：冲突备份 .scaffold-backup/ 语义正确、不堆积。
  - C4 便于深化：生成物结构与 AGENTS/目录结构一致，Agent/开发者改动不破坏脚手架自洽。
  - C5 命名一致：projectName/projectSlug 贯穿 LICENSE、README、compose、deploy、k8s labels。
- 通过标准：确定性满足即基石达成；整洁度用主观+清单双评。

---

## 3. 打分模型（可选）

给每个维度 0–3 分，用「权重 + 门槛」合成结论：

| 维度 | 权重 | 3=优 | 2=达标 | 1=有缺 | 0=失败 |
|---|---|---|---|---|---|
| D1 正确性 | 20% | 全通过 | 全通过 | 1-2 处小问题 | 坏引用/路径问题 |
| D2 完整性 | 20% | 无遗漏 | 无遗漏 | 有遗漏但无害 | 静默丢段 |
| D3 自洽性 | 20% | 全同源 | 全同源 | 1-2 处不一致 | 命令/端口/镜像矛盾 |
| D4 协作就绪 | 15% | 六段全对 | 六段全对 | 个别空引用 | AGENTS 空/失真 |
| D5 可运行性 | 10% | 关键路径跑通 | 可验证项全绿 | 部分待验证 | 关键命令不可用 |
| D6 场景匹配 | 5% | 高度贴合 | 贴合 | 有错配 | 语言/形态不匹配 |
| D7 规范落地 | 5% | 全可执行 | 全可执行 | 部分纯声明 | 仅空文 |
| D8 整洁 | 5% | 干净 | 干净 | 占位偏多 | 混乱 |

规则：
- **门槛制**：D1/D2/D3/D4 任一 <2 分 → 组合不可发布为内置预设/内置环节，先修再谈。
- 总分 = 各维度分数 × 权重 求和；80 分以上可作推荐预设种子；60–80 需附取舍说明；<60 不建议对外默认推荐。

---

## 4. 设计时门禁（每做一件事前用）

### 4.1 设计一个「新环节」时 checklist
1. 确定性的字段：id（小写+连字符）、name/description 双语、category 语义正确。
2. 参数最小化：每个参数都被模板用到且类型/默认合理；必填参数带校验器（nonEmpty/slug/safePath/javaPackage）。
3. 文件清单自证：每个 files[] 项在渲染后确实产出；带 if: 条件的要列全参数分支（选其一时必有文件）。
4. 无死引用：本环节模板引用的每把键都来自「本环节参数 / 引擎派生 hasXxx / 兜底 / 他环节参数(需注释声明)」；hasXxx 必须与真实环节 id 对应（别再犯 A1）。
5. 可运行：能生成 shell/CI/k8s 等可执行物时做最小运行验证（bash -n / make -n / yaml 解析 / dry-run）。
6. 自洽对外：若被 AGENTS/README/runbook 引用，引用的产物与它处命名一致（端口、分支、镜像、命令）。
7. 给「缺省/占位」配指引注释：空 imageRepo、TODO 都写清怎么填。
8. 至少一个 e2e 断言：在 tests/scaffold-panel 加组合用例锁住该环节的关键产出（内容级断言）。

### 4.2 设计一个「预设场景」时 checklist
1. 场景定义先行：一句话写清「面向什么企业场景、产出什么形态」，用 D6 自检。
2. 环节选择即边界：不自动带上不需要的强栈（D6 C5）；轻量场景不硬塞 docker/deploy。
3. 语言/形态自洽：makefile.lang 与 docker.runtime 与后端语言一致；缺支持要标缺口或提供语言族自定义预设（A4）。
4. 默认参数可直达可用：预设注入的默认值让组合「生成即最小可用」（D5/D6 C4）。
5. 跑一遍 D1–D4 门槛：该组合真渲染到临时目录，断言 AGENTS 结构/命令、makefile↔CI、端口/镜像一致。
6. 命名/简介双语一致：内置预设文件（scaffold-presets/*.yaml）的 name/desc 双语与 stageIds/params 不脱节。

---

## 5. 评审工作流（对一个生成骨架做快速体检）

三步，逐级深入（可在 CI 无头跑前两步）：

1. 静态（代码级，秒级）：读 stage.yaml + 模板 + 派生逻辑 → 用 §2 的检查项核对（D1 坏引用、D2 条件文件、D3 同语义字段、D7 密钥纪律）。可用 grep 找死引用与敏感字眼。
2. 渲染（无头，秒-分）：把「预设 or 环节组合 + 一组参数」渲染到临时目录 → 比对预期文件清单、断言 AGENTS/跨环节一致（D1–D4）。落成 tests/scaffold-panel 用例。
3. 运行（本机，分钟级）：在临时目录跑关键路径（make -n、bash -n、--dry-run、hook 拦/放、有 docker/kubectl 则 build/dry-run）→ 验证 D5–D7。
4. 结论：按 §3 打分，给出「可发布 / 需修 / 不推荐」+ 取舍说明。

产物建议落两个地方：
- **每个内置环节/预设**：在 tests/scaffold-panel/scaffold-tests.swift 追加端到端断言（§6 模板）；
- **每次设计评审**：在 docs 对应文档（scaffold-stages-presets-audit.md）增补「评估记录」小节，写明 D1–D8 结论与遗留。

---

## 6. 自动化断言清单（可直接写成 tests/scaffold-panel 用例）

按 §2 维度给「断言模板」，可直接抄成用例：

- D1 坏引用守卫（回归 A1 一类）：
  - 断言：模板中每个 hasXxx，Xxx 属于现有环节的 capitalize(id) 集合；否则报错（或显式别名表）。
  - 用例：勾选 ci-cd + docs-standards + agents-md → 渲染 AGENTS.md → 断言同时含 CI/CD 与 docs/ 行（今天会挂，修 A1 后绿）。
- D2 完整/静默丢段守卫：
  - 断言：对组合，比对该产出文件清单与实际产出树全等；对模板每个条件分支各产一次并断言存在。
  - 用例：git-init license=Apache → 只出 LICENSE-Apache；ci-cd platform 遍历 github/gitlab/jenkins 各自产出对应文件。
- D3 自洽守卫：
  - 断言：AGENTS 出现的每个目录名都在产出树中（反向不夸大）；makefile 出现的每个目标在 make -n 输出/目标表存在。
  - 用例：fullstack 预设 → 断言 ci 的 ciBuild/ciTest 与 Makefile 的 backend-*/lang 默认同源；deploy+docker → 断言 servicePort/exposePort/healthzPath/镜像 repo 全一致。
- D5 可运行守卫（能跑就跑）：
  - 用例：生成后 bash -n deploy/*.sh；Makefile make -n 0 退出；enforce 生成 commit-msg hook → 一条违规 msg 拦截、合法放行。
- D7 密钥纪律：
  - 用例：grep 整个产物树无真实密钥/token 字面量；docker/k8s 脚本 --dry-run 只打印不写集群。
- 端到端回归（已存在）：纯后端 API 预设 / platform=jenkins / git-conventions(enforce) / deploy 全选——沿用并补 §2 新断言。

> 建议把 §2 检查项做成一份共享的「评估断言清单」文件，供 ScaffoldPanel 引擎与 tests/scaffold-panel 共用，避免评审规则与测试漂移。

---

## 7. 现有审计发现 → 维度映射（样例，说明本方案怎么用）

| 审计项（scaffold-stages-presets-audit.md） | 命中维度 | 性质 |
|---|---|---|
| A1 AGENTS 用 hasCI/hasDocs 引擎产 hasCiCd/hasDocsStandards | D1 + D2 + D4 | 坏引用 + 静默丢段 + AGENTS 失真 |
| A2 docker runtime=static 端口/健康检查错 | D1(语法对但语义错)→D5 + D3 | 可运行失败 + 自洽矛盾（80 vs 8080） |
| A3 deploy 不吃 .env 镜像 + 回滚无效 | D3 + D5 | 镜像标识不自洽 + 回滚不可运行 |
| A4 docker 缺 go/python | D6 | 语言/场景匹配缺口 |
| A5 java 镜像无 curl→HEALTHCHECK | D5 | 探活不可运行（待验证） |
| A6 configmap 生而未用 | D2/D7 | 产出过剩但无接线 |
| A7 imageRepo 空默认→非法镜像 | D6 + D3 | 默认值无效 + 镜像名不自洽 |
| A8 MIT 版权行用 projectName | D8 | 整洁/合规提示 |

可见：本方案能系统定位「哪层、哪维」出问题，设计时提前过门禁可少走弯路。

---

## 8. 附录：名词与产物清单

- 产物类型（生成树里常见的文件）：README/AGENTS/.editorconfig/.gitignore/LICENSE/docs 骨架/Makefile/CI(.github|.gitlab-ci|Jenkinsfile)/Dockerfile+compose/deploy 脚本+k8s manifests/.dsh/wiki 占位/state.json。
- 关键同语义字段（D3 必查）：trunk · imageRepo/imageTag · exposePort/servicePort · healthzPath · make 命令族 · primaryLang/lang/runtime/ci 命令。
- 阅读线索：docs/scaffold-stages-presets-audit.md（发现明细）· docs/scaffold-panel-analysis.md（功能/定位）· tests/scaffold-panel/scaffold-tests.swift（已有 e2e 断言范式）。

