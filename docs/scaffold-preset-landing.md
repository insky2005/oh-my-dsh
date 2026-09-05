# 预设骨架落地流程（定义：从场景到可维护的预设 + 验收卡 + golden tree）

> 文档性质：**流程规范** —— 规定「一个新预设骨架」如何从「场景想法」一步步落成一个「可验证、可评审、可持续维护」的预设（含默认参数、验收卡、golden tree、自动化守卫）。
> 定位口径：企业工程规范落地。配套：docs/scaffold-evaluation-scheme.md（评估维度）· docs/scaffold-stages-presets-audit.md（现状审计 + 预设推荐）· docs/scaffold-preset-catalog.md（预设清单）。
> 撰写：2026-08（按分支 feature/scaffold-workbench 现状）。

---

## 0. 目的与范围

本流程回答「一个预设骨架怎么才算落地」：不是把环节列一列就叫落地，而是要产出**四件套**：
1. 明确的场景与目标（target user + job + must-have）；
2. 环节组合 + 默认参数（开箱可用、跨环节自洽）；
3. 验收卡（可证伪的 correct 断言 + suitable 门槛）；
4. golden tree 基准（随模板改动能 diff 的权威产物树）+ 自动化守卫。

适用对象：新内置预设（改 ScaffoldPreset.builtin）或面向团队/自定义的预设（preset.yaml 文档），以及「为某预设补验收 / 补 golden」的后续工作。

---

## 1. 术语

| 词 | 含义 |
|---|---|
| 预设骨架 | 一组环节 + 每环节默认参数，渲染出一个目标项目的产物树 |
| 验收卡 | 某预设一份验收文档：correct 断言（能证伪、能跑）+ suitable 门槛（对目标用户必须成立） |
| golden tree | 某预设以一组固定参数渲染出的权威产物树，提交进仓库，供模板改动时 diff |
| correct | 事实 / 功能成立：产物能生成、格式有效、真能跑、跨环节自洽 |
| suitable | 价值 / 定位成立：对着写死的 target user + job + must-have 命中 |

---

## 2. 落地总流程（7 步）

    P0 场景定义 → P1 环节+默认参数 → P2 渲染 golden → P3 验收（correct+suitable 卡）
       → P4 落地形态（内置种子 / 用户预设）→ P5 自动化守卫（e2e 断言 + golden diff）
       → P6 评审与提交

| 步骤 | 做 | 产物 | 门禁 |
|---|---|---|---|
| P0 场景定义 | 写 target user + job + 3-5 条 must-have | 场景卡 | 写不清就不做（无 ground truth 无法评适合性） |
| P1 环节+参数 | 选最小正确单元，定默认参数 | 环节序 + 参数表 | 每环节单一职责、可独立勾选；默认参数开箱可用 |
| P2 渲染 golden | 用引擎渲染到临时目录并保存 | golden tree + expected manifest | 渲染 isValid、无 stage 错误 |
| P3 验收 | 跑 correct 断言 + suitable 门槛 | 验收卡（verdict） | 门槛未过不得进 P4 |
| P4 落地 | 内置种子 or 用户预设 + 文档卡 | 代码 / 文档 | 双语 name/desc、与 golden 一致 |
| P5 自动化守卫 | 在 tests/scaffold-panel 加 e2e 断言 + golden diff | 测试 + fixtures | tests/scaffold-panel 全绿 |
| P6 评审提交 | 分支、commit、review、CI | PR | CI 全绿 + review |

---

## 3. 每步细则

### P0 场景定义
- 一句话场景：给谁、解决什么 job。
- 3-5 条 must-have：该场景成立时必须为真的产物事实（这些就是 suitable 的 ground truth）。
- 例子（Vue3）：target = 前端工程师要起一个 Vue3+Vite+TS 仓；must-have = 1) 能 make dev 起本地 dev server；2) CI 跑 lint + 单测 + build；3) 产物含 package.json 与源码骨架；4) 规范与 Agent 入口就位。
- 退出标准：target + job + must-have 写清楚；否则回到「只做规范骨架」的定位再议。

### P1 环节与默认参数
- 选环节原则：最小正确单元（不把多环节焊死），先规范层（git/docs/agents/coding-conventions）再按需加栈（makefile/ci/docker/deploy）。
- 默认参数原则：能让组合「生成即最小可用」；语言维度与 docker.runtime / makefile.lang / ci 命令自洽；不留空 imageRepo 等会立刻坏的值（见审计 A7）。
- 落地输出：环节顺序 + 每环节非默认参数（其余继承环节默认）。

### P2 渲染 golden
- 用引擎渲染（引擎无头即可，参照 tests/scaffold-panel/run.sh 的编译方式）到临时目录；git init 等命令照跑。
- 检查 isValid / validationErrors / stageErrors / hints 为空。
- 把产物树保存到 fixtures，并生成一份 expected manifest（期望文件清单），供比对。

### P3 验收（验收卡）
见第 4 节 schema。原则：
- correct：每条都是可证伪断言，能跑（bash -n / make -n / 渲染断言 / AGENTS 自洽）。
- suitable：must-have 逐条对照产物；任一不满足 → verdict = 不适合，回 P1 或补环节。
- verdict 分级：可发布 / 需修 / 不适合（对应评估方案 D1-D8 与打分）。

### P4 落地形态
- 内置种子：ScaffoldPreset.builtin 加种子（id + 双语 name/desc + stageIds + paramDefaults），需要时补 L10n；加文档卡。
- 用户 / 团队预设：以 preset.yaml 文档 + 本流程产出交付，用户用预设编辑器导入自定义；不必改代码。
- 落地前用同一组参数再渲染一次，确认与 P2 golden 一致（防手抄错）。

### P5 自动化守卫
- 在 tests/scaffold-panel/scaffold-tests.swift 加 e2e：渲染该预设 → 断言关键文件 / 参数 / AGENTS 自洽 / 跨环节一致性。
- 把 golden tree 放入 fixtures，模板改动后跑 golden diff 判断是否需要更新与评审。
- 跑 tests/scaffold-panel/run.sh 全绿。

### P6 评审与提交
- 分支：功能新预设用 feature/，修补用 fix/（AGENTS 分支约定）。
- 提交：conventional commits；只含本次文件；不捎带他人改动（如 appkit-ui-layout-guide.md）。
- 评审重点：验收卡 verdict、golden 是否与产物一致、是否动了不应动的行为。

---

## 4. 验收卡 schema（每预设一份）

    # 预设验收卡：<id>
    ## 场景
    - target user：…  - job：…  - 定位口径：企业工程规范落地
    ## must-have（suitable 门槛）
    - [ ] 1 …  - [ ] 2 …  - [ ] 3 …
    ## 环节与默认参数
    | 环节 | 关键参数 | 说明 |
    ## correct 断言（可证伪）
    | 断言 | 怎么验 | 结果 |
    ## golden
    - fixtures 路径：tests/scaffold-panel/fixtures/<id>-golden/
    - 渲染参数（记录在 golden/params.json，供再生成）
    ## verdict：可发布 / 需修 / 不适合（附原因）

---

## 5. golden tree 约定

- 目录：tests/scaffold-panel/fixtures/<preset-id>-golden/，内含产物树 + params.json（该预设用的环节顺序与参数）+ expected.txt（期望清单）。
- 生成方式：引擎渲染（无头），git 命令照跑；用 params.json 复现。
- 比对：模板 / 环节改动后跑 golden diff；产物变化需说明并更新 golden（提交前评审）。
- 何时更新：修正正确性缺陷（如 A1-A3 那种）时预期变，更新 golden 并加断言；仅风格变化不得悄悄改 golden。
- golden 与引擎单测互补：单测锁断言语义，golden 锁整棵树。

---

## 6. 与评估方案 / 审计的关系

- 评估方案 D1-D8 是「评某一产物」的通用尺；本流程把「为一个预设做验收」落到每个预设身上（correct 断言 = D1-D5 可机器化部分；suitable 门槛 = D6-D8 + 定位）。
- 审计发现的 A1-A9 是「落地一个骨架前就应先满足」的已知坑：A1（派生键自洽）、A2/A3（docker/deploy 端口与镜像自洽）、A4（语言面一致）、A7（默认值可开箱）。新预设验收卡应显式排除同类问题。

---

## 7. 落地前速查清单（P0-P5 最后过一遍）

- [ ] target user + job + must-have 已写清
- [ ] 环节均为最小正确单元、可独立勾选
- [ ] 默认参数开箱可用、语言 / 形态自洽
- [ ] 渲染 isValid 且与 golden 一致
- [ ] correct 断言全过（bash -n / make -n / AGENTS 自洽 / 跨环节一致性）
- [ ] suitable must-have 全过（否则标记不适合并说明）
- [ ] e2e 断言已加、tests/scaffold-panel 全绿
- [ ] 双语 name/desc、conventional commit、未捎带他人文件
