//
//  Minimal declarations for the WebKit classes Clearbrowse talks to.
//
//  tvOS ships WebKit, but its headers are not part of the tvOS SDK, so the classes are looked up
//  by name at runtime (see CWBWebView.m). These protocols only give the compiler the method
//  signatures to call; nothing in here links against WebKit.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@protocol CWBWKFrameInfo <NSObject>
@property (nonatomic, readonly, getter=isMainFrame) BOOL mainFrame;
@end

@protocol CWBWKNavigationAction <NSObject>
@property (nonatomic, readonly, copy) NSURLRequest *request;
@property (nonatomic, readonly, nullable) id<CWBWKFrameInfo> targetFrame;
/// WKNavigationType: 0 = link activated, -1 = other (for example window.open from a script).
@property (nonatomic, readonly) NSInteger navigationType;
@end

@protocol CWBWKNavigationResponse <NSObject>
@property (nonatomic, readonly, getter=isForMainFrame) BOOL forMainFrame;
@property (nonatomic, readonly, copy) NSURLResponse *response;
@property (nonatomic, readonly) BOOL canShowMIMEType;
@end

@protocol CWBWKScriptMessage <NSObject>
@property (nonatomic, readonly, copy) id body;
@property (nonatomic, readonly, nullable) id<CWBWKFrameInfo> frameInfo;
@end

@protocol CWBWKUserScript <NSObject>
/// injectionTime: 0 = document start, 1 = document end.
- (instancetype)initWithSource:(NSString *)source injectionTime:(NSInteger)injectionTime forMainFrameOnly:(BOOL)forMainFrameOnly;
@end

@protocol CWBWKUserContentController <NSObject>
- (void)addUserScript:(id)userScript;
- (void)addScriptMessageHandler:(id)scriptMessageHandler name:(NSString *)name;
@end

@protocol CWBWKPreferences <NSObject>
@property (nonatomic) BOOL javaScriptCanOpenWindowsAutomatically;
@end

@protocol CWBWKWebpagePreferences <NSObject>
/// WKContentMode: 0 = recommended, 1 = mobile, 2 = desktop.
@property (nonatomic) NSInteger preferredContentMode;
@end

@protocol CWBWKHTTPCookieStore <NSObject>
- (void)getAllCookies:(void (^)(NSArray<NSHTTPCookie *> *cookies))completionHandler;
- (void)setCookie:(NSHTTPCookie *)cookie completionHandler:(nullable void (^)(void))completionHandler;
@end

@protocol CWBWKWebsiteDataStore <NSObject>
+ (nullable id<CWBWKWebsiteDataStore>)defaultDataStore;
+ (NSSet<NSString *> *)allWebsiteDataTypes;
@property (nonatomic, readonly) id<CWBWKHTTPCookieStore> httpCookieStore;
- (void)removeDataOfTypes:(NSSet<NSString *> *)dataTypes modifiedSince:(NSDate *)date completionHandler:(void (^)(void))completionHandler;
@end

@protocol CWBWKContentWorld <NSObject>
+ (id)pageWorld;
@end

@protocol CWBWKWebViewConfiguration <NSObject>
@property (nonatomic, strong) id<CWBWKUserContentController> userContentController;
@property (nonatomic, strong) id<CWBWKPreferences> preferences;
@property (nonatomic, copy) id<CWBWKWebpagePreferences> defaultWebpagePreferences;
@property (nonatomic) BOOL allowsInlineMediaPlayback;
/// WKAudiovisualMediaTypes: 0 = none (media may start without a tap).
@property (nonatomic) NSUInteger mediaTypesRequiringUserActionForPlayback;
@property (nonatomic) BOOL allowsPictureInPictureMediaPlayback;
@end

@protocol CWBWKWebView <NSObject>
- (instancetype)initWithFrame:(CGRect)frame configuration:(id)configuration;
@property (nonatomic, weak, nullable) id navigationDelegate;
@property (nonatomic, weak, nullable) id UIDelegate;
@property (nonatomic, readonly, nullable, copy) NSURL *URL;
@property (nonatomic, readonly, nullable, copy) NSString *title;
@property (nonatomic, readonly, getter=isLoading) BOOL loading;
@property (nonatomic, readonly) double estimatedProgress;
@property (nonatomic, readonly) BOOL canGoBack;
@property (nonatomic, readonly) BOOL canGoForward;
@property (nonatomic, readonly, strong) UIScrollView *scrollView;
@property (nonatomic, nullable, copy) NSString *customUserAgent;
@property (nonatomic) CGFloat pageZoom;
- (nullable id)loadRequest:(NSURLRequest *)request;
- (nullable id)loadHTMLString:(NSString *)string baseURL:(nullable NSURL *)baseURL;
- (nullable id)reload;
- (void)stopLoading;
- (nullable id)goBack;
- (nullable id)goForward;
- (void)evaluateJavaScript:(NSString *)javaScriptString
         completionHandler:(nullable void (^)(id _Nullable result, NSError * _Nullable error))completionHandler;
- (void)evaluateJavaScript:(NSString *)javaScriptString
                   inFrame:(nullable id)frame
            inContentWorld:(id)contentWorld
         completionHandler:(nullable void (^)(id _Nullable result, NSError * _Nullable error))completionHandler;
@end

NS_ASSUME_NONNULL_END
