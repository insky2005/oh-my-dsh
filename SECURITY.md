# Security Policy

## Supported Versions

本项目维护最近 2 个大版本。安全修复会以 patch 形式合入 `main` 并随下一个发布 tag 分发（当前最新发布为 v1.13.0）。

| Version | Supported          |
| ------- | ------------------ |
| 1.13.x  | ✅ Supported       |
| 1.12.x  | ✅ Supported       |
| < 1.12  | ❌ End of life     |

## Reporting a Vulnerability

请**不要**在公开 issue 中报告安全漏洞。请通过私有渠道联系维护者：

- 创建 GitHub **Security Advisory**（仓库 → Security → Report a vulnerability），或
- 直接邮件维护者（见 CODEOWNERS / 仓库主页联系方式）。

报告时请附上：

- 受影响版本；
- 复现步骤（尽量最小化）；
- 影响面与潜在危害分析；
- 如已有修复建议一并提供。

我们承诺：48 小时内确认收到，评估后给出修复时间表；修复发布前不公开漏洞细节。

## Security Notes (本项目已知边界)

- 应用为**本地个人工具**：所有服务绑定 `127.0.0.1`，不对外暴露端口；
- 构建产物为 ad-hoc 签名（无 Apple 开发者账号），macOS Gatekeeper 会提示「无法验证开发者」——右键 → 打开即可；正式签名/公证在 M5 里程碑；
- 应用内置完整 Node 运行时 + `@deepseek-ai/dsh` 依赖树，升级只作用于应用包内的 `Contents/Resources/runtime/dsh`，**不触碰系统安装的 dsh/node**；
- `dsh web` 会话数据存放于 `~/.dsh`（`DSH_HOME` 可覆盖）；请勿将含密钥/口令的文件提交到本仓库（参见 `.dsh/wiki/conventions.md` 脱敏约定）。
