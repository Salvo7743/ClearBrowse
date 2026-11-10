import AVKit
import UIKit

/// Video: what the page has playing, full screen, and the Apple TV player.
///
/// Full screen ("theater") never asks the web engine to present anything, because the engine's
/// own full-screen path isn't usable on tvOS. The page script reports where the video (or the
/// element a site asked to make full screen) sits, and the whole page is magnified so that
/// rectangle fills the TV. The video keeps playing in the page, so it works for every site that
/// plays inline, including streaming players that have no plain file address.
extension BrowserViewController {

    // MARK: What the page has reported

    /// The video the viewer most likely cares about: audible and playing first, then the latest.
    var activeVideo: FrameVideo? {
        frameVideos.values
            .filter { $0.hasVideo }
            .max { rank($0) < rank($1) }
    }

    private func rank(_ video: FrameVideo) -> (Int, TimeInterval) {
        let level = video.isPlaying ? (video.isAudible ? 2 : 1) : 0
        return (level, video.updated.timeIntervalSinceReferenceDate)
    }

    func videoChanged(frameID: String, frame: Any?, page: URL?, hasVideo: Bool, isPlaying: Bool, isAudible: Bool, source: URL?) {
        if hasVideo {
            var entry = frameVideos[frameID] ?? FrameVideo()
            entry.frame = frame
            entry.page = page
            entry.hasVideo = true
            entry.isPlaying = isPlaying
            entry.isAudible = isAudible
            entry.source = source
            entry.updated = Date()
            frameVideos[frameID] = entry
        } else {
            frameVideos[frameID] = nil
        }
        refreshVideoState()

        if isPlaying, isAudible, !didShowVideoHint, !theaterActive, presentedViewController == nil {
            didShowVideoHint = true
            showToast("Press Play/Pause to watch full screen.", duration: 5)
        }
    }

    func streamFound(_ url: URL, frameID: String, frame: Any?, page: URL?) {
        var entry = frameVideos[frameID] ?? FrameVideo()
        if entry.frame == nil { entry.frame = frame }
        if entry.page == nil { entry.page = page }
        // The first playlist a player asks for is the one that lists every quality.
        guard entry.stream == nil else { return }
        entry.stream = url
        frameVideos[frameID] = entry
        refreshVideoState()
    }

    func refreshVideoState() {
        let hasVideo = activeVideo != nil
        if model.hasVideo != hasVideo { model.hasVideo = hasVideo }
        let playerURL = playerCandidate?.url
        if model.playerURL != playerURL { model.playerURL = playerURL }
        // Keep the screen saver away while something is playing in the page.
        UIApplication.shared.isIdleTimerDisabled = frameVideos.values.contains { $0.hasVideo && $0.isPlaying }
    }

    /// An address the Apple TV player could open, and the frame it belongs to.
    private var playerCandidate: (url: URL, entry: FrameVideo)? {
        if let active = activeVideo {
            if let source = active.source, Self.playerCanOpen(source) { return (source, active) }
            if let stream = active.stream { return (stream, active) }
        }
        // The playlist is sometimes fetched by a different frame than the one showing the video.
        let newest = frameVideos.values
            .filter { $0.stream != nil }
            .max { $0.updated < $1.updated }
        if let newest, let stream = newest.stream { return (stream, newest) }
        return nil
    }

    private static func playerCanOpen(_ url: URL) -> Bool {
        !["webm", "mkv", "ogv", "ogg", "mpd", "flv"].contains(url.pathExtension.lowercased())
    }

    // MARK: Full screen in the page

    func enterTheater() {
        guard let video = activeVideo else {
            showToast("There's no video on this page yet.")
            return
        }
        runCommand("theater", [true], frame: video.frame) { [weak self] result in
            if result as? Bool != true {
                self?.showToast("Couldn't find the video to enlarge.")
            }
        }
    }

    /// Magnifies the page so the given part of it (in fractions of the page's viewport) fills the
    /// screen. Called again whenever the page reports that the rectangle moved.
    func showTheater(viewportFraction fraction: CGRect) {
        guard let webView else { return }
        let bounds = webView.bounds
        let target = webView.rect(forViewportFraction: fraction)
        guard bounds.width > 0, bounds.height > 0, target.width > 8, target.height > 8 else { return }

        let fit = min(bounds.width / target.width, bounds.height / target.height)
        let scale = min(max(fit, 0.25), 10)
        var transform = CGAffineTransform(
            a: scale, b: 0, c: 0, d: scale,
            tx: scale * (bounds.midX - target.midX),
            ty: scale * (bounds.midY - target.midY)
        )
        if abs(scale - 1) < 0.01, abs(transform.tx) < 2, abs(transform.ty) < 2 {
            transform = .identity
        }
        let shown = CGRect(
            x: bounds.midX - target.width * scale / 2,
            y: bounds.midY - target.height * scale / 2,
            width: target.width * scale,
            height: target.height * scale
        )

        let starting = !theaterActive
        theaterActive = true
        if let owner = theaterOwnerCandidate { theaterFrame = owner }
        if starting {
            resetRemoteState()
            showCursor()
            if !didShowTheaterHint {
                didShowTheaterHint = true
                showToast("Play/Pause to pause, left and right to skip, Back to leave full screen.", duration: 6)
            }
        }

        letterbox.setHole(shown)
        UIView.animate(withDuration: starting ? 0.35 : 0.2, delay: 0, options: [.beginFromCurrentState, .curveEaseInOut]) {
            webView.transform = transform
            self.letterbox.alpha = 1
        }
    }

    /// Puts the page back to normal size. `tellPage` is false when the page is the one that left
    /// full screen, or when it is going away.
    func endTheater(tellPage: Bool) {
        let owner = theaterFrame ?? theaterOwnerCandidate
        theaterOwnerCandidate = nil
        guard theaterActive else { return }
        theaterActive = false
        theaterFrame = nil

        if tellPage {
            runCommand("theater", [false], frame: owner)
        }
        if let webView {
            UIView.animate(withDuration: 0.3, delay: 0, options: [.beginFromCurrentState, .curveEaseInOut]) {
                webView.transform = .identity
                self.letterbox.alpha = 0
            }
        }
        showCursor()
    }

    // MARK: Apple TV player

    /// Opens the page's video in the system player, when the page exposes an address for it.
    func openInPlayer() {
        guard let candidate = playerCandidate else {
            showToast("This page doesn't expose a video the Apple TV player can open.")
            return
        }
        let entry = candidate.entry
        guard entry.hasVideo else {
            playInPlayer(candidate.url, startAt: nil, pageURL: entry.page ?? webView?.url, pageFrame: nil, syncsBack: false)
            return
        }
        // Carry on from where the page's own player is, and stop it so the two don't overlap.
        runCommand("videoInfo", frame: entry.frame) { [weak self] result in
            guard let self else { return }
            let info = result as? [String: Any]
            let live = info?["live"] as? Bool ?? false
            let time = info?["time"] as? Double ?? 0
            self.runCommand("media", ["pause"], frame: entry.frame)
            self.playInPlayer(
                candidate.url,
                startAt: (live || time < 1) ? nil : time,
                pageURL: entry.page ?? self.webView?.url,
                pageFrame: entry.frame,
                syncsBack: !live
            )
        }
    }

    func playInPlayer(_ url: URL, startAt: Double?, pageURL: URL?, pageFrame: Any?, syncsBack: Bool) {
        guard player == nil else { return }
        endTheater(tellPage: true)
        let userAgent = preferences.siteMode.userAgent
        // The player makes its own requests, so it needs the page's cookies to be let in.
        CWBWebView.fetchAllCookies { [weak self] cookies in
            MainActor.assumeIsolated {
                self?.startPlayer(
                    url: url, startAt: startAt, pageURL: pageURL, pageFrame: pageFrame,
                    syncsBack: syncsBack, cookies: cookies, userAgent: userAgent
                )
            }
        }
    }

    private func startPlayer(
        url: URL, startAt: Double?, pageURL: URL?, pageFrame: Any?,
        syncsBack: Bool, cookies: [HTTPCookie], userAgent: String
    ) {
        guard player == nil, isViewLoaded, view.window != nil, presentedViewController == nil else { return }

        var headers = ["User-Agent": userAgent]
        if let pageURL, let scheme = pageURL.scheme, scheme.hasPrefix("http"), let host = pageURL.host {
            headers["Referer"] = pageURL.absoluteString
            var origin = "\(scheme)://\(host)"
            if let port = pageURL.port { origin += ":\(port)" }
            headers["Origin"] = origin
        }
        var options: [String: Any] = [
            "AVURLAssetHTTPHeaderFieldsKey": headers,
            AVURLAssetHTTPUserAgentKey: userAgent,
        ]
        let mediaHost = url.host?.lowercased() ?? ""
        let matching = cookies.filter { cookie in
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return !domain.isEmpty && (mediaHost == domain || mediaHost.hasSuffix("." + domain))
        }
        if !matching.isEmpty {
            options[AVURLAssetHTTPCookiesKey] = matching
        }

        let item = AVPlayerItem(asset: AVURLAsset(url: url, options: options))
        let player = AVPlayer(playerItem: item)
        self.player = player
        playerPageFrame = pageFrame
        playerSyncsBack = syncsBack
        playerStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor [weak self] in
                self?.playerFailed()
            }
        }
        if let startAt, startAt > 1 {
            player.seek(to: CMTime(seconds: startAt, preferredTimescale: 600))
        }

        let controller = AVPlayerViewController()
        controller.player = player
        controller.delegate = self
        resetRemoteState()
        present(controller, animated: true) {
            player.play()
        }
    }

    private func playerFailed() {
        guard player != nil else { return }
        let message = "The Apple TV player couldn't open this video. Use Full Screen Video in the menu instead."
        if presentedViewController is AVPlayerViewController {
            dismiss(animated: true) { [weak self] in
                MainActor.assumeIsolated {
                    self?.finishPlayer()
                    self?.showToast(message, duration: 7)
                }
            }
        } else {
            finishPlayer()
            showToast(message, duration: 7)
        }
    }

    /// Releases the player and moves the page's own video to where the viewer stopped.
    fileprivate func finishPlayer() {
        guard let player else { return }
        let time = player.currentTime().seconds
        let failed = player.currentItem?.status == .failed
        player.pause()
        player.replaceCurrentItem(with: nil)
        playerStatusObservation?.invalidate()
        playerStatusObservation = nil
        self.player = nil

        if playerSyncsBack, !failed, time.isFinite, time > 1, let frame = playerPageFrame {
            runCommand("media", ["seekTo", time], frame: frame)
        }
        playerPageFrame = nil
        playerSyncsBack = false
    }
}

extension BrowserViewController: AVPlayerViewControllerDelegate {
    func playerViewControllerDidEndDismissalTransition(_ playerViewController: AVPlayerViewController) {
        finishPlayer()
    }
}
