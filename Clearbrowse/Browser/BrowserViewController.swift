import AVKit
import Combine
import SwiftUI
import UIKit

/// What the menu shows about the current page.
@MainActor
final class BrowserModel: ObservableObject {
    @Published var url: URL?
    @Published var title = ""
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var hasVideo = false
    /// A video address the Apple TV player can open directly, when the page exposes one.
    @Published var playerURL: URL?
    @Published var blockedPopup: URL?
}

/// What one frame of the page has reported about its video.
struct FrameVideo {
    var frame: Any?
    var hasVideo = false
    var isPlaying = false
    var isAudible = false
    var source: URL?
    var stream: URL?
    var page: URL?
    var updated = Date()
}

/// The browser screen: a full-screen page, a cursor moved by the Siri Remote, and nothing else
/// until the menu is opened.
///
/// The class is split across files: page callbacks in `+Page`, the remote in `+Remote`, and
/// full-screen video in `+Video`.
@MainActor
final class BrowserViewController: UIViewController {
    let model = BrowserModel()
    let preferences = Preferences.shared

    // Views
    var webView: CWBWebView?
    let letterbox = LetterboxView()
    let progressBar = UIView()
    let toast = ToastView()
    let cursorView = CursorView()

    // Page
    let scriptToken = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    var lastKnownURL: URL?
    var wantsMenu = false
    var cookieSaveTimer: Timer?
    var lastCrashReload = Date.distantPast

    // Remote (see BrowserViewController+Remote.swift)
    var cursorPosition = CGPoint.zero
    var lastTouchLocation: CGPoint?
    var activePresses: Set<Int> = []
    var playPauseTimer: Timer?
    var playPauseLongFired = false
    var scrollDirection = CGPoint.zero
    var scrollHoldTime: TimeInterval = 0
    var pendingScroll = CGPoint.zero
    var displayLink: CADisplayLink?
    var lastFrameTimestamp: CFTimeInterval = 0
    var hoverTimer: Timer?
    var cursorHideTimer: Timer?

    // Video (see BrowserViewController+Video.swift)
    var frameVideos: [String: FrameVideo] = [:]
    var theaterActive = false
    var theaterFrame: Any?
    var theaterOwnerCandidate: Any?
    var player: AVPlayer?
    var playerStatusObservation: NSKeyValueObservation?
    var playerPageFrame: Any?
    var playerSyncsBack = false
    var didShowVideoHint = false
    var didShowTheaterHint = false

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        cursorPosition = CGPoint(x: view.bounds.midX, y: view.bounds.midY)

        letterbox.frame = view.bounds
        letterbox.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        progressBar.backgroundColor = CursorView.accent
        progressBar.isUserInteractionEnabled = false
        progressBar.isHidden = true

        view.addSubview(letterbox)
        view.addSubview(progressBar)
        view.addSubview(toast)
        view.addSubview(cursorView)
        cursorView.position = cursorPosition

        guard CWBWebView.isEngineAvailable else {
            showEngineMissing()
            return
        }
        buildWebView()

        // Sign-ins come back before the first page loads.
        CWBWebView.restoreCookies(CookieJar.load()) { [weak self] in
            MainActor.assumeIsolated {
                self?.openStartPage()
            }
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if wantsMenu {
            showMenu()
        }
    }

    private func buildWebView() {
        webView?.delegate = nil
        webView?.removeFromSuperview()

        let mode = preferences.siteMode
        let web = CWBWebView(
            frame: view.bounds,
            userScript: PageScript.source(token: scriptToken),
            userAgent: mode.userAgent,
            desktopMode: mode == .desktop
        )
        web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        web.pageZoom = Double(preferences.zoomPercent) / 100
        web.delegate = self
        view.insertSubview(web, at: 0)
        webView = web
    }

    private func showEngineMissing() {
        cursorView.isHidden = true
        let label = UILabel(frame: view.bounds.insetBy(dx: 200, dy: 200))
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .white
        label.font = .systemFont(ofSize: 38, weight: .medium)
        let version = ProcessInfo.processInfo.operatingSystemVersionString
        label.text = "Clearbrowse can't show web pages on this Apple TV.\n\nThe web engine it relies on wasn't found in tvOS (\(version))."
        view.addSubview(label)
    }

    private func openStartPage() {
        let interrupted = preferences.restoreInProgress
        if preferences.reopenLastPage, !interrupted,
           let saved = preferences.lastURL, let url = URL(string: saved) {
            // If this page takes the app down, the next launch opens the menu instead.
            preferences.restoreInProgress = true
            Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { _ in
                MainActor.assumeIsolated {
                    Preferences.shared.restoreInProgress = false
                }
            }
            load(url)
            return
        }

        preferences.restoreInProgress = false
        if interrupted {
            showToast("The last page wasn't reopened because Clearbrowse closed unexpectedly.", duration: 6)
        }
        showMenu()
    }

    func showRemoteHintIfNeeded() {
        guard !preferences.hasSeenRemoteHint, presentedViewController == nil else { return }
        preferences.hasSeenRemoteHint = true
        showToast("Swipe to move the cursor. Click to select. Press Play/Pause for the menu.", duration: 9)
    }

    // MARK: Navigation

    func load(_ url: URL) {
        load(URLRequest(url: url))
    }

    func load(_ request: URLRequest) {
        endTheater(tellPage: false)
        webView?.load(request)
    }

    /// Opens what was typed in the address field: an address if it looks like one, else a search.
    func open(text: String) {
        guard let url = Address.destination(for: text, engine: preferences.searchEngine) else { return }
        load(url)
    }

    func goBack() {
        endTheater(tellPage: false)
        webView?.goBack()
    }

    func goForward() {
        endTheater(tellPage: false)
        webView?.goForward()
    }

    func reloadOrStop() {
        guard let webView else { return }
        if webView.isLoading {
            webView.stopLoading()
        } else {
            webView.reload()
        }
    }

    func toggleBookmark() {
        guard let url = webView?.url, url.scheme?.hasPrefix("http") == true else { return }
        Library.shared.toggleBookmark(title: webView?.title ?? "", url: url)
    }

    func openBlockedPopup() {
        guard let url = model.blockedPopup else { return }
        model.blockedPopup = nil
        load(url)
    }

    // MARK: Settings that change the page

    func applyZoom() {
        webView?.pageZoom = Double(preferences.zoomPercent) / 100
    }

    /// The device a page sees is fixed when the engine is created, so changing it starts over.
    func applySiteMode() {
        guard webView != nil else { return }
        let current = webView?.url
        endTheater(tellPage: false)
        frameVideos.removeAll()
        refreshVideoState()
        buildWebView()
        if let current, current.scheme?.hasPrefix("http") == true {
            load(current)
        }
    }

    func clearWebsiteData() {
        CookieJar.clear()
        CWBWebView.clearWebsiteData { [weak self] in
            MainActor.assumeIsolated {
                self?.showToast("Cookies and website data cleared.")
                self?.webView?.reload()
            }
        }
    }

    // MARK: Session

    /// Called when the app is about to leave the screen.
    func saveSession() {
        backUpCookies()
        resetRemoteState()
    }

    func backUpCookies() {
        guard webView != nil else { return }
        CWBWebView.fetchAllCookies { cookies in
            CookieJar.save(cookies)
        }
    }

    func scheduleCookieBackup() {
        cookieSaveTimer?.invalidate()
        cookieSaveTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.backUpCookies()
            }
        }
    }

    // MARK: Chrome

    func syncModel() {
        guard let webView else { return }
        let url = webView.url
        if model.url != url { model.url = url }
        let title = webView.title ?? ""
        if model.title != title { model.title = title }
        if model.canGoBack != webView.canGoBack { model.canGoBack = webView.canGoBack }
        if model.canGoForward != webView.canGoForward { model.canGoForward = webView.canGoForward }
        if model.isLoading != webView.isLoading { model.isLoading = webView.isLoading }

        if let url, url != lastKnownURL {
            lastKnownURL = url
            addressChanged(to: url)
        }
    }

    private func addressChanged(to url: URL) {
        if url.scheme?.hasPrefix("http") == true {
            preferences.lastURL = url.absoluteString
        }
        // Sites that swap videos without loading a new page would otherwise keep an old stream.
        for key in frameVideos.keys {
            frameVideos[key]?.stream = nil
        }
        refreshVideoState()
    }

    func updateProgress() {
        guard let webView else { return }
        progressBar.isHidden = !webView.isLoading
        let fraction = CGFloat(max(0.06, min(1, webView.estimatedProgress)))
        progressBar.frame = CGRect(x: 0, y: 0, width: view.bounds.width * fraction, height: 6)
    }

    func showToast(_ text: String, duration: TimeInterval = 4) {
        toast.show(text, for: duration, in: view.bounds)
    }

    // MARK: Menu

    func showMenu() {
        guard isViewLoaded, view.window != nil, presentedViewController == nil else {
            wantsMenu = true
            return
        }
        wantsMenu = false
        resetRemoteState()
        syncModel()

        let host = UIHostingController(rootView: MenuView(browser: self, model: model))
        host.modalPresentationStyle = .blurOverFullScreen
        host.view.backgroundColor = .clear
        present(host, animated: true)
    }

    /// Closes the menu, then runs `action` once the page is back in front.
    func closeMenu(then action: (@MainActor () -> Void)? = nil) {
        guard presentedViewController != nil else {
            action?()
            return
        }
        dismiss(animated: true) {
            MainActor.assumeIsolated {
                action?()
            }
        }
    }

    // MARK: Talking to the page

    /// Calls a command in the injected page script. `frame` targets a specific frame of the page.
    func runCommand(
        _ name: String,
        _ arguments: [Any] = [],
        frame: Any? = nil,
        completion: (@MainActor (Any?) -> Void)? = nil
    ) {
        let payload: [Any] = [scriptToken, name] + arguments
        guard let webView,
              JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8)
        else {
            completion?(nil)
            return
        }
        let script = "window.__cwb ? window.__cwb.apply(null, \(json)) : undefined"
        webView.evaluate(script, inFrame: frame) { result, _ in
            MainActor.assumeIsolated {
                completion?(result)
            }
        }
    }
}

/// Decides what a typed address means.
enum Address {
    static func destination(for input: String, engine: SearchEngine) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let lower = text.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://"), let url = URL(string: text), url.host != nil {
            return url
        }

        let host = lower.split(separator: "/").first.map(String.init) ?? lower
        let looksLikeHost = !text.contains(" ") && (host.contains(".") || host.hasPrefix("localhost"))
        if looksLikeHost {
            // Devices on the home network (routers, media servers) usually have no certificate.
            let name = host.split(separator: ":").first.map(String.init) ?? host
            let isLocal = name == "localhost" || name.hasSuffix(".local")
                || name.allSatisfy { $0.isNumber || $0 == "." }
            if let url = URL(string: (isLocal ? "http://" : "https://") + text), url.host != nil {
                return url
            }
        }
        return engine.searchURL(for: text)
    }
}
