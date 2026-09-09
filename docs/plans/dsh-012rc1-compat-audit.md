# dsh 0.1.2-rc.1 升级兼容审计（壳层 ↔ dsh web 交互）

> 分支 feature/dsh-upgrade-staged。目标：把内置 dsh 升到 0.1.2-rc.1，并让 oh-my-dsh 各面板与 dsh web 的交互在新接口/新鉴权下恢复。
> 状态基准：已在真机（dev 隔离 ~/.dsh-dev）把内置 dsh 升到 0.1.2-rc.1 验证启动与鉴权。

## 一、背景与决策
- **dsh 0.1.2-rc.1 两大变化**（已实测）：
  1. **Web 界面加每实例鉴权**：裸 GET / → 401；GET /?token=… → 303 + 种 dsh-auth-* cookie，带 cookie → 200。
  2. **内部 API 换代**：老 POST /api/session.list（client-request 信封）→ 401 / 带 cookie 也 404；改为控制器式 RPC（/api/session-controller、/api/workspace-controller 等，Cordis Gateway + 流式）。
- **决策（建议）**：内置 dsh 升级到 0.1.2-rc.1，壳层以 0.1.2-rc.1 为目标适配，不再维护老版本双兼容。改动点见四。

## 二、壳层 ↔ dsh web 交互清单与影响
| # | 交互面 | 机制 | 0.1.2-rc.1 影响 | 状态 |
|---|---|---|---|---|
| A1 | 服务拉起就绪 + WebView 加载 | ServerManager.start()、webView.load(url) | 需读 dsh 打印的带 token 地址 | 已修（servedEntryURL） |
| A2 | 复用外部已启动 dsh web（非自拉起） | 复用 3080 返回裸 URL | 外部 0.1.2 需 token → 401 | 遗留（待取 token） |
| B1 | 会话 cwd / 活跃会话工作区 | native DSHSessionRPC POST /api/session.list | 401 / 404 | 已坏（本次主诉） |
| B2 | 具体会话 cwd | 同上 fetchSessionCwd | 401 / 404 | 已坏 |
| B3 | 项目目录解析 | resolveProjectDirectory → B1 | 拿不到 cwd → nil | 受影响 |
| C1 | 频道 runner（ohmy-core channel run）| 子进程 HTTP 到 dsh web 端口，走会话 RPC | 传输/鉴权变更 → 风险 | 待核 |
| D1 | 会话切换跟踪 | 注入 sessionTrackerScript 拦 fetch /api/* 的 client-request（session.*/subagent.list）| 若客户端改传输（Gateway/stream）则拦截不到 | 待核 |
| D2 | 面板→打开 dsh 会话 | 注入 sessionOpenerScript：POST /api/session.list 查标题→DOM 点行 | session.list 404 → 查标题失败 | 已坏（DOM 点行或仍可用） |
| D3 | 预览文件打开 | 注入 previewInterceptorScript 拦 /api/host.openPath | 若客户端改文件打开 RPC 则拦不到 | 待核 |
| D4 | dsh 设置跳转 | DOM 点侧栏 Settings（openDSHSettingsJS） | 无关 API，纯 DOM | 不受影响 |
| E1 | WebView 重载/兜底 URL | 3428 / 4012 处用裸 http://127.0.0.1:<port> | 0.1.2 裸地址 401 | 需改用带 token 基址 |
| F | About / registry / 升级 | 与 npm registry 交互，不走 dsh web API | 无关 | 不受影响 |

## 三、结论要点
- **已确认坏**：B1/B2/B3（会话 cwd / workspace 读取）、D2 的标题解析（open session）。
- **高风险待运行时核对**：C1（频道）、D1（会话切换跟踪）、D3（预览打开文件）、E1（重载裸 URL）。
- 根因都是同一个：壳层以“裸 HTTP + 老 session.list 信封 + 无鉴权”的方式直连 dsh web，而 0.1.2-rc.1 改为“鉴权 cookie + 控制器/Gateway 传输”。

## 四、建议的改造方案（以 0.1.2-rc.1 为目标）
1. **内置 dsh 升到 0.1.2-rc.1**：build-app.sh 的 DSH_PACKAGE_SPEC 默认改为 @deepseek-ai/dsh@0.1.2-rc.1（两处 spec + 打印行；README/productization 的当前固定版本一并更新）。
2. **建立“鉴权基址”**：ServerManager 保存 dsh 打印的带 token 基址（如 http://127.0.0.1:<port>/?token=…），供 WebView 加载、native 直连、reuse 兜底、E1 重载统一使用。
3. **会话/工作区读取改为「webView 内桥接」**（最不依赖上游内部接口）：在已鉴权 webView 内用 dsh 新客户端现有数据（活动会话 workspace/根目录）取 cwd 桥回壳层，替换 native DSHSessionRPC 的 session.list。
4. **注入脚本按新传输重写**：sessionTracker / sessionOpener / previewInterceptor 若发现 fetch 信封/路由已变，改挂钩新客户端暴露的全局状态或新 RPC；D2 不再依赖 /api/session.list（webView 内直接拿 title）。
5. **频道 runner 与会话直连**：核对新鉴权/传输后统一加 cookie/新信封。

## 五、验证
- 用 dev 隔离把内置 dsh 定到 0.1.2-rc.1，逐一走：启动、切会话（D1）、面板点开会话（D2）、文件预览打开（D3）、会话所在项目目录里的终端/wiki/tasks 定位（B3）、频道消息/会话（C1）、重载后仍可用（E1）。
- core 单测 + swift 编译全绿；scripts/local-ci.sh dev 通过。

## 六、待确认/上游依赖
- 需要从运行中的 0.1.2-rc.1 客户端确认：文件打开、会话切换、会话 workspace 在新传输下走哪个全局/接口（决定四.3/4 的具体挂钩点）。
- 0.1.2-rc.1 若仍为 RC 可能继续变；锁定后按此适配，后续 RC 变化走本表复核。
