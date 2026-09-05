# 预设骨架清单（常见企业场景：环节 / 默认参数 / 验收卡 + golden tree）

> 文档性质：**可执行清单** —— 梳理面向常见企业工作场景的预设骨架，每项给 场景、环节顺序、默认参数、验收卡（correct 断言 + suitable must-have）、golden 落地状态。
> 落地方法见 docs/scaffold-preset-landing.md（流程）· 评估维度见 docs/scaffold-evaluation-scheme.md · 现状审计见 docs/scaffold-stages-presets-audit.md。
> 撰写：2026-08（分支 feature/scaffold-workbench）。标注 现状可用 / 待生成golden / 需先补环节。

---

## 0. 读法

- 环节 10 个 foundation：agents-md · git-init · git-conventions · docs-standards · coding-conventions · docker · makefile · ci-cd · deploy · repo-knowledge。
- 关键默认参数：只列预设覆盖环节默认值的；未列 = 继承环节默认。参数键与 stage.yaml 一致。
- 状态：内置 = 已在 ScaffoldPreset.builtin；草稿 = 本清单推荐、按流程落地；需补环节 = 依赖未内置的示例栈（如 vue3-frontend / java-backend）。
- 验收卡：每项给 must-have（适合性门槛）+ 可证伪 correct 断言；golden 指向 fixtures（生成方式见附录）。

---

## 1. 一览表

| id | 名称 | 场景一句话 | 状态 |
|---|---|---|---|
| foundation | 文档+规范 | 只落规范、不含栈（含存量治理默认） | 内置 |
| base-conventions | 企业规范基础 | 存量 / 新仓先统一规范 + CI 门禁 | 草稿·推荐先落地 |
| backend | 纯后端 API | 后端 API 新仓（java 固化） | 内置 |
| backend-go / backend-python | 后端服务（语言族） | Go / Python 后端（消除 java 固化） | 草稿 |
| fullstack | 前后端兼备 | 前后端一体仓 | 内置 |
| frontend-spa | 纯前端应用（Vue3 范例） | 独立前端仓 / SPA | 草稿·需先补 vue3-frontend |
| oss-library | 开源库 / SDK | 对外发布的库，Apache + CI release 门控 | 草稿 |
| cli-tool | 内部 CLI / 自动化 | 轻量命令行工具 | 草稿 |
| etl-data | 数据 / 批处理 | 数据管道 / 批处理仓（Python） | 草稿 |
| microservice-group | 微服务 / 多仓统一 | 团队给每个 service 仓套同一规范 | 草稿·治理视角 |

---

## 2. 逐项卡片

### A. foundation 文档+规范【内置】
- 场景：只落 Git/文档/DoD/Agent 入口，不含构建部署栈。
- 环节：agents-md + git-init + git-conventions + docs-standards + coding-conventions + repo-knowledge。
- 关键参数：git-conventions.enforce=false（不强制改现有习惯）。
- must-have：有 AGENTS.md 且自洽；有 git 规范 + DoD；无 docker/deploy/ci 文件。
- golden：见后端 / 全栈 e2e 已覆盖；建议补 foundation 专用 golden。

### B. base-conventions 企业规范基础【草稿·推荐先落地】
- 场景：存量目录或新仓先铺团队规范，含可强制的 commit 规范与 CI 门禁；用「初始化此目录」落地。
- 环节：agents-md + git-init + git-conventions(enforce=true) + docs-standards + coding-conventions + makefile(按栈填命令) + ci-cd(hasBackend 按需) + repo-knowledge。
- must-have：enforce=true 时 install-git-hooks.sh 存在且纯 shell；AGENTS 与所选规范文件自洽；有 CI lint/test/build 门禁；不含 docker/deploy（避免污染既有代码）。
- 验收要点：bash -n hook；违规 commit msg 被拦；ci 与 makefile 命令同源。
- golden：待生成（落地时按流程 P2-P5）。

### C. backend 纯后端 API【内置，语言 java】
- 场景：后端 API 新仓（Spring Boot/Maven 形态的命令骨架）。
- 环节：10 个 foundation（agents-md · git-init · git-conventions · docs-standards · coding-conventions · docker · makefile · ci-cd · deploy · repo-knowledge）。
- 关键参数：ci-cd hasBackend=true hasFrontend=false；docker runtime=java；makefile 走多端模式后端默认 mvn -q package / mvn -q test；deploy 仅 deployDocker=true。
- must-have：AGENTS 自洽；Makefile backend-build/test 存在；docker runtime=java 时 Dockerfile 用 Maven + Temurin；CI 后端门禁。
- 局限：语言 java 固化 → 见 D。

### D. backend-go / backend-python 后端服务（语言族）【草稿】
- 场景：Go / Python 后端新仓；消除 C 的 java 固化（docker 已补 go/python 运行时，A4 已修）。
- 环节：同 backend，但 docker.runtime=go 或 python；makefile.lang=go 或 python（走语言预设目标）。
- 关键默认参数示例（backend-go）：ci-cd hasBackend=true；docker runtime=go exposePort=8080；makefile lang=go。
- must-have：Makefile 出现 go-* / py-* 目标且不出现 mvn/npm（可断言）；docker runtime=go 的 Dockerfile 用 golang→alpine 且 HEALTHCHECK 有 wget；CI 用 go test / pytest。
- golden：待生成（Go / Python 各一份）。

### E. fullstack 前后端兼备【内置】
- 场景：前后端一体新仓（同仓多端）。
- 环节：10 个 foundation。
- 关键参数：ci-cd 双 true；makefile 多端模式 frontendInstall=npm ci、frontendBuild=npm run build（后端 mvn 默认）。
- must-have：Makefile 同时有 backend-* 与 frontend-*；CI 分后端与前端步；AGENTS 命令自洽。
- golden：现有 e2e 覆盖主干，建议补 fullstack 专用 golden 锁参数。

### F. frontend-spa 纯前端应用（Vue3 范例）【草稿·需先补 vue3-frontend 示例环节】
- 场景：独立前端 / SPA 仓（Vue3 + Vite + TS 目标）。
- 环节（现状 foundation 可落地部分，按规范顺序）：agents-md(ts/node) + git-init(node) + git-conventions + docs-standards + coding-conventions + docker(runtime=static, exposePort=80) + makefile(lang=node) + ci-cd(hasFrontend=true hasBackend=false)。
- 关键参数：git-init gitIgnorePreset=node；makefile lang=node；docker runtime=static；ci-cd 仅前端。
- 已跑通验证（2026-08 实际渲染 my-vue-app，20 文件）：make -n OK、install-git-hooks.sh bash -n OK、AGENTS.md 自洽列出 CI/docs（A1 修复生效）、docker 产出 nginx.conf + 监听 exposePort。
- 验收卡：
  - must-have（适合性）：1) 能 make dev 起 Vue3 dev server；2) CI 跑 lint+单测+build；3) 产物含 package.json 与 Vue3 源码骨架。
  - correct 断言：Makefile 有 node-dev/build/test/lint；ci.yml 含前端 install&build 步；hook bash -n 通过；nginx.conf 监听 80。
- 当前结论（实测缺口）：
  1) 无 vue3-frontend 示例环节 → 产物无 package.json/src/vite，make dev 与 docker build 会失败（只能算规范+CI+容器骨架，不算可运行 app）；
  2) frontend-only 的 ci.yml 没有 test 步（vitest 不进 CI）→ 需给 ci-cd 补前端 test 步。
- 落地路径：先补 vue3-frontend 示例环节（M2），再按流程 P0-P6 落地本预设 + golden。
- golden：待生成（需先有 vue3-frontend）。

### G. oss-library 开源库 / SDK【草稿】
- 场景：对外发布库（npm/Maven/Go module），Apache + changelog + ADR + CI release 门控。
- 环节：git-init(license=Apache-2.0) + git-conventions(enforce) + docs-standards + coding-conventions + makefile(test/lint) + ci-cd + repo-knowledge。
- 关键参数：git-init license=Apache-2.0；docs-standards docsLang=en（或 bilingual）；不含 docker/deploy。
- must-have：LICENSE 为 Apache 全文；CI 仅 test/lint + tag 触发发布占位；无内联密钥。
- golden：待生成。

### H. cli-tool 内部 CLI / 自动化【草稿】
- 场景：内部命令行 / 脚本工具（无 web 服务）。
- 环节：agents-md + git-init + git-conventions + coding-conventions + makefile(lang 按脚本语言)；不含 ci/docker/deploy（如需门禁再加 ci-cd）。
- must-have：Makefile 统一 install/build/test/lint/run 入口；不生成 Dockerfile/部署（避免过度生成）。
- golden：待生成。

### I. etl-data 数据 / 批处理【草稿】
- 场景：企业数据管道 / 批处理仓（Python）。
- 环节：agents-md + git-init + git-conventions + docs-standards + coding-conventions + makefile(lang=python) + ci-cd(校验/单测门禁)；不含 docker/deploy（非 web 服务）。
- 关键参数：makefile lang=python。
- must-have：Makefile 有 py-test/py-lint（pytest/ruff）；CI 跑 pytest；不生成 web 部署物。
- golden：待生成。

### J. microservice-group 微服务 / 多仓统一规范【草稿·治理视角】
- 场景：团队给每个新 service 仓套同一规范模板（脚手架 v1 为单项目模型，多仓一致性靠「同预设复用到每个仓」达成）。
- 环节：agents-md + git-conventions(enforce) + docs-standards + coding-conventions + makefile(统一目标约定) + ci-cd(镜像占位+发布门控) + repo-knowledge；是否含 docker/deploy 视团队部署方式。
- must-have：跨 service 仓能产出一致的规范文件（diff 稳定）；CI 发布动作默认门控。
- 备注：属组织级复用，落地以「规范基线文档 + 模板」而非单一产物为主。

---

## 3. 落地状态与建议优先级

| 优先级 | 动作 | 前置 |
|---|---|---|
| P0 | 落 base-conventions 内置种子 + golden（最贴近企业规范落地主张） | 无（现有环节够） |
| P0 | 修 ci-cd：frontend-only 也跑 test 步 | ci-cd 模板 |
| P1 | 落 backend-go / backend-python 语言族预设 + golden | docker go/python 已补（A4 完成） |
| P1 | 补 vue3-frontend 示例环节，再落 frontend-spa + golden | 需新建示例环节（M2） |
| P2 | oss-library / cli-tool / etl-data 验收 + golden | 无 |
| P2 | foundation / fullstack 补专用 golden | 无 |

---

## 附录：怎么为一个预设生成 golden（复现方法）

1. 准备：仓库在可编译状态，内置环节在 scaffold-stages/；无头编译参照 tests/scaffold-panel/run.sh（swiftc + stubs + ScaffoldPanel.swift）。
2. 写一段小型 main：读 DSH_SCAFFOLD_STAGES，用 ScaffoldPlan.build 传入该预设的 selection 与 params（项目名可固定如 demo），ScaffoldApplier.apply 到临时目录。
3. 落 fixtures：把产物树拷到 tests/scaffold-panel/fixtures/<id>-golden/，去掉 .git，写 params.json（selection + params）与 expected.txt（期望清单）。
4. 跑断言：参考 tests/scaffold-panel 现有 e2e（backend/jenkins/gitconv/deploy），补 make -n / bash -n / AGENTS 自洽等。
5. 跑 tests/scaffold-panel/run.sh 全绿后提交（conventional commit）。

（Vue3 已在 2026-08 用此法渲染验证过一次，产物树即 frontend-spa 的 golden 雏形；待 vue3-frontend 补入后再固化。）
