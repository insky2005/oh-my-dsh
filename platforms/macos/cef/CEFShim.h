// CEFShim.h — Objective-C bridge between Swift (oh-my-dsh shell) and the
// Chromium Embedded Framework (CEF) C++ API (see CEFShim.mm).
//
// The shim keeps the CEF surface intentionally minimal: render (one browser per
// tab, native NSView hosting via CefWindowInfo::SetAsChild which forces Alloy
// style), navigation and lifecycle callbacks. Everything else
// (console/network/eval/screenshot) goes through the Chrome DevTools Protocol
// (CDP) on the remote debugging port (BrowserCDP.swift).

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// Lifecycle / state callbacks delivered on the main thread.
@protocol CEFBrowserDelegate <NSObject>
- (void)cefTitleChanged:(NSString *)title forBrowser:(int64_t)browserId;
- (void)cefLoadingStateChanged:(BOOL)isLoading
                     canGoBack:(BOOL)canGoBack
                  canGoForward:(BOOL)canGoForward
                    forBrowser:(int64_t)browserId;
- (void)cefLoadError:(NSString *)errorText
           failedURL:(NSString *)failedURL
          forBrowser:(int64_t)browserId;
- (void)cefBrowserClosed:(int64_t)browserId;
@end

/// Process-level CEF integration for the browser process.
@interface CEFShim : NSObject

/// Whether CEF has been initialized and browsers can be created.
@property(class, readonly) BOOL isInitialized;

/// Load and initialize CEF for the browser process. Must run on the main
/// thread before any browser is created.
+ (BOOL)initializeWithCachePath:(NSString *)cachePath
           remoteDebuggingPort:(int)remoteDebuggingPort
                       logPath:(NSString *)logPath
                         error:(NSError **)error;

/// Drive the CEF message loop (external_message_pump). Call periodically
/// (e.g. every 8-10 ms) from the app's own run loop.
+ (void)runMessageLoopWork;

/// Create a browser hosted inside |view|. Returns the browser id immediately;
/// the delegate receives cefLoadingStateChanged once it is live.
+ (int64_t)createBrowserInView:(NSView *)view
                           url:(nullable NSString *)url
                      delegate:(id<CEFBrowserDelegate>)delegate;

+ (void)closeBrowser:(int64_t)browserId;
+ (void)navigateBrowser:(int64_t)browserId url:(NSString *)url;
+ (void)goBack:(int64_t)browserId;
+ (void)goForward:(int64_t)browserId;
+ (void)reload:(int64_t)browserId;
+ (void)stop:(int64_t)browserId;

/// Shut CEF down (call before process exit).
+ (void)shutdown;

@end

/// NSApplication subclass required by CEF (CefAppProtocol). Selected via
/// Info.plist NSPrincipalClass so AppKit instantiates it for the app bundle.
@interface DSHApplication : NSApplication
@end

NS_ASSUME_NONNULL_END
