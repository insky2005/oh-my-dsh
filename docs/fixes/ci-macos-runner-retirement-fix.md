# CI 全部失败：macos-14 runner 镜像退役

> 日期：2026-11-19
> 状态：已实施（`.github/workflows/ci.yml` / `.github/workflows/nightly.yml` / `.github/workflows/release.yml` / `scripts/local-ci.sh` / `docs/research/productization.md`，分支 `fix/ci-macos-runner-retirement`）
> 现象版本：main（v1.16.4 之后）

## 现象

2026-11-19 起 CI / Nightly 全部不再变绿，日志里唯一的报错是：

```
The configuration 'macos-14-arm64-us-default' is not supported
```

且表现为**「取消」而不是「失败」**：run 结论是 `cancelled`，`core (Node)` 仍是 success，而所有 `runs-on: macos-14` 的 job 在 **8 秒内、无任何 step、无 runner** 的情况下被置为 `cancelled`，依赖它的 `swift tests` / `build` 因为 `needs` 被 skip。

## 排查

用 GitHub API 拉 run / job / annotation（`check-runs/{job_id}/annotations`）得到两条关键事实：

1. 注解 `The configuration 'macos-14-arm64-us-default' is not supported` 精确挂在 `labels: ['macos-14']` 的 job 上，`runner_name` 为空 —— 说明任务**在「排队 → 取机器」阶段就被拒**，从未开始执行（所以没有日志可看，只能看注解）；
2. 时间线吻合：最后一个绿的 run 是 2026-10-06（10-06 之后到 11-19 没有推送，所以中间没有失败记录），11-19 恢复推送后全部挂掉；Nightly 从 2026-11-05 起每日都是 `cancelled`。

对照 GitHub 2026-10-01 的公告：**macOS 14 runner 镜像于 2026-11-02 退役**，退役前有 10/5–10/6、10/12、10/16、10/19、10/23、10/26、10/29、10/30 的多轮 brownout；受影响标签为 `macos-14` / `macos-14-large` / `macos-14-xlarge`，官方推荐替代为 `macos-15`、`macos-latest`（= `macos-26`）及其 xlarge 版本。参见 [GitHub Changelog](https://github.blog/changelog/2026-10-01-github-actions-macos-14-runner-image-retirement/)。

`macos-14-arm64-us-default` 不是我们写的标签，它是 GitHub 内部对 macOS 14 / arm64 / 美国区 runner 配置的编号 —— 所以这条报错看起来「跟我们无关」，实际就是 `runs-on: macos-14` 打空了。

## 根因

`.github/workflows/` 里所有 macOS job 都钉在已退役的 `macos-14` 上（此前从 `macos-13` 迁到 `macos-14` 时只改了标签，没有留「镜像会过期」的机制）：

| 文件 | 位置 |
|------|------|
| `ci.yml` | L35 `prepare`、L63 `swift` matrix、L148 `build` matrix |
| `nightly.yml` | L18 `smoke` |
| `release.yml` | L21 `prepare`、L49/L51 `build` matrix（arm64 + x86_64） |

## 修复

统一改为 **`macos-15`**（而非 `macos-latest`：`macos-latest` 已漂到 `macos-26`，镜像内 Xcode/工具链变化更激进；等需要时再显式升级，届时同样是改 5 处）。

版本约束不受影响，无需改构建脚本：

- `platforms/macos/build-app.sh` 用 `-target arm64-apple-macos13` / `x86_64-apple-macos13` 显式交叉编译；
- `platforms/macos/build-cef.sh` 用 `-target <arch>-apple-macos13`；
- `Info.plist` 的 `LSMinimumSystemVersion` 亦是 macos13。

即 macOS 15 镜像上产物与之前一致（arm64 + x86_64，x86_64 仍在 arm64 机器上交叉编译，不依赖已退役的 `macos-13`）。

顺带同步了文档与本地脚本注释：`scripts/local-ci.sh`（与 CI 差异说明）、`docs/research/productization.md`（构建矩阵 + 参考资料）。`docs/milestones/M1-productization-foundation.md` 属历史里程碑记录，保留原文不追改。

## 验证

- 三个 workflow 用 Ruby Psych 解析通过，`prepare` / `smoke` 均为 `macos-15`，matrix `runner` 值亦为 `macos-15`；
- 本 PR 的 CI run 即为端到端验证：`prepare`（双架构 CEF 预编译 + prefetch）→ `swift tests` → `build (arm64)` 应全部跑起来；Release workflow 需打 tag 才能验证 x86_64 交叉构建路径。

## 教训 / 后续

- 这类失败**不看 workflow 日志就能定位**：先看 job 的 annotation（`check-runs/{id}/annotations`），再看 `runner_name` 是否为空 —— 空即「没取到机器」，与代码无关；
- GitHub 的 runner 镜像有生命周期（约 2–3 年），建议后续把「workflow 里出现已退役 macOS 标签」做成 lint（参照 `tests/l10n/run.sh` 的轻量 lint 形态），在镜像退役前主动报警，而不是等全红。
