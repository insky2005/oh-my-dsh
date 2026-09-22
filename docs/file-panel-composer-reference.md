# Files 面板 → 对话输入框：右键「添加到对话」（@ 引用）

> 目标：在 **Files 面板的目录树**上右键文件 / 文件夹 → **添加到对话** → dsh web 的输入框里出现该文件的 **@ 引用**，就像自己敲 `@` 从候选里选了一样。
> 约束：**不改 dsh 源码**（壳层只做「面板 + 注入」），dsh 升级可能打断它——耦合面已登记在 `docs/dsh-version-impact.md` **B9**。

## 1. 用户看到的行为

| 右键对象 | 菜单 | 结果 |
|---|---|---|
| 文件 | 添加到对话 / 重命名 / 删除 / 在 Finder 中显示 | 输入框追加一个引用 chip：`@src/foo.ts` |
| 文件夹 | 添加到对话 / 新建… / 重命名 / 删除 / 在 Finder 中显示 | `@src/components/`（**目录带尾斜杠**，模型据此知道该 list 而不是 read） |
| 项目根 / 空白处 | 根：条目可见但**禁用**；空白处：无此条目 | 工作区根没有「相对的自己」，不编造 token |
| 未打开会话（dsh web 停在启动页） | 条目禁用 | 无 editor 可写，不做无声失败 |

追加（不是替换）：用户已写的正文、图片、已有 chip 一律不动；插入后光标留在输入框末尾，可以直接接着打字。草稿里**不会**出现「@ 粘在前一个字后面」——`@` 只有在行首或空白之后才是引用 token，必要时先补一个空格。

## 2. 为什么是「写编辑器状态」而不是「伪造按键」

dsh web 的输入框是一个 **Lexical** 富文本编辑器，引用 chip 是一种**装饰器节点**（`reference-chip`）。dsh 自己从 `@` 候选里选中一项时，走的就是「把检测区间替换成一个 chip 节点」这条路（`shell.insertReference`）。壳层因此做同一件事：

- 拿到编辑器实例（Lexical 会把实例挂在根元素上：`[data-composer-input].__lexicalEditor`）；
- 从**运行时节点登记表**取出 chip 类（`editor._nodes.get('reference-chip').klass` —— 这个类在模块闭包里，除了这里拿不到）；
- 在 `editor.update()` 里把 `[可选的空格, chip, 空格]` 插到文档末尾。

好处：**不依赖焦点**（不是 `execCommand`、不是粘贴、不是模拟按键），不会「半个 token 已经敲进草稿」；插入结果与用户手选**是同一种节点**，因此提交时走的是同一条序列化路径：

```js
ref            = "@src/foo.ts"     // 模型读到的就是它（source 的 codec.serialize 是恒等）
label          = "foo.ts"          // chip 上的文字
appearance     = "file" | "folder" // chip 的图标
clipboardText  = "@src/foo.ts"     // 复制/持久化投影
```

## 3. 代码分层

| 层 | 文件 | 职责 |
|---|---|---|
| 纯模型 | `platforms/macos/src/ComposerReference.swift` | 相对路径 + `@` 语法（引号/尾斜杠/非法字符）→ `ComposerReference{text,label,appearance}`；无 AppKit，可无头测试 |
| 菜单规则 | `platforms/macos/src/FilePanelTreeMenu.swift` | 条目顺序与可见性：**isRoot 无引用**、没有监听方即禁用 |
| 面板 | `platforms/macos/src/FilePanel.swift` | 右键处理 → `onAddToConversation(ComposerReference)` |
| 壳层 | `platforms/macos/src/main.swift` | 注入 `composerReferenceScript`（`window.__dshInsertFileReference`）、`insertComposerReference()`、失败提示与日志、QA 钩子 |

引用语法（与 dsh 的 `@deepseek-ai/dsh-file-reference/grammar` 一致，故与终端 / 文件候选完全同源）：

```
@src/foo.ts            文件
@src/                  目录（尾斜杠 = 目录）
@"my dir/foo.txt"      含空格 → 引号形式
@"my dir/              含空格的目录 → 引号**不闭合**（dsh 的补全靠这个继续往下钻）
```

不能变成引用的（菜单禁用，不是编一个坏 token）：工作区根自己、工作区之外、名字里带 `"` 或控制字符（含换行）、空相对路径。

## 4. 失败模式（都不静默）

桥接函数对每一跳都做了守卫，失败回 `{ok:false, reason}`：

| reason | 含义 | 用户看到 |
|---|---|---|
| `bridge-unavailable` | 注入脚本还没装（页面还没重建过 WebView） | 「添加引用失败」提示 + 日志 |
| `no-composer` | 页面上没有 `[data-composer-input]` | 同上 |
| `no-editor` | 停在启动页（hero）／没有打开的会话：输入框是 inert 的 | 「请先在对话中打开一个会话」 |
| `unknown-composer` | 编辑器不是预期的 Lexical 形态（chip 类或文本类取不到） | 「添加引用失败」提示 + 日志 |
| `throw: …` | 上面之外的异常 | 同上（异常原文进日志） |

成功时 `app.log` 记录 `composer reference inserted (chip): @src/foo.ts`；dsh 升级后若日志里出现其它 reason，就是 B9 那一行需要复核。

## 5. 验证

### 无头（已接入 `tests/file-panel/run.sh` → `scripts/local-ci.sh`）
- `tree-menu-tests.swift`：菜单顺序 / 分组 / 禁用规则（根、无监听方、空白处）；
- `composer-reference-tests.swift`：语法与相对路径（含空格引号、目录尾斜杠、`..` 归一、非法字符、根与工作区外拒绝）。

### 真 WebKit 实测（2026-09-22，dsh 0.1.2-rc.1）
用一个**独立 WKWebView**（与壳层同引擎）加载 `http://127.0.0.1:<port>/?token=…`，打开一个会话后执行桥接函数：

```
[inject] {"hasComposer":true,"editorBound":true,"editable":true,"via":"_pending",
          "hasChipClass":true,"hasTextClass":true,"ok":true,"mode":"chip"}
[verify] {"text":"FilePanel.swift ","chipNodes":1,
          "json":"…{\"type\":\"reference-chip\",\"source\":\"reference\",
                  \"ref\":\"platforms/macos/src/FilePanel.swift\",…}"}
```

即：chip 节点落进编辑器状态、装饰器渲染出 chip（`data-composer-chip="reference"`），`ref` 就是模型要读的 `@path`。

### 在真 App 里跑（QA 钩子）

```bash
DSH_COMPOSER_TEST_SESSION=<sessionId> \
DSH_COMPOSER_TEST_PATH=platforms/macos/src/FilePanel.swift \
  open -a dist/oh-my-dsh.app --args   # 或直接跑二进制
# 期望 app.log：
#   composer probe: inserting @platforms/macos/src/FilePanel.swift (exists: true)
#   composer reference inserted (chip): @platforms/macos/src/FilePanel.swift
```

钩子走的正是右键菜单那条路（同一个格式化 + 同一个注入函数），只是省掉点击；`DSH_COMPOSER_TEST_SESSION` 是因为刚加载的页面停在启动页（没有 editor 可写）。

## 6. 未做（有意）

- **一次加多个**：目录树是单选，菜单作用于右键那一行；批量选择、拖拽、剪贴板粘贴都没有做。
- **chip 之外的形态**：不提供「插入纯文本 @path」的开关——dsh 自己把「手敲的 @token」也当作引用（文本引用会被着色），但壳层插入的一律是 chip，行为统一。
- **不改草稿顺序**：只追加，不插到光标处（右键发生在面板里，光标位置在那个时刻没有意义）。
