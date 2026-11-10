//
//  A UIView that hosts the system web engine and exposes the small part of it the app needs.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class CWBWebView;

/// Every method is called on the main thread.
NS_SWIFT_UI_ACTOR
@protocol CWBWebViewDelegate <NSObject>

- (void)webViewDidStartLoading:(CWBWebView *)webView
    NS_SWIFT_NAME(webViewDidStartLoading(_:));
- (void)webViewDidCommitNavigation:(CWBWebView *)webView
    NS_SWIFT_NAME(webViewDidCommitNavigation(_:));
- (void)webViewDidFinishLoading:(CWBWebView *)webView
    NS_SWIFT_NAME(webViewDidFinishLoading(_:));
- (void)webView:(CWBWebView *)webView didFailWithError:(NSError *)error provisional:(BOOL)provisional
    NS_SWIFT_NAME(webView(_:didFail:provisional:));
/// URL, title, progress, loading state or back/forward availability changed.
- (void)webViewDidUpdateState:(CWBWebView *)webView
    NS_SWIFT_NAME(webViewDidUpdateState(_:));
- (void)webViewContentProcessDidTerminate:(CWBWebView *)webView
    NS_SWIFT_NAME(webViewContentProcessDidTerminate(_:));

/// A message posted by the injected page script. `frame` identifies the sending frame and can be
/// passed back to -evaluateJavaScript:inFrame:completion:.
- (void)webView:(CWBWebView *)webView didReceiveMessage:(NSDictionary<NSString *, id> *)message fromFrame:(nullable id)frame isMainFrame:(BOOL)isMainFrame
    NS_SWIFT_NAME(webView(_:didReceiveMessage:fromFrame:isMainFrame:));

/// The page tried to open a new window. `fromLink` is YES for a clicked link, NO for a script.
- (void)webView:(CWBWebView *)webView didRequestNewWindowWithRequest:(NSURLRequest *)request fromLink:(BOOL)fromLink
    NS_SWIFT_NAME(webView(_:didRequestNewWindow:fromLink:));

/// The main frame navigated straight to a media file. Return YES to cancel the navigation and
/// play it some other way.
- (BOOL)webView:(CWBWebView *)webView shouldHandleMediaAtURL:(NSURL *)url mimeType:(NSString *)mimeType
    NS_SWIFT_NAME(webView(_:shouldHandleMediaAt:mimeType:));

/// A navigation was cancelled: `isDownload` for a file the engine cannot display, otherwise an
/// address with a scheme the browser does not open.
- (void)webView:(CWBWebView *)webView didBlockNavigationToURL:(NSURL *)url isDownload:(BOOL)isDownload
    NS_SWIFT_NAME(webView(_:didBlockNavigationTo:isDownload:));

// JavaScript dialogs. Every completion block must be called exactly once.
- (void)webView:(CWBWebView *)webView runAlertWithMessage:(NSString *)message completion:(void (^)(void))completion
    NS_SWIFT_NAME(webView(_:runAlert:completion:));
- (void)webView:(CWBWebView *)webView runConfirmWithMessage:(NSString *)message completion:(void (^)(BOOL confirmed))completion
    NS_SWIFT_NAME(webView(_:runConfirm:completion:));
- (void)webView:(CWBWebView *)webView runPromptWithMessage:(NSString *)message defaultText:(nullable NSString *)defaultText completion:(void (^)(NSString * _Nullable text))completion
    NS_SWIFT_NAME(webView(_:runPrompt:defaultText:completion:));

@end

@interface CWBWebView : UIView

/// NO when this tvOS version has no loadable web engine.
@property (class, nonatomic, readonly) BOOL isEngineAvailable;

/// `userScript` is injected into every frame at document start.
- (instancetype)initWithFrame:(CGRect)frame
                   userScript:(NSString *)userScript
                    userAgent:(nullable NSString *)userAgent
                  desktopMode:(BOOL)desktopMode;

@property (nonatomic, weak, nullable) id<CWBWebViewDelegate> delegate;

@property (nonatomic, readonly) BOOL hasEngine;
@property (nonatomic, readonly, nullable) NSURL *URL;
@property (nonatomic, readonly, nullable) NSString *title;
@property (nonatomic, readonly) BOOL canGoBack;
@property (nonatomic, readonly) BOOL canGoForward;
@property (nonatomic, readonly, getter=isLoading) BOOL loading;
@property (nonatomic, readonly) double estimatedProgress;

/// 1.0 = 100%. Zooming gives the page a smaller window and magnifies it, so pages reflow the
/// way they do when a desktop browser zooms in.
@property (nonatomic) double pageZoom;

/// Converts a point in `view` to a position in the page's viewport, as fractions (0...1) of its
/// width and height.
- (CGPoint)viewportFractionForPoint:(CGPoint)point inView:(UIView *)view
    NS_SWIFT_NAME(viewportFraction(for:in:));
/// Converts a rectangle given as fractions of the page's viewport into this view's coordinates.
- (CGRect)rectForViewportFraction:(CGRect)fraction
    NS_SWIFT_NAME(rect(forViewportFraction:));

- (void)loadRequest:(NSURLRequest *)request NS_SWIFT_NAME(load(_:));
- (void)loadHTMLString:(NSString *)html baseURL:(nullable NSURL *)baseURL NS_SWIFT_NAME(loadHTML(_:baseURL:));
- (void)reload;
- (void)stopLoading;
- (void)goBack;
- (void)goForward;

/// Runs `script` in `frame` (a value received from the delegate), or in the main frame when nil.
- (void)evaluateJavaScript:(NSString *)script
                   inFrame:(nullable id)frame
                completion:(nullable void (^)(id _Nullable result, NSError * _Nullable error))completion
    NS_SWIFT_NAME(evaluate(_:inFrame:completion:));

+ (void)fetchAllCookies:(void (^)(NSArray<NSHTTPCookie *> *cookies))completion
    NS_SWIFT_NAME(fetchAllCookies(_:));
+ (void)restoreCookies:(NSArray<NSHTTPCookie *> *)cookies completion:(void (^)(void))completion
    NS_SWIFT_NAME(restoreCookies(_:completion:));
+ (void)clearWebsiteDataWithCompletion:(void (^)(void))completion
    NS_SWIFT_NAME(clearWebsiteData(_:));

@end

NS_ASSUME_NONNULL_END
