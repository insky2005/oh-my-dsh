---
name: web-dev-tools
description: 驱动 oh-my-dsh 壳层的「浏览器」面板排查网页问题（打开页面、读 console/网络日志、执行 JS、截图）。Drive the oh-my-dsh shell's Browser panel to troubleshoot web pages (open pages, read console/network logs, run JS, take screenshots).
modelInvocable: true
---

# web-dev-tools — 用 oh-my-dsh 浏览器面板排查网页问题

oh-my-dsh 壳层内置一个**浏览器面板**（CEF 嵌入式 Chromium 内核），通过 **localhost REST API** 驱动，无需额外浏览器/驱动。面板与 dsh web 共用同一 App，Agent 驱动时面板会自动展开，用户实时可见。

## 端口发现（必做）

API 服务随 App 启动常驻，默认端口 **3081**。按顺序取：

```bash
PORT="$(cat "$HOME/.dsh/browser-api.port" 2>/dev/null || echo 3081)"
```

（若设置了 `DSH_BROWSER_PORT` 环境变量则端口不同；port 文件由 App 写入。App 未运行时 API 不可用——先请用户打开 oh-my-dsh。）

## API 速查（`http://127.0.0.1:$PORT`）

| 方法/路径 | 请求体 | 说明 |
|---|---|---|
| GET `/api/browser/status` | — | `{panelVisible, tabs:[{id,url,title,loading,canGoBack,canGoForward}], activeTabId}` |
| POST `/api/browser/open` | `{"url":"…","tab":"active"\|"new"\|tabId}` | 打开/导航；自动展开面板（`"show":false` 可抑制） |
| POST `/api/browser/tabs` | `{"action":"new"\|"close"\|"activate","tabId":N}` | 标签管理 |
| POST `/api/browser/back` `/forward` `/reload` `/stop` | `{"tabId":N?}` | 导航控制 |
| POST `/api/browser/eval` | `{"expression":"document.title"}` | JS 求值 → `{ok,result}` / `{ok:false,error}` |
| GET `/api/browser/console` | `?level=error&limit=50` | console 日志（含 `network` 行） |
| POST `/api/browser/console/clear` | — | 清空 |
| GET `/api/browser/screenshot` | — | PNG 字节（`curl -o` 保存） |
| POST `/api/browser/hide` | — | 收起面板 |

## 标准排查工作流

1. **打开页面**：
   ```bash
   curl -s -X POST "http://127.0.0.1:$PORT/api/browser/open" -d '{"url":"https://example.com/page"}' -H 'Content-Type: application/json'
   ```
2. **等待加载完成**（轮询 status 直到目标 tab `loading=false`，最多 ~30s；超时视为页面慢，继续读日志）：
   ```bash
   for i in $(seq 1 30); do
     S=$(curl -s "http://127.0.0.1:$PORT/api/browser/status")
     echo "$S" | grep -q '"loading":false' && break
     sleep 1
   done
   ```
3. **读 console 日志（重点看 error/network 失败行）**：
   ```bash
   curl -s "http://127.0.0.1:$PORT/api/browser/console?level=error&limit=100"
   curl -s "http://127.0.0.1:$PORT/api/browser/console?limit=200" | python3 -c "import sys,json; [print(e['level'], e['text']) for e in json.load(sys.stdin)['entries'] if e['level'] in ('error','network')]"
   ```
4. **JS 求值取证**（DOM 状态、接口返回值、渲染结果）：
   ```bash
   curl -s -X POST "http://127.0.0.1:$PORT/api/browser/eval" -d '{"expression":"document.title + \" | \" + document.readyState"}' -H 'Content-Type: application/json'
   curl -s -X POST "http://127.0.0.1:$PORT/api/browser/eval" -d '{"expression":"JSON.stringify(document.querySelectorAll(\"img\").length)"}' -H 'Content-Type: application/json'
   ```
5. **截图取证**（存工作区，可读图/分享，预览面板可见）：
   ```bash
   curl -s "http://127.0.0.1:$PORT/api/browser/screenshot" -o "$(pwd)/browser-shot.png" && ls -la browser-shot.png
   ```
6. **汇报**：URL、加载结果、console/网络错误（含状态码）、eval 关键值、截图路径与观察结论。

## 注意事项

- **安全边界**：API 仅绑定 127.0.0.1、无鉴权（与 dsh web 同信任模型）；`eval` 可读任意页面内容——只对用户指定的页面操作；
- **能力**：CDP 捕获 console/异常/全部网络请求（含图片/CSS/子框架，优于 WKWebView 注入）；完整 DevTools 由面板头部「DevTools」按钮在系统浏览器打开；
- 面板隐藏时 status/open/eval/screenshot 全部可用（CEF 离屏渲染，截图无需展开面板）；
- 多标签：open 默认在当前 tab 导航，`"tab":"new"` 新建；tab 上限 8。
