# 浏览器面板「内容区一片空白 + 右键菜单弹错位」分析与修复

> 日期：2026-09-13
> 状态：已实施（`platforms/macos/src/BrowserPanel.swift` / `platforms/macos/src/ShellConfig.swift` / `platforms/macos/src/main.swift`，分支 `release/1.14`）
> 现象版本：v1.14.0

## 问题描述

内置浏览器面板（CEF/Chromium）里输入网址后：

- **内容区一片空白**（只有背景色），但页签标题、地址栏、前进/后退状态**照常跟随**页面更新；
- 右键能弹出菜单，但**位置离谱**：点右键 → 菜单跑到屏幕左半边；点下面 → 菜单跑到上面，点上面 → 跑到下面（用户描述为「点右边，左边有反应」）；
- CEF 本身是好的：`/api/browser/eval`、`console`、`screenshot`（CDP 截图）全部正常——**只靠 REST API 排查发现不了**。

## 根因（两层叠加）

### 一、触发点：1.14.0 设置搬家丢了用户取值

v1.14.0 把壳层设置从 `UserDefaults` 搬进 `$DSH_HOME/shell/config.json`（`ShellConfig`，日志与 CLI 可读），但**没有迁移已有取值**：

| 位置 | 内容 |
|------|------|
| `defaults read com.ohmydsh.app` | `browserRenderMode = windowed`（用户显式设过，1.14.0 之前一直生效） |
| `~/.dsh/shell/config.json` | 无 `browserRenderMode` → 代码落到默认分支 |

`main.swift` 当时写的是 `ShellConfig.shared.string(forKey: "browserRenderMode") == "windowed"`，键缺失即 **OSR（离屏帧自绘）**。于是升级到 1.14.0 的用户（以及任何没设过这个键的人）**静默换到了另一条渲染路径**——而这条路径是坏的（见下），日志里只有一行 `CEF render mode: osr`。

> 注：docs/plans/BROWSER_PLAN-browser-panel.md §十一 记录的是「最终切窗口化（`SetAsChild`，Chromium 原生绘制）」，只有 OSR 可回退；代码默认与之相反，属于实现与文档不一致，这一次被设置搬家引爆。

### 二、OSR 路径本身：帧画在被盖住的层上

视图嵌套（OSR 模式）：

```
contentContainer (masksToBounds)
└── BrowserOSRView            ← 帧原来写在这里（父层 contents）
    ├── pageView              ← 铺满容器 + 不透明背景（暗=黑/亮=白），页面区
    └── devtoolsArea (0 高)   ← DevTools 区
```

OSR 模式下 CEF 不建自己的视图，帧经 `OnPaint` 回调交给宿主自绘。宿主的 `presentFrame` 把帧写进 **`BrowserOSRView.layer.contents`（容器自己的层）**，而 `pageView` 是容器的子视图——**子视图的 layer 合成在父层 contents 之上**，且 `updatePageBackground()` 给 `pageView` 垫了不透明背景，于是整帧被盖得严严实实，只剩背景色。

这也解释了为什么「其他一切正常」：地址栏/标题来自 `OnTitleChange`/`OnAddressChange`，console 与截图走 CDP，都不经过这条自绘路径。

### 三、右键菜单：CEF 的菜单坐标不是视图坐标

`OnBeforeContextMenu` 给的 `GetXCoord/GetYCoord` 在 OSR 下按 `GetScreenInfo.device_scale_factor`（这里恒为 2.0）走**设备像素**——同一份证据：视口 907×1087 点，而 `OnPaint` 交来的帧是 1814×2174。宿主却按「视图坐标」换算：

```swift
// 旧实现：把设备像素当点用
NSPoint(x: CGFloat(x), y: container.bounds.height - CGFloat(y))  // → 2× 远的点
```

点于是落到窗口右下之外，`NSMenu.popUp` 只能把菜单塞回屏幕边缘 → 表现为「点右键弹到左边、点下面弹到上面」。

（对照实验：走宿主自己的 `sendMouseClick` 链路、坐标按点发送时，页面里 `mousedown` 收到的 `clientX/clientY` 与发送值完全一致——**输入事件是点、菜单参数是设备像素**，CEF 这两个回调的坐标系并不统一。）

### 四、顺带修掉：OSR 帧派发错配

帧回调按 `browserId`（shim 侧全局计数器，**DevTools 子浏览器也吃号**）派发，旧代码却用 `tab.id` 去查页签。开过 DevTools、或关过页签再开新页签后两者必然错位 → 帧画到别的页签上（或干脆不画）。

## 修复

1. **ShellConfig 一次性迁移**（`ShellConfig.legacyUserDefaultsKeys` + `loadIfNeeded()` 里的 `migrateLegacyUserDefaultsIfNeeded()`）：把旧 `UserDefaults` 里壳层自有键（browserRenderMode / appTheme / appLanguage / previewPanel* / rightPanelKind / autoUpgrade* / channel.global.list / wiki* …）搬进 `config.json`。
   - 只搬**本文件没有取值**的键；显式值永远优先；
   - `legacyUserDefaultsMigratedAt` 标记保证只做一次（旧版进程之后再写 plist 也不会覆盖新值）；
   - 迁移在 `loadIfNeeded()`（持锁）里做，因此直接原子写文件，不走 `flush()`（避免自锁）。
2. **渲染默认改回文档记载的 windowed**（`main.swift`：`!= "osr"` 即窗口化），OSR 保留为显式回退项；
3. **OSR 帧改画在 `pageView` 自己的 layer 上**：与背景色同层（背景在 contents 之下做兜底），窗口化模式不受影响；
4. **帧派发按 `browserId`**：主浏览器 → `pageView`，DevTools 子浏览器 → `devtoolsContent`；
5. **右键菜单锚点用当前鼠标的屏幕坐标**（右键必来自鼠标），CEF 参数只在鼠标不在窗口内（键盘唤起菜单）时兜底，并把兜底值写 `app.log`。

## 回归测试

| 用例 | 位置 | 对修复前代码 |
|------|------|--------------|
| 帧落在 `pageView` 的 layer（不是容器层） | `tests/browser-panel/` | FAIL（实测） |
| 容器层保持空 | `tests/browser-panel/` | FAIL（实测） |
| DevTools 帧进 `devtoolsContent`、不动主页面层 | `tests/browser-panel/` | FAIL（实测） |
| 帧按 `browserId` 派发（构造 browserId ≠ tabId） | `tests/browser-panel/` | FAIL（实测） |
| 菜单锚点回退路径不出窗口 | `tests/browser-panel/` | PASS |
| 旧 UserDefaults 取值迁移进 config.json | `tests/shell-config/` | FAIL（新套件） |
| 迁移只做一次 / config.json 优先 / 不搬无关键 | `tests/shell-config/` | FAIL（新套件） |

## 排查手法备忘

- `POST /api/browser/debug`：看 `frameCount` / `avgLum` / `osrLayerContents`——**帧到了、亮度正常**就说明 CEF 没问题，问题在宿主合成；
- `POST /api/browser/hierarchy`：全窗口视图层级 + layer `layerSuperChain`（层是否挂进窗口树）+ 命中测试 + `cacheDisplay` 截图（`/tmp/panel-browser-shot.png`）——本次就是靠 `layerSuperChain` 看到 `pageView` 的层挂在容器层之上；
- `POST /api/browser/debug {"click":[x,y]}` + 页面里 `addEventListener('mousedown')` 打 console：验证「发给 CEF 的坐标 = 页面收到的坐标」这条链路；
- 渲染路径由 `app.log` 的 `CEF render mode: windowed|osr` 一行确认。
