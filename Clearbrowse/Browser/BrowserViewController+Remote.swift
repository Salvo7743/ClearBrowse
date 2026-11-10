import UIKit

/// Siri Remote handling.
///
/// - Swipe: move the cursor. Pushing against an edge scrolls the page.
/// - Click: click whatever is under the cursor.
/// - Arrow clicks: scroll (in full-screen video: skip back and forward).
/// - Play/Pause: the menu. In full-screen video it pauses and resumes; holding it opens the menu.
/// - Back: leave full screen, or go back a page.
extension BrowserViewController: RemoteEventHandler {
    func handleRemoteEvent(_ event: UIEvent) -> Bool {
        // While the menu, a dialog or the Apple TV player is up, the remote belongs to them.
        guard webView != nil, isViewLoaded, view.window != nil, presentedViewController == nil else {
            resetRemoteState()
            return false
        }
        if let pressesEvent = event as? UIPressesEvent {
            return handlePresses(pressesEvent)
        }
        if event.type == .touches {
            handleTouches(event)
        }
        return false
    }

    /// Forgets anything half-finished: held buttons, a finger on the touch surface, scrolling.
    func resetRemoteState() {
        activePresses.removeAll()
        lastTouchLocation = nil
        playPauseTimer?.invalidate()
        playPauseTimer = nil
        scrollDirection = .zero
        pendingScroll = .zero
        stopDisplayLink()
    }

    // MARK: Buttons

    private func handlePresses(_ event: UIPressesEvent) -> Bool {
        var consumed = false
        for press in event.allPresses {
            let key = press.type.rawValue
            switch press.phase {
            case .began:
                if pressBegan(press.type) {
                    activePresses.insert(key)
                    consumed = true
                }
            case .ended:
                if activePresses.remove(key) != nil {
                    pressEnded(press.type, cancelled: false)
                    consumed = true
                }
            case .cancelled:
                if activePresses.remove(key) != nil {
                    pressEnded(press.type, cancelled: true)
                    consumed = true
                }
            case .changed, .stationary:
                if activePresses.contains(key) {
                    consumed = true
                }
            @unknown default:
                break
            }
        }
        return consumed
    }

    /// Returns true when the browser takes the press. A press it doesn't take goes to tvOS, which
    /// is how Back leaves the app once there is nothing left to go back to.
    private func pressBegan(_ type: UIPress.PressType) -> Bool {
        switch type {
        case .select:
            showCursor()
            return true

        case .playPause:
            playPauseLongFired = false
            playPauseTimer?.invalidate()
            playPauseTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.presentedViewController == nil else { return }
                    self.playPauseLongFired = true
                    self.showMenu()
                }
            }
            return true

        case .menu:
            return theaterActive || (webView?.canGoBack ?? false)

        case .upArrow:
            if !theaterActive { startScrolling(CGPoint(x: 0, y: -1)) }
            return true
        case .downArrow:
            if !theaterActive { startScrolling(CGPoint(x: 0, y: 1)) }
            return true
        case .leftArrow:
            if !theaterActive { startScrolling(CGPoint(x: -1, y: 0)) }
            return true
        case .rightArrow:
            if !theaterActive { startScrolling(CGPoint(x: 1, y: 0)) }
            return true

        default:
            return false
        }
    }

    private func pressEnded(_ type: UIPress.PressType, cancelled: Bool) {
        switch type {
        case .select:
            if !cancelled { clickAtCursor() }

        case .playPause:
            playPauseTimer?.invalidate()
            playPauseTimer = nil
            if !cancelled, !playPauseLongFired { playPauseTapped() }

        case .menu:
            guard !cancelled else { return }
            if theaterActive {
                endTheater(tellPage: true)
            } else {
                goBack()
            }

        case .upArrow, .downArrow, .leftArrow, .rightArrow:
            scrollDirection = .zero
            guard !cancelled, theaterActive else { return }
            if type == .leftArrow {
                runCommand("media", ["seek", -10], frame: theaterFrame)
            } else if type == .rightArrow {
                runCommand("media", ["seek", 10], frame: theaterFrame)
            }

        default:
            break
        }
    }

    /// Outside full screen this always opens the menu, whatever the page is doing, so there is
    /// always one obvious way to leave a site. (It used to start full screen when a video was
    /// playing, which left no clear way to the menu on sites where a video is always playing.)
    private func playPauseTapped() {
        if theaterActive {
            runCommand("media", ["toggle"], frame: theaterFrame)
        } else {
            showMenu()
        }
    }

    // MARK: Touch surface

    private func handleTouches(_ event: UIEvent) {
        guard let touch = event.allTouches?.first(where: { $0.type == .indirect }) else { return }
        let location = touch.location(in: view)
        switch touch.phase {
        case .began:
            lastTouchLocation = location
        case .moved:
            if let last = lastTouchLocation {
                moveCursor(by: CGPoint(x: location.x - last.x, y: location.y - last.y))
            }
            lastTouchLocation = location
        default:
            lastTouchLocation = nil
        }
    }

    private func moveCursor(by delta: CGPoint) {
        let speed = CGFloat(preferences.cursorSpeed)
        let limit = view.bounds.insetBy(dx: 4, dy: 4)
        var x = cursorPosition.x + delta.x * speed
        var y = cursorPosition.y + delta.y * speed

        // Whatever doesn't fit on screen becomes scrolling.
        var overflow = CGPoint.zero
        if x < limit.minX {
            overflow.x = x - limit.minX
            x = limit.minX
        } else if x > limit.maxX {
            overflow.x = x - limit.maxX
            x = limit.maxX
        }
        if y < limit.minY {
            overflow.y = y - limit.minY
            y = limit.minY
        } else if y > limit.maxY {
            overflow.y = y - limit.maxY
            y = limit.maxY
        }

        cursorPosition = CGPoint(x: x, y: y)
        cursorView.position = cursorPosition
        showCursor()
        scheduleHover()

        if overflow != .zero, !theaterActive {
            pendingScroll.x += overflow.x
            pendingScroll.y += overflow.y
            startDisplayLink()
        }
    }

    /// Where the cursor is in the page, as fractions of the page's viewport.
    private var cursorFraction: CGPoint? {
        guard let webView else { return nil }
        let fraction = webView.viewportFraction(for: cursorPosition, in: view)
        guard fraction.x.isFinite, fraction.y.isFinite else { return nil }
        return fraction
    }

    private func clickAtCursor() {
        guard let fraction = cursorFraction else { return }
        showCursor()
        cursorView.pulse()
        runCommand("click", [Double(fraction.x), Double(fraction.y)])
    }

    // MARK: Cursor appearance

    func showCursor() {
        if cursorView.alpha < 1 {
            UIView.animate(withDuration: 0.12) { self.cursorView.alpha = 1 }
        }
        cursorHideTimer?.invalidate()
        // Out of the way sooner over a full-screen video than over a page being read.
        let delay: TimeInterval = theaterActive ? 3 : 12
        cursorHideTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                UIView.animate(withDuration: 0.4) { self.cursorView.alpha = 0 }
            }
        }
    }

    /// Tells the page where the cursor is (so hover effects and player controls react) and picks
    /// the cursor shape from what's underneath. Limited to about a dozen times a second.
    func scheduleHover() {
        guard hoverTimer == nil else { return }
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.hoverTimer = nil
                guard self.presentedViewController == nil, let fraction = self.cursorFraction else { return }
                self.runCommand("hover", [Double(fraction.x), Double(fraction.y)]) { [weak self] result in
                    let kind = CursorView.Kind(rawValue: result as? String ?? "") ?? .arrow
                    self?.cursorView.kind = kind
                }
            }
        }
    }

    // MARK: Scrolling

    private func startScrolling(_ direction: CGPoint) {
        scrollDirection = direction
        scrollHoldTime = 0
        // A quick click still moves the page a useful amount.
        pendingScroll.x += direction.x * 140
        pendingScroll.y += direction.y * 140
        startDisplayLink()
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        lastFrameTimestamp = 0
        let link = CADisplayLink(target: self, selector: #selector(displayLinkFired(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func displayLinkFired(_ link: CADisplayLink) {
        let elapsed = lastFrameTimestamp > 0 ? min(link.timestamp - lastFrameTimestamp, 0.1) : 1.0 / 60
        lastFrameTimestamp = link.timestamp

        var delta = pendingScroll
        pendingScroll = .zero
        if scrollDirection != .zero {
            // Speeds up the longer the button is held.
            scrollHoldTime += elapsed
            let speed = min(700 + scrollHoldTime * 1600, 3600)
            delta.x += scrollDirection.x * CGFloat(speed * elapsed)
            delta.y += scrollDirection.y * CGFloat(speed * elapsed)
        }

        guard delta != .zero else {
            if scrollDirection == .zero { stopDisplayLink() }
            return
        }
        guard let fraction = cursorFraction else { return }
        let size = view.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        runCommand("scroll", [
            Double(fraction.x), Double(fraction.y),
            Double(delta.x / size.width), Double(delta.y / size.height),
        ])
        scheduleHover()
    }
}
