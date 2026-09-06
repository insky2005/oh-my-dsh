# 示例栈（Example Stage）落地规范

> 文档性质：**约定规范** —— 定义脚手架里「示例栈」这类环节（category: examples）如何落地：输出到项目下**独立子目录**、自带该语言的 **Makefile**，自成一体的最小可运行骨架。
> 范本：scaffold-stages/vue3-frontend/（已落地）。配套：docs/scaffold-preset-landing.md（预设/环节落地流程）· docs/scaffold-stages-presets-audit.md · docs/scaffold-panel-analysis.md。
> 撰写：2026-08（分支 feature/scaffold-workbench）。

---

## 0. 为什么这样定

- 一个项目可能同时要「前端 + 后端」等**多个语言示例**；若都写进项目根会互相污染（如多个 package.json / src）。
- 因此每个示例栈 = 项目下的**独立子目录**，且**自带该语言命令入口（Makefile）**：开发者 `cd <子目录> && make dev` 即可，语言指令集中在本目录，互不干扰。
- 示例是「自成一体」的最小可运行骨架：可在其目录内 install/build/test，不依赖根目录构建自动指进来（根如何聚合另议）。

---

## 1. 模型与形态

选一个示例栈环节，会在项目根下生成一个它自己的子目录：

    <项目根>/
      ├── AGENTS.md / README / .editorconfig / docs/ ...（工程规范，根）
      ├── vue3-frontend/            # 前端示例（自成一体的子目录）
      │   ├── Makefile              # 该语言的 make 指令（转发到 npm/go/mvn …）
      │   ├── package.json / src/ / vite.config.ts …
      └── backend/                  #（若还选了后端示例）其自带 Makefile 与源码

根目录只放「工程规范 + 文档 + 项目级 stuff」；**每个语言示例是一个可独立进入、独立 make 的子项目**。

---

## 2. 环节（stage）约定

### 2.1 基础字段
- id：小写 + 连字符（如 vue3-frontend / java-backend / go-backend）。
- category：examples（向导归到「示例栈」分组）。
- name / description：中英双语，说明技术栈 + “输出到独立子目录、可与后端示例并存”。

### 2.2 子目录参数 dir
- 每个示例栈都要有 `dir` 参数：子目录名（相对项目根）。
- default = 本环节 id（如 vue3-frontend），便于多示例时一眼区分；用户可在参数里改成 web / app 等。
- validate：safePath（拒绝 ../ 、绝对路径），避免目录穿越。
- 该环节所有产出文件 path **一律以 `{{dir}}/` 为前缀**。
- Java 包名 → 目录：引擎对 `validate: javaPackage` 的 string 参数会自动派生 `<key>Path`（点号→斜杠），源码路径用它（如 `{{dir}}/src/main/java/{{packageNamePath}}/Application.java`）。

### 2.3 自带 Makefile（关键）
- 在子目录内生成一个 `Makefile`（path = `{{dir}}/Makefile`），把**该语言命令**收口：
  - Node 类：dev/build/test/lint/typecheck/install → `npm run …` / `npm install`；
  - Java 类（未来）：mvn spring-boot:run / mvn package / mvn test …；
  - Go 类（未来）：go run . / go build / go test ./... / golangci-lint …。
- 子 Makefile 目标命名尽量统一：dev / build / test / lint / install（+ 语言特有如 typecheck/preview），便于以后根目录统一聚合。
- 注意：Makefile 配方**必须用 Tab 缩进**（模板里写真实 Tab）。

### 2.4 最小可运行（自带脚本）
- 示例要「进目录即可跑」：其语言清单文件（package.json / pom.xml / go.mod）自带脚本（dev/build/test/lint…），与子 Makefile 对齐。
- 首装命令用 `npm install` 这类能生成 lockfile 的，**不要用 `npm ci`**（全新项目无 lockfile 会失败）。

### 2.5 与渲染器 {{ }} 的冲突
- 脚手架渲染器用 `{{ }}` 作为变量。若该语言模板本身也含 `{{ }}`（如 Vue SFC 插值），要么**改用指令/方法避免**（vue3-frontend 的 SFC 用 v-text、@click 而不写 `{{ }}`），要么用 `{{{{ }}}}` 转义。
- 生成的源码里**不得残留 `{{{{` 转义泄漏**（e2e 会断言）。

### 2.6 边界
- **不写 .gitignore**：仓库级 .gitignore 由 git-init 环节负责，避免同路径冲突；如确需语言片段，放入 git-init 的 preset 或与 git-init 冲突协调。
- 示例之间**不写同路径文件**（各在自家子目录）；子目录由 dir 保证隔离。
- 不在示例目录外散落脚本/文件。

### 2.7 登记与测试
- 每个示例栈：在 tests/scaffold-panel 加一条 e2e（渲染含该示例的组合 → 断言子目录文件、自带 Makefile、无转义泄漏、根目录无污染）。
- 在 docs/scaffold-preset-catalog.md 登记对应预设/示例状态；示例可被预设组合（预设只组合 stage）。

---

## 3. 产出文件约定（示例子目录内）

| 文件 | 是否必须 | 说明 |
|---|---|---|
| Makefile | 必须 | 语言命令入口（Tab 缩进） |
| 语言清单（package.json/pom.xml/go.mod） | 必须 | 自带 dev/build/test/lint 等脚本 |
| 语言配置（vite.config/tsconfig 等） | 推荐 | 能直接 build |
| 最小源码 + 一个可跑单测 | 推荐 | vitest/go test/… 示例 |
| .gitignore | 不写 | 由 git-init 提供 |

---

## 4. 范本：vue3-frontend

### 4.1 stage.yaml 要点
- id: vue3-frontend，category: examples
- params：dir（默认 vue3-frontend，safePath）、apiBase（默认 /api）、vitePort（默认 5173）
- 所有 file path = `{{dir}}/…`：Makefile / package.json / vite.config.ts / tsconfig.json / index.html / src/…

### 4.2 子 Makefile（转发 npm）

    .PHONY: dev build preview test lint typecheck install
    dev:     npm run dev      # vite，端口 {{vitePort}}
    build:   npm run build    # vue-tsc + vite build
    test:    npm test         # vitest
    lint:    npm run lint     # vue-tsc（作 lint 兜底）
    typecheck: npm run typecheck
    install: npm install      # 首次生成 lockfile

（示例中缩进示意为空格；实际文件为 Tab。）

### 4.3 语言脚本（package.json scripts）
dev/build/preview/typecheck/lint/test/test:watch 齐全，与子 Makefile 一一对应。

---

## 5. 示例对照（范本 + 未来，复用同一模式）

| 示例 | 默认子目录 | 自带 Makefile 主要命令 |
|---|---|---|
| java-backend（已落地·范本二，2026-08） | 默认 java-backend/（可改 backend/） | mvn spring-boot:run / mvn -q package / mvn -q test |
| go-backend（未来） | backend/ 或 go-backend/ | go run . / go build / go test ./... |
| python-api（未来） | api/ 或 python-api/ | uvicorn / pytest / ruff |

原则：每个示例都满足 §2（dir 参数 + 自带 Makefile + 最小可运行 + 独立子目录 + e2e）。

---

## 6. 落地一份新示例栈的 checklist（对 §2 / docs/scaffold-preset-landing 的 P0-P5）

- [ ] 定义 target/job：给谁、产出什么语言的独立子项目
- [ ] 写 stage.yaml：id/category=examples/双语 name+desc
- [ ] 加 `dir` 参数（默认=id，safePath），所有文件 path 前缀 `{{dir}}/`
- [ ] 加 `{{dir}}/Makefile` 模板（语言命令，Tab 缩进，统一目标名）
- [ ] 语言清单自带 dev/build/test/lint 脚本；首装用 npm install 类
- [ ] 规避/转义渲染器 {{ }}；源码无 `{{{{` 泄漏
- [ ] 不写 .gitignore；示例间无同路径
- [ ] tests/scaffold-panel 加 e2e（子目录文件 + 自带 Makefile + 无泄漏 + 根无污染）
- [ ] catalog / 相应预设登记；tests/scaffold-panel 全绿

---

## 7. 关联与待议

- 根目录如何聚合多个示例（root make build/test/dev 一键遍历各子目录、CI 一条命令全量）：**另行讨论**，本规范先保证“每个示例自带 Makefile、各自可跑”。
- 预设只组合 stage（模板只属于 stage），见 docs/scaffold-stages-presets-audit.md 结论。
