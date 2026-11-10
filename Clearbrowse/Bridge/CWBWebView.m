#import "CWBWebView.h"
#import "WebKitRuntime.h"

#import <dlfcn.h>
#import <objc/message.h>

static void *CWBObservationContext = &CWBObservationContext;
static NSString * const CWBMessageHandlerName = @"cwb";

/// Makes the WebKit classes resolvable by name. On current tvOS they are already in the shared
/// cache; the dlopen is a fallback for systems where the framework is not loaded yet.
static void CWBLoadWebKit(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (NSClassFromString(@"WKWebView") != Nil) {
            return;
        }
        NSArray<NSString *> *candidates = @[
            @"/System/Library/Frameworks/WebKit.framework/WebKit",
            @"/System/Library/PrivateFrameworks/WebKit.framework/WebKit",
        ];
        for (NSString *path in candidates) {
            if (dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL) != NULL && NSClassFromString(@"WKWebView") != Nil) {
                break;
            }
        }
    });
}

static NSArray<NSString *> *CWBObservedKeyPaths(void) {
    return @[@"estimatedProgress", @"title", @"URL", @"canGoBack", @"canGoForward", @"loading"];
}

/// Calls a BOOL setter that only exists on some OS versions.
static void CWBSetOptionalBool(id object, NSString *selectorName, BOOL value) {
    SEL selector = NSSelectorFromString(selectorName);
    if (object != nil && [object respondsToSelector:selector]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(object, selector, value);
    }
}

@interface CWBWebView ()
@property (nonatomic, strong, nullable) UIView<CWBWKWebView> *engineView;
@property (nonatomic, strong, nullable) id messageRelay;
- (void)handleScriptMessage:(id<CWBWKScriptMessage>)message;
@end

/// The content controller retains its message handlers, so it gets this relay instead of the view.
@interface CWBScriptMessageRelay : NSObject
@property (nonatomic, weak, nullable) CWBWebView *owner;
@end

@implementation CWBScriptMessageRelay

- (void)userContentController:(id)userContentController didReceiveScriptMessage:(id<CWBWKScriptMessage>)message {
    [self.owner handleScriptMessage:message];
}

@end

@implementation CWBWebView

+ (BOOL)isEngineAvailable {
    CWBLoadWebKit();
    return NSClassFromString(@"WKWebView") != Nil && NSClassFromString(@"WKWebViewConfiguration") != Nil;
}

- (instancetype)initWithFrame:(CGRect)frame
                   userScript:(NSString *)userScript
                    userAgent:(NSString *)userAgent
                  desktopMode:(BOOL)desktopMode {
    self = [super initWithFrame:frame];
    if (self != nil) {
        _pageZoom = 1.0;
        self.backgroundColor = UIColor.blackColor;
        // The remote never touches the page directly; the app turns cursor clicks into page events.
        self.userInteractionEnabled = NO;
        [self buildEngineWithUserScript:userScript userAgent:userAgent desktopMode:desktopMode];
    }
    return self;
}

- (void)dealloc {
    for (NSString *keyPath in CWBObservedKeyPaths()) {
        @try {
            [_engineView removeObserver:self forKeyPath:keyPath context:CWBObservationContext];
        } @catch (__unused NSException *exception) {
        }
    }
}

- (void)buildEngineWithUserScript:(NSString *)userScript userAgent:(NSString *)userAgent desktopMode:(BOOL)desktopMode {
    CWBLoadWebKit();
    Class configurationClass = NSClassFromString(@"WKWebViewConfiguration");
    Class webViewClass = NSClassFromString(@"WKWebView");
    if (configurationClass == Nil || webViewClass == Nil) {
        return;
    }

    id<CWBWKWebViewConfiguration> configuration = (id<CWBWKWebViewConfiguration>)[[configurationClass alloc] init];
    if (configuration == nil) {
        return;
    }

    if ([configuration respondsToSelector:@selector(setAllowsInlineMediaPlayback:)]) {
        configuration.allowsInlineMediaPlayback = YES;
    }
    if ([configuration respondsToSelector:@selector(setMediaTypesRequiringUserActionForPlayback:)]) {
        // Clicks come from the app, not from a touch, so playback must not wait for a "real" tap.
        configuration.mediaTypesRequiringUserActionForPlayback = 0;
    }
    if ([configuration respondsToSelector:@selector(setAllowsPictureInPictureMediaPlayback:)]) {
        configuration.allowsPictureInPictureMediaPlayback = NO;
    }

    id<CWBWKPreferences> preferences = [configuration respondsToSelector:@selector(preferences)] ? configuration.preferences : nil;
    if ([preferences respondsToSelector:@selector(setJavaScriptCanOpenWindowsAutomatically:)]) {
        // New windows are routed to the delegate, which decides whether to block them.
        preferences.javaScriptCanOpenWindowsAutomatically = YES;
    }
    // Streaming sites need Media Source Extensions; these switches are off by default on tvOS.
    CWBSetOptionalBool(preferences, @"_setMediaSourceEnabled:", YES);
    CWBSetOptionalBool(preferences, @"_setManagedMediaSourceEnabled:", YES);
    CWBSetOptionalBool(preferences, @"_setMediaCapabilityGrantsEnabled:", YES);
    CWBSetOptionalBool(preferences, @"_setVideoQualityIncludesDisplayCompositingEnabled:", YES);

    if (desktopMode && [configuration respondsToSelector:@selector(defaultWebpagePreferences)]) {
        id<CWBWKWebpagePreferences> pagePreferences = configuration.defaultWebpagePreferences;
        if ([pagePreferences respondsToSelector:@selector(setPreferredContentMode:)]) {
            pagePreferences.preferredContentMode = 2;
        }
    }

    id<CWBWKUserContentController> contentController =
        [configuration respondsToSelector:@selector(userContentController)] ? configuration.userContentController : nil;
    Class userScriptClass = NSClassFromString(@"WKUserScript");
    if (contentController != nil && userScriptClass != Nil && userScript.length > 0) {
        id script = [(id<CWBWKUserScript>)[userScriptClass alloc] initWithSource:userScript injectionTime:0 forMainFrameOnly:NO];
        if (script != nil) {
            [contentController addUserScript:script];
        }
    }
    if (contentController != nil) {
        CWBScriptMessageRelay *relay = [[CWBScriptMessageRelay alloc] init];
        relay.owner = self;
        self.messageRelay = relay;
        [contentController addScriptMessageHandler:relay name:CWBMessageHandlerName];
    }

    UIView<CWBWKWebView> *engineView =
        (UIView<CWBWKWebView> *)[(id<CWBWKWebView>)[webViewClass alloc] initWithFrame:self.bounds configuration:configuration];
    if (engineView == nil) {
        return;
    }

    engineView.frame = self.bounds;
    engineView.backgroundColor = UIColor.blackColor;
    engineView.userInteractionEnabled = NO;
    engineView.navigationDelegate = self;
    engineView.UIDelegate = self;
    if (userAgent.length > 0 && [engineView respondsToSelector:@selector(setCustomUserAgent:)]) {
        engineView.customUserAgent = userAgent;
    }

    UIScrollView *scrollView = [engineView respondsToSelector:@selector(scrollView)] ? engineView.scrollView : nil;
    scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    scrollView.bounces = NO;
    scrollView.userInteractionEnabled = NO;

    [self addSubview:engineView];
    for (NSString *keyPath in CWBObservedKeyPaths()) {
        [engineView addObserver:self forKeyPath:keyPath options:0 context:CWBObservationContext];
    }
    self.engineView = engineView;
    [self applyPageZoom];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey, id> *)change context:(void *)context {
    if (context != CWBObservationContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    if (NSThread.isMainThread) {
        [self.delegate webViewDidUpdateState:self];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate webViewDidUpdateState:self];
        });
    }
}

#pragma mark - State

- (BOOL)hasEngine {
    return self.engineView != nil;
}

- (NSURL *)URL {
    return self.engineView.URL;
}

- (NSString *)title {
    return self.engineView.title;
}

- (BOOL)canGoBack {
    return self.engineView.canGoBack;
}

- (BOOL)canGoForward {
    return self.engineView.canGoForward;
}

- (BOOL)isLoading {
    return [self.engineView isLoading];
}

- (double)estimatedProgress {
    return self.engineView.estimatedProgress;
}

- (void)setPageZoom:(double)pageZoom {
    _pageZoom = pageZoom;
    [self applyPageZoom];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self applyPageZoom];
}

/// Zoom is done with plain view geometry: the engine gets a window that is `zoom` times smaller
/// than this view and is scaled back up to fill it.
- (void)applyPageZoom {
    UIView *engineView = self.engineView;
    CGRect bounds = self.bounds;
    if (engineView == nil || CGRectIsEmpty(bounds)) {
        return;
    }
    CGFloat zoom = (CGFloat)MAX(0.5, MIN(4.0, self.pageZoom));
    CGSize size = CGSizeMake(floor(bounds.size.width / zoom), floor(bounds.size.height / zoom));
    engineView.transform = CGAffineTransformIdentity;
    engineView.bounds = CGRectMake(0, 0, size.width, size.height);
    engineView.center = CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds));
    engineView.transform = CGAffineTransformMakeScale(bounds.size.width / size.width, bounds.size.height / size.height);
}

- (CGPoint)viewportFractionForPoint:(CGPoint)point inView:(UIView *)view {
    UIView *engineView = self.engineView;
    CGSize size = engineView.bounds.size;
    if (engineView == nil || size.width <= 0 || size.height <= 0) {
        return CGPointZero;
    }
    CGPoint local = [engineView convertPoint:point fromView:view];
    return CGPointMake(local.x / size.width, local.y / size.height);
}

- (CGRect)rectForViewportFraction:(CGRect)fraction {
    UIView *engineView = self.engineView;
    CGSize size = engineView.bounds.size;
    if (engineView == nil) {
        return self.bounds;
    }
    CGRect local = CGRectMake(fraction.origin.x * size.width, fraction.origin.y * size.height,
                              fraction.size.width * size.width, fraction.size.height * size.height);
    return [engineView convertRect:local toView:self];
}

#pragma mark - Navigation

- (void)loadRequest:(NSURLRequest *)request {
    (void)[self.engineView loadRequest:request];
}

- (void)loadHTMLString:(NSString *)html baseURL:(NSURL *)baseURL {
    (void)[self.engineView loadHTMLString:html baseURL:baseURL];
}

- (void)reload {
    (void)[self.engineView reload];
}

- (void)stopLoading {
    [self.engineView stopLoading];
}

- (void)goBack {
    (void)[self.engineView goBack];
}

- (void)goForward {
    (void)[self.engineView goForward];
}

- (void)evaluateJavaScript:(NSString *)script
                   inFrame:(id)frame
                completion:(void (^)(id _Nullable, NSError * _Nullable))completion {
    UIView<CWBWKWebView> *engineView = self.engineView;
    if (engineView == nil) {
        if (completion != nil) {
            completion(nil, nil);
        }
        return;
    }
    if (frame == nil) {
        [engineView evaluateJavaScript:script completionHandler:completion];
        return;
    }

    Class worldClass = NSClassFromString(@"WKContentWorld");
    BOOL canTargetFrame = worldClass != Nil
        && [worldClass respondsToSelector:@selector(pageWorld)]
        && [engineView respondsToSelector:@selector(evaluateJavaScript:inFrame:inContentWorld:completionHandler:)];
    id world = canTargetFrame ? [(Class<CWBWKContentWorld>)worldClass pageWorld] : nil;
    if (world == nil) {
        // Better to do nothing than to run a frame's command in the wrong document.
        if (completion != nil) {
            completion(nil, nil);
        }
        return;
    }
    [engineView evaluateJavaScript:script inFrame:frame inContentWorld:world completionHandler:completion];
}

#pragma mark - Page script messages

- (void)handleScriptMessage:(id<CWBWKScriptMessage>)message {
    id body = [message respondsToSelector:@selector(body)] ? message.body : nil;
    if (![body isKindOfClass:NSDictionary.class]) {
        return;
    }
    id<CWBWKFrameInfo> frame = [message respondsToSelector:@selector(frameInfo)] ? message.frameInfo : nil;
    BOOL isMainFrame = frame == nil || ([frame respondsToSelector:@selector(isMainFrame)] && [frame isMainFrame]);
    [self.delegate webView:self didReceiveMessage:(NSDictionary<NSString *, id> *)body fromFrame:frame isMainFrame:isMainFrame];
}

#pragma mark - Navigation delegate (called by the engine)

- (void)webView:(id)webView didStartProvisionalNavigation:(id)navigation {
    [self.delegate webViewDidStartLoading:self];
}

- (void)webView:(id)webView didCommitNavigation:(id)navigation {
    [self.delegate webViewDidCommitNavigation:self];
}

- (void)webView:(id)webView didFinishNavigation:(id)navigation {
    [self.delegate webViewDidFinishLoading:self];
}

- (void)webView:(id)webView didFailNavigation:(id)navigation withError:(NSError *)error {
    [self.delegate webView:self didFailWithError:error provisional:NO];
}

- (void)webView:(id)webView didFailProvisionalNavigation:(id)navigation withError:(NSError *)error {
    [self.delegate webView:self didFailWithError:error provisional:YES];
}

- (void)webViewWebContentProcessDidTerminate:(id)webView {
    [self.delegate webViewContentProcessDidTerminate:self];
}

- (void)webView:(id)webView decidePolicyForNavigationAction:(id<CWBWKNavigationAction>)navigationAction decisionHandler:(void (^)(NSInteger policy))decisionHandler {
    NSURL *url = navigationAction.request.URL;
    NSString *scheme = url.scheme.lowercaseString;
    static NSSet<NSString *> *openableSchemes;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        openableSchemes = [NSSet setWithObjects:@"http", @"https", @"about", @"blob", @"data", @"javascript", nil];
    });

    if (scheme.length > 0 && ![openableSchemes containsObject:scheme]) {
        decisionHandler(0);
        id<CWBWKFrameInfo> targetFrame = navigationAction.targetFrame;
        BOOL isMainFrame = targetFrame == nil || [targetFrame isMainFrame];
        if (isMainFrame && url != nil) {
            [self.delegate webView:self didBlockNavigationToURL:url isDownload:NO];
        }
        return;
    }
    decisionHandler(1);
}

- (void)webView:(id)webView decidePolicyForNavigationResponse:(id<CWBWKNavigationResponse>)navigationResponse decisionHandler:(void (^)(NSInteger policy))decisionHandler {
    if (![navigationResponse isForMainFrame]) {
        decisionHandler(1);
        return;
    }

    NSURLResponse *response = navigationResponse.response;
    NSURL *url = response.URL;
    NSString *mimeType = response.MIMEType.lowercaseString ?: @"";
    BOOL isMedia = [mimeType hasPrefix:@"video/"] || [mimeType hasPrefix:@"audio/"] || [mimeType containsString:@"mpegurl"];
    if (isMedia && url != nil && [self.delegate webView:self shouldHandleMediaAtURL:url mimeType:mimeType]) {
        decisionHandler(0);
        return;
    }
    if (!navigationResponse.canShowMIMEType && url != nil) {
        decisionHandler(0);
        [self.delegate webView:self didBlockNavigationToURL:url isDownload:YES];
        return;
    }
    decisionHandler(1);
}

#pragma mark - UI delegate (called by the engine)

- (id)webView:(id)webView createWebViewWithConfiguration:(id)configuration forNavigationAction:(id<CWBWKNavigationAction>)navigationAction windowFeatures:(id)windowFeatures {
    NSURLRequest *request = navigationAction.request;
    if (request.URL != nil) {
        [self.delegate webView:self didRequestNewWindowWithRequest:request fromLink:(navigationAction.navigationType == 0)];
    }
    return nil;
}

- (void)webView:(id)webView runJavaScriptAlertPanelWithMessage:(NSString *)message initiatedByFrame:(id)frame completionHandler:(void (^)(void))completionHandler {
    id<CWBWebViewDelegate> delegate = self.delegate;
    if (delegate == nil) {
        completionHandler();
        return;
    }
    [delegate webView:self runAlertWithMessage:(message ?: @"") completion:completionHandler];
}

- (void)webView:(id)webView runJavaScriptConfirmPanelWithMessage:(NSString *)message initiatedByFrame:(id)frame completionHandler:(void (^)(BOOL result))completionHandler {
    id<CWBWebViewDelegate> delegate = self.delegate;
    if (delegate == nil) {
        completionHandler(NO);
        return;
    }
    [delegate webView:self runConfirmWithMessage:(message ?: @"") completion:completionHandler];
}

- (void)webView:(id)webView runJavaScriptTextInputPanelWithPrompt:(NSString *)prompt defaultText:(NSString *)defaultText initiatedByFrame:(id)frame completionHandler:(void (^)(NSString * _Nullable result))completionHandler {
    id<CWBWebViewDelegate> delegate = self.delegate;
    if (delegate == nil) {
        completionHandler(nil);
        return;
    }
    [delegate webView:self runPromptWithMessage:(prompt ?: @"") defaultText:defaultText completion:completionHandler];
}

#pragma mark - Cookies and website data

+ (nullable id<CWBWKWebsiteDataStore>)defaultDataStore {
    CWBLoadWebKit();
    Class storeClass = NSClassFromString(@"WKWebsiteDataStore");
    if (storeClass == Nil || ![storeClass respondsToSelector:@selector(defaultDataStore)]) {
        return nil;
    }
    return [(Class<CWBWKWebsiteDataStore>)storeClass defaultDataStore];
}

+ (nullable id<CWBWKHTTPCookieStore>)cookieStore {
    id<CWBWKWebsiteDataStore> store = [self defaultDataStore];
    if (store == nil || ![store respondsToSelector:@selector(httpCookieStore)]) {
        return nil;
    }
    return store.httpCookieStore;
}

+ (void)fetchAllCookies:(void (^)(NSArray<NSHTTPCookie *> *))completion {
    id<CWBWKHTTPCookieStore> cookieStore = [self cookieStore];
    if (cookieStore == nil || ![cookieStore respondsToSelector:@selector(getAllCookies:)]) {
        completion(@[]);
        return;
    }
    [cookieStore getAllCookies:^(NSArray<NSHTTPCookie *> *cookies) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(cookies ?: @[]);
        });
    }];
}

+ (void)restoreCookies:(NSArray<NSHTTPCookie *> *)cookies completion:(void (^)(void))completion {
    id<CWBWKHTTPCookieStore> cookieStore = [self cookieStore];
    if (cookies.count == 0 || cookieStore == nil || ![cookieStore respondsToSelector:@selector(setCookie:completionHandler:)]) {
        completion();
        return;
    }

    // Finish once every cookie is stored, or after a short wait so a stuck store can't block launch.
    __block BOOL finished = NO;
    void (^finish)(void) = ^{
        if (!finished) {
            finished = YES;
            completion();
        }
    };

    dispatch_group_t group = dispatch_group_create();
    for (NSHTTPCookie *cookie in cookies) {
        dispatch_group_enter(group);
        [cookieStore setCookie:cookie completionHandler:^{
            dispatch_group_leave(group);
        }];
    }
    dispatch_group_notify(group, dispatch_get_main_queue(), finish);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), finish);
}

+ (void)clearWebsiteDataWithCompletion:(void (^)(void))completion {
    id<CWBWKWebsiteDataStore> store = [self defaultDataStore];
    Class storeClass = NSClassFromString(@"WKWebsiteDataStore");
    BOOL canClear = store != nil
        && [storeClass respondsToSelector:@selector(allWebsiteDataTypes)]
        && [store respondsToSelector:@selector(removeDataOfTypes:modifiedSince:completionHandler:)];
    if (!canClear) {
        completion();
        return;
    }
    NSSet<NSString *> *dataTypes = [(Class<CWBWKWebsiteDataStore>)storeClass allWebsiteDataTypes];
    [store removeDataOfTypes:dataTypes modifiedSince:[NSDate dateWithTimeIntervalSince1970:0] completionHandler:^{
        dispatch_async(dispatch_get_main_queue(), completion);
    }];
}

@end
