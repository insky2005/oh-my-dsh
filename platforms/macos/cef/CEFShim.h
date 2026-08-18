// CEFShim.h — Objective-C bridge between Swift (oh-my-dsh shell) and the
// Chromium Embedded Framework (CEF) C++ API (see CEFShim.mm).
//
// 渲染模式：OSR（windowless）——Chromium 把每一帧 BGRA 像素经
// cefSetPaintHandler 交给壳层，壳层自绘到 CALayer（windowed 路径在
// layer-backed 壳窗口内呈现失效，见 docs/plans/BROWSER_PLAN-browser-panel.md）。

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// Lifecycle / state callbacks delivered on the main thread.
@protocol CEFBrowserDelegate <NSObject>
- (void)cefTitleChanged:(NSString *)title forBrowser:(int64_t)browserId;
- (void)cefAddressChanged:(NSString *)url forBrowser:(int64_t)browserId;
- (void)cefLoadingStateChanged:(BOOL)isLoading
                     canGoBack:(BOOL)canGoBack
                  canGoForward:(BOOL)canGoForward
                    forBrowser:(int64_t)browserId;
- (void)cefLoadError:(NSString *)errorText
           failedURL:(NSString *)failedURL
          forBrowser:(int64_t)browserId;
- (void)cefBrowserClosed:(int64_t)browserId;
@end

/// OSR 帧回调：BGRA 像素（主线程）。
typedef void (^CEFPaintHandler)(int64_t browserId, const void *buffer,
                                int width, int height);

/// 光标变化回调（主线程）：cursor 为 CefCursorHandle（macOS 上即 NSCursor*，
/// 未持有引用，调用方按需使用）。
typedef void (^CEFCursorHandler)(int64_t browserId, void *cursor);

/// 上下文菜单条目类型。
typedef NS_ENUM(NSInteger, CEFMenuItemType) {
  CEFMenuItemCommand = 0,
  CEFMenuItemSeparator = 1,
  CEFMenuItemCheck = 2,
  CEFMenuItemRadio = 3,
};

/// 上下文菜单请求回调（主线程）：x/y 为 OSR 视口坐标（左上原点），
/// items 为 NSArray<NSDictionary *>（key: id/type/label，type 为
/// CEFMenuItemType 原始值；label 为 nil 时用默认标题）。
typedef void (^CEFMenuRequestHandler)(int64_t browserId, float x, float y,
                                      NSArray<NSDictionary *> *items);

@interface CEFShim : NSObject

@property(class, readonly) BOOL isInitialized;

/// 注册 OSR 帧回调（App 启动后、创建浏览器前）。
+ (void)setPaintHandler:(nullable CEFPaintHandler)handler;

/// 注册光标变化回调（OSR hover 光标跟随页面）。
+ (void)setCursorHandler:(nullable CEFCursorHandler)handler;

/// 注册上下文菜单请求回调（OSR 右键；宿主在正确屏幕位置弹 NSMenu）。
+ (void)setMenuRequestHandler:(nullable CEFMenuRequestHandler)handler;

/// 用户选择菜单项后执行命令（由 menu model 执行默认动作）。
+ (void)executeContextMenuCommand:(int64_t)browserId commandId:(int)commandId;

/// 用户取消菜单（可选，OSR 下 CEF 需要收尾）。
+ (void)cancelContextMenu:(int64_t)browserId;

/// 初始化 CEF（浏览器进程，主线程调用）。
+ (BOOL)initializeWithCachePath:(NSString *)cachePath
           remoteDebuggingPort:(int)remoteDebuggingPort
                       logPath:(NSString *)logPath
                         error:(NSError **)error;

/// 渲染模式：YES = 窗口化（CEF 自建 NSView，Chromium 原生绘制，零拷贝）；
/// NO = OSR 离屏（默认，帧回调自绘）。必须在 initialize 之前调用。
+ (void)setWindowedMode:(BOOL)on;
+ (BOOL)isWindowedMode;

/// 驱动 CEF 消息泵（external_message_pump）。
+ (void)runMessageLoopWork;

/// 创建 OSR 浏览器；|view| 仅用于定位（对话框/菜单父级与初始尺寸）。
+ (int64_t)createBrowserInView:(NSView *)view
                           url:(nullable NSString *)url
                      delegate:(id<CEFBrowserDelegate>)delegate;

+ (void)closeBrowser:(int64_t)browserId;
+ (void)navigateBrowser:(int64_t)browserId url:(NSString *)url;
+ (void)goBack:(int64_t)browserId;
+ (void)goForward:(int64_t)browserId;
+ (void)reload:(int64_t)browserId;
+ (void)stop:(int64_t)browserId;

/// 弹出独立 DevTools 窗口（CEF 原生 ShowDevTools，Chromium 自带调试器）。
+ (void)showDevTools:(int64_t)browserId;

/// 容器尺寸变化时通知 CEF（OSR 视口跟随）。
+ (void)resizeBrowser:(int64_t)browserId width:(float)width height:(float)height;

/// 输入转发（OSR）。
+ (void)sendMouseClick:(int64_t)browserId
                    x:(float)x y:(float)y
               button:(int)button  // 0 左 1 右 2 中
                count:(int)count   // 1 down, 2 up, 3 drag
             modifiers:(int)modifiers;
+ (void)sendMouseMove:(int64_t)browserId
                    x:(float)x y:(float)y
            modifiers:(int)modifiers;
+ (void)sendMouseWheel:(int64_t)browserId
                     x:(float)x y:(float)y
                deltaX:(float)deltaX deltaY:(float)deltaY
             modifiers:(int)modifiers;
+ (void)sendKeyEvent:(int64_t)browserId
             keyCode:(unsigned short)keyCode
            charCode:(unsigned short)charCode
            keyDown:(BOOL)keyDown
            modifiers:(int)modifiers;
+ (void)setFocus:(int64_t)browserId focused:(BOOL)focused;

/// 关闭（进程退出前调用）。
+ (void)shutdown;

@end

/// NSApplication 子类（CefAppProtocol）；经 Info.plist NSPrincipalClass 生效，
/// 另附 NSApplication category 兜底（见 .mm）。
@interface DSHApplication : NSApplication
@end

NS_ASSUME_NONNULL_END
