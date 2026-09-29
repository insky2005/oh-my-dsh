# 任务面板 Skill（task-todo）设计

> 状态：实现中（v1.1x 开发线，feature/task-todo-skill）
> 关联面板：任务（Tasks / IssueRunner）
> 关联：docs/builtin-skills-design.md、docs/issue-runner-design.md、docs/multi-agent-host-design.md
> 基线：自动任务面板（TasksCore / TasksStore / TasksRunner / TasksWorkspaces）所在的
> feature/tasks-manual-queue 线——main 上还没有手动任务与任务面板的模型层。

## 1. 背景与目标

用户在会话里和 Agent 聊完需求与方案之后，下一步通常是「把这件事拆成任务清单」。
目前这条链路只能靠人：用户自己在任务面板点 ➕，一条一条把刚才聊出来的任务敲进去。
聊了半小时，落到面板上还要再抄一遍——而 Agent 手里本来就有完整的任务描述。

本设计新增一个**内置 Skill** `task-todo`：Agent 在**用户明确要求**时，把沟通结论
一次性写进任务面板（可批量），面板随即显示出来，用户接下来照常挑队列、按「处理」运行。

### 成功标准

1. 用户说「把刚才讨论的拆成任务清单，建到任务面板」，Agent 加载 `task-todo`，一次调用
   创建多条任务；面板自动切到对应工作区并展开，「手动」页签下能看到这些任务（待处理、未入队）。
2. 任务内容完整保留：标题 + 描述（描述即 Agent 给下一棒的执行说明），不是被压成一行标题。
3. **用户没要求就绝不创建**：Skill 正文把「必须由用户明确要求」写成硬规则；
   Skill 只描述怎么建，不主动触发。
4. App 没运行 / 端口不通时，Agent 明确报错并让用户开 App，绝不假装成功，也不绕过 API 直接改盘上文件。
5. 内置 Skill 与其它三个一致：App 启动安装到 `$DSH_HOME/skills/task-todo/SKILL.md`，
   安装器受管更新、仓库副本字节一致、测试可校验。

## 2. 机制：壳层本地 API

任务面板在 App 进程里，盘上是 `<workspace>/.dsh/tasks/{manual,queues,local,index}.json`
（TasksStore）。**Agent 不直接写这些文件**：面板在内存里持有 board，外部改动会被面板
自己的下一次 persist 覆盖，且没有「任务已创建」的可见反馈。

因此沿用浏览器面板（web-dev-tools）已经跑通的形状：**壳层 localhost REST API**。

- 服务：App 启动时起的同一个 HTTP 服务（`BrowserAPIServer`，127.0.0.1、无鉴权、
  与 dsh web 同一信任模型），路由面按前缀分工：
  `/api/browser/*` 归浏览器面板，`/api/tasks/*` 归任务面板。
- 端口发现：沿用 `$DSH_HOME/oh-my-dsh/browser-api.port`（默认 3081、占用自增），
  **并额外写一份同值的 `$DSH_HOME/oh-my-dsh/shell-api.port`** 供本 Skill 语义正确地发现；
  Skill 读取顺序：`shell-api.port` → `browser-api.port` → 3081。

### 2.1 端点

| 方法/路径 | 请求 | 响应 |
|---|---|---|
| GET `/api/tasks/list` | `?workspace=<path>`（可选） | `{ok, workspace, tasks:[{id,title,state,source,queueId,queueName}], queues:[{id,name,branch,state}]}` |
| POST `/api/tasks/create` | `{workspace?, focus?, tasks:[{title, body?} \| "标题"]}` | `{ok, workspace, shown, created:[{id,title}], rejected:[{title,error}]}` |

- `tasks` 每项可以是对象（推荐，带描述）或字符串（只有标题，描述回退为标题，与面板
  单行创建一致：`TaskDraft.effectiveBody`）。
- 上限 50 条/次（超出部分进 `rejected`，reason `too-many`）。
- `focus` 默认 **true**：切到该工作区 board 并展开任务面板——用户刚要求建的任务，
  就该在眼前。`focus:false` 只落盘不打扰。
- 部分成功：`ok` 以「至少建了一条」为准；一条都没建成 → 400 + `rejected` 原因。
- 任务一律以「待处理、未入队」落盘：**建任务不启动任何东西**，队列与运行仍由用户在
  面板上决定（与面板内新建任务完全同语义）。

### 2.2 工作区解析

Agent 的 cwd 是**会话工作区**，但可能落在子目录（`pwd` ≠ workspace 根）。
解析顺序（纯函数 `TasksAPIWorkspace.resolve`，可单测）：

1. 请求里的 `workspace` 与面板当前 board / 已跟踪 board **完全一致** → 用它；
2. 否则在候选里找它的**最近祖先**（cwd 在 workspace 子目录里的常见情形）→ 用祖先；
3. 否则该路径本身存在且是目录 → 就用它（用户可能正在另一个项目里让 Agent 建任务）；
4. 都没有（没传 workspace 且面板没有 board）→ 400 `no-workspace`。

候选取面板当前工作区 + 所有已跟踪工作区（`TaskWorkspaceRegistry`），不额外做 RPC。

### 2.3 落盘与线程

- API 线程 → `DispatchQueue.main.sync`（沿用 `BrowserAPIBridge.apiStatus` 的既有形状）：
  board 的读改写必须与面板的 3 秒 step 定时器同一条线程，否则两个写者会互相覆盖。
- 写入走 `TasksRunner.createManualTask(TaskDraft)`（唯一入口，自带 persist 与日志），
  再由面板 `syncFromBoard()` 重绘——与用户在面板上点「创建」是同一条路径。
- 非当前工作区：`TaskWorkspaceRegistry.runner(for:)` 取/建 runner 后直接写，
  `focus:true` 时再 `adopt` 过去（当前工作区若在跑任务不受影响，registry 一直跟踪它）。

## 3. 实现清单

| 文件 | 改动 |
|---|---|
| `platforms/macos/src/TasksAPI.swift`（新） | `HTTPRequest/HTTPResponse` 之上的纯路由：`TasksAPIRouter.route`、`TaskCreateDraft`、`TasksAPIDelegate` 协议、`TaskAPIWorkspace` 解析、`TaskAPIResult` 序列化；无 AppKit 依赖，无头可测 |
| `platforms/macos/src/BrowserAPI.swift` | `BrowserAPIRouter.route` 开头挂 `TasksAPIRouter.route(request, delegate: delegate as? TasksAPIDelegate)`（命中即返回，未命中返回 nil 继续原路由）；`BrowserAPIBridge` 实现 `TasksAPIDelegate`（`main.sync` 派发；已在主线程时不再 sync，测试会从主线程调用）。“面板控制器”以**闭包**注入（`tasksList` / `tasksCreate`），本文件因此**不认识面板类型** —— 这是 `tests/browser-panel` 能无头编译它的前提 |
| `platforms/macos/src/IssueRunnerPanel.swift` | `apiTaskList(workspace:)` / `apiTaskCreate(workspace:focus:drafts:)`；新增 `onShowPanel` 闭包 |
| `platforms/macos/src/main.swift` | `BrowserAPIBridge` 桥接任务面板（weak）+ `showTasksPanel`；端口文件再加 `shell-api.port`；新增 L10n 文案 |
| `platforms/macos/src/SkillInstaller.swift` | `BuiltinSkill.taskTodo` 用例 + 内嵌 markdown |
| `.dsh/skills/task-todo/SKILL.md`（新） | 仓库副本（与内嵌字节一致，tests/skills 校验） |
| `tests/tasks-panel/api-tests.swift`（新） | 路由/解析/工作区解析/上限/部分失败 |
| `docs/`、`README.md`、`CHANGELOG.md`、`.dsh/wiki/` | 文档同步 |

单测依赖：`TasksAPI.swift`（纯模型）+ `TasksCore.swift`（taskDictionary/queueDictionary 的类型）
+ 本测试自带的 HTTPRequest/HTTPResponse 形状替身；不引入 AppKit、不编译 `BrowserAPI.swift`。
对照面由 `tests/browser-panel` 覆盖：它把 `TasksAPI.swift` 一起编译并跑真实的
`BrowserAPIRouter`，从而钉住「两块路由面同处一个服务、互不吞对方的路由与 404」。

## 4. Skill 正文（要点）

- 触发：**只有用户明确要求**（「建任务/生成任务清单/写进任务面板」）才执行；沟通没结束、
  用户没点头，不建。
- 输入：本轮对话里已确认的需求与方案；每条任务 = 标题（可扫的行）+ 描述（给执行者的
  上下文与验收点，写清「做什么/依据什么/怎么算完成」，不臆造）。
- 动作：先 `GET /api/tasks/list` 看面板里已有什么（避免重复建），再 `POST /api/tasks/create`
  一次提交全部任务；不逐条调用。
- 边界：**不启动任务、不建队列、不改分支**（那是用户/面板的事）；不直接改
  `.dsh/tasks/*.json`；端口不通就报错并请用户打开 oh-my-dsh。
- 汇报：列出创建的 id/标题与面板里看到的样子，几行以内。

## 5. 测试

1. `tests/tasks-panel/api-tests.swift`（新增，并入 `run.sh`）：
   - 路由命中：GET list / POST create / 其它路径返回 nil（不吞原路由）；
   - 解析：字符串简写、对象、空标题 → `rejected:empty-title`、非数组 → 400、>50 → `too-many`；
   - workspace 解析：完全匹配 / 子目录 → 祖先 / 未知路径原样 / 无候选 → nil；
   - delegate 缺失 → 503 `panel-unavailable`；
   - 响应的 JSON 形状（created/rejected/ok/status）。
2. `tests/skills/run.sh` 自动覆盖新技能：安装、托管更新、仓库副本字节一致。
3. `node --test core/tests/` 与其余 `tests/*/run.sh` 保持全绿。

## 6. 边界与失败模式

- App 未运行：curl 直接失败 → Skill 报「oh-my-dsh 没在运行」，不建文件、不假装。
- 端口被占：服务自增端口，`shell-api.port` 由 App 写，Skill 永远读实际值。
- 面板尚未 adopt 任何工作区（早期启动）：`no-workspace`，Skill 请用户先选项目。
- 重名任务：不自动去重（与面板内新建一致）；Skill 要求先 list 再建。
- 任务面板被关闭：`focus:true` 会展开它（`setRightPanel(.tasks)`）。
- 并发：API 写入经主线程串行，与 step 定时器同一线程，不存在两个写者。

## 7. 已定决策

1. **通道**：壳层本地 API（不用「直接写 .dsh/tasks/*.json」——面板内存态会覆盖，且无反馈）。
2. **Skill 名**：`task-todo`（领域词 + 面板名，与 web-dev-tools / repo-knowledge / issue-resolve 同一体例）。
3. **能力边界**：只创建（+ 查询）；建队列、入队、启动一律留给用户与面板。
4. **默认 focus**：true（用户刚要求的东西要看得见）。
5. **批量**：一次请求多条，上限 50。
6. **用户显式要求**：写进 Skill 正文硬规则；Skill 不主动建任务。
