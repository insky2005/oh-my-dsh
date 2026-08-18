// CEFShim.mm — Objective-C++ bridge between Swift (oh-my-dsh shell) and the
// Chromium Embedded Framework (CEF) C++ API. Compiled as ObjC++ with clang++ and
// imported into Swift via `swiftc -import-objc-header`. Render/navigation/lifecycle
// only; console/network/eval/screenshot go through CDP (BrowserCDP.swift).
#import "CEFShim.h"

#include "include/base/cef_build.h"
#include "include/cef_app.h"
#include "include/cef_browser.h"
#include "include/cef_browser_process_handler.h"
#include "include/cef_client.h"
#include "include/cef_command_line.h"
#include "include/cef_display_handler.h"
#include "include/cef_life_span_handler.h"
#include "include/cef_load_handler.h"
#include "include/wrapper/cef_helpers.h"
#include "include/wrapper/cef_library_loader.h"

#include <map>
#include <string>
#include <vector>

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
std::vector<PendingCreate> g_pending;
int64_t g_nextBrowserId = 1;
bool g_ready = false;

bool CreateBrowserInternal(NSView* view, const std::string& url,
                           CEFDelegateProxy* proxy, int64_t browserId);

class AppShim : public CefApp, public CefBrowserProcessHandler {
 public:
  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override {
    return this;
  }

  // 避免 Chromium 访问登录钥匙串弹密码框：本 App 不保存网页密码，
  // 用模拟钥匙串（use-mock-keychain）彻底绕开钥匙串访问。
  void OnBeforeCommandLineProcessing(const CefString& process_type,
                                     CefRefPtr<CefCommandLine> command_line) override {
    command_line->AppendSwitch("use-mock-keychain");
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
                      public CefDisplayHandler {
 public:
  explicit BrowserClient(CEFDelegateProxy* proxy, int64_t browserId)
      : proxy_(proxy), browserId_(browserId) {}

  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }

  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    g_browsers[browserId_] = browser;
    NotifyLoading(browser);
  }

  bool DoClose(CefRefPtr<CefBrowser> browser) override { return false; }

  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    g_browsers.erase(browserId_);
    id<CEFBrowserDelegate> d = proxy_.delegate;
    if (d && [d respondsToSelector:@selector(cefBrowserClosed:)]) {
      [d cefBrowserClosed:browserId_];
    }
  }

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

  void OnTitleChange(CefRefPtr<CefBrowser> browser, const CefString& title) override {
    id<CEFBrowserDelegate> d = proxy_.delegate;
    if (d && [d respondsToSelector:@selector(cefTitleChanged:forBrowser:)]) {
      [d cefTitleChanged:[NSString stringWithUTF8String:title.ToString().c_str()]
              forBrowser:browserId_];
    }
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
  window_info.SetAsChild(
      CAST_NSVIEW_TO_CEF_WINDOW_HANDLE(view),
      CefRect(0, 0, (int)view.bounds.size.width, (int)view.bounds.size.height));
  CefBrowserSettings browser_settings;
  CefRefPtr<BrowserClient> client(new BrowserClient(proxy, browserId));
  return CefBrowserHost::CreateBrowser(
      window_info, client.get(), CefString(url), browser_settings, nullptr, nullptr);
}

}  // namespace

@implementation CEFShim

+ (BOOL)isInitialized { return g_ready; }

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
  settings.remote_debugging_port = remoteDebuggingPort;
  if (cachePath.length > 0) {
    CefString(&settings.cache_path) = cachePath.UTF8String;
    // root_cache_path 显式设为 cache 的父目录：进程单例锁按其定位，
    // 不设会落到默认的 ~/Library/Application Support/CEF，与其他 CEF
    // 应用/异常残留互相干扰（曾导致 "Failed to create a ProcessSingleton"）。
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
  auto it = g_browsers.find(browserId);
  if (it != g_browsers.end()) it->second->GetHost()->CloseBrowser(true);
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

+ (void)shutdown {
  std::vector<int64_t> ids;
  for (const auto& kv : g_browsers) ids.push_back(kv.first);
  for (int64_t id : ids) {
    auto it = g_browsers.find(id);
    if (it != g_browsers.end()) it->second->GetHost()->CloseBrowser(true);
  }
  if (g_loader) {
    CefShutdown();
    delete g_loader;
    g_loader = nullptr;
  }
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
