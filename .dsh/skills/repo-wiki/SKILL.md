---
name: repo-wiki
description: 为当前仓库生成/维护 .dsh/wiki/ 知识库（初始生成、增量更新、重建 index、陈旧标记）。Generate / maintain the .dsh/wiki/ knowledge base for the current repository (initial generation, incremental update, index rebuild, staleness marking).
modelInvocable: true
userInvocable: false
---

# repo-wiki — 仓库知识库生成/维护

为当前仓库维护 `<repoRoot>/.dsh/wiki/` 下的结构化 markdown 知识库。用户要求「生成/更新/维护知识库」时加载本 skill 执行。

## 执行方式（强制）
- **在当前会话内直接执行，绝不新建顶层会话**（不得 session.create / fork，也不得建议用户另开会话）；确需并行探索时可使用 subagent（子会话，不影响顶层会话归属）；
- **仓库根**：取当前会话的工作目录（`pwd`）；wiki 输出到 `<repoRoot>/.dsh/wiki/`，目录不存在则创建；
- **模式选择**：`.dsh/wiki/index.md` 存在 → 增量更新；不存在 → 初始生成。

## 页面结构（初始生成 ≤ 20 页，单页 ≤ 200 行）
- `index.md`：总索引（一句话简介 + 分节页链接 + 统计 + 最后生成时间）
- `overview.md`：技术栈、目录布局、构建/运行/测试方式
- `architecture.md`：分层、模块依赖、关键数据流、部署形态
- `modules/<name>.md`：每个主要模块/包一页
- `data-model.md`：核心数据模型/表结构/领域概念
- `conventions.md`：工程约定（命名、提交规范、代码风格、工具链）
- `tasks.md`：常见任务手册（如何加接口/发布/排查）

## 页面 frontmatter（每页必写）
```yaml
---
title: <标题>
tags: [a, b]
updated: <本次实际 UTC ISO8601>
sources: [<相对路径，列全依据文件或目录>]
manual: false
---
```

## 规则（强制）
1. 只写可从代码/文档证实的事实；不确定处标注「待确认」；禁止编造；
2. **增量更新**：先读 `index.md` 了解已有结构；用 `git status --short` + mtime 定位变更文件，只重写 `sources` 命中变更的页面；未变页面保持**字节不变**；git 不可用时退化为 mtime 扫描；
3. **sources 质量**：`sources` 列全该页依据的文件/目录（目录即可覆盖其子树）——它决定陈旧检测与后续增量更新的准确性，遗漏会导致页面无法被判定过期；
4. `manual: true` 的页面绝不改写；
5. 脱敏：跳过 .env*/密钥/口令/个人数据，示例一律占位符；
6. **不删除页面**：源码删除后在该页标注「已失效」而非删文件，留给用户审阅；
7. 完成后更新 `index.md` 的统计与最后生成时间；
8. **汇报**：简短列出本次生成/更新的页面（含新增 / 失效 / 手动跳过），不超过几行，不粘贴正文。