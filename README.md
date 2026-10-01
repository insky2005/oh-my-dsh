# oh-my-dsh — DeepSeek Harness 原生 macOS 壳

把 DeepSeek Harness 的 Web 界面（`dsh web`）封装成一个可以在 macOS 上**直接双击运行**的原生 App。
**不改动任何 DeepSeek Harness 源码**——它只是一个壳：内置运行时自拉起 `dsh web`，用原生 `WKWebView`
呈现界面，并在窗口右侧提供九个原生面板（项目 / 文件 / 终端 / 浏览器 / Repo Wiki 知识库 / 任务 / 通道 / 审查 / 技能）。

## 特性一览

- **完全自包含**：App 内置 Node 运行时（含 npm）+ 完整的 `@deepseek-ai/dsh` 依赖树，**不依赖本机安装的 node 或 dsh**，拿到即可用（全新机器也能跑）；
- **总是自拉起自己的服务**：用内置运行时**自己拉起** `dsh web`（默认 3080，被占用自动换空闲端口），就绪后装进原生窗口。**从不复用**别的实例——dsh ≥ 0.1.2 的 `/api` 只认「由本进程 launch token 换来的 cookie」，复用别人的实例拿不到 token，会让所有原生 RPC（wiki 生成 / 任务面板 / 会话目录）401 静默失败；同 `DSH_HOME` 下数据本就共享，自拉起不丢任何东西；
- **退出只清自己的**：Cmd+Q、关窗口、`kill`（SIGTERM/SIGINT/SIGHUP，含注销/关机）都会触发清理，关掉**自己拉起的**服务（优雅退出，3 秒内未退出则 SIGKILL），绝不干扰外部实例；
- **dsh 可升级（含自动升级）**：设置菜单「检查并升级 dsh…」(`⌘U`) 为**分步升级**——检测到「当前 vA → 可升 vB」→ 确认 → 后台把 vB 预热进缓存（可取消）→ **再次确认**才原地安装 + 重启；升级前整树备份、失败自动回滚；「自动升级 dsh」默认开启，每次启动最多检查一次（24h 节流），**不阻塞启动**（后台检测下载、下载完成后弹窗请用户确认）；
- **中/英界面**：设置 →「语言」可选「系统 / 中文 / English」（默认跟随系统），可记忆；`DSH_LANG=zh|en` 强制指定；切换联动刷新 dsh web 页面语言（会话在服务端不受影响）；
- **registry 可配置，默认国内源**：检查/升级走 npm registry，默认 `https://registry.npmmirror.com`，可在「设置 dsh registry…」里改（运行期），构建期用 `DSH_NPM_REGISTRY` 覆盖；
- **首次引导 onboarding**：首次启动展示欢迎说明（内置运行时/自包含原理/上手提示）；
- **关于面板**：App 菜单 →「关于 oh-my-dsh」显示 App 版本、build、依赖的 dsh 版本与运行时来源、Node 版本+路径、dsh registry。
- **通道面板（远程驱动）**：绑定微信个人号（官方 iLink 协议）或钉钉（dingtalk-stream 原生适配器），在微信/钉钉里发消息 / 斜杠指令远程驱动 dsh 干活——消息路由到项目会话、结果回复回原平台；扫码登录、项目开关、会话列表均在面板内完成。
- **技能面板（Skills）**：在壳层里管理 agent 技能——**查找**（registry 清单 / 关键字搜索 / 已装技能搜索）、**安装**（清单勾选 / 输入地址 / 手动导入本地目录）、**移除**，并按 **内置 / 用户级 / 共享级 / 项目级** 标注每个技能；非内置技能可切换 `user-invocable` 与 `disable-model-invocation`（写回 `SKILL.md` frontmatter，重启后保持）；registry 可配置（skills.sh 搜索型、well-known 清单、GitHub 仓库清单）。
- **页面刷新自愈（`⌘R`）**：长时运行后 WebView 手里那份 cookie 可能不再被接受（页面只显示一行 `dsh web authentication required…`，而各面板照常可用）。视图菜单「**重新加载页面** `⌘R`」改走带启动 token 的入口地址**重新认证**（不再依赖那份 cookie），主框架遇到 401 / 加载失败还会**自动自愈一次**（自己拉起的 dsh web 已死则重拉）；
- **审查面板（只读审计）**：直接读 dsh 落盘的会话日志，按 会话 → 对话 → 文件 → 变更内容 列出代理到底改了哪些文件、改成什么（标出每处改动是工具 hunk、参数还原还是仅全文写入），并显式列出 shell 直改与失败的调用——**只读、不写任何文件、不发任何请求**。

## 右栏面板

窗口**最右侧是活动栏**（图标入口，九个面板互斥切换，**首位是「项目」**），右侧面板顶部为统一背景条与布局，图标按钮在深浅色下均可见。

所有原生面板**共用一套灰阶配色**（面板底色一档 + 控件常态/高亮两档，全部取自 dsh web 的 `neutral bluish` 设计令牌），深浅两套主题一一对应；**单一事实来源为 `PanelSurface.swift`——改色只改这一个文件**，方案见 [`docs/ui-color-scheme.md`](./docs/ui-color-scheme.md)。

「视图」菜单提供九面板的显示/隐藏快捷键（首项即「项目」）。

### 项目面板（`⌥⌘P` / 活动栏首位「项目」图标）

把「工作区 = 一个目录」变成壳层里的一等公民：**在面板里建目录、再用六个面板就地打开它**。

- **项目根目录可配置**：默认 `$DSH_HOME/oh-my-dsh/projects`（开发版 `~/.dsh-dev/…`），面板头部「更改…」或设置窗口的「项目」区块都能改（存 `oh-my-dsh/shell/config.json` 的 `projectsRoot`）；**只有新建工作区时才会创建目录**，单纯打开面板不写盘；
- **新建工作区**：只输入目录名（如 `abc`），面板 `mkdir` 后调 dsh 的 `workspace/create` **幂等注册**——注册失败（dsh 未起来 / 旧版本）只标「未注册」，目录保留，之后在卡片上点「创建 dsh 工作区」重试即可；
- **每个工作区一张卡片**：名称 + 徽标（已注册 · N 个会话 / 未注册）+ 标题行右侧的**那一个 dsh 动作按钮**；第二行是路径紧跟着「在 Finder 中显示 / 复制路径」两个小按钮（贴路径文本，不右对齐）；第三行是六个面板入口。面板右上角的 `folder+` 同样是「添加工作区 / Add workspace」（输入目录名即建目录并注册）。**未注册的目录不与 dsh web 联动**（点卡片/「新会话」都不可用，只在状态行提示），徽标后面显示 **folder+ 图标 =「添加工作区 / Add workspace」**（与 dsh web 同词），点它把该目录注册进 dsh；**已注册**的徽标后面则是 **+ 图标 =「新会话 / New Session」**。两种状态下**六个本地面板入口都照常可用**。已注册的卡片：
  - **文件 / 终端 / 知识库 / 任务 / 通道 / 审查** 六个快捷入口：点一下就把壳层当前工作区切到它并打开对应面板（终端 cwd、文件树根、wiki 根、任务/通道/审查的工作区一起跟着走）；
  - **新会话**（标题行 `+` 图标）：在该工作区建一条 dsh web 会话并切过去（先 `session/create { workspaceId }` 保证归属分组，被拒退回 `cwd`）；
  - **在 dsh 中打开**（点卡片名称）：复用该工作区**最近一条会话**（运行中优先），没有则新建；
  - 在 Finder 中显示 / 复制路径；
- **单一真相**：当前工作区始终是壳层的 `ProjectDirectory`（面板只做高亮）——在 dsh web 里切到别的工作区的会话，面板也跟着换根，两边不会各说各话；
- dsh web 侧边栏有延迟时（刚建好的工作区/会话）：面板先 nudge 客户端、桥内部重试、再补一次；**始终不会自动重载页面**——定位不到时在状态行说明原因（侧栏现场会写进 `app.log`），由你决定手动刷新。

### 文件面板（`⌥⌘F` / 活动栏「文件」图标）

点击 dsh web 对话中的文件链接（`read`/`write`/`edit` 工具行、「Files changed」产出文件行，以及 turn 末尾 `present` 交付文件卡片）不再由 dsh 自带侧栏或系统默认应用打开，而是在壳层文件面板内预览。

- 面板**左侧是项目目录树**：自动定位当前项目目录，目录可展开、点文件即预览，树宽可拖拽**并被记住**（关闭面板再打开、切到别的面板再切回来都不会丢，也不会被框架重排挤成上限宽度）；
- **目录树右键菜单**：目录上「新建文件夹 / 新建文件 ｜ 重命名 / 删除（移到废纸篓，可恢复）/ 在 Finder 中显示」，**文件上不提供新建项**；重命名与删除后已打开的页签跟随改名或关闭。项目目录可用外部应用打开；
- **无后缀 / 点文件也能查看**（如 `LICENSE`、`Makefile`、`.gitignore`、`.env`）：内容可被 UTF-8 解码且非二进制即按文本预览；
- **代码 / 文本支持编辑**：UTF-8 且 ≤2MB 的文件可在面板内直接编辑，左侧**行号栏**随滚动严格对齐，头部「保存」按钮 + `File ▸ 保存`（⌘S）原子写回；未保存时页签文件名后显示 `*`，保存后消失；
- **语法高亮**：内置 highlight.js（经 vendored Highlightr，MIT），180+ 语言，明暗自适应；**大文件不再关高亮**（改为分块着色，3000+ 行照样着色且不卡 UI）；图片 / PDF / 文件夹列表 / 未知类型（图标 + 元数据）按类型预览；
- **图片预览自适应 + 手动缩放**：打开即**按比例适应窗口**（不放大超过 100%），可用触控板**捏合**、`⌘+` / `⌘−` / `⌘0`、`⌘`+滚轮、**双击**（适应窗口 ↔ 100%）缩放，放大后可拖拽平移；范围 5%–1600%、单步 ×1.25，右下角有百分比角标；
- **多文件以页签切换**，可关闭（`File ▸ 关闭页签` ⌘W）；面板头部是「**打开项目 ▾ / 当前文件 ▾**」两个菜单按钮（点开定位项目目录、切换当前文件，RPC 失败时回退手动选文件夹；「打开文件」仅在选中文件时可用），另有「保存」「在默认应用中打开」「在 Finder 中显示」「关闭」；
- **页签按工作区记忆**：在 dsh web 切换工作区时关闭并记下原工作区的页签（顺序 + 选中项），切回时按原样重开；未保存修改会先问「保存并切换 / 不保存」；
- **打开文件实时刷新**：已打开的页签在磁盘内容变化后自动刷新——代理（或任何进程）改写打开的文件时，可编辑页签经 `reloadFromDisk()` 保留滚动位置、且不覆盖未保存的本地编辑（dirty 页签跳过），只读文本 / 图片 / PDF / 元数据页签直接重渲染（与 Wiki 面板 2s 轮询刷新一致），打开即所见最新内容；**大文件（3000+ 行）改为异步读取 + 单次高亮**，磁盘变更后重新加载不再卡住应用；
- 面板宽度可拖拽并记住，且**自动保证 WebView 宽度 ≥1100pt**（dsh web 低于 1024pt 会自动收起左侧会话栏）；
- 纯 WebView 侧注入实现，不改任何 DeepSeek Harness 源码。

![files](./docs/screenshots/files.png)

### 终端面板（`⌥⌘T` / 活动栏「终端」图标）

右侧打开一个**真实交互的 shell**（原生 PTY，默认 `$SHELL -l`，如 `/bin/zsh`；`TERM=xterm-256color`）。

- **多标签页**：`+` 新建 / `✕` 关闭，默认编号「终端 1/2/3…」，OSC 标题自动更新标签名；`⌘1-9` 直切、`⌘⇧[` / `⌘⇧]` 循环切换；**页签按工作区隔离并记忆**——在 dsh web 切换工作区时同步跟随，切到没有终端的工作区会自动开一个，切回来还是原来那些；
- **全功能渲染**：16/256/真彩色、`vim`/`top`/`less` 等全屏程序的备用屏与滚动区（DECSTBM），窗口缩放列数自适应（`tput cols`）；**宽字符（中文/日文/全角）按整两格拉伸对齐**（等宽字体的 CJK 回退字宽只有约 1.6 格，不处理会和光标/后续文本错位），光标跨整个宽字符；
- **编辑体验**：鼠标拖拽选中 + `⌘C` 复制（无选区时 `⌘C` 发 SIGINT）、`⌘V` 粘贴（多行走括号粘贴，不会误执行）、`⌘A` 全选、`⌘K` 清屏、触控板滚动查看历史（方向与其余面板一致，带惯性）；**双击按词选中**，可在设置菜单里打开「终端：选中文本即复制」，选中即进剪贴板；
- **输入法直输**：原生 `NSTextInputClient` —— 中文/日文/韩文等输入法的候选窗跟随光标，预编辑（拼音）文本在光标处内联显示，回车/空格上屏直接送进 shell（不再需要 `⌘V` 粘贴）；
- 输入 `exit`（或 `⌃D`）正常退出并自动关闭标签页（最后一个标签退出则收起面板）；异常退出保留「会话已结束 + 重启」以便查看错误；
- 新会话默认在**当前 dsh 会话的项目目录**启动（服务就绪后解析，失败回退用户主目录）；退出 App 自动终止所有会话；
- **已知限制**：组合表情/零宽连接符按近似宽度渲染、会话不跨 App 重启保留。

![terminal](./docs/screenshots/terminal.png)

### 浏览器面板（`⌥⌘B` / 活动栏「浏览器」图标）

**多标签嵌入式 Chromium 浏览器**（CEF/Chromium 内核，每标签一个渲染进程），面向开发调试 web 页面与 Agent 排查网页问题。

- **多标签**：`+` 新建 / `✕` 关闭 / `⌘1-9` 切换，上限 8 个；地址栏导航（无 scheme 自动补 `https://`）、后退/前进/刷新·停止、标签标题随页面更新；启动恢复上次 URL；
- **渲染**：默认 **窗口化渲染**（CEF 视图原生合成；曾误设为 OSR，1.15.0 已改回）；如确需 **OSR 离屏渲染**（每帧像素自绘），在 `$DSH_HOME/oh-my-dsh/shell/config.json` 里设 `"browserRenderMode": "osr"`；
- **Chromium 原生 DevTools**：头部「DevTools」按钮弹出独立窗口的完整调试器（Elements/Network/Console/Sources）；
- **控制台/网络日志**：经 CDP 捕获页面 console、异常与网络请求，供 REST API 读取（`eval`/`screenshot` 也走 CDP；CDP 端口默认 `9333`，`DSH_CDP_PORT` 覆盖）；
- **Agent 驱动（curl 即用）**：壳层常驻 localhost REST API（默认 `127.0.0.1:3081`，端口文件 `~/.dsh/oh-my-dsh/browser-api.port`）——`status` / `open` / `tabs` / `back` / `forward` / `reload` / `stop` / `eval` / `console` / `console/clear` / `screenshot`(PNG) / `hide`，外加 QA 端点 `debug` / `hierarchy`；Agent 驱动时面板自动展开，截图可存工作区供读图/分享；配套技能 `web-dev-tools`（App 启动时安装到全局 `$DSH_HOME/skills/web-dev-tools/SKILL.md`，model+user 可调用）开箱即用；
- **说明**：CEF 构建体积约 +320MB/架构；Chromium 使用模拟钥匙串（`use-mock-keychain`，不弹密码框、不存网页密码）；profile 数据收在 `~/.dsh/oh-my-dsh/browser/`；随包分发 5 个 helper app（base/Alerts/GPU/Plugin/Renderer）；集成细节见 `docs/plans/BROWSER_PLAN-browser-panel.md`。

![browser](./docs/screenshots/browser.png)

### Repo Wiki 知识库面板（`⌥⌘W` / 活动栏「知识库」图标）

让 dsh 代理维护一份**随代码演进的结构化 markdown 知识库**（`.dsh/wiki/`，可随仓库提交/共享），新会话不再盲目重新探索代码库。

- **生成/更新**：右上「+」一键让 dsh 代理执行 `repo-knowledge` skill（App 启动时安装到全局 `$DSH_HOME/skills/repo-knowledge/SKILL.md`）——初始生成（index/overview/architecture/modules/data-model/conventions/tasks）或增量更新（只重写受影响页面）；经 `session.create` + `session.prompt`（queue 模式）触发，不阻塞对话，生成会话在 dsh web 左侧可见、可取消；状态条显示进度；
- **浏览**：左侧页面树（分组、过期/手动徽标）+ 右侧渲染后的 markdown（标题/粗斜体/代码/列表/链接，软换行保真）+ 反向链接区 + `dshwiki://` 页内跳转；标题过滤搜索；
- **维护**：陈旧检测（页面 `sources` 比 `updated` 新 → 标 ⚠）；`manual: true` 页面代理绝不覆盖（标 ✎）；可选写入项目根 `AGENTS.md` 注册块（设置开关，默认关）；「自动更新知识库」（默认关，≥3 页过期且 index 超 1 小时才触发，每小时最多一次）；wiki 根目录可选「仓库内 `.dsh/wiki`」或「`DSH_HOME` 私有」；
- **提交**：生成更新完成后自动 `git add .dsh/wiki` + commit（不 push；维护代理主提交，`WikiAutoCommit` 兜底）；
- 设计文档：`docs/repo-wiki-design.md`。**已知限制**：v1 搜索为标题过滤（无正文/语义检索）；知识由代理生成，质量取决于 dsh 代理能力。

### 任务面板（`⌥⌘J` / 活动栏「任务」图标）

任务台：**手动任务 + GitHub issue** 两种来源、**队列（泳道）** 串行执行，全部以**卡片**呈现。

- **卡片列表（布局对齐审查面板）**：内容区**第一行是统计卡**——整宽圆角卡里一行 `队列 12 · 排队 5 · 运行 1 · 失败 1`，**只有失败 > 0 时那一段变红**；其下每张任务卡的**标题与两枚徽标在同一行**（任务名**前面**一枚行标 `checklist`、**后面**是来源徽标 `Issue #12` / `手动`、最右是状态徽标：待处理 / 队列中 #n / 运行中 / 已完成 / 失败 / 已取消 / 已关闭），下一行是「标签 · 分支 · PR」元信息；**点卡片展开**详情（队列名 / 会话 / 错误 / 任务正文）与操作按钮（主操作 + 编辑/删除图标按钮）；标题行第二行标出当前工作区（GitHub 仓库显示 `owner/repo`；git 仓库没有 GitHub 远端显示 `目录名 · 非 GitHub 仓库`；目录根本不是 git 仓库则显示 `目录名 · 非 Git 仓库`，太长会省略号截断、悬停看全文），其下一行是来源筛选**扁平页签**（**全部 / 手动 / Issue**——手动排在 Issue 前面，顺序由 `TaskSourceFilter.allCases` 一处定义、标题也从它生成）——与技能面板同一套页签体例，判据由纯模型 `TaskSourceFilter` 给出：**泳道按「里面有没有这个页签认的任务」出现**（全部 → 不落下任何一条泳道；手动 → 用户自建的泳道都在，加上装着手动任务的自动队列；Issue → 只有装着 issue 任务的泳道）；**非 GitHub 工作区里 `配置 GitHub Token` / 刷新 Issues / 全部处理 三个按钮置灰**（它们本来就 guard 掉了 repo，点了不会有任何反应），tooltip 说明原因；卡片宽度撑满列表，窄面板下自动让位（标题/徽标截断），hover 提亮，选中（展开）与运行中各有一档强调边框；**队列是一块容器、卡片语法与审计面板同源**：泳道 = 抬起档（白）容器、队内卡片 = 下沉档（浅灰）、未入队卡片 = 抬起档，全部只有一条发丝描边（状态不再染边框，队列活跃 / 失败 / 已完成只看徽标）；卡片与队列头都用 chevron 符号开合，展开态不改底色或边框（只有**运行中**的卡片用审计面板「当前会话」那套 accent 淡填充 + 边框强调），因此"哪些任务属于这个队列"一眼可辨——队列头两行：名称 + 进度 + 状态徽标 + **图标按钮**（开始 / 暂停 / 开 PR / ⋯），下一行（展开时）是分支 → 基线 + 进度条 + 失败数；
- **手动任务（全程不弹对话框）**：页签行右侧的 **「＋」图标按钮**（空态里另给文字按钮「新建任务」）把一张**表单抽屉从内容区顶部下拉出来**（抽屉背后有一层**虚化背景**：`NSVisualEffectView` 模糊并压暗列表，抽屉与内容区因此分层）——**只有一个内容框：首行是任务标题，其余行都是任务描述（发给代理的指令），只有一行时这一行同时是两者**（`⌘↩` 创建、Esc 关闭），`创建` 后落在**未入队**区并**保持打开**（可连续录入，`完成` / Esc 关闭，抽屉滑回）；`编辑` 打开同一张抽屉并预填原值。**「新建队列」图标按钮（▣＋）**在同一个位置：队列名 / 分支（留空按队列名派生 `feature/<slug>`，中文名回退 `feature/queue-<id 前4位>`；想「就在当前分支上干」就勾上旁边的**「不切分支」**，非 git 工作区的新建表单默认就是它）/ 基于分支 / 队列完成后自动开 PR；卡片上的 **「加入队列 ▾」是和文件面板「打开项目 ▾」同一个下拉控件**（图标 + 文案 + chevron，菜单落在按钮正下方），**第一项固定是「新建队列…」**，其后才是已有队列 —— 选它新建的队列会**顺手把这一个任务入队**；队列头的**三个操作直接在行上**（图标按钮）：`gearshape` 队列设置（同一张抽屉改队列名/分支/基于分支/PR 开关）、`checkmark.circle.fill`/`circle` 完成后自动开 PR（**非 GitHub 工作区整块不显示**，已开着则显示但不可点并说明原因）、`trash` 删除队列；**`arrow.up.right.square` 打开 PR 永远在这一行的最右**（已经有 PR 时那一格就是 PR 链接），**打开 PR 只在队列头上**：卡片上的主按钮不再有「打开 PR」（用户 2026-09-27：PR 是队列跑完后由那个专门的会话开的，打开它自然也在队列那一行）——完成的 **issue 任务**主按钮是「打开 Issue」，完成的**手动任务没有主按钮**（没有任何待办动作，汇报就在详情里）；**只保留破坏性操作的确认框**（删除任务/队列、评论并关闭 issue）；**运行中/已完成的任务与 github 任务不可编辑删除**（2026-09-27 起代码与这句话一致了：还留在板上、还可能再跑的任务 —— 未入队 / 队列中 / 失败 / 已取消 —— 才有 编辑 / 删除，已完成的是**记录**）；**已完成的队列连 `gearshape` 队列设置与 `trash` 删除都没有**（改了设置也不会再跑），队列名与任务名前各有一枚**行标**（`rectangle.stack` 泳道 / `checklist` 任务，静态的第三档灰，紧挨名字）；
- **交接简报：一任务一会话，但队列里的下一棒知道上一棒做了什么**。每个任务一条自己的会话（上下文小、审查/取消/会话名都是任务级的），代价是"不连续"——所以队列里**第 2 个任务起**，提示词里会带一段 `## 队列信息`（与「开 PR 会话」同一套字段、同一个抬头）：队列与位次、分支与基线、分支上已有的提交、前面每一棒的标题/结局（含**失败与被取消**的）、**它在自己会话里的最后一段汇报（原样，不截断）**，以及分支上相对基线已有的提交列表（`git log --oneline`），末尾明确要求「不要重做已完成的部分，只做本任务」。汇报由壳层已有的会话日志通道取出（`ohmy-core brief report <sessionId>`，复用 `core/lib/review-log.js` 的解码能力，读 `$DSH_HOME/sessions/...`）。读不到汇报时简报会写明「它没有留下汇报」，而不是假装上一棒什么都没说。
- **跨工作区作业台（2026-09-27 起）**：每个**有任务在跑**的工作区各自持有一个 runner —— **切到别的项目不再放弃跟踪**（此前切走会把正在跑的任务标成「上次运行被中断」，而它的 dsh 会话其实还在后台干活、跑完也没人更新卡片）。git 按工作树串行，所以不同工作区可以**同时**跑（A 改代码、B 跑测试互不干扰）。配套的三件可见性：① 活动栏小点表示「**任意**工作区在跑」；② 面板头部多出一个只在「别的工作区有任务在跑」时出现的图标，悬停列出「工作区 — 任务标题」，点开选中即把壳层切过去；③ 任务结束的提醒（Dock 弹跳 + 日志）里带**工作区名**。工作区只在**本次运行第一次加载**时对账（reconcile「上次运行被中断」），重复重建不再误判；空转的工作区会被放下（板子在磁盘上，切回去即重建）。
- **跑起来之后看得见**：活动栏「任务」图标在运行中带一个角落小点；任务在后台结束时 Dock 图标弹一下并留角标（聚焦即清，用户主动取消的不打扰）；运行中的卡片 meta 行第一项是**已运行时长**（`1:05` / `1:02:05`）；展开卡片可**直接打开该任务的会话**（`arrow.up.forward.app`，切到 dsh web）或**审查这次改动**（`doc.text.magnifyingglass`，把该会话交给审查面板；tooltip 就是「打开会话 / 审查改动」这两句短话）——此前卡片上的「会话：xxx」是死文本，两个按钮的 tooltip 也长到读不完；**点了立刻有反应**：状态行先说「正在打开会话…」，定位失败时**把原因说在这个面板的状态行上**（此前失败只说给项目面板听，用户在这个面板里看到的就是「点了没反应」），而且查找用的「正在打开」标记带超时（一次没回话的 bridge 调用不会再永久吞掉同一个会话的后续点击）；重启后被中断的任务与暂停的队列会用状态行说明一句，不再只写日志。
- **「全部处理」不再只管 issue（2026-09-27 起）**：它的语义是「把所有还在等的任务跑起来」——**每个任务各自一个单任务队列**（一条分支、一个 PR，和 issue 任务的形状一致），按板面顺序串行推进；issue 需要 GitHub，手动任务任何工作区都能跑 —— **包括不是 git 仓库的目录**：那里队列不设分支（流水线完全不碰 git，提示词只说壳层那一半「不会切分支、不会提交、不会推送」，**任务自己要求建仓库／提交时照做** —— 见下面「提示词按工作区的形状写」），已有的坏队列在重试时会被就地修好。批量 >1 时先确认，**确认框里写清这一步要做什么**（N 个任务各自一个队列与一条分支、串行执行、是否开 PR；非 git 目录则说不切分支也不开 PR）；按钮的 tooltip 只说这个按钮做什么（图标按钮没有文案，只能靠它），禁用时才多一句「没有待处理的任务」。可用性从「有没有 GitHub 仓库」改成**「有没有待办」**（没有待办就禁用，顺带修掉此前「点了没反应」的死点击），按钮挪到工具栏**第一位**（它才是这个面板的主操作）。**批量收的是「自己站着的」任务**：未入队的（`.pending`），加上**队列被删掉之后的失败 / 已取消任务**（它们回到未入队、卡片上只剩「加入队列」一个一个点，批量正该带上它们）；**仍在队列里的失败任务不归批量管** —— 那是泳道自己的事（重试 / 跳过并继续），全局批量不去悄悄复活一个被暂停的队列。
- **基线分支问 git，不写死 main（2026-09-27 起）**：采纳工作区时探测它的默认分支（推送远端 `github`>`origin`>首个远端的 `HEAD` → 本地 `main` → 本地 `master` → 当前分支 → 兜底 `main`），issue 任务的自动队列与队列表单的「基于分支」都用它——此前一律 `main`，默认分支是 `master`/`develop` 的仓库**第一个 issue 任务必然失败**（流水线第一步 `git checkout main`）。
- **任务超时 60 分钟且写在卡片上（2026-09-27 起）**：此前硬编码 30 分钟、悄悄掐掉长任务。现在默认 **60 分钟**，运行中的卡片直接显示「已运行 1:05（上限 60 分钟，到点会取消会话）」；需要更长可在壳层设置里覆盖 `tasksTimeoutMinutes`（5–1440 之间的整数，`~/.dsh/shell/config.json`）。
- **队列 = 泳道**：同一队列的任务**共享一个分支、按 FIFO 顺序执行**（后一个任务看得到前一个的 commit —— 依赖关系由分支累积表达）；**全局严格串行**（一个工作树一次只能在一个分支上）；队内失败/取消**暂停该队列**，卡片给「重试 / 跳过并继续」；**队列被删除后**，失败任务卡片的主操作直接变成「加入队列」（issue 任务则是「处理」）——已经没有队列可以重试进去了，不会再出现「点重试只是把卡片重置一次、再点一次才出现加入队列」的两跳；切到另一个队列前要求工作区干净（脏工作区拒绝启动并提示）；
- **issue 任务**：点「处理」自动建一个**单任务队列**（分支仍是 label 判定的 `feature/issue-N` / `fix/issue-N`），保留 v1 的「一 issue 一分支一 PR」；「全部处理」给每个 pending issue 各建一个，串行依次跑；
- **issue 任务与手动任务对齐（2026-09-27 起）**：两种来源现在**共用同一份提示词要求**（`TaskPrompts.requirements`），只有「头」不同 —— issue 头给**编号 + 标题 + 标签 + 正文**（此前只给标题，正文还得代理自己去 GitHub 拉），手动任务头给标题 + 描述。于是：issue 任务同样**只 commit、不提 push/PR**（旧版因为提示词指向 `issue-resolve` 技能、而技能停在「任务自己 push、面板开 PR」的旧政策里，同一个面板里两种行为）；要求条目同样按工作区形状出现（非 git 目录没有分支条、非 GitHub 没有 token 条）；同样带队列交接简报。自动队列的形状也统一：非 git 目录里 issue 任务的单任务队列**不再派生 `fix/issue-N`**（此前写死分支，任务必然 `errNotGit`），旧队列带着切不了的分支时启动前先去掉。`issue-resolve` 技能随之**退役**（App 启动时删除受管的旧副本，用户自己改过的保留）；
- **任务只 commit，push 与 PR 交给一个专门的「开 PR 会话」（2026-09-27 起，第二轮）**：任务会话**只做本地 commit** —— 提示词里没有 push、没有 PR、没有「远端必须有这些提交」，也没有任何推送校验（旧版会因为「分支不在远端」把干完的活判成 `tasks.errNoPush`，那条路连同 `ls-remote` 检查一起删了）。队列**全部任务跑完**、且队列开着「完成后自动开 PR」、工作区有 GitHub 远端时，壳层**另起一个会话**：它先看这个分支到底改了什么（`git log/diff`），自己写 PR 标题与正文（要的是**总结**，不是模板），推送分支、开或复用 PR，并在最后一行给出 PR 链接 —— 壳层从它的汇报里读出链接写回队列（读不到就查这个分支上已有的 PR 兜底）。这个会话在 dsh 里就叫「开 PR：<队列名>」，可以像别的会话一样打开看。队列头的 `开 PR` 按钮走的也是这条路（不是直接调 API）；失败时原因落在队列上并显示在按钮 tooltip 里（`tasks.errPR` / 无分支 / 无远端 / 会话起不来），队列保持「已完成」，不会把一个 PR 失败算成任务失败。
- **汇报回写到任务卡片（2026-09-27 起）**：每个任务结束（成功或失败）时，壳层把代理在会话里的**最后一段文字**取出来写到任务上（`TaskItem.report`，落在 `local.json`，不进随仓库走的 `manual.json`/`index.json`）——卡片详情里多一行「汇报」，队列里**下一棒的交接简报优先用它**（会话被删掉也还在），点「重试」会清掉上一轮的汇报（它不是这一轮的结局）。提示词里那条因此是**必须**：「**必须**在结束时汇报：改了什么、怎么验证的、结果如何（没做完或失败也要说清楚）」——这段汇报现在真的会被用起来。
- **提示词按工作区的「形状」按需出条目（2026-09-27 起）**：面板把工作区分成**三态**（`TaskRepoShape`：非 git 目录 / git 仓库但没有 GitHub 远端 / GitHub 仓库），并在**写提示词的那一刻**重新探测（不是 adopt 时抄下来的那份）——同一个队列里第一个任务跑了 `git init` 或 `git remote add`，第二个任务的提示词说的就是新状态。要求列表不再是写死的 1–6 条，而是**按状态决定哪些条目出现、编号连续**：非 git 目录**没有分支条**（`git init` 建了仓库才 commit）；有仓库才有「完成前 commit」与分支条（有分支的写「本任务须在分支 X 上处理（若该分支不存在，须基于 base 分支新建）」，不切分支的写「本队列不切分支：直接在主分支 base 上处理」——两条都点名分支，`TaskPrompts.manual` 因此多了个 `base` 参数）；**token 条只在 GitHub 仓库出现**；「改完自查」一条同时照顾代码与文档（没有可跑测试的就说明）；「汇报」一条每个任务都要。
- **PR**：**队列最后一项完成时**由它的「开 PR 会话」创建（先查该分支已有的 PR 复用，避免 422）；开不出来**不算任务失败**——原因落在队列上、按钮 tooltip 里说清楚，可以点「开 PR」再来一次；工作区不是 GitHub 仓库（公司内部远端）时 PR 能力自动关闭，那个队列也就不开 PR 会话（见上两条）。
- **失败处理**：脏工作区 / checkout / pull / 建会话 / 提示词 / 超时（60min）各有明确原因（存的是 L10n 键，随界面语言显示），可重试；取消走 `session.cancel`；**目录不是 git 仓库时也能跑任务**——不切分支的队列全程不碰 git，在非 git 工作区新建队列默认就是「不切分支」；万一队列设了分支而目录没有仓库，任务以「当前工作区不是 git 仓库」失败，卡片主按钮同时变成**「不切分支并重试」**（点一下清掉该队列的分支再重跑），不用自己去队列设置里绕；
- **Agent 也能建任务（技能 `task-todo`，2026-09-27 起）**：壳层常驻的 localhost REST API 上多了一组 **`/api/tasks/*`**（`GET list` / `POST create`，一次可建多条），端口发现文件 **`~/.dsh/oh-my-dsh/shell-api.port`**（与 `browser-api.port` 同值、同一个服务）；配套**内置技能 `task-todo`**（App 启动安装到全局 `$DSH_HOME/skills/task-todo/SKILL.md`）让代理在**用户明确要求**时把沟通好的需求与方案**批量**落成手动任务（每条 = 标题 + 给执行者的描述）。落盘走的是面板自己的那条路（`TasksRunner.createManualTask`，经主线程串行），任务一律「**待处理、未入队**」——**建任务不启动任何东西**，队列与运行仍由用户决定；默认 `focus: true` 让面板切到那个工作区并展开，用户立刻看见卡片（状态行同时说明「已由 Agent 创建 N 个任务」）。2026-09-30 起还能**建「等待态队列」并批量入队**（`POST /api/tasks/queue/create`，队列以 `.draft` 待启动），队列**跑到 `.done`** 时把各任务完成情况（汇报首行 / 失败原因 / PR）**回传创建它的会话**（技能带上 `$DSH_SESSION_ID`；回传文案要求代理只简短确认、不主动改代码）；失败或手动取消让队列停在 `.paused`，不回传。启动有两条路：会话里说「启动队列」（技能调 `POST /api/tasks/queue/start`）或面板点「开始」，两者都不改变创建时记下的队列↔会话关联。技能**默认**建「等待态队列 + 入队」，只有用户明确说「只建任务 / 先别入队 / 不要队列」时才只建裸任务；
- **重启恢复**：读 `.dsh/tasks/` 四文件（`index.json` 提交的 issue 关联 / `manual.json` 手动任务 / `queues.json` 队列 / `local.json` 本机 task↔session，兼容 v1 的数字键），上次运行中的任务标为「已中断」、**活跃**队列暂停（**等待态 `.draft` 不在此列，仍是待启动**），**恢复后不自动开跑**；

- **GitHub token（按仓库作用域，只走文件）**：面板「配置 GitHub Token」**只写文件** —— 有当前仓库时写文件专属 `~/.dsh/oh-my-dsh/tokens/<owner>-<repo>`，否则写通用 `~/.dsh/oh-my-dsh/gh-token`（均 chmod 600，App 与外部工具/代理共用）；解析优先级：文件专属 → 文件通用；**不再读写 macOS 钥匙串**（旧版写在钥匙串里的 token 需重新填写一次）；公开仓库无需 token，私有仓库拉取/开 PR/评论关闭需要；
- 工作区非 GitHub 仓库时诚实显示空态（不替换为其他已注册工作区）；切换到不同仓库先清空旧列表再重载。

### 通道面板（`⌥⌘H` / 活动栏「通道」图标）

把微信个人号或钉钉机器人接入 dsh，**在微信/钉钉里远程驱动 dsh 干活**：发消息 → 路由到项目会话 → 结果回复回原平台。微信走官方 iLink 协议、钉钉走 dingtalk-stream 原生适配器，两平台与微信共享同一套面板模型（扫码向导 / 连接状态 / 项目视图会话消息 / 每会话跨项目路由）。

- **接入向导**：内置平台卡片（微信 ClawBot / 钉钉 / 飞书，带实时连接状态徽标）；微信扫码登录**在面板内渲染二维码**（不弹浏览器），登录态落 `~/.dsh/oh-my-dsh/channels/<id>.json`（文件优先，chmod 600），微信绑定页展示**已配置状态 + 显式「重新登录」**（避免误替换已绑定的 token）；钉钉走 **device-code 扫码向导**（`init/begin` 得二维码 → 面板内渲染 → 手机钉钉扫码自动创建企业内部应用+机器人 → 本地轮询 `poll` 拿 AppKey/AppSecret 写入 store，chmod 600），已配置通道不重复扫码、重开向导自动恢复 `/bind` 口令；
- **项目视图**：当前项目可用通道开关（启用状态存全局 `~/.dsh/oh-my-dsh/channels/<channelId>.workspaces.json`，project=workspace，见 `docs/channel-project-switch.md`）。开关**真正门控路由**：普通消息 / `/new` 路由到未启用该通道的 workspace → 回「该项目未启用该通道」、不建会话；`/workspaces` 只列已启用项。会话列表：通道标题行展示「图标 + 平台名 (channelId) + 会话数」、启用开关靠右，整行独立背景；每条会话独立区块，标题可点开/收起，消息按对话气泡展示（提问靠右、回复靠左）；顶部「全局配置」随时重开；
- **通道内斜杠指令**（微信 / 钉钉共用）：`/help` `/ping` `/status`（全局）；工作区指令 `/workspaces`(`/wks`)、`/sessions`(`/ses`)（无内容列出 / 有内容切换，等同 `#wN`/`#sN`）、`/new [内容]`（统一回 `创建新会话 #sN (sessionId)`，无内容建占位 `New Session`（dsh 标题由 dsh web 按首条消息自动命名）等首条消息激活、有内容 prompt=内容并回推答案）；快捷指令 `#w1`/`#s1…`（切项目/会话，均按目标/当前 workspace 是否启用该通道**门控**：未启用回「该项目未启用该通道」）与 #tag 路由（如 `#w1 帮我看看`）；
- **消息分发**：路由优先级（显式会话绑定 > 关键词 > 默认兜底），未绑定项目回复提示不静默；同会话串行、跨会话可并发（jobqueue）；
- **钉钉专属（owner-binding 安全门）**：`/bind <口令>`（口令本机生成、见面板或运行日志）——未绑定管理员前**拒绝所有人**，仅绑定管理员可驱动本机 dsh（防任何组织成员经机器人操作本地 bash/文件/token）；绑定成功回两条消息（确认 + 完整 `/help` 输出）；绑定状态存 `~/.dsh/oh-my-dsh/channels/<channelId>.binding.json`（chmod 600）；钉钉无「正在输入」，以文字 ack 代替 sendTyping；
- **会话驱动**：conversationId → dsh 会话映射（多轮对话续接，`/new` 另起），`/new` 后绑定会话到 conversation、下一条普通消息复用而非新建；经 `session.create` + `session.prompt`（queue）驱动，**生成时回原生「正在输入…」(微信 sendTyping / 钉钉文字 ack)，完成后回推答案**；
- **可靠性**：官方 iLink 协议**严格串行长轮询**（修复重复回复）；断线/鉴权失效（-14）归一到统一状态机，受控重连/重新扫码；启动自动拉起 listener、退出清理、同通道去重；
- **实时刷新**：项目视图在对话回复后 **~1.5s 内自动更新**——轻量重读全局 store，仅当内容签名变化时全量重建（保留折叠/展开状态），不随轮询抖动；
- **与 dsh web 会话双向联动**：点击项目视图会话行（单一手势）同时展开/收起其消息并**定位到 dsh web 对应会话**（经注入的 `sessionOpenerScript` 驱动）；反过来在 dsh web 切换会话时，面板自动展开对应会话、其余行收起（无对应则会话列表保持可见、仅全部收起）。**以 sessionId 对应、不用 name**（name 会因 `/new` 重绑/标题变化失配）；设计见 `docs/channel-web-session-link.md`；
- **全局存储**：会话映射与消息日志归档到全局 `~/.dsh/oh-my-dsh/channels/`（按 channelId/workspaceKey/sessionId 分桶）；「项目开关」关联存全局 `~/.dsh/oh-my-dsh/channels/<channelId>.workspaces.json`（见 `docs/channel-storage.md`、`docs/channel-project-switch.md`）；
- **当前限制**：飞书仅展示卡片（适配器待实现）；钉钉富特性（AI Card 流式 / 互动审批卡 / 图片 / DWS）留作后续增强，v1 以文本/Markdown 回复为主；
- 设计与指令清单：`docs/channel-design.md`、`docs/channel-dingtalk-stream.md`、`docs/channel-commands.md`、`docs/channel-status.md`、`docs/channel-project-switch.md`。

![channel](./docs/screenshots/channel.png)

### 技能面板（`⌥⌘S` / 活动栏「技能」图标）

管理 agent 技能（SKILL.md）：**已安装** 与 **可安装** 两个页签。

**已安装**：扫描 dsh 的四个技能根，按优先级去重，逐行标出级别 —— `内置` / `用户级` / `共享级` / `项目级`，同名被压住的标「被遮蔽」，并给出描述与完整路径。

- **内置技能只读**：开关禁用、无「移除」、卸载不掉（App 启动时按内嵌内容同步，内嵌与已装文件保持字节一致）；
- **共享级**（`~/.agents/skills`，外部 skills CLI 管理）：可看到、可改开关，但不在面板里移除；
- **用户级 / 项目级**：可改开关、可移除（项目级会写进用户仓库，确认框会提示）；
- **调用开关**：`用户可调用` 写 `user-invocable`、`模型可调用` 写 `disable-model-invocation`（关 = 写 true）——改的是 `SKILL.md` 的 frontmatter，dsh 自动识别，无需重启；切回默认值会**删掉该键**，文件字节还原；

**可安装**：顶部选 registry，列表就是该 registry 的技能清单；**进入即有内容** —— 有清单来源的 registry（GitHub 仓库 / well-known）直接列出清单，只有搜索接口的（skills.sh）默认显示**热门列表（按安装量降序，前 30）**，输入关键字即切换为搜索结果。

- **registry 可配置**（`$DSH_HOME/oh-my-dsh/shell/skills.json`）：`owner/repo` 或 GitHub 地址 → 列该仓库的技能清单；well-known 地址 → 读 `/.well-known/skills/index.json`；其他 URL → 视为 skills.sh 兼容的搜索接口（默认预置 skills.sh，仅有搜索，无全量清单，故无清单来源时列表区会提示「按关键字搜索」）；
- **交互**：**整张卡片可点 = 看详情**（用系统默认浏览器打开该技能的页面：skills.sh 型 registry → `https://www.skills.sh/<source>/<skill>`；GitHub → 仓库内技能目录；well-known → 该技能的 SKILL.md；本地路径 → 在 Finder 中显示），悬停时整卡有 accent 底色提示可点；**「安装」按钮只在鼠标移入卡片时出现**，移出即隐藏；
- **安装方式**：清单勾选安装 / 「从地址安装…」（`owner/repo`、`owner/repo@skill`、GitHub·GitLab 地址、well-known 地址、本地路径）/ 「手动导入…」（本地目录含 SKILL.md，或单个 SKILL.md，附件一并复制）；
- **落点**：默认 **用户级** `$DSH_HOME/skills/<name>/`（所有工作区通用），可选 **项目级** `<工作区>/.dsh/skills/<name>/`（优先级最高）；同名已存在会先确认，内置同名技能拒绝覆盖；
- **安全**：技能以完整代理权限运行，安装确认处固定提示；仅接受 https 地址，路径穿越被拒绝，失败不留半成品。

设计与机制（四档级别判定、registry 模型、开关的可逆写法）：`docs/skills-manager-design.md`。

### 审查面板（`⌥⌘R` / 活动栏「审查」图标）

**只读**回答「这个会话里代理到底改了哪些文件、改成什么」——直接读 dsh 自己落盘的会话日志（`$DSH_HOME/sessions/<workspace>/<session>/session[.vN].jsonl[.zstd]`；日志文件名里的 `.vN` 是 dsh 的 **Session 格式世代**，dsh 0.1.5 的新会话是 `session.v3.jsonl`，面板按规范名枚举并**取世代最大的那一份**），不写任何文件、不发任何请求、不改 dsh。

**按 会话 → 对话（turn）→ 文件 → 变更内容 的树展示，每层可展开/收起**；对话用该轮的用户消息做摘要；
会话在第一次展开时才真正审计（列表只读日志头，展开才解码全量日志）。**审计结果会跟着日志走**：正在对话的会话
日志一直在追加，面板按日志身份（大小 + mtime）判断有没有新内容——面板在屏上时每 5 s 做一次 `stat`，只有真的变了
才重读一次，所以新建会话里刚改的文件会**自己出现**，不需要重开面板或点刷新。

- **每个文件的逐次改动**都标出该条记录**从哪来**：
  - `已应用` —— 顶层 `write`/`edit` 工具结果里的 hunk（与 dsh web 的 diff 卡片同源）；
  - `参数还原` —— 由调用参数还原（`run_code` 嵌套调用没有 hunk 元数据）；
  - `全文写入` / `新建` —— 只记录了写入内容（新建文件没有「旧内容」可比）；
  - `嵌套调用` 标记 —— 该改动来自 `run_code` 内部的工具调用；
- **shell 命令单列**：`bash` 直改（`sed -i`、`>`、`rm`、`git checkout` …）没有结构化的前后内容记录，面板按「可能写文件」启发式标出，默认只显示可疑项（可关掉过滤看全部）；
- **失败调用单列**：记录为「尝试但未生效」的改动不混进变更列表；
- **跟随 dsh web**：在 dsh web 切换会话时，面板展开同一 sessionId（按 id 解析，跨工作区也能定位），并标为「当前会话」；工作区切换只重列会话、不清审计缓存；
- **读取诊断**：Zstandard 尾部未完成帧、无法解析的行等一律显式列出（不静默丢数据）；
- **只读边界**：日志里没有的东西不会显示——`bash` 直改、以及日志**尚未落盘**的部分只标注「需人工核对」（落盘后会自动读到，见上）；
- 设计与覆盖矩阵：`docs/review-panel-design.md`。

## 产物

```
dist/oh-my-dsh.app                    编译好的原生 App（arm64，ad-hoc 签名，含内置运行时 + CEF）
dist/oh-my-dsh-<version>-arm64.pkg    安装包（装到 /Applications，版本号随 git tag）
dist/oh-my-dsh-<version>-arm64.dmg    拖拽安装镜像（把 App 拖进 Applications）
```

> 版本号由 git tag 驱动（见「构建」）；发布产物（含 SHA-256SUMS）见 GitHub Releases。

## 安装到 Applications

**方式一：安装包（推荐）**

```bash
open "dist/oh-my-dsh-<version>-arm64.pkg"
```

跟随安装器向导即可（会要求输入管理员密码）。安装器带 preinstall 脚本，重装前自动移除旧版本。
由于是本地构建、未公证，首次安装时 macOS 可能提示"无法验证开发者"——右键 →「打开」，或在
系统设置 → 隐私与安全性 中允许即可。

**方式二：拖拽镜像**

```bash
open "dist/oh-my-dsh-<version>-arm64.dmg"
```

把 `oh-my-dsh.app` 拖进 `Applications` 文件夹。

**构建安装包**（基于已构建的 `dist/oh-my-dsh.app`）：

```bash
./platforms/macos/make-pkg.sh   # 生成 arm64 的 .pkg 与 .dmg
```

## 环境要求

- 运行：macOS 13+（Apple Silicon）。**无需安装 Node、无需安装 dsh**。
- 构建：需要 Xcode Command Line Tools、curl、python3，以及网络（下载 Node + 从 registry 装 dsh；浏览器面板需先经 `build-cef.sh` 构建 CEF）。

## 构建

```bash
./platforms/macos/build-app.sh --prefetch  # （可选）先预下载 Node + 预装 dsh 到 .cache/，不产出 App
./platforms/macos/build-app.sh             # 全量构建 → dist/oh-my-dsh.app（复用 .cache/，无需再联网）
```

内置运行时是**构建时现做**的，不复制本机的任何 node/dsh 文件：

1. **下载 Node**：默认从国内镜像 `npmmirror.com/mirrors/node` 下载 `darwin-arm64` tarball
   （自动选最新 LTS，失败自动回退 nodejs.org），用官方 `SHASUMS256.txt` 校验 SHA-256 后，
   把 `bin/node` 和 `lib/node_modules/npm`（升级功能要用）嵌入 `Contents/Resources/runtime/`；
2. **安装 dsh**：用刚下载的 Node 自带 npm，在 `Contents/Resources/runtime/dsh` 里执行
   **`npm ci`**（默认版本，含其全部依赖闭包），默认走国内 npm 源 `registry.npmmirror.com`（失败自动回退 npmjs.org）。
   ⚠️ **闭包用提交的 lockfile 钉死**：`platforms/macos/runtime-locks/<spec>/package-lock.json`（随 App 分发到
   `Contents/Resources/runtime-locks/`）。**只改 `DSH_PACKAGE_SPEC` 而不配 lock 是不行的**——dsh 用 caret 范围声明
   它的 cordis 工具链，裸 `npm install` 会装当天最新的 1.x，可能让这个 dsh 版本**启动即崩**
   （实测：`cordis-plugin-hmr` 1.0.19 装进 0.1.2-rc.1 → `user patch-layer watching requires the Cordis HMR service`，见
   `docs/dsh-version-impact.md` R8）。装完还会跑一次**启动冒烟**（`smoke_runtime`：起一次 `dsh web`，40 秒内必须打出入口 URL
   且进程存活，否则构建失败；跨架构 stage 自动跳过，`DSH_SKIP_RUNTIME_SMOKE=1` 可临时跳过）。

**Node 选择策略（运行期）**：`DSH_NODE` 显式指定 > 系统 node（PATH→nvm current→nvm default→nvm 最新→Homebrew，
取**通过版本门槛** `≥22.0.0` 者，`DSH_NODE_MIN` 可覆盖）> 内置 node 兜底；dsh web 子进程经登录 shell 合并用户 PATH。

构建变量：

| 变量 | 默认 | 作用 |
|---|---|---|
| `DSH_NODE_VERSION` | 自动检测最新 LTS | 指定下载的 Node 版本，如 `v22.23.2` |
| `DSH_PACKAGE_SPEC` | `@deepseek-ai/dsh@0.1.5-rc.3` | 内置 dsh 版本（壳层与该版本同步适配；每个受支持版本需在 `platforms/macos/runtime-locks/<spec>/` 配一份 lockfile，构建用 `npm ci` 复现闭包） |
| `DSH_NODE_MIRROR` | `https://npmmirror.com/mirrors/node` | Node 下载镜像 |
| `DSH_NPM_REGISTRY` | `https://registry.npmmirror.com` | npm registry（构建期装 dsh 用） |
| `DSH_ARCH` | `uname -m` | 目标架构：`arm64` / `x86_64`（CI 构建 arm64，release 构建 arm64 + x86_64；不再出 universal） |
| `DSH_DEV_BUILD` | `0` | `1` 打包**开发版**（Info.plist 写 `DSHDevBuild=1`）：独立 bundle id `com.ohmydsh.app.dev`（独立 UserDefaults 域）；运行时**自拉起独立 dsh 实例**（3080 被占则自动换空闲端口）、使用**独立 `DSH_HOME`（默认 `~/.dsh-dev`）**、CEF CDP / Browser API 端口错开（9333→9433、3081→4081），可与已安装正式版并存测试（均尊重显式 `DSH_HOME` / `DSH_CDP_PORT` / `DSH_BROWSER_PORT` 覆盖） |
| `DSH_CEF_VERSION` | build-cef.sh pin 的版本 | 浏览器面板的 CEF/Chromium 版本（如 `150.0.18+gdb11278+chromium-150.0.7871.213`） |

构建缓存：Node tarball、npm 缓存、已构建的运行时与 CEF 产物存放在 `.cache/`（按架构分目录，不随 `.build/` 清除）；
相同组合会直接复用，重建只需几十秒。网络不可用时，会用缓存的 Node tarball 推导版本继续构建。

## 运行

```bash
open "dist/oh-my-dsh.app"
```

或者直接双击 `dist/oh-my-dsh.app`。

- 界面用系统 WebKit 渲染，与 Safari 同引擎；窗口标题固定为 `oh-my-dsh (DeepSeek Harness)`；
- 外部链接、`target=_blank` 会交给默认浏览器打开，不会在壳内跳走；文件下载走原生「另存为」对话框（`WKDownload`）；
- **菜单**：App 菜单（关于/隐藏/退出）、编辑菜单（`⌘C/V/X/A/Z` 路由到 WebView 首响应者）、视图菜单（八面板切换 + **「重新加载页面」`⌘R`**）、设置菜单（`⌘,` 设置窗口 / `⌘U` 检查并升级 dsh / `⌘L` 打开日志文件夹 / dsh 设置 / registry / 自动升级 / 终端选中即复制 / wiki 设置组 / 语言子菜单 / 外观子菜单）；
- 首次启动若被 Gatekeeper 拦（"无法验证开发者"），右键 App →「打开」即可（本地构建，无公证）。

## dsh 升级

- **手动（分步 + 二次确认）**：设置菜单 →「检查并升级 dsh…」(`⌘U`)：① 检测并提示「当前 vA → 可升 vB」→ 用户确认；② 后台把 vB 预热进共享 npm 缓存（**不改动线上 dsh 树、可取消**）；③ 下载完成**再次确认**才原地安装 + 重启服务并重载页面。每次只升到**紧邻的下一个发布候选**（stable/rc，排除 alpha/beta/dev），不会一步跳到 latest；
- **自动**：设置菜单 →「自动升级 dsh」开关（默认开），每次启动最多检查一次（24h 节流）；**不再阻塞启动**——服务先起来，后台检测并预热下载，**下载完成后弹窗请用户确认**才正式升级；选「稍后」推迟约 2 小时并定时提醒，离线 / 下载失败按约 2h 重试；
- **备份与回滚**：正式升级前把 `runtime/dsh` 整树快照到 `~/Library/Caches/oh-my-dsh/upgrade-backups/`（只保留最近一份）；安装失败或安装后版本校验不符时**自动回滚**并提示；
- 升级只作用于**内置运行时**（`Contents/Resources/runtime/dsh`），绝不碰系统安装的 dsh；升级进行中「检查并升级」菜单项自动置灰，避免与自动流程并发；
- 升级日志见 `~/Library/Logs/oh-my-dsh/app.log`（`auto-upgrade: …` 行）；
- 注意：升级会改写 App 包内文件，ad-hoc 签名因此失效，但本地运行不受影响；重新 `./platforms/macos/build-app.sh` 可还原干净包。


## 会话快照与回退（Session Snapshots）

dsh 升级会**把会话日志换成新世代**（0.1.5 起新建会话写 `session.v3.jsonl`，老会话被迁移后把原文件留成冻结归档），
而且**上游没有降级通道**——这是一次不可逆的数据迁移。所以壳层在任何「App / 内置 dsh 版本组合变化」发生**之前**自动留一份可回退的快照，
设置菜单 →「**会话快照…**」里可以查看与回退。

| 资源 | 内容 | 成本（实测） |
|---|---|---|
| 数据快照 | `$DSH_HOME/sessions/ + storages/`，最多保留 3 份 | 306 MB / 246 会话 → **0.124 s**（APFS clonefile，实际几乎不占空间） |
| 树池 | `runtime/dsh` 整树，**按 dsh 版本去重**存一份 | 256 MB / 24,872 文件 → 5–6 s、约 14 MB（每个版本只一次） |
| 隔离区 | 回退时"快照之后新建的会话"移到这里，**不删除** | 0（rename） |

**触发时机**：① 功能首次启用（基线）；② App / dsh 版本组合变化；③ **App 内升级 dsh 之前（强制）**；④ 用户点回退时的现场快照（使回退本身可撤销）。
顺序铁律是「**先打快照、再起 dsh**」——dsh 一打开会话就会写盘，晚一步就抓不到干净状态。组合没变时启动只读一次状态文件（~60 ms）。

**回退并退出**：选一份快照 → 预览「将恢复 N 条 / 将隔离 M 条 / 内置 dsh 换回 X」→ 二次确认 →
停掉壳层自拉起的 dsh web → 把现场整体停放到一份 pre-rollback 快照（可撤销）→ 恢复数据并删掉被恢复会话的新世代日志 →
快照之后新建的会话移入隔离区 → 换回旧 dsh 树（池内 rename，**离线瞬时**）→ 写回数据所属组合并**钉住自动升级** → 退出 App。
事务带 journal：中途崩溃或「数据与树版本不一致」会在下次启动提示，可续做或撤销。

**边界**：这是数据回退，不是 App 回退——pkg 装不了旧版本，所以「问题出在 App 本身」时要选「只回退数据 + 重装旧版 App」
（快照 meta 里记着当时的 App 版本，界面会据此提示装哪一版）。凭据（`credentials*`）、壳层自身状态与 token（`shell/`）、
通道绑定（`channels/`）、CEF profile（`browser*/`）**一律不进快照、不回退**。设计与场景演绎：`docs/session-snapshot-rollback-design.md`。

## 退出行为说明

| 场景 | 行为 |
|---|---|
| App 自己拉起了服务 | 退出时**关闭**（SIGTERM → 3 秒后 SIGKILL 兜底） |
| 上次异常退出（崩溃 / 强杀）残留的服务 | 下次启动时按 `$DSH_HOME/oh-my-dsh/shell/dsh-web.json` 的记录（pid + 端口 + launch token）**回收**：token 每进程随机，用它探活即证明还是自己那台，绝不误杀别的进程 |

## 环境变量（可选）

| 变量 | 作用 |
|---|---|
| `DSH_CLI` | 直接指定 `dsh` 入口（`@deepseek-ai/dsh` 的 `lib/bin.js` 路径；优先于内置运行时） |
| `DSH_NODE` | 直接指定 `node` 可执行文件路径（优先于内置运行时） |
| `DSH_NODE_MIN` | 系统 node 候选的最低版本门槛（默认 `22.0.0`） |
| `DSH_HOME` | 传给 `dsh web` 的 `DSH_HOME`（默认 `~/.dsh`，首次使用自动初始化 web profile） |
| `DSH_NATIVE_PORT` | 自拉起时使用的端口（默认 3080，被占用则自动换空闲端口） |
| `DSH_REGISTRY` | 运行期 dsh 检查/升级用的 npm registry（优先于「设置 dsh registry…」与默认国内源） |
| `DSH_AUTO_UPGRADE=0` | 本次运行关闭自动升级 |
| `DSH_AUTO_UPGRADE_NOW=1` | 测试钩子：忽略 24h 节流，每次启动都跑一遍自动升级流程 |
| `DSH_LANG=zh|en` | 强制界面语言（优先于「设置」→「语言」的选择；默认跟随系统） |
| `DSH_BROWSER_PORT` | 浏览器面板 REST API 端口（默认 3081，占用自动递增；生效端口写 `~/.dsh/oh-my-dsh/browser-api.port`） |
| `DSH_CDP_PORT` | 浏览器面板 CDP 端口（默认 9333） |
| `DSH_BROWSER_TEST=1` | 启动即打开浏览器面板（QA/调试钩子） |
| `DSH_REVIEW_TEST=1` | 启动即打开审计面板（QA/调试钩子） |
| `DSH_REVIEW_TEST_PATH` | 审计面板固定读取的工作区路径（QA/调试钩子，默认跟随当前工作区） |

> 其他 QA/调试钩子（环境变量或 `--ui-debug`）：`DSH_UI_DEBUG=1` 统一开关（打开浏览器面板 + 面板层级 dump + 截图）、
> `DSH_PREVIEW_TEST_PATH` / `DSH_TERMINAL_TEST` / `DSH_WIKI_TEST` / `DSH_REVIEW_TEST` / `DSH_SKILLS_TEST`（启动即开对应面板）、
> `DSH_PANEL_TEST="files,terminal,wiki,tasks,browser,channel,review,skills"`（**按序开全部面板**，配 `DSH_UI_DEBUG=1` 每个面板各落一张 `panel-<name>-debug.png` ——dsh 升级后的面板全量核对就靠它）、
> `DSH_PREVIEW_DEBUG`（fetch 拦截探针，同时演练 `host.openPath` 与 `session/openWorkspacePath` 两种形状）、`DSH_SESSION_DEBUG`（会话跟踪 dump）。

> **壳层设置存放位置**：语言 / 主题 / 面板宽度 / 浏览器 / 通道 / wiki 等**壳层自有设置**存为 UTF-8 JSON `$DSH_HOME/oh-my-dsh/shell/config.json`
> （开发版 `~/.dsh-dev/oh-my-dsh/shell/config.json`），可由外部工具 / 代理直接读写（写入经 core CLI 合并 + 原子落盘，壳层侧 0.3s 防抖异步）；
> 仅系统级项（`AppleLanguages`、窗口位置）仍留在原生 UserDefaults。
> 壳层工作数据（本目录）从 `$DSH_HOME` 根迁移过来时，会在 `$DSH_HOME/oh-my-dsh/ROLLBACK.md` 落一份回退说明（含把子目录 `mv` 回根目录的脚本）。

> **GitHub token（任务面板，按仓库作用域，只走文件）**：面板「配置 GitHub Token」保存时**只写文件** —— 有当前仓库时写
> 专属 `~/.dsh/oh-my-dsh/tokens/<owner>-<repo>`，否则写通用 `~/.dsh/oh-my-dsh/gh-token`（均 chmod 600）——App 与外部工具/代理共享同一份。
> 解析优先级：① 文件专属 ② 文件通用 `~/.dsh/oh-my-dsh/gh-token`；**不再读写 macOS 钥匙串**（旧版写在钥匙串里的 token 需重新填写一次）。
> 公开仓库无需 token；私有仓库拉取/开 PR/评论关闭 issue 需要。

> 构建期变量 `DSH_NODE_VERSION`、`DSH_PACKAGE_SPEC`、`DSH_NODE_MIRROR`、`DSH_NPM_REGISTRY`、`DSH_CEF_VERSION`、`DSH_ARCH` 见上文「构建」。

## 日志

- `~/Library/Logs/oh-my-dsh/app.log` — App 自身行为（启动、拉起/回收 dsh web、运行时版本信息、自动/手动升级、页面加载、退出清理、面板/QA dump）
- `~/Library/Logs/oh-my-dsh/server.log` — 自拉起的 `dsh web` 进程输出

## 工作原理（为什么不动源码）

壳二进制只做三件事：探测空闲端口 → 用内置 `node` 执行内置 `<dsh>/lib/bin.js web --port <n>` 拉起（并回收自己上次残留的实例）→ `WKWebView` 加载 `http://127.0.0.1:<n>/?token=…`。
`dsh` 本体、`~/.dsh` 配置、会话数据全部原样，无任何补丁或注入。内置运行时装在 `Contents/Resources/runtime/`
（`node` + `npm` + `dsh/` 依赖树），App 优先使用它，找不到时才回退到本机安装。
右侧八个面板是壳层原生 UI，其中文件面板通过 WebView 注入拦截文件打开，任务 / 知识库 / 浏览器 / 通道 / 审查 / 技能通过 dsh 既有能力（RPC / 会话 / 独立浏览器内核 / 会话日志 / SKILL.md 发现）驱动。

## 目录

```
platforms/macos/src/                  原生壳（Swift）
  main.swift        壳层核心：日志/L10n/服务管理/升级/窗口/菜单/设置窗口/onboarding/右栏插槽/WebView 注入
  PreviewPanel.swift  文件面板回滚基线 + 共享 UI 组件库
  FilePanel.swift    文件面板（预览+编辑：无后缀/点文件、行号栏、保存 ⌘S、大文件分块高亮、按工作区记忆页签）
  FilePanelTreeMenu.swift 文件面板目录树右键菜单（按对象给项：新建/重命名/删除到废纸篓/在 Finder 中显示）
  ImagePreviewView.swift / ImageZoom.swift 图片预览（适应窗口 + 手动缩放，缩放数学为纯模型可无头测试）
  WorkspaceTabMemory.swift 文件面板的工作区页签记忆（顺序/选中项，纯逻辑可无头测试）
  CodeEditorView.swift 文件面板编辑视图（行号栏 + vendored Highlightr 高亮）
  TerminalPanel.swift 终端面板（PTY 会话 + ANSI/VT 模拟器）
  TerminalWorkspaceTabs.swift 终端页签按工作区隔离与记忆（顺序/选中项/自动开启，纯逻辑）
  WikiPanel.swift      Repo Wiki 知识库面板（生成/维护/浏览 + 自动 git 提交）
  IssueRunnerPanel.swift 任务面板（卡片列表 + 队列分区 + 内联表单装配，装配层）
  TaskInlineForms.swift   任务面板的内联表单（新建/编辑任务、新建队列/队列设置，卡片式无模态）
  TasksCore.swift         任务/队列模型（状态机、分支命名、入队·移出·失败暂停·重启恢复，纯逻辑）
  TasksStore.swift        .dsh/tasks 四文件持久化（index/manual/queues/local，v1 兼容）
  TasksRunner.swift       队列运行器（git 三步显式检查、dsh 会话、队列级 PR、取消·重试·跳过）
  TasksUI.swift           任务卡片视图模型（徽标/元信息/主操作/队列头/摘要，无头可断言）
  TasksAPI.swift          任务面板的 localhost API（/api/tasks/* 路由 + 请求解析 + 工作区解析，纯模型可无头测试）
  TaskCardView.swift      卡片与队列头视图（渲染 + 点击转发）
  ChannelPanel.swift     通道面板（微信/钉钉接入：引导卡片/扫码向导/项目视图 + 启动自动拉起 listener）
  SkillsPanel.swift      技能面板（已安装/可安装/registry/调用开关/移除）
  SkillsCore.swift       技能模型（frontmatter 读写、四根扫描与级别、壳层技能记录）
  SkillSources.swift     技能来源（地址解析、registry 清单与搜索、拉取/安装/移除）
  ReviewPanel.swift      审计面板（只读：会话日志变更/嵌套调用/shell 可疑命令）
  ReviewLogModel.swift   审计面板数据模型（核心 JSON 解码 + 文件分组/diff 折叠 + 日志新鲜度打戳，纯 Foundation 可无头测试）
  PanelSurface.swift    面板配色单一事实来源（面板底色 + 控件常态/高亮两档，见 docs/ui-color-scheme.md）
  BrowserPanel.swift / BrowserAPI.swift / BrowserCDP.swift  浏览器面板（CEF 渲染 + REST API + CDP）
  DshWebRPC.swift      壳层原生 dsh RPC（0.1.2 斜杠端点 + launch token 换 cookie，wiki/任务/会话共用）
  DshWebCookieJanitor.swift 启动/退出清理非本次 authority 的 dsh-auth-* cookie + 回收上次残留实例
  ShellConfig.swift    壳层设置门面（读 $DSH_HOME/oh-my-dsh/shell/config.json，写委托 core CLI，含旧 UserDefaults 迁移）
  MakeIcon.swift     App 图标生成器（渲染 → iconset → icns）
platforms/macos/cef/                   CEFShim.h/.mm（ObjC++ 桥：OSR 渲染/输入转发/DevTools）+ helper
platforms/macos/build-app.sh           一键构建脚本（编译、打包、镜像下载 Node、npm 装 dsh、预下载模式、签名）
platforms/macos/build-cef.sh           CEF 构建脚本（版本 pin + sha1 校验 + 缓存 + shim/helper 编译）
platforms/macos/make-pkg.sh            安装包脚本（pkgbuild 生成 .pkg + hdiutil 生成 .dmg）
core/                共享核心（Node 模块：ANSI 模拟器 / 服务管理 / 升级 / 会话 RPC / issues / jobqueue / tasks 关联索引 / channel（统一抽象·路由·指令·会话关联·全局存储·微信 ClawBot 与钉钉 stream 适配器）/ review-log（会话日志变更审计，zstd 多帧解码），跨平台复用）
platforms/           各平台壳（macos/ 现有壳，windows/ linux/ 规划中）
scripts/             跨平台工具（version.sh 版本单一来源 / changelog.sh / release-checksums.sh / github-publish.sh / local-release.sh / git-remote.sh）
.github/             CI 工作流（core 单测、壳层单测/编译检查 + arm64 构建；release.yml 打 tag 时构建 x86_64 + 发布）
.dsh/skills/         web-dev-tools / repo-knowledge / task-todo 等面板配套 skill（App 启动时同步安装到全局 $DSH_HOME/skills/；issue-resolve 已于 2026-09-27 退役）
.cache/              构建缓存（node tarball、npm 缓存、已构建运行时/CEF，按架构分目录）
dist/                构建产物（.app / .pkg / .dmg）
docs/                设计/排查文档（productization.md、dsh-version-impact.md、git-workflow.md、release-process.md、**ui-color-scheme.md（面板配色方案）**、repo-wiki-design.md、review-panel-design.md、browser-blank-panel-fix.md、issue-runner-design.md、milestones/、plans/ 等）
```

## 如何贡献

欢迎提交 PR、Issue 与建议！请先阅读 [CONTRIBUTING.md](CONTRIBUTING.md)（构建/测试/提交规范/PR 流程）
与 [SECURITY.md](SECURITY.md)（安全报告渠道）。

- **Bug / 功能请求**：使用仓库的 Issue 模板（bug / feature）提交；
- **本地测试**：`node --test --test-timeout=60000 core/tests/*.test.js`（共享核心单测：ANSI 模拟器 / 端口 / 升级 / 会话 RPC / issues / 队列 / 任务索引 / channel 指令·路由·会话·传输层 / review-log 变更审计；`--test-timeout` 保证任何泄漏定时器的用例快速失败而不是挂死）、
  `tests/tasks-panel/run.sh`（任务面板 1333 项：**模型 203**（入队·移出·失败暂停·重启恢复 + `.dsh/tasks` 四文件持久化 + index.json v1 兼容）+ **运行器 433**（假 git + 假 dsh 驱动全流水线：分支进入 / 全局串行 / 失败暂停 / 队列级 PR 复用 / 取消·重试·跳过 / 手动任务增删改与队列选择 + **非 git 目录**：无分支的队列照常跑完、有分支的队列报 `errNotGit` 且不浪费会话）+ **视图模型 349**（卡片徽标与按钮可用性 / 队列头进度与状态 / 发布按钮随 Git 工作流（pr/merge/push/无）与收尾结果 / 摘要计数 / 内联表单校验与提交 / 空态 / 头部工作区行：非 git 与 非 GitHub 分开说 + GitHub 专属按钮可用性）+ **视图 235**（无窗口 AppKit：两张表单（队列表单的 Git 工作流也是单选组、发布排在关闭之前）+ 面板设置抽屉（默认工作流单选组、按工作区、工作流在 Token 之上）的字段宽度·按钮·提示状态与提交流程、输入框必须撑满表单、描述框与单行框同款且随输入长高、队列表单默认只问队列名、表单在 260pt 矮面板下必须把按钮留在可见区，卡片/队列容器/分区头与进度条的真实布局——卡片必须撑满列表宽度、窄面板下不得反向撑宽列表，队内卡片还必须缩进在泳道内）+ **本地 API 113**（`/api/tasks/*`：路由命中与不吞 404、请求解析（字符串简写/对象/空标题/上限 50/部分成功）、**queue/create + queue/start + queue/append**（等待态、`session` 来源、按 `name`/id 消歧、409/404、追加回 draft、`reportsToSession`）、工作区解析（cwd 在子目录 → 最近祖先）、响应形状））、`tests/projects-panel/run.sh`（项目面板：根目录/命名规则/列举/注册合并 + 控制器无头：建目录、注册请求、快捷入口回调、改根）、`tests/injected-scripts/run.sh`（注入 dsh web 的 JS：脚本可解析 + 桥名与壳层调用对得上）、`tests/wiki-panel/run.sh`（Wiki 面板）、`tests/terminal-emulator/run.sh`（模拟器）、`tests/terminal-panel/run.sh`（终端面板头部）、`tests/browser-panel/run.sh`（浏览器 REST 路由/日志缓冲 + 同一服务上的 `/api/tasks/*` 路由面一起编译）、`tests/channel-panel/run.sh`（通道项目视图数据模型）、`tests/file-panel/run.sh`（文件面板：工作区页签记忆 / 未保存提示 / 切换语义）、`tests/preview-interceptor/run.sh`（注入的文件打开拦截脚本：dsh ≥0.1.5 点击捕获 + 旧版 RPC fetch 形状）、`tests/dsh-rpc/run.sh`（壳层原生 dsh RPC：信封形状 / 斜杠↔点号回退 / launch token 换 cookie）、`tests/dsh-auth-cookies/run.sh`（dsh-auth cookie 清理与 NODE_OPTIONS）、`tests/shell-config/run.sh`（壳层设置与旧 UserDefaults 迁移）、`tests/l10n/run.sh`（L10n 键名 lint）、`tests/skills/run.sh`（内置 skill 安装 / 迁移）、`tests/skills-panel/run.sh`（技能面板：frontmatter 字节保真 / 四根级别与遮蔽 / 内置与共享级写操作拒绝 / 安装·移除 / registry 清单与搜索 + 面板控制器无头冒烟 + 离屏绘制回归）、`tests/review-panel/run.sh`（审计面板：日志审计模型解码/分组/diff 折叠 + 控制器无头回归「日志变了必须重审、没变不许重审」）；`scripts/local-ci.sh` 一次跑全部；
- **CI**：push/PR 自动跑 core 单测 + 壳层编译检查 + macOS arm64 构建（`.github/workflows/ci.yml`）；发布由 release 流程构建双架构。

本项目遵循 [MIT License](LICENSE)，代码只封装、绝不修改 DeepSeek Harness 上游源码。
