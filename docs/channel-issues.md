# Channel 消息重复回复问题排查记录

> 状态：✅ 已修复（2026-08-21）
> 关联：docs/channel-design.md、docs/channel-ui-commands.md、core/lib/weixin-clawbot.js、core/lib/weixin-clawbot-transport.js

## 1. 问题现象

在微信里发送一条消息（如 /help），**收到 5 条重复回复**（两种内容各 5 条：『该会话未绑定任何项目（未匹配路由）』和『可用指令：…』）。/ping 也回复 5 条 pong。

## 2. 排查过程

### 2.1 排除的错误假设

| 假设 | 结论 |
|---|---|
| 多个 runner 在跑 | ✗ 用 ps/pgrep 确认只有 1 个 channel run 进程 |
| 消息堆积（早期多条消息） | ✗ 清空队列后重发，仍重复 |
| 请求格式与官方不一致 | ✗ 逐项核对官方 main 分支 src/api/api.ts，headers/body/base_info 完全一致 |

### 2.2 加跟踪日志定位

在 transport 的 fetchUpdates 和 runner 的 onEvent 加日志后，铁证如下：

    [clawbot:...] fetchUpdates got 1 msg(s) @088293 [{id:7496605738120288000, t:"/help"}]
    [clawbot:...] fetchUpdates got 1 msg(s) @098551 [{id:7496605738120288000, t:"/help"}]  ← 同一 messageId
    [clawbot:...] fetchUpdates got 1 msg(s) @100579 [{id:7496605738120288000, t:"/help"}]
    ... 共 6 次
    [transport] buf advanced len 0->96 tail=ZWIyYzA=
    [transport] buf advanced len 96->96 tail=ZWIyYzA=  ← tail 完全相同

**结论**：服务端每次返回的 get_updates_buf 内容完全不变（游标未推进），同一条消息（相同 messageId）被反复返回 → 每次都被处理并回复。

### 2.3 与官方实现逐项核对

- 官方 Tencent/openclaw-weixin main 分支 src/api/api.ts：getUpdates 请求体 = { get_updates_buf, base_info: { channel_version, bot_agent } }，headers 含 iLink-App-Id / iLink-App-ClientVersion / AuthorizationType / X-WECHAT-UIN / Authorization——与我们的实现一致。
- 官方 src/monitor/monitor.ts：**严格串行 while 死循环**（无 setInterval），每次 getUpdates 阻塞到新消息或长轮询超时，然后立即循环；get_updates_buf 持久化到磁盘。

## 3. 根因

**轮询方式破坏了长轮询游标推进。**

我们的 adapter 用 setInterval(tick, intervalMs=1000) 每 1 秒触发一次 fetchUpdates。虽然 fetchUpdates 内部是长轮询（35s），但这种 setInterval 驱动的方式破坏了与服务端长轮询连接的**连续性**，导致服务端不推进 get_updates_buf 游标 → 同一条消息被反复推送。

> 注：部分资料称 iLink 协议层有 ACK/seq_id 机制，但官方开源源码（plugin 层）不含显式 ACK——ACK 在 openclaw 网关层。我们脱离网关裸调 HTTP 时，必须以官方 plugin 完全一致的**严格串行长轮询**方式才能让游标正确推进。

## 4. 解决方案

把 adapter 的轮询从 setInterval 改为**官方式的严格串行 while 循环**（core/lib/weixin-clawbot.js）：

    function startPolling() {
      if (pollTimer || running) return;
      running = true;
      const loop = async () => {
        while (running) {
          try {
            const raw = await transport.fetchUpdates();  // 长轮询：阻塞到新消息或超时
            for (const r of raw || []) { /* normalize + emit */ }
            await sleep(0);  // 仅防 mock 立即返回时 busy-loop；真实长轮询自然阻塞
          } catch (err) {
            lastError = err;
            state.reconnecting();
            if (transport.onError) transport.onError(err);
            await sleep(intervalMs);  // 出错才短暂退避
          }
        }
      };
      pollTimer = loop();
    }

## 5. 验证

- 修复后，微信发 /help **只收到 1 条**回复（onEvent 1 次、command 1 次）。
- node --test core/tests/*.test.js：**131 全绿**。
- 附带修复：runner 去重（同 channelId 只跑一个）、channel run CLI 默认 dshHome=~/.dsh、增加 onEvent/command 诊断日志。

## 6. 涉及提交

| 提交 | 内容 |
|---|---|
| 346ed7b | runner 去重 + channel run 默认 dshHome |
| afa46d5 | **轮询改严格串行 while 长轮询（核心修复）** |
| a64278a | runner 增加 onEvent/command 诊断日志 |
| 8031766 | 文档记录长轮询游标教训 |

## 7. 经验教训（后续接入平台注意）

1. **长轮询必须严格串行**：一个长轮询连接要连续，不能 setInterval 每 N ms 重触发，否则游标不推进、消息重复。
2. **与官方实现逐项对齐**：接入前拉官方源码（npm 编译产物可能滞后）核对请求格式。
3. **加跟踪日志是定位利器**：在 fetchUpdates/onEvent 加日志，能立刻看到『同一 messageId 反复返回』这一铁证。
4. 钉钉/飞书若用长轮询/长连接，同样遵循『严格串行』原则。