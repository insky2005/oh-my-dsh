# 终端粘贴混乱 & 方向键失效 问题总结与解决思路

> 适用版本：1.6.28（修复完成）· 症状：终端里 ⌘V 粘贴文字出现乱码（英文也乱），↑/↓ 方向键无法调出历史命令

## 问题描述

在 oh-my-dsh.app 的终端面板中：

1. **粘贴混乱**：⌘V 粘贴英文文本后，终端里出现乱码——zsh 显示成反向视频的 `<ffffffff>` / `<05ed>` 十六进制占位块，字符顺序错乱；
2. **方向键失效**：按 ↑/↓ 无法切换历史命令，终端只响一声蜂鸣（`BEL`）。

单字符打字一直正常（`abc`、`git status` 都能正常输入执行），所以问题长期被掩盖。

## 排查过程（关键线索）

### 1. 诊断日志定位（DSH_TERMINAL_DEBUG=1）

给输入/输出路径加日志后，抓到了三个决定性事实：

```
term input: special keyCode=126 -> "\u{1B}[A"     ← 方向键已发送
term output: "\u{07}"                            ← 但 shell 只回蜂鸣
term input: paste 44 chars bracketed=true bytes(56) [1b 5b 32 30 30 7e …]  ← 粘贴字节在写入侧完全正确
term output: "\u{1B}[7m<ffffffff>\u{1B}[27m"      ← shell 侧却渲染成十六进制占位
```

- **方向键和粘贴事件都正确到达了视图层**（keyDown 正常、日志字节正确）；
- **shell（zsh + oh-my-zsh + robbyrussell）对收到的多字节序列反应异常**：蜂鸣、显示 `<ffffffff>`；
- 单字符打字正常 → 问题集中在**多字节输入**。

### 2. 排除的假设

| 假设 | 结论 |
|---|---|
| 颜色/tint 渲染问题 | ❌ 是输入问题不是渲染问题 |
| zsh 的 bracketed-paste / DECCKM 模式不匹配 | ⚠️ 部分相关（见下），但**不是主因** |
| PTY 缺少 UTF-8 locale | ⚠️ 有影响，但**不是主因**（强制 locale 后仍乱） |
| oh-my-zsh 键位绑定缺失 | ❌ 实测 `^[OA` 已绑定 `up-line-or-history` |

### 3. 最终定位：写入 API 用错（Pipe 往返十六进制铁证）

用普通 `pipe()` 直接验证 `Darwin.write` 的写入内容（无需 PTY）：

```
期望写入: 68 65 6c 6c 6f 20 77 6f 72 6c 64        ("hello world")
实际写入: 68 04 00 00 00 00 00 00 00 00 00        ← 只有首字节对！
改用 withUnsafeBytes: 68 65 6c 6c 6f …             ← 逐字节正确
```

**根因：`Darwin.write(fd, &bytes[off], count)` 对 Swift `[UInt8]` 数组写出的不是元素数据，而是数组对象头部**（首元素后紧跟的是数组内部的引用计数/容量等头字节）。

**为什么单字符打字一直正常**：每次按键只写 1 字节，`&bytes[0]` 恰好第一个字节正确，count=1 不会把后面的头字节带出去；而方向键（`\x1bOA`）和粘贴文本是多字节，第一个字节 `\x1b` 之后全是垃圾头字节 → zsh 收到 `\x1b`+乱码 → 蜂鸣/`<ffffffff>`。

## 解决思路（三层修复）

### ① 主修复：重写 PTY 写入路径

```swift
// 错误写法（写出数组头部）：
var bytes = Array(data)
let n = Darwin.write(fd, &bytes[off], bytes.count - off)

// 正确写法（逐字节写入）：
data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
    guard let base = raw.baseAddress else { return }
    var off = 0
    while off < raw.count {
        let n = Darwin.write(fd, base.advanced(by: off), raw.count - off)
        if n > 0 { off += n; continue }
        if n < 0 && errno == EINTR { continue }
        break
    }
}
```

**经验：向 C 函数传 Swift Array 缓冲区时，不要用 `&array[index]` 当指针，用 `withUnsafeBytes`/`withUnsafeBufferPointer` 拿到真实的连续内存。**

### ② 配套：终端模式跟踪（真实终端行为）

zsh 在提示符处会启用两个模式，终端必须跟踪并据此编码输入：

| 模式 | 转义 | 影响 |
|---|---|---|
| DECCKM 应用光标键 | `CSI ? 1 h` / `l` | 方向键：应用模式 `\x1bOA/B/C/D`，普通模式 `\x1b[A/B/C/D` |
| 括号粘贴 | `CSI ? 2004 h` / `l` | 粘贴文本需包 `\x1b[200~ … \x1b[201~`，否则 shell 渲染乱码 |

在 `TerminalEmulator` 中跟踪这两个状态（`handlePrivateCSI` 的 `?1h/l`、`?2004h/l`），`TerminalView` 的 `paste` 与方向键映射按状态编码。

### ③ 辅助：PTY 子进程强制 UTF-8 locale

GUI 进程启动的子进程常缺 `LANG`/`LC_ALL`，zsh 在非 UTF-8 locale 下会把输入字节渲染成 `<ffffffff>`/`<05ed>` 占位。给 PTY 环境强制：

```
LANG=en_US.UTF-8  LC_ALL=en_US.UTF-8  LC_CTYPE=en_US.UTF-8
```

## 修复结果验证

1. **Pipe 往返测试**：`withUnsafeBytes` 写出的字节与输入完全一致（`match: true`）；
2. **模拟器单元测试**：新增 DECCKM/括号粘贴模式跟踪断言（`?1h` → `applicationCursorKeys=true`，`?2004h` → `bracketedPaste=true`，`?1l`/`?2004l`/RIS 复位），全部通过；
3. **真机验证**：↑/↓ 正常调出历史命令、⌘V 粘贴原样显示无乱码，用户确认「正常了」。

## 经验总结

1. **C API 与 Swift 数组的内存模型**：`&array[index]` 传给 C 的 `write`/`read` 类函数，拿到的是数组对象而非元素存储——必须用 `withUnsafeBytes`。这类 bug 特征明显：**单字节正常、多字节必坏**。
2. **终端实现必须跟踪 shell 的模式切换**（DECCKM、括号粘贴、备用屏等），否则键码/粘贴编码与 shell 预期不匹配。
3. **诊断优先于猜测**：给 I/O 路径加字节级日志（`DSH_TERMINAL_DEBUG=1`），用 `pipe()` 在无 PTY 环境下也能验证写入正确性——本轮能定位到写入 API 正是靠 pipe 往返的十六进制对比。
4. **单字节正常不代表写入路径正确**：打字、按键这类 1 字节输入无法暴露多字节写入 bug，必须用粘贴、方向键等真实多字节场景回归。
