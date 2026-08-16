---
title: oh-my-dsh 仓库知识库
tags: [wiki, index, oh-my-dsh]
updated: 2026-08-16T13:10:06Z
sources: [README.md, .dsh/skills/repo-wiki/SKILL.md, platforms/macos/src/IssueRunnerPanel.swift, core/lib/issues.js, core/lib/jobqueue.js, core/lib/tasks.js, core/tests/issues.test.js]
manual: false
---

# oh-my-dsh 仓库知识库

一句话简介：**oh-my-dsh** 是把 DeepSeek Harness 的 Web 界面（`dsh web`）封装成 macOS 原生 App 的自包含壳层（WKWebView 壳 + 内置 Node/npm/dsh 运行时），不改动任何 DeepSeek Harness 源码。

## 分节页

- [overview](overview.md) — 技术栈、目录布局、构建/运行/测试方式
- [architecture](architecture.md) — 分层、模块依赖、关键数据流、部署形态
- [data-model](data-model.md) — 核心数据模型与领域概念（UserDefaults 键、RPC 信封、wiki frontmatter 等）
- [conventions](conventions.md) — 工程约定（不改源码原则、L10n、编译清单、QA 钩子、版本管理）
- [tasks](tasks.md) — 常见任务手册（构建/打包/测试/加面板/排查）

## 模块页

- [main（壳层核心）](modules/main.md) — 服务管理、升级、菜单、窗口与右栏插槽
- [preview-panel（预览面板）](modules/preview-panel.md) — 文件/文件夹预览、项目目录树
- [terminal-panel（终端面板）](modules/terminal-panel.md) — PTY 会话 + ANSI/VT 模拟器
- [wiki-panel（Repo Wiki 面板）](modules/wiki-panel.md) — 知识库生成/维护/浏览
- [issue-runner-panel（任务面板）](modules/issue-runner-panel.md) — GitHub issue 驱动的串行任务流水线（切分支→修复→推送→PR）
- [build-scripts（构建与打包脚本）](modules/build-scripts.md) — platforms/macos/build-app.sh / platforms/macos/make-pkg.sh / MakeIcon.swift

## 统计

- 页面数：12（含本页；模块页 6 个）
- 主要源码：`platforms/macos/src/`（6 个 Swift 文件）+ 共享核心 `core/`（Node 模块，含 issues/jobqueue/tasks 后 77 用例单测）
- 最近一次提交：`63525e3`（"feat(tasks): 完成后的 issue 支持「评论并关闭」…"）
- 工作区版本号：`1.8.0`（BUILD 64），版本单一来源（git tag vX.Y.Z → scripts/version.sh；见 [overview](overview.md)）
- 仓库新增文档：`docs/productization.md`（产品化方案：P0 已达成 → P1 开源/CI → P2 Windows → P3 Linux → P4 生态 → F Apple 生态暂缓，见 [overview](overview.md)）；`docs/milestones/`（M1 产品化基础 … M5 Apple 生态 5 份里程碑目标文档，README「目录」收录）；`docs/issue-runner-design.md`（任务面板设计 + 远程驱动预留 + 关联索引章节）
- 任务关联索引：`.dsh/tasks/index.json`（issue→branch→PR→state，随仓库提交）+ `local.json`（sessionId，gitignore），实现 `core/lib/tasks.js`（Node）+ `IssueRunnerPanel.swift` 的 `TaskIndex`（Swift），见 [data-model](data-model.md) 与 [issue-runner-panel](modules/issue-runner-panel.md)
- Wiki 提交：更新完成后由代理（repo-wiki skill）`git add` + commit（不 push，message 概括实际变更）；`WikiAutoCommit` 兜底（代理未提交时），见 [wiki-panel](modules/wiki-panel.md)

## 维护约定

- 本知识库由 dsh 代理按 `repo-wiki` skill（`.dsh/skills/repo-wiki/SKILL.md`）维护；
- 增量更新只重写 `sources` 命中变更的页面；`manual: true` 页面绝不改写；
- 内容只写可证实事实；`.env*`/密钥/口令一律不收录。

最后生成时间：2026-08-16T13:10:06Z
