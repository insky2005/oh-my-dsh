
# 内置环节与预设审计（内容合理性 / 正确性 / 有效性）+ 预设推荐

> 文档性质：**内容级审计** —— 逐环节核对 scaffold-stages/ 下真实的 stage.yaml 与 templates/ 内容，评估**合理性 / 正确性 / 有效性**；并对内置预设给出现状评估与**面向更多企业工作场景的预设推荐**。
> 审计对象：scaffold-stages/（agents-md · git-init · git-conventions · docs-standards · coding-conventions · docker · makefile · ci-cd · deploy · repo-knowledge，均 category: foundation）+ ScaffoldPreset.builtin（backend / fullstack / foundation）+ ScaffoldPlan.build 的派生上下文逻辑（platforms/macos/src/ScaffoldPanel.swift）。
> 定位口径：**企业工程规范落地**（配套：docs/scaffold-panel-analysis.md）。
> 撰写：2026-08（按分支 feature/scaffold-workbench 当前内容）。结论分「确定问题 / 设计权衡 / 待确认」；示例栈（java-backend / vue3-frontend）未随内置库发布，故本审计只覆盖现存 foundation 环节。
> 配套：docs/scaffold-workbench-design.md（技术）、docs/scaffold-panel-analysis.md（功能）、docs/scaffold-panel-ui.md（交互）。

---

## 0. 摘要

逐环节核对后：环节库整体**结构严谨、工程细节扎实**（YAML 校验器、非破坏 hook、纯 shell 校验、k8s 脚本与 manifests 一致性、密钥只引用不内联），无破坏性错误。但存在**若干正确性 / 有效性缺口**，集中在三处：

1. **AGENTS.md 的派生标志名错配（确定问题，影响 G3「协作就绪」）**：AGENTS.md.tmpl 用 hasCI / hasDocs，而引擎只生成 hasCiCd / hasDocsStandards → 当勾选 ci-cd 或 docs-standards 时，AGENTS.md 的「目录结构」**不会列出 CI/CD 与 docs/**，静默丢失（不会被单测捕捉，单测只断言 make / git-conventions 行）。这与「AGENTS.md 与骨架永远自洽」的目标相悖。
2. **docker 环节 runtime=static 不正确（确定问题）**：Dockerfile 让 nginx 默认监听 80，但 EXPOSE / compose / healthcheck 都写 exposePort（默认 8080）→ 端口映射落空、健康检查失败；静态站点不可达。需 nginx 改听 exposePort（或固定 80）。
3. **deploy 的「env 覆盖 + 自动回滚」名不副实（确定问题）**：docker-compose.prod.yml 的 image 是**渲染期字面量**，不吃 deploy/.env 的 IMAGE_REPO/IMAGE_TAG；deploy-docker.sh 脚本计算的 IMAGE 只用于提示，compose 仍拉渲染时的镜像 → 改 .env 不生效；回滚时改 IMAGE_TAG 也动不了 compose 的固定 image → **回滚实际无效**。

另有若干中等缺口：docker 运行时缺 go/python（与 makefile / agents-md / CI 的语言面不一致）；java 运行镜像无 curl/wget → Dockerfile 与 compose 的 HEALTHCHECK 可能失败；k8s configmap 生成但未被 deployment 引用；deploy.imageRepo 空默认值会产生非法镜像名等。

**预设现状**：内置三组（纯后端 API / 前后端兼备 / 文档+规范）合理，但**不覆盖语言维度**（backend 预设硬编码 docker runtime=java + makefile 的 mvn 默认，对 Go/Python 后端不适合）；缺「纯前端应用」「开源库/发布」「存量项目规范化落地」「数据/批处理」「CLI 工具」等企业场景。

---

## 1. 审计方法

- 对每个环节读 stage.yaml（params / files / commands）与全部 templates/；
- 把模板引用的上下文键与 ScaffoldPlan.build 实际生成的键做交叉比对（param 键、select 每个选项的 键.选项、multiselect 的 键.选项 / 键Empty / 键Any、string 的 键Empty、derived has<Capitalize(id)>、ci-cd 派生的 ciLint/ciTest/ciBuild/ciFrontend、兜底 trunk/imageRepo/imageTag/jenkinsAgentLabel/techSummary）；
- 无头方式无法运行 App，静态读码 + 比对得出；标注「推断 / 待人工验证」处需跑 tests/scaffold-panel 或在真实目标目录生成验证。

---

## 2. 派生上下文事实（供判读）

引擎（ScaffoldPlan.build）对每个**选中环节**生成：
- has<Capitalize(id)>（把 id 按「-」切分、每段首字母大写再拼接）：git-init→hasGitInit；ci-cd→**hasCiCd**；git-conventions→hasGitConventions；docs-standards→**hasDocsStandards**；agents-md→hasAgentsMd；makefile→hasMakefile；docker→hasDocker；deploy→hasDeploy；coding-conventions→hasCodingConventions；repo-knowledge→hasRepoKnowledge。
- select 参数 → 键.选项 布尔；multiselect → 键.选项 + 键Empty / 键Any；string → 键Empty。
- 选中 ci-cd 时派生 ciLint / ciTest / ciBuild / ciFrontend。
- 兜底：trunk=main、imageRepo=your-registry、imageTag=latest、jenkinsAgentLabel=linux、techSummary（空 + techSummaryEmpty）。

各模板实际引用的 has*（grep 全库）：hasBackend / hasFrontend（ci-cd 的参数，非派生）、hasConventions / hasDeploy / hasDocker / hasGitConventions / hasMakefile / hasRepoKnowledge / **hasCI** / **hasDocs**。
→ **hasCI、hasDocs 无任何来源**（引擎不产、代码无别名注入）。已在 ScaffoldPanel.swift 全文确认不存在别名。

---

## 3. 逐环节审计

### 3.1 git-init（仓库初始化）
- 内容：.gitignore（基础 + gitIgnorePreset.{java,node,generic} 条件段）、README 骨架（techSummary 或占位、可选 make build/test）、LICENSE（license=MIT/Apache-2.0/none 条件）、命令 git init -b main。
- 合理性：好。多语言场景（java+node 同仓库）只能选一个 preset（select），属小限制。
- 正确性：LICENSE-MIT / LICENSE-Apache-2.0 均为完整正文；MIT 版权行写 {{year}} {{projectName}}（项目名即版权人，企业通常应改公司名——占位合理，建议模板内注释提示改为法人 / 组织名）。Apache 正文完整。
- 有效性：git init 在 Applier 执行命令阶段跑；README 与 AGENTS 的 techSummary 联动见 3.3。问题（低）：项目名可含中文 / 企业名，作 LICENSE 版权行可接受但需用户替换。

### 3.2 git-conventions（Git 提交与分支规范）
- 内容：docs/conventions/git.md（Conventional Commits 全 type 枚举 + 分支规范 + 合并规则，trunk 参数）、.gitmessage（commit 模板）、install-git-hooks.sh（enforce=true，纯 shell commit-msg 校验）。
- 正确性：hook 正则 ^(feat|fix|docs|refactor|perf|test|chore|build|ci|revert)(\([a-z0-9_-]+\))?!?: .+ 允许 scope 与 breaking 感叹号，合理；**非破坏**：已有同名 hook 先备份 .scaffold-backup/ 再写；set -euo pipefail、先校验 .git 存在；无 node 依赖（符合企业离线 / 受限环境）。与仓库自身 docs/git-workflow.md 惯例一致。
- 有效性：高。enforce=false 时 git.md 不给「校验」段（合理自洽）。
- 待确认：hook 允许 breaking 感叹号，但 .gitmessage 模板未提示该写法；不影响正确性。

### 3.3 agents-md（AGENTS.md）
- 内容：AGENTS.md：项目是什么（techSummary）、主语言多选（primaryLang 各选项布尔）、目录结构（按 has<环节> 罗列）、常用命令（make / docker）、工程规范引用、禁区、与 dsh 协作（repo-knowledge 占位）。
- 正确性：主语言多选渲染正确（仅列所选，单测覆盖）。**确定问题（高）**：目录结构里 ci-cd 用 hasCI、docs-standards 用 hasDocs，均无来源 → 勾选这两个环节时 AGENTS.md 不列 CI/CD 与 docs/；同时 hasCiCd / hasDocsStandards 被生成却无人用。修复：模板改用 hasCiCd / hasDocsStandards（或引擎为 CI / Docs 补别名）。影响：对企业最常用的「CI + 文档」骨架，AGENTS 少了结构指引，弱化 G3。
- 有效性：低-中——其余 hasConventions / hasGitConventions / hasMakefile / hasDocker / hasDeploy / hasRepoKnowledge 均正确映射，故多数场景仍自洽。

### 3.4 docs-standards（文档规范骨架）
- 内容：docs/architecture.md、docs/adr/ADR-0001-template.md、docs/conventions.md、docs/ops/runbook.md（docsLang 双语）。
- 正确性：docsLang 是 select，模板 {{docsLang}} 输出 bilingual/zh/en；conventions.md 用 hasGitConventions、runbook 用 hasDeploy（均正确）。ADR / 架构为占位骨架，合理。
- 有效性：作为企业文档骨架合格；与 AGENTS「目录结构」联动因 3.3 的 hasDocs 失效而丢失 docs/ 行（连带问题）。

### 3.5 coding-conventions（开发规范落地）
- 内容：.editorconfig（root + 通用 + md 例外 + Makefile tab）、CONTRIBUTING.md（vcs.github/gitlab 分支、DoD 清单）。
- 正确性：CONTRIBUTING 用 hasGitConventions（正确）+ vcs.github / vcs.gitlab（select 选项）。.editorconfig 内容标准。DoD 清单通用。
- 有效性：好；建议按需扩展（如代码风格细则引用，v2）。

### 3.6 makefile（统一命令入口）
- 内容：Makefile。两种模式：未选 lang（多端 / 自定义：dev/build/test/lint/format/check/install/start + backend-* / frontend-* 汇总目标）；选了 lang（java/node/go/python 可多选，每语言 java-<action> 等子目标，统一 dev/build/test/lint/format/install/start 汇总）。
- 正确性：lang 为空 → langEmpty 走多端分支；langAny 走语言分支；lang.java 等布尔由 multiselect 派生；各 string 命令的 xxxEmpty 分支给默认（java→mvn、node→npm、go→go、python→ruff/pytest）。逻辑自洽。多语言时 dev/build 汇总各语言目标，合理。
- 有效性：较高。注意点：a) python 的 build 是无编译提示（合理）；b) 语言预设与 docker/deploy 的 runtime 面不一致（见 3.7）；c) 未选 lang 的多端模式，后端默认 backendBuild=mvn -q package——若用户后端并非 mvn（如自建 go）会落到 mvn；建议生成后注释提示填真实命令。

### 3.7 docker（容器化）
- 内容：Dockerfile（runtime.java / node / static 三分支，多阶段 + HEALTHCHECK）、.dockerignore、compose.yaml（app 服务 + 占位 db）。
- 正确性问题 1（高，runtime=static）：static 分支构建成 node 产物后 FROM nginx:alpine、COPY 到 /usr/share/nginx/html，但 EXPOSE 与 compose 端口 / 健康检查都写 exposePort（默认 8080），nginx 默认监听 80 → 端口映射落空、healthcheck（curl localhost:8080/healthz）因 8080 无服务而失败 → 静态站点不可达、健康检查必挂。修复：static 时 nginx 改听 exposePort（补 nginx.conf）或将 exposePort 视为 80；compose 同步。
- 正确性问题 2（中，java 探活工具缺失）：runtime.java 运行时 eclipse-temurin:21-jre（Ubuntu 系）默认无 curl/wget，Dockerfile 与 compose 的 HEALTHCHECK 都用 curl → 可能失败。修复：java runtime 阶段 apt 装 curl 或换探活。
- 覆盖缺口（中）：runtime 仅 java/node/static，无 go/python——但 makefile / agents-md / CI / deploy 的语言面都含 go/python → Go/Python 后端无法用本环节正确容器化（只能近似选 node 或手改）。建议补 go（golang → distroless）与 python（gunicorn）分支，或对未支持语言提示手改。
- 有效性：java/node 常规路径尚可用；node 默认入口 node dist/main.js 假定 TS→dist/main.js（对 src/ index 型入口需手改，可接受为最小骨架）。SPA 深链 fallback 未处理（v2）。

### 3.8 ci-cd（CI/CD 门禁）
- 内容：platform=github-actions → ci.yml + cd.yml；gitlab-ci → .gitlab-ci.yml；jenkins → Jenkinsfile。ciLint/ciTest/ciBuild/ciFrontend 由 makefile 参数派生（见 §2）。
- 正确性：ci.yml 用 trunk（兜底 main）、hasBackend / hasFrontend 分段、build 用 ciBuild；gitlab-ci 三阶段 + dist/ 产物；Jenkinsfile 声明式：agent label 参数化、timestamps / disableConcurrentBuilds / timeout、PUBLISH 参数门控（默认不触发）、Checkout 补 git fetch --tags（吸收浅克隆教训）、凭据 withCredentials 占位不内联、post.always 归档 dist/**（allowEmptyArchive）。与仓库自用 Jenkinsfile 形态对齐。整体严谨。
- 有效性：高。细节：a) gitlab-ci 的 artifacts 固定 dist/（后端项目为空目录，带 warn 可接受）；b) 纯前端 + 未选 makefile 时会得到 echo 占位 + 提示（有 hint）；c) cd.yml 仅在 push tag v* 触发、镜像推送 / 部署为注释占位（不内联密钥）——符合「门控 + 占位」定位。
- 待确认：多语言（lang 多选）时 CI 只取 firstLang 的单条命令（见 ScaffoldPlan langDefault），对多语言 monorepo 是近似；现阶段可接受（单仓库以首语言为主）。

### 3.9 deploy（部署脚本）
- 内容：deployDocker/K8s/Rancher 三选可多选 → 可执行脚本 + manifests：deploy-docker.sh + docker-compose.prod.yml + .env.example；deploy-k8s.sh + k8s/{deployment,service,configmap}.yaml；deploy-rancher.sh + rancher/README.md。
- 正确性（整体高，k8s/rancher）：deploy-k8s.sh 前置校验 context、create namespace、apply 顺序（configmap→deployment→service）、set image 免改 yaml、rollout status→失败 rollout undo；deployment 容器名 app 与 set image 的 app=IMAGE 匹配；service targetPort=containerPort。scripts 均 set -euo pipefail、--dry-run、默认交互确认 + --yes。无内联密钥。rancher 复用 k8s manifests + KUBECONFIG / RANCHER_SERVER 前置指引。
- 正确性问题（中-高，docker 回滚与 env 覆盖失效）：deploy-docker.sh 计算的 IMAGE=repo/slug:tag 仅用于提示；实际 docker compose up 用 docker-compose.prod.yml 里**渲染期字面量** image（imageRepo/projectSlug/imageTag），**不读 .env 的 IMAGE_REPO/IMAGE_TAG** → 改 .env 不影响实际部署镜像；回滚 rollback() 仅改脚本内 IMAGE_TAG 再 up，同样动不了 compose 固定 image → 自动回滚实际无效。设计稿宣称「切回上一 tag」名不副实。修复：compose 内 image 用 compose 环境变量替换（IMAGE_REPO / IMAGE_TAG）或回滚用 docker compose override / force-recreate。
- 缺口（中）：deploy.imageRepo 默认空且无 nonEmpty → 未填时 image 形如 /slug:latest（compose / 脚本 / README 都坏）。建议设占位或 nonEmpty 必填（像 servicePort / healthzPath）。
- 缺口（低-中）：configmap 生成但 deployment 未引用（无 envFrom / mounts）→ 实际未生效；要么接上，要么在注释说明「按需接线」。
- 待确认：远程 docker 部署在远端是否具备 docker + curl 未前置探测（本机只查 docker / rsync）。

### 3.10 repo-knowledge（知识库准备）
- 内容：.dsh/wiki/README.md 占位（引导用 repo-knowledge skill 生成，保持确定性）。
- 正确性 / 有效性：作为占位合格；AGENTS「与 dsh 协作」用 hasRepoKnowledge 正确引用。无参数、无副作用，低风险。

---

## 4. 环节问题汇总（按影响排序）

| # | 环节 | 问题 | 类型 | 影响 | 建议 |
|---|---|---|---|---|---|
| A1 | agents-md | AGENTS.md 用 hasCI/hasDocs，引擎产 hasCiCd/hasDocsStandards | 确定·正确性 | 高：CI/docs 不列、破 G3 自洽 | 模板改 hasCiCd/hasDocsStandards，或引擎补别名；加断言单测 |
| A2 | docker | runtime=static 端口 / 健康检查全错（nginx 80 vs exposePort 8080） | 确定·正确性 | 高：静态站点不可达 | static 走 80 或补 nginx.conf 监听 exposePort |
| A3 | deploy | docker 部署不吃 .env 镜像覆盖 + 自动回滚无效 | 确定·正确性 | 中-高：env/回滚名不副实 | compose 用环境变量替换；补 docker compose override |
| A4 | docker | runtime 无 go/python（与 makefile/agents/CI 面不一致） | 覆盖缺口 | 中：Go/Python 后端无法正确容器化 | 补 go/python 分支或对未支持语言给手改提示 |
| A5 | docker | runtime=java 镜像无 curl → HEALTHCHECK 可能失败 | 正确性·待验证 | 中 | java runtime 装 curl 或换探活 |
| A6 | deploy | configmap 生成但 deployment 未引用 | 缺口 | 低-中 | envFrom 接线或注释说明 |
| A7 | deploy | imageRepo 空默认 → 非法镜像名 | 缺口 | 中 | 占位 / 必填校验 |
| A8 | git-init | MIT 版权行用 projectName | 权衡 | 低 | 注释提示改法人 / 组织名 |
| A9 | makefile/ci | 多语言 CI 只取 firstLang；makefile 多端默认 mvn | 权衡 | 低-中 | 注释 / 文档明示；按需 lang 预设 |

---

## 5. 内置预设审计

内置三组（ScaffoldPreset.builtin）：

| id | 环节 | 参数默认 | 适配场景 | 评估 |
|---|---|---|---|---|
| backend 纯后端 API | 全部 10 个 foundation | ci-cd hasBackend=true；docker runtime=java | 后端 API 新项目 | 合理但**语言固化**（java+mvn），Go/Python 后端不适配；且一次拉起 deploy+k8s 等，偏重 |
| fullstack 前后端兼备 | 全部 10 个 | ci-cd 双 true；makefile frontendInstall/frontendBuild | 前后端一体 | 合理；但 makefile 走多端模式、后端默认 mvn，语言同样固化 |
| foundation 文档+规范 | agents-md/git-init/git-conventions/docs-standards/coding-conventions/repo-knowledge | 无 | 只落规范、不含栈 | 好；与「企业规范落地」定位最贴，可作存量项目规范化默认 |

共性缺口：
1. **不覆盖语言维度**：backend/fullstack 硬编码 docker runtime=java + makefile 的 mvn 默认；企业里 Go/Python/Node 后端很普遍 → 需要一个「语言可切换」的表达（预设里加 makefile.lang / docker.runtime / ci-cd 命令即可，但内置预设没这么做，且 docker 无 go/python，见 A4）。
2. **无「纯前端应用」预设**（SPA / 管理台前端）：企业常有独立前端仓。
3. **无「开源库 / SDK 发布」预设**（license Apache + changelog + 文档 + CI release gate）。
4. **无「存量项目规范化落地」预设**（面向既有仓库，配合「初始化此目录」，不含 docker/deploy 强栈）。
5. **无「CLI / 内部工具 / 批处理 / 数据」等轻量预设**。

---

## 6. 面向企业工作场景的预设推荐

以下预设以「先落规范、再按需加栈」分层设计，均可用现有 10 环节组合（不改引擎）表达；括号内为建议环节顺序与关键参数默认。

### 6.1 分层 / 推荐清单
1. **base-conventions「企业规范基础（存量治理）」** —— 面向**既有 / 新仓只先落规范**：
   git-init + git-conventions(enforce=true) + coding-conventions + agents-md + docs-standards + repo-knowledge + makefile(按栈填命令) + ci-cd(hasBackend 按需)
   定位：团队统一 Git / 文档 / DoD / Agent 入口；不含容器 / 部署（避免污染既有代码）。比 foundation 多 ci-cd 门禁。→ 替代 / 扩展现有 foundation，最适合企业铺开。

2. **frontend-spa「纯前端应用」**：
   git-init(gitIgnorePreset=node) + git-conventions + agents-md(primaryLang 含 typescript/node) + coding-conventions + docs-standards + makefile(lang 含 node) + ci-cd(hasBackend=false, hasFrontend=true) + docker(runtime=node 或 static，待 A2 修复后建议 static/80) [+ deploy(k8s，若公司用 K8s)]
   覆盖独立前端仓的 CI（装依赖 → lint → build → 部署占位）。

3. **backend-go「Go 后端服务」 / backend-python「Python 后端服务」**（语言可切换族，取代 backend 的 java 固化）：
   git-init + git-conventions + agents-md + coding-conventions + docs-standards + makefile(lang=go 或 python) + ci-cd(hasBackend=true) + docker(runtime=go→需先补 A4) + deploy(k8s)
   用参数把 docker.runtime / makefile.lang / ci 命令与所选后端语言对齐。

4. **microservice-group「微服务 / 多仓统一规范」**（治理视角）：
   不生成单一 app，而强调**跨仓库一致**：git-conventions(enforce) + coding-conventions + agents-md + docs-standards + ci-cd(镜像占位 + 发布门控) + repo-knowledge + makefile(统一目标约定)
   定位：团队用它给「每个新 service 仓」套同款规范模板，保证一致性（需配合每个仓分别跑一次；脚手架 v1 是单项目模型，多仓一致性靠同预设复用来达成，见注）。

5. **oss-library「开源库 / SDK 发布」**：
   git-init(license=Apache-2.0, gitIgnorePreset 按语言) + git-conventions(enforce) + coding-conventions + docs-standards(docsLang=en/bilingual) + makefile(test/lint) + ci-cd + repo-knowledge
   突出：LICENSE 全文本、ADR、CI 仅 test/lint + tag 触发发布占位。

6. **cli-tool「内部 CLI / 自动化工具」**（轻量）：
   git-init + git-conventions + agents-md + coding-conventions + docs-standards(可选) + makefile(lang 按脚本语言)；不含 docker/deploy/ci 强栈；突出 makefile 统一入口。

7. **etl-data「数据 / 批处理工程」**：
   git-init + git-conventions + agents-md + coding-conventions + docs-standards + makefile(lang=python, 填 ETL 命令) + ci-cd(单测 / 校验门禁)
   企业数据管道仓的规范落地（不部署 web 服务，故不强制 docker/deploy）。

8. **api-gateway-bff**：与 fullstack 等价但显式前端为管理台 / 网关形态；可并入 fullstack 预设家族，不必新增。

### 6.2 让预设「语言可切换」的工程建议（关键）
- 建议把 docker 环节补 go/python 运行时（A4），并把内置预设从「java 固化」改为**参数化**：backend 预设默认 java，另给 backend-go / backend-python（或用户在预设编辑器里改 makefile.lang 与 docker.runtime 后存为自定义预设——现有预设编辑器已支持，作为 P0 前不必新内置；可内置 2-3 个语言族预设省去手配）。
- 预设推荐落地方式：A) 直接新增内置种子（改 ScaffoldPreset.builtin + 双语 name/desc）；B) 或作为「预设模板文档」让用户按 6.1 自定义。建议内置 base-conventions 与 frontend-spa 两个种子先落地，语言族用自定义预设承载。

### 6.3 关于预设与定位
- 「企业工程规范落地」的最短路径 = **base-conventions（含 enforce git hook）+ 存量目录初始化 + AGENTS 让 Agent 自洽**。推荐把 base-conventions 设为**首个可一键套用**的入口预设，配合 A1 修复，最贴近本功能的定位主张。

---

## 7. 落地建议（按影响排序）

| 优先级 | 动作 | 归属 |
|---|---|---|
| P0 | 修 AGENTS.md：hasCI→hasCiCd、hasDocs→hasDocsStandards（或引擎补别名）+ 加断言单测 | A1 |
| P0 | 修 docker runtime=static：nginx 监听与 exposePort / compose / healthcheck 对齐（或固定 80） | A2 |
| P0 | 修 deploy docker：compose image 改环境变量替换、回滚用 override / force-recreate | A3 |
| P1 | docker 补 go/python 运行时；java runtime 补 curl 探活 | A4/A5 |
| P1 | deploy.imageRepo 必填 / 占位；configmap 接线或注释 | A6/A7 |
| P1 | 新增内置预设种子 base-conventions、frontend-spa；README 给语言族自定义预设指南 | §6 |
| P2 | makefile 多端默认 mvn 的注释提示；docs / A4 语言面一致性说明 | A9 |

> 审计为静态读码结论；P0 修复建议先在 tests/scaffold-panel 加覆盖（如：勾选 ci-cd + docs-standards + agents-md 后断言 AGENTS.md 含 CI/CD 与 docs/；docker static 生成后断言端口与探活一致），再跑 tests/scaffold-panel/run.sh 全绿后落地。

---

## 8. 附录：阅读线索

- 环节内容：scaffold-stages/<id>/stage.yaml + templates/
- 派生逻辑：platforms/macos/src/ScaffoldPanel.swift → ScaffoldPlan.build（§2 所列键）
- 内置预设：同文件 ScaffoldPreset.builtin / static backend·fullstack·foundation
- 引擎单测：tests/scaffold-panel/scaffold-tests.swift（含端到端组合：纯后端 API / jenkins / git-conventions(enforce) / deploy 全选）

