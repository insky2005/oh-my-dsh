# AGENTS.md — Agent 工作指引

> 本文件供 AI 代理（如 DeepSeek Harness 会话）在进入本仓库时快速了解上下文。
> 维护方式：与 `.dsh/wiki/` 同步更新（可用 repo-wiki skill 做增量刷新）。

## 项目是什么

**oh-my-dsh**：把 DeepSeek Harness 的 Web 界面（`dsh web`）封装成原生 macOS App 的壳层。

- **只封装、不修改** DeepSeek Harness 上游源码；
- 完全自包含：内置 Node 运行时 + `@deepseek-ai/dsh` 依赖树；
- 启动复用 `127.0.0.1:3080` 已有服务，否则自拉起；退出只清理自己拉起的服务。

## 先读什么

- `.dsh/wiki/index.md` 与 `.dsh/wiki/conventions.md` —— 工程约定（L10n / 构建 / 测试 / 日志）；
- `docs/productization.md` —— 产品化总纲（路线图 / 分发 / 升级 / 多平台 / 开源治理）；
- `docs/milestones/` —— 各里程碑目标（M1 产品化基础 … M5 Apple 生态）；
- `README.md` —— 安装 / 构建 / 环境变量。

## 关键约束

1. **绝不改动 DeepSeek Harness 源码**；扩展只走壳层面板 + dsh 既有能力；
2. 自包含优先：构建不复制本机 node/dsh；退出只清理自己拉起的服务；
3. 版本号单一来源：`build-app.sh` 从 git tag 读取 VERSION，BUILD 由 CI 注入；
4. 新增文案必须中英双语成对（`main.swift` 的 `L10n.table`）；
5. 新增 Swift 文件必须登记进 `build-app.sh` 编译清单；
6. 面板 UI 遵循 `PreviewPanel.swift` 基件约定；layer-backed 合成陷阱见 `docs/terminal-header-fix.md`。

## 测试

```bash
tests/terminal-emulator/run.sh   # ANSI 模拟器单测（P1 起迁入 core/tests/）
tests/wiki-panel/run.sh          # Wiki 面板模型层单测
```

提交前保持全绿；CI 会在 push/PR 自动跑（macOS arm64/x64/Universal）。

## 提交规范

conventional commits（`feat(term): …` / `fix(upgrade): …` / `chore(version): …`），见 CONTRIBUTING.md。
