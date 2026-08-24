# Channel「项目视图」↔ dsh web 会话双向联动

> 状态：✅ 已落地实现（2026-08-24）
> 关联：docs/channel-status.md、docs/channel-association-model.md、platforms/macos/src/ChannelPanel.swift、platforms/macos/src/main.swift（sessionTrackerScript / sessionOpenerScript / dshSession handler）

## 1. 目标

让 Channel 面板的「项目视图」会话列表与 dsh web 的当前会话**双向联动**：

- **面板 → dsh web**：在项目视图中**点击某会话行**（= 展开/收起其消息），同时 dsh web 切换到该会话；
- **dsh web → 面板**：在 dsh web 切换会话时，面板自动展开对应的会话（无对应则保持会话列表可见、仅全部收起消息）。

## 2. 关键认知：用 sessionId 对应，不用 name

会话对应一律以 **dsh 会话 id（sessionId）** 为键，**不用 name**：

- 面板会话记录（ChannelStoreReader 读取 `~/.dsh/channels/<id>.sessions.json`）自带 `sessionId`（即 dsh 会话 id）；
- dsh web 当前会话经 `sessionTrackerScript` 以 sessionId 上报（`dshSession` message handler）；
- name 会因 /new 重绑、标题变化而失配，**不作为对应依据**。

## 3. 实现

### 3.1 面板 → dsh web（onOpenSession）

- 点击会话行（`SessionTitleBar.onTap`）同时触发：展开/收起其消息 + `onOpenSession(sessionId)` 定位到 dsh web（单一手势，无独立按钮）；
- main.swift 注入 `sessionOpenerScript`（documentStart user script），暴露 `window.__dshOpenSession(sessionId)`：
  - 发起 `session.list` RPC 用 sessionId 解析目标会话标题；
  - 先展开所有折叠的 workspace/会话组（React 渲染是异步的，故带 ≤8 次、每次 120ms 的重试）；
  - 按标题在侧边栏找到 session 行并 `click()`（与用户手动切换同一手势）。
- `openDSHSession(sessionId)` 经 `webView.evaluateJavaScript` 调用该桥。

### 3.2 dsh web → 面板（setActiveSession）

- 既有 `dshSession` message handler（sessionTrackerScript 上报当前 sessionId）在 resolve cwd 后追加 `channelPanel?.setActiveSession(sid)`；
- **单一展开状态**：面板只用 `collapsedSessionIds` 一个集合控制展开/收起。`setActiveSession` 把 follow 目标直接写入该集合——命中某会话则只展开它、其余收起；未命中（或 nil）则全部收起。手动点击会话行也读写同一集合，故手动展开/收起与 web follow **永不打架**。

## 4. 改动文件

| 文件 | 改动 |
|---|---|
| platforms/macos/src/ChannelPanel.swift | `onOpenSession` 回调；`setActiveSession` 写 `collapsedSessionIds`（单一展开状态）；点击会话行 = 展开 + 定位 dsh web；`ProjectRowView`/`ChannelSessionRow`/`SessionTitleBar` 透传 open 回调 |
| platforms/macos/src/main.swift | 注入 `sessionOpenerScript`；`channelPanel.onOpenSession` → `openDSHSession`；`dshSession` handler 追加 `setActiveSession` |

## 5. 测试 / 验收

- `swiftc` 全量编译检查通过（local-ci 阶段2 等价命令）；
- `node --test core/tests/` 172 全绿；`tests/channel-panel/run.sh` 全绿；
- 手动 QA：面板点会话行 → 展开/收起 + dsh web 切到该会话；dsh web 切会话 → 面板展开对应行、其余收起。
