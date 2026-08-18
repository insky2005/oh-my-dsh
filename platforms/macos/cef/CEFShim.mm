// CEFShim.mm — Objective-C++ bridge（OSR 渲染模式）。详见 CEFShim.h。
//
// Build: clang++ -std=c++20 -fno-exceptions -fno-rtti -fobjc-call-cxx-cdtors
// -fvisibility=hidden -mmacosx-version-min=13.0；链接 -Wl,-undefined,dynamic_lookup
// （CEF C API 由 libcef_dll_dylib trampoline 在运行期 dlopen 框架解析）。

#import "CEFShim.h"

#include "include/base/cef_build.h"
#include "include/cef_app.h"
#include "include/cef_browser.h"
#include "include/cef_browser_process_handler.h"
#include "include/cef_client.h"
#include "include/cef_command_line.h"
#include "include/cef_context_menu_handler.h"
#include "include/cef_display_handler.h"
#include "include/cef_life_span_handler.h"
#include "include/cef_load_handler.h"
#include "include/cef_render_handler.h"
#include "include/wrapper/cef_helpers.h"
#include "include/wrapper/cef_library_loader.h"

#include <map>
#include <string>
#include <vector>
#include <unistd.h>

#if defined(OS_MAC)
#include "include/cef_application_mac.h"
#endif

@interface CEFDelegateProxy : NSObject
@property(nonatomic, weak) id<CEFBrowserDelegate> delegate;
@end
@implementation CEFDelegateProxy
@end

namespace {

struct PendingCreate {
  NSView* view;
  std::string url;
  CEFDelegateProxy* proxy;
  int64_t browserId;
};

class BrowserClient;
class AppShim;

CefScopedLibraryLoader* g_loader = nullptr;
CefRefPtr<AppShim> g_app;
std::map<int64_t, CefRefPtr<CefBrowser>> g_browsers;
std::map<int64_t, CefRefPtr<BrowserClient>> g_clients;
std::vector<PendingCreate> g_pending;
int64_t g_nextBrowserId = 1;
bool g_ready = false;
// 渲染模式：NO=OSR（默认），YES=窗口化（CEF 自建 NSView 原生绘制）。
bool g_windowedMode = false;

// OSR 帧回调（Swift 侧经 CEFShim.setPaintHandler 注册）。
static CEFPaintHandler g_paintHandler = nil;
// 光标变化回调（hover 跟随页面）。
static CEFCursorHandler g_cursorHandler = nil;
// 上下文菜单请求回调。
static CEFMenuRequestHandler g_menuRequestHandler = nil;
// 每个 browser 的菜单模型（executeContextMenuCommand 用）。
std::map<int64_t, CefRefPtr<CefMenuModel>> g_menu_models;
// DevTools 独立宿主窗口（强引用防释放；CEF 150 mac 无 SetAsPopup）。
NSWindow* g_devtoolsWindow = nil;

bool CreateBrowserInternal(NSView* view, const std::string& url,
                           CEFDelegateProxy* proxy, int64_t browserId);

class AppShim : public CefApp, public CefBrowserProcessHandler {
 public:
  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override {
    return this;
  }

  // 避免钥匙串弹密码框；允许软件渲染兜底。
  void OnBeforeCommandLineProcessing(const CefString& process_type,
                                     CefRefPtr<CefCommandLine> command_line) override {
    command_line->AppendSwitch("use-mock-keychain");
    command_line->AppendSwitch("enable-unsafe-swiftshader");
    command_line->AppendSwitch("ignore-gpu-blocklist");
    // DevTools 前端（inspector.html 页面）发起的 WebSocket 连接带
    // Origin: http://127.0.0.1:9333；CEF 默认拒绝带 Origin 的 DevTools
    // ws → 页面报 "WebSocket 无法连接"。放行所有 Origin（本地调试端口）。
    command_line->AppendSwitchWithValue("remote-allow-origins", "*");
    // （GPU 路径已恢复默认）
  }

  void OnContextInitialized() override {
    for (const PendingCreate& p : g_pending) {
      CreateBrowserInternal(p.view, p.url, p.proxy, p.browserId);
    }
    g_pending.clear();
    g_ready = true;
  }

 private:
  IMPLEMENT_REFCOUNTING(AppShim);
};

class BrowserClient : public CefClient,
                      public CefLifeSpanHandler,
                      public CefLoadHandler,
                      public CefDisplayHandler,
                      public CefRenderHandler,
                      public CefContextMenuHandler {
 public:
  explicit BrowserClient(CEFDelegateProxy* proxy, int64_t browserId)
      : proxy_(proxy), browserId_(browserId) {}

  void SetViewSize(NSSize size) { viewSize_ = size; }

  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefRenderHandler> GetRenderHandler() override { return this; }
  CefRefPtr<CefContextMenuHandler> GetContextMenuHandler() override { return this; }

  // CefLifeSpanHandler
  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    NSLog(@"CEFShim OnAfterCreated browser=%lld windowed=%d", browserId_, (int)g_windowedMode);
    g_browsers[browserId_] = browser;
    // 窗口化模式：CEF 自建的 NSView 跟随容器尺寸（父容器 autoresizesSubviews）。
    if (g_windowedMode) {
      NSView* cefView = (__bridge NSView*)browser->GetHost()->GetWindowHandle();
      NSLog(@"CEFShim OnAfterCreated view=%@ super=%@ window=%@",
            cefView, cefView.superview, cefView.window);
      if (cefView) {
        cefView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [cefView setFrame:NSMakeRect(0, 0, viewSize_.width, viewSize_.height)];
      }
    }
    NotifyLoading(browser);
  }

  bool DoClose(CefRefPtr<CefBrowser> browser) override {
    NSLog(@"CEFShim DoClose browser=%lld", browserId_);
    return false;
  }

  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    NSLog(@"CEFShim OnBeforeClose browser=%lld", browserId_);
    g_browsers.erase(browserId_);
    g_clients.erase(browserId_);
    g_menu_models.erase(browserId_);
    id<CEFBrowserDelegate> d = proxy_.delegate;
    if (d && [d respondsToSelector:@selector(cefBrowserClosed:)]) {
      [d cefBrowserClosed:browserId_];
    }
  }

  // CefLoadHandler
  void OnLoadingStateChange(CefRefPtr<CefBrowser> browser, bool isLoading,
                            bool canGoBack, bool canGoForward) override {
    NotifyLoading(browser);
  }

  void OnLoadError(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                   cef_errorcode_t errorCode, const CefString& errorText,
                   const CefString& failedUrl) override {
    if (!frame->IsMain()) return;
    id<CEFBrowserDelegate> d = proxy_.delegate;
    if (d && [d respondsToSelector:@selector(cefLoadError:failedURL:forBrowser:)]) {
      [d cefLoadError:[NSString stringWithUTF8String:errorText.ToString().c_str()]
            failedURL:[NSString stringWithUTF8String:failedUrl.ToString().c_str()]
           forBrowser:browserId_];
    }
  }

  // CefDisplayHandler
  void OnTitleChange(CefRefPtr<CefBrowser> browser, const CefString& title) override {
    id<CEFBrowserDelegate> d = proxy_.delegate;
    if (d && [d respondsToSelector:@selector(cefTitleChanged:forBrowser:)]) {
      [d cefTitleChanged:[NSString stringWithUTF8String:title.ToString().c_str()]
              forBrowser:browserId_];
    }
  }

  // 主 frame 导航地址变化（窗口化模式触发；后退/前进/重定向后更新地址栏）。
  void OnAddressChange(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                       const CefString& url) override {
    if (!frame->IsMain()) return;
    id<CEFBrowserDelegate> d = proxy_.delegate;
    if (d && [d respondsToSelector:@selector(cefAddressChanged:forBrowser:)]) {
      [d cefAddressChanged:[NSString stringWithUTF8String:url.ToString().c_str()]
               forBrowser:browserId_];
    }
  }

  // CefRenderHandler（OSR）
  void GetViewRect(CefRefPtr<CefBrowser> browser, CefRect& rect) override {
    rect = CefRect(0, 0, (int)viewSize_.width, (int)viewSize_.height);
  }

  void OnPaint(CefRefPtr<CefBrowser> browser, PaintElementType type,
               const RectList& dirtyRects, const void* buffer, int width,
               int height) override {
    if (type != PET_VIEW || !g_paintHandler || !buffer) return;
    // buffer 仅在本次回调内有效：先同步拷贝成 NSData，再派发到主队列。
    NSData* copy = [NSData dataWithBytes:buffer length:(NSUInteger)width * (NSUInteger)height * 4];
    CEFPaintHandler handler = g_paintHandler;
    int64_t bid = browserId_;
    dispatch_async(dispatch_get_main_queue(), ^{
      handler(bid, copy.bytes, width, height);
    });
  }

  bool GetScreenInfo(CefRefPtr<CefBrowser> browser, CefScreenInfo& screen_info) override {
    if (viewSize_.width <= 0 || viewSize_.height <= 0) return false;
    screen_info.rect = CefRect(0, 0, (int)viewSize_.width, (int)viewSize_.height);
    screen_info.available_rect = screen_info.rect;
    screen_info.device_scale_factor = 2.0;
    return true;
  }

  // OSR hover：页面光标变化（链接 → pointing hand 等）回调宿主。
  // （CefDisplayHandler::OnCursorChange，返回 bool）
  bool OnCursorChange(CefRefPtr<CefBrowser> browser, CefCursorHandle cursor,
                      cef_cursor_type_t type,
                      const CefCursorInfo& custom_cursor_info) override {
    if (g_cursorHandler) {
      CEFCursorHandler h = g_cursorHandler;
      int64_t bid = browserId_;
      void* c = cursor;
      dispatch_async(dispatch_get_main_queue(), ^{ h(bid, c); });
    }
    return false;
  }

  // CefContextMenuHandler
  // OSR 下 CEF 不知道宿主窗口位置，默认菜单会弹错位；这里把菜单模型转给
  // Swift 侧，由宿主在正确的屏幕坐标弹 NSMenu。
  void OnBeforeContextMenu(CefRefPtr<CefBrowser> browser,
                           CefRefPtr<CefFrame> frame,
                           CefRefPtr<CefContextMenuParams> params,
                           CefRefPtr<CefMenuModel> model) override {
    g_menu_models[browserId_] = model;
    if (!g_menuRequestHandler) return;
    NSMutableArray* items = [NSMutableArray array];
    int count = model->GetCount();
    for (int i = 0; i < count; i++) {
      cef_menu_item_type_t t = model->GetType(i);
      int cmdId = model->GetCommandIdAt(i);
      CefString label = model->GetLabelAt(i);
      NSMutableDictionary* d = [NSMutableDictionary dictionary];
      d[@"id"] = @(cmdId);
      d[@"type"] = @((NSInteger)t);
      if (!label.empty()) {
        d[@"label"] = [NSString stringWithUTF8String:label.ToString().c_str()];
      }
      [items addObject:d];
    }
    CEFMenuRequestHandler h = g_menuRequestHandler;
    int64_t bid = browserId_;
    float x = params->GetXCoord(), y = params->GetYCoord();
    dispatch_async(dispatch_get_main_queue(), ^{ h(bid, x, y, items); });
  }

 private:
  void NotifyLoading(CefRefPtr<CefBrowser> browser) {
    id<CEFBrowserDelegate> d = proxy_.delegate;
    if (!d || ![d respondsToSelector:@selector(cefLoadingStateChanged:canGoBack:canGoForward:forBrowser:)]) return;
    [d cefLoadingStateChanged:browser->IsLoading()
                    canGoBack:browser->CanGoBack()
                 canGoForward:browser->CanGoForward()
                   forBrowser:browserId_];
  }

  CEFDelegateProxy* proxy_;
  int64_t browserId_;
  NSSize viewSize_ = {800, 600};
  IMPLEMENT_REFCOUNTING(BrowserClient);
};

CefMainArgs BuildMainArgs() {
  NSArray<NSString*>* args = NSProcessInfo.processInfo.arguments;
  static std::vector<std::string> storage;
  static std::vector<char*> ptrs;
  storage.clear();
  ptrs.clear();
  for (NSString* a in args) storage.push_back(std::string(a.UTF8String));
  for (auto& s : storage) ptrs.push_back(const_cast<char*>(s.c_str()));
  return CefMainArgs(static_cast<int>(ptrs.size()), ptrs.data());
}

bool CreateBrowserInternal(NSView* view, const std::string& url,
                           CEFDelegateProxy* proxy, int64_t browserId) {
  CefWindowInfo window_info;
  NSSize size = view.bounds.size;
  if (size.width < 50) size.width = 800;   // 容器未布局时给合理默认
  if (size.height < 50) size.height = 600;
  if (g_windowedMode) {
    // 窗口化：CEF 自建 NSView 加为容器子视图，Chromium 原生绘制（零拷贝）。
    NSLog(@"CEFShim CreateBrowser windowed parent=%@ size=%dx%d", view, (int)size.width, (int)size.height);
    window_info.SetAsChild((__bridge CefWindowHandle)view,
                           CefRect(0, 0, (int)size.width, (int)size.height));
  } else {
    window_info.SetAsWindowless((__bridge CefWindowHandle)view);
  }
  CefBrowserSettings browser_settings;
  CefRefPtr<BrowserClient> client(new BrowserClient(proxy, browserId));
  client->SetViewSize(size);
  g_clients[browserId] = client;
  bool ok = CefBrowserHost::CreateBrowser(
      window_info, client.get(), CefString(url), browser_settings, nullptr, nullptr);
  NSLog(@"CEFShim CreateBrowser result=%d browser=%lld mode=%s", (int)ok, browserId,
        g_windowedMode ? "windowed" : "osr");
  return ok;
}

}  // namespace

@implementation CEFShim

+ (BOOL)isInitialized { return g_ready; }

+ (void)setWindowedMode:(BOOL)on {
  g_windowedMode = on ? true : false;
}

+ (BOOL)isWindowedMode { return g_windowedMode ? YES : NO; }

+ (void)setPaintHandler:(CEFPaintHandler)handler {
  g_paintHandler = handler;
}

+ (void)setCursorHandler:(CEFCursorHandler)handler {
  g_cursorHandler = handler;
}

+ (void)setMenuRequestHandler:(CEFMenuRequestHandler)handler {
  g_menuRequestHandler = handler;
}

+ (void)executeContextMenuCommand:(int64_t)browserId commandId:(int)commandId {
  // CEF 的 CefMenuModel 无 ExecuteCommand；菜单命令由宿主直接驱动 CEF。
  auto it = g_browsers.find(browserId);
  g_menu_models.erase(browserId);
  if (it == g_browsers.end()) return;
  CefRefPtr<CefBrowser> b = it->second;
  CefRefPtr<CefFrame> frame = b->GetFocusedFrame();
  switch ((cef_menu_id_t)commandId) {
    case MENU_ID_BACK: b->GoBack(); break;
    case MENU_ID_FORWARD: b->GoForward(); break;
    case MENU_ID_RELOAD: b->Reload(); break;
    case MENU_ID_STOPLOAD: b->StopLoad(); break;
    case MENU_ID_UNDO: if (frame) frame->Undo(); break;
    case MENU_ID_REDO: if (frame) frame->Redo(); break;
    case MENU_ID_CUT: if (frame) frame->Cut(); break;
    case MENU_ID_COPY: if (frame) frame->Copy(); break;
    case MENU_ID_PASTE: if (frame) frame->Paste(); break;
    case MENU_ID_SELECT_ALL: if (frame) frame->SelectAll(); break;
    case MENU_ID_VIEW_SOURCE: if (frame) frame->ViewSource(); break;
    default: break;  // 链接/拼写等其它命令暂不处理
  }
}

+ (void)cancelContextMenu:(int64_t)browserId {
  g_menu_models.erase(browserId);
}

+ (BOOL)initializeWithCachePath:(NSString *)cachePath
           remoteDebuggingPort:(int)remoteDebuggingPort
                       logPath:(NSString *)logPath
                         error:(NSError **)error {
  if (g_loader) return YES;

  g_loader = new CefScopedLibraryLoader();
  if (!g_loader->LoadInMain()) {
    delete g_loader;
    g_loader = nullptr;
    if (error) {
      *error = [NSError errorWithDomain:@"CEFShim" code:1 userInfo:@{NSLocalizedDescriptionKey: @"CEF framework not found in app bundle (Contents/Frameworks)."}];
    }
    return NO;
  }

  CefSettings settings;
  settings.no_sandbox = true;
  settings.external_message_pump = true;
  // 窗口化模式必须关掉 OSR 开关（全局设置，创建浏览器前定）。
  settings.windowless_rendering_enabled = !g_windowedMode;
  settings.remote_debugging_port = remoteDebuggingPort;
  if (cachePath.length > 0) {
    CefString(&settings.cache_path) = cachePath.UTF8String;
    NSString* parent = [cachePath stringByDeletingLastPathComponent];
    CefString(&settings.root_cache_path) = parent.UTF8String;
  }
  if (logPath.length > 0) {
    CefString(&settings.log_file) = logPath.UTF8String;
    settings.log_severity = LOGSEVERITY_WARNING;
  }

  NSString* helperPath = [[NSBundle mainBundle]
      pathForAuxiliaryExecutable:@"oh-my-dsh Helper"];
  if (helperPath.length > 0) {
    CefString(&settings.browser_subprocess_path) = helperPath.UTF8String;
  }

  g_app = new AppShim();
  CefMainArgs main_args = BuildMainArgs();
  if (!CefInitialize(main_args, settings, g_app.get(), nullptr)) {
    g_app = nullptr;
    delete g_loader;
    g_loader = nullptr;
    if (error) {
      *error = [NSError errorWithDomain:@"CEFShim" code:2 userInfo:@{NSLocalizedDescriptionKey: @"CefInitialize failed."}];
    }
    return NO;
  }
  return YES;
}

+ (void)runMessageLoopWork {
  if (g_loader) CefDoMessageLoopWork();
}

+ (int64_t)createBrowserInView:(NSView *)view url:(NSString *)url
                      delegate:(id<CEFBrowserDelegate>)delegate {
  CEFDelegateProxy* proxy = [[CEFDelegateProxy alloc] init];
  proxy.delegate = delegate;
  int64_t browserId = g_nextBrowserId++;
  if (!g_ready) {
    PendingCreate p;
    p.view = view;
    p.url = url ? std::string(url.UTF8String) : std::string("about:blank");
    p.proxy = proxy;
    p.browserId = browserId;
    g_pending.push_back(p);
    return browserId;
  }
  CreateBrowserInternal(view, url ? std::string(url.UTF8String) : std::string("about:blank"), proxy, browserId);
  return browserId;
}

+ (void)closeBrowser:(int64_t)browserId {
  NSLog(@"CEFShim closeBrowser %lld", browserId);
  auto it = g_browsers.find(browserId);
  if (it != g_browsers.end()) it->second->GetHost()->CloseBrowser(true);
}

+ (void)showDevTools:(int64_t)browserId {
  auto it = g_browsers.find(browserId);
  if (it == g_browsers.end()) return;
  // CEF 150 mac 无 SetAsPopup：自建独立窗口，SetAsChild 挂 DevTools 视图。
  if (!g_devtoolsWindow) {
    g_devtoolsWindow = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(200, 200, 960, 640)
                  styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                             NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable)
                    backing:NSBackingStoreBuffered
                      defer:NO];
    g_devtoolsWindow.title = @"DevTools";
  }
  NSView* content = g_devtoolsWindow.contentView;
  [g_devtoolsWindow makeKeyAndOrderFront:nil];
  CefWindowInfo wi;
  wi.SetAsChild((__bridge CefWindowHandle)content, CefRect(0, 0, 960, 640));
  it->second->GetHost()->ShowDevTools(wi, nullptr, CefBrowserSettings(),
                                      CefPoint(0, 0));
}

+ (void)navigateBrowser:(int64_t)browserId url:(NSString *)url {
  auto it = g_browsers.find(browserId);
  if (it != g_browsers.end() && url.length > 0) {
    it->second->GetMainFrame()->LoadURL(CefString(url.UTF8String));
  }
}

+ (void)goBack:(int64_t)browserId {
  auto it = g_browsers.find(browserId);
  if (it != g_browsers.end() && it->second->CanGoBack()) it->second->GoBack();
}

+ (void)goForward:(int64_t)browserId {
  auto it = g_browsers.find(browserId);
  if (it != g_browsers.end() && it->second->CanGoForward()) it->second->GoForward();
}

+ (void)reload:(int64_t)browserId {
  auto it = g_browsers.find(browserId);
  if (it != g_browsers.end()) it->second->Reload();
}

+ (void)stop:(int64_t)browserId {
  auto it = g_browsers.find(browserId);
  if (it != g_browsers.end()) it->second->StopLoad();
}

+ (void)resizeBrowser:(int64_t)browserId width:(float)width height:(float)height {
  auto it = g_browsers.find(browserId);
  auto cit = g_clients.find(browserId);
  if (it == g_browsers.end() || cit == g_clients.end()) return;
  if (width <= 0 || height <= 0) return;
  cit->second->SetViewSize(NSMakeSize(width, height));
  it->second->GetHost()->WasResized();
}

// MARK: OSR 输入转发

+ (void)sendMouseClick:(int64_t)browserId
                     x:(float)x y:(float)y
                button:(int)button
                 count:(int)count
              modifiers:(int)modifiers {
  auto it = g_browsers.find(browserId);
  if (it == g_browsers.end()) return;
  CefMouseEvent ev;
  ev.x = (int)x; ev.y = (int)y;
  ev.modifiers = modifiers;
  CefBrowserHost::MouseButtonType type = MBT_LEFT;
  if (button == 1) type = MBT_RIGHT;
  else if (button == 2) type = MBT_MIDDLE;
  if (count == 1) it->second->GetHost()->SendMouseClickEvent(ev, type, false, 1);
  else if (count == 2) it->second->GetHost()->SendMouseClickEvent(ev, type, true, 1);
  else if (count == 3) it->second->GetHost()->SendMouseMoveEvent(ev, false);
}

+ (void)sendMouseMove:(int64_t)browserId x:(float)x y:(float)y modifiers:(int)modifiers {
  auto it = g_browsers.find(browserId);
  if (it == g_browsers.end()) return;
  CefMouseEvent ev;
  ev.x = (int)x; ev.y = (int)y;
  ev.modifiers = modifiers;
  it->second->GetHost()->SendMouseMoveEvent(ev, false);
}

+ (void)sendMouseWheel:(int64_t)browserId x:(float)x y:(float)y
               deltaX:(float)deltaX deltaY:(float)deltaY modifiers:(int)modifiers {
  auto it = g_browsers.find(browserId);
  if (it == g_browsers.end()) return;
  CefMouseEvent ev;
  ev.x = (int)x; ev.y = (int)y;
  ev.modifiers = modifiers;
  it->second->GetHost()->SendMouseWheelEvent(ev, (int)deltaX, (int)deltaY);
}

+ (void)sendKeyEvent:(int64_t)browserId keyCode:(unsigned short)keyCode
            charCode:(unsigned short)charCode keyDown:(BOOL)keyDown modifiers:(int)modifiers {
  auto it = g_browsers.find(browserId);
  if (it == g_browsers.end()) return;
  CefKeyEvent ev;
  ev.modifiers = modifiers;
  ev.native_key_code = keyCode;
  if (keyDown) {
    ev.type = KEYEVENT_KEYDOWN;
    ev.windows_key_code = (int)keyCode;
  } else {
    ev.type = KEYEVENT_KEYUP;
    ev.windows_key_code = (int)keyCode;
  }
  it->second->GetHost()->SendKeyEvent(ev);
  if (keyDown && charCode > 0) {
    CefKeyEvent ch;
    ch.type = KEYEVENT_CHAR;
    ch.modifiers = modifiers;
    ch.windows_key_code = (int)charCode;
    ch.native_key_code = keyCode;
    it->second->GetHost()->SendKeyEvent(ch);
  }
}

+ (void)setFocus:(int64_t)browserId focused:(BOOL)focused {
  auto it = g_browsers.find(browserId);
  if (it != g_browsers.end()) it->second->GetHost()->SetFocus(focused);
}

+ (void)shutdown {
  // 关闭所有浏览器并泵几轮让 CEF 收尾（OnBeforeClose / 子进程退出）。
  std::vector<int64_t> ids;
  for (const auto& kv : g_browsers) ids.push_back(kv.first);
  for (int64_t id : ids) {
    auto it = g_browsers.find(id);
    if (it != g_browsers.end()) it->second->GetHost()->CloseBrowser(true);
  }
  for (int i = 0; i < 20; i++) {
    CefDoMessageLoopWork();
    usleep(10000);
  }
  // 不调用 CefShutdown()：CEF 150 + external_message_pump 下 CefShutdown
  // 在 macOS 退出流程里稳定触发 CHECK 崩溃（SIGTRAP，见 crash logs——
  // 泵等浏览器销毁也未能规避）。进程退出时 OS 回收所有子进程，残留单例锁
  // 由下次启动 cleanStaleCEFSingleton 清理，行为与 cefclient 的 mac 退出一致。
  g_app = nullptr;
  g_ready = false;
}

@end

@implementation DSHApplication {
  BOOL handlingSendEvent_;
}

- (BOOL)isHandlingSendEvent { return handlingSendEvent_; }
- (void)setHandlingSendEvent:(BOOL)handlingSendEvent {
  handlingSendEvent_ = handlingSendEvent;
}
- (void)sendEvent:(NSEvent *)event {
  CefScopedSendingEvent sendingEventScoper;
  [super sendEvent:event];
}
@end

// 兜底：NSPrincipalClass 未生效时（NSApp 为普通 NSApplication）也响应
// CefAppProtocol 方法，避免 "unrecognized selector" 崩溃。
@implementation NSApplication (CefAppProtocolShim)

- (BOOL)isHandlingSendEvent { return NO; }
- (void)setHandlingSendEvent:(BOOL)handlingSendEvent {}

@end
