# CI 冷缓存构建超时：CEF wrapper 编译无界并发

> 日期：2026-11-19
> 状态：已实施（`platforms/macos/build-cef.sh` / `.github/workflows/ci.yml` / `.github/workflows/release.yml` / `.github/workflows/nightly.yml`，分支 `fix/ci-macos-runner-retirement`）
> 现象版本：main（v1.16.4 之后）

## 现象

把 runner 从退役的 `macos-14` 换成 `macos-15` 后，PR 的 CI：

- `prepare (CEF + node caches)` 拿到机器、`actions/cache` 步骤正常，但第 4 步
  `Pre-build CEF artifacts (arm64 + x86_64) + prefetch node/runtime` 从 14:39 跑到
  20:42 —— **6h03m，正好是 GitHub job 的 6 小时硬上限**，被平台取消；
- 依赖它的 `swift tests` / `build` 全部 skip，run 结论 `failure`；
- 重跑（attempt 2）连机器都没拿到：`The job was not acquired by Runner of type hosted
  even after multiple attempts` + `Due to capacity constraints, jobs targeting macOS
  arm64 runners may experience longer queue times`（macOS arm64 托管机容量紧张，属另一回事）。

## 排查

关键事实链：

| 事实 | 来源 |
|------|------|
| prepare 的第 4 步单步跑了 6h03m 后被平台取消 | job 的 step `started_at` / `completed_at` |
| 历史 Nightly（**无缓存**、冷构建）在 macos-14 上成功耗时 **1h03m–2h04m** | Nightly run 历史 |
| 本机（10 核）用 `DSH_CEF_JOBS=4` 重编 x86_64 wrapper：**57 秒**（CPU 2m09s） | 本地实测 |
| `build-cef.sh` 编译 wrapper 时对**每个** `.cc/.mm` 都 `clang++ ... &`，**一次性起 ~300 个进程** | 源码 |

结论：编译本身只要几分钟 CPU 时间，但**并发度是文件数**。本地/大机器上侥幸能跑；
在 GitHub 的 **3 核 / 7GB** macOS runner 上，300 个 clang++ 会互相抢内存并疯狂 swap ——
表现为「单步跑几个小时不结束」，这与 6h 上限完全吻合（Nightly 冷构建 1–2h 也是同一毛病的轻症）。

另一个次生问题：`ci.yml` 的 prepare 与 `release.yml` 的 prepare 调 `build-app.sh --prefetch`
时**没有传 `DSH_NPM_REGISTRY` / `DSH_NODE_MIRROR`**（build / nightly job 都传了），
于是美国 runner 上冷缓存会用默认的 npmmirror 装整棵 dsh 依赖树。

## 修复

1. **`build-cef.sh` 编译限流**：并发上限 `${DSH_CEF_JOBS:-$(sysctl -n hw.ncpu)}`（CI 3 核 → 3），
   FIFO 等待（`wait ${PIDS[0]}` + 出队），任一失败立即 kill 其余并 `exit 1`。
   本机大机器想跑满可 `DSH_CEF_JOBS=64`。
2. **prepare 拆成独立 step**（CEF arm64 / CEF x86_64 / prefetch runtime），各带
   `timeout-minutes: 30`，job 级 `timeout-minutes: 90` —— 以后哪一段慢/挂，UI 上的
   step 耗时就够定位，不必等日志；也不会再吃满平台 6h。
3. **prepare 补官方 registry / Node 镜像**：`DSH_NPM_REGISTRY=https://registry.npmjs.org`、
   `DSH_NODE_MIRROR=https://nodejs.org/dist`（与 build / nightly 一致）。
4. **job 超时**：ci `swift` / `build` 120 min、nightly `smoke` 180 min、release `prepare` 90 min /
   `build` 120 min —— 卡死快速失败而不是空转 6h。

## 验证

- 语义自测：限流循环在 bash 3.2（macOS 自带）下实测最大并发 ≤ 上限、失败能正确冒泡；
- 本地冷编 `build-cef.sh x86_64`（`DSH_CEF_JOBS=4`）**57s** 完成，产物 `libcef_dll_wrapper` 4.1M、framework 318M；
- PR 的 CI run 作为端到端验证：prepare 的三个 step 各自耗时应落在分钟级。

## 教训

- 无界 `&` 并发在本地是「更快」，在 CI 小机器上是「更慢」甚至「看起来卡死」；
  跨环境的并行度应该显式跟随 `hw.ncpu`（或环境变量）而不是文件数；
- 长跑 job 一定要有**低于平台上限**的 `timeout-minutes`，否则唯一的信号是 6 小时后
  的「被取消」，日志还可能取不到（cancelled job 的日志 blob 经常 404）；
- 同一个变量（registry / mirror）在不同 job 里传一半，是最容易埋雷的写法：
  冷缓存时差异才会暴露。
