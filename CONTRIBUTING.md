# Contributing to oh-my-dsh

感谢你愿意为 oh-my-dsh 贡献！这是一个把 DeepSeek Harness（`dsh web`）封装成原生 macOS 应用的开源项目。
在提交 PR 之前，请花几分钟读完本指南。

## 项目结构（P1 起）

```
oh-my-dsh/
├── LICENSE  README.md  CHANGELOG.md  CONTRIBUTING.md  SECURITY.md
├── .github/             # workflows / ISSUE_TEMPLATE / CODEOWNERS
├── core/                # 共享核心（Node 模块）：端口探测 / 服务管理 / 升级 / 会话 RPC / ANSI 模拟器
├── platforms/
│   └── macos/           # macOS 壳：src/ + build-app.sh + make-pkg.sh
├── scripts/             # 跨平台工具（版本读取 / CHANGELOG 生成 / 校验和）
├── tests/               # 跨切面集成 / QA 测试
├── docs/                # 设计文档（productization.md 等）
└── .dsh/                # wiki / skills（随仓库提交）
```

> 迁移说明：P1 期间 `src/`、`build-app.sh`、`make-pkg.sh` 正从仓库根迁入 `platforms/macos/`，
> 提交时以 `git status` 实际位置为准。

## 环境要求（构建）

- macOS 13+（Apple Silicon；CI 会同时验证 x64 与 Universal）
- Xcode Command Line Tools（`swiftc`、`codesign`、`iconutil`）
- `curl`、`python3`，以及网络（构建期下载 Node + 从 registry 安装 dsh）

```bash
./platforms/macos/build-app.sh --prefetch  # 可选：预下载 Node + 预装 dsh 到 .cache/
./platforms/macos/build-app.sh             # 全量构建 → dist/oh-my-dsh.app
./platforms/macos/make-pkg.sh             # 生成 .pkg / .dmg
```

## 运行测试

```bash
# 模拟器单测（核心，headless）
tests/terminal-emulator/run.sh          # P1 起迁入 core/tests/

# Wiki 面板模型层单测
tests/wiki-panel/run.sh
```

CI（`.github/workflows/ci.yml`）会在 push/PR 时跑完整测试矩阵（macOS arm64 / x64 / Universal），
并做 `swiftc` 编译检查。本地提交前请确保 `run.sh` 全绿。

## 提交规范

沿用 conventional commits：

```
feat(terminal): support bracketed paste toggle     # 新功能
fix(upgrade): retry official registry on failure   # 修复
docs(productization): add release checklist        # 文档
chore(version): bump to v1.8.0                     # 构建/版本
test(core): migrate emulator tests into core/      # 测试
```

- 一个 PR 一个主题，保持小而可审查；
- 新增面向用户的文案必须中英双语成对（见 `.dsh/wiki/conventions.md` 的 L10n 约定）；
- 新增 Swift 文件必须在 `build-app.sh` 的编译清单里登记；
- 新增面板需配套模型层单测（`tests/<name>/run.sh` 模式）。

## PR 流程

1. Fork 本仓库（或直接开分支，`trunk-based` 开发）；
2. 从 `main` 拉分支：`git checkout -b feat/your-change`；
3. 提交并推送，开 PR 到 `main`；
4. CI 全绿 + 至少 1 位 CODEOWNER 审查后合并；
5. 合并后由维护者打 tag（`vX.Y.Z`）触发发布流程（`.github/workflows/release.yml`）。

## 行为准则

- 尊重所有人，讨论聚焦技术；
- 不引入与 DeepSeek Harness 上游源码的耦合改动——本项目**只封装、不修改** `dsh`；
- 涉及安全问题的报告请走 `SECURITY.md` 的私有渠道，不要发公开 issue。

## 资源

- 设计总纲：`docs/productization.md`
- 里程碑：`docs/milestones/`
- 工程约定：`.dsh/wiki/conventions.md`
- 版本发布规划：`docs/productization.md` §4.6 / §11
