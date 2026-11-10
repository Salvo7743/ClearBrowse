import UIKit

/// Calls its handler exactly once: with the given value, or with the fallback if it is released
/// without having been called. The web engine raises an exception when one of its dialog
/// callbacks is dropped, which could otherwise happen if an alert goes away without a choice.
private final class Reply<Value> {
    private var handler: ((Value) -> Void)?
    private let fallback: Value

    init(fallback: Value, handler: @escaping (Value) -> Void) {
        self.fallback = fallback
        self.handler = handler
    }

    func send(_ value: Value) {
        let handler = self.handler
        self.handler = nil
        handler?(value)
    }

    deinit {
        handler?(fallback)
    }
}

// MARK: - Engine callbacks

extension BrowserViewController: CWBWebViewDelegate {
    func webViewDidStartLoading(_ webView: CWBWebView) {
        syncModel()
        updateProgress()
    }

    func webViewDidCommitNavigation(_ webView: CWBWebView) {
        // A new document replaced the old one, so nothing known about its videos still holds.
        endTheater(tellPage: false)
        frameVideos.removeAll()
        refreshVideoState()
        cursorView.kind = .arrow
        syncModel()
    }

    func webViewDidFinishLoading(_ webView: CWBWebView) {
        preferences.restoreInProgress = false
        syncModel()
        updateProgress()
        if let url = webView.url {
            Library.shared.recordVisit(title: webView.title, url: url)
        }
        scheduleCookieBackup()
        // The first page ever opened: say how the remote works, including how to get the menu back.
        showRemoteHintIfNeeded()
    }

    func webView(_ webView: CWBWebView, didFail error: Error, provisional: Bool) {
        let failure = error as NSError
        // Not failures: a load the browser cancelled itself, or one handed to the video player.
        if failure.domain == NSURLErrorDomain, failure.code == NSURLErrorCancelled { return }
        if failure.domain == "WebKitErrorDomain", failure.code == 102 || failure.code == 204 { return }

        syncModel()
        updateProgress()
        guard provisional else {
            showToast(failure.localizedDescription)
            return
        }
        let failingURL = (failure.userInfo[NSURLErrorFailingURLErrorKey] as? URL)
            ?? (failure.userInfo[NSURLErrorFailingURLStringErrorKey] as? String).flatMap { URL(string: $0) }
        webView.loadHTML(ErrorPage.html(message: failure.localizedDescription, url: failingURL), baseURL: nil)
    }

    func webViewDidUpdateState(_ webView: CWBWebView) {
        syncModel()
        updateProgress()
    }

    func webViewContentProcessDidTerminate(_ webView: CWBWebView) {
        endTheater(tellPage: false)
        frameVideos.removeAll()
        refreshVideoState()
        // Reload once; a page that keeps crashing is left alone.
        if Date().timeIntervalSince(lastCrashReload) > 30 {
            lastCrashReload = Date()
            showToast("The page stopped working, so it was reloaded.")
            webView.reload()
        } else {
            showToast("The page stopped working. Press Play/Pause to go somewhere else.", duration: 6)
        }
    }

    func webView(_ webView: CWBWebView, didRequestNewWindow request: URLRequest, fromLink: Bool) {
        guard let url = request.url else { return }
        if fromLink || !preferences.blockPopups {
            load(request)
        } else {
            model.blockedPopup = url
            showToast("Pop-up blocked. You can open it from the menu.")
        }
    }

    func webView(_ webView: CWBWebView, shouldHandleMediaAt url: URL, mimeType: String) -> Bool {
        // A link straight to a video or audio file: play it in the Apple TV player.
        playInPlayer(url, startAt: nil, pageURL: webView.url, pageFrame: nil, syncsBack: false)
        return true
    }

    func webView(_ webView: CWBWebView, didBlockNavigationTo url: URL, isDownload: Bool) {
        if isDownload {
            showToast("Files can't be downloaded on Apple TV.")
        } else {
            showToast("Clearbrowse can't open \"\(url.scheme ?? "these")\" links.")
        }
    }

    // MARK: JavaScript dialogs

    private var canShowDialog: Bool {
        isViewLoaded && view.window != nil && presentedViewController == nil
    }

    private var dialogTitle: String {
        webView?.url?.host ?? "This page"
    }

    func webView(_ webView: CWBWebView, runAlert message: String, completion: @escaping () -> Void) {
        guard canShowDialog else {
            completion()
            return
        }
        let reply = Reply<Void>(fallback: (), handler: { _ in completion() })
        let alert = UIAlertController(title: dialogTitle, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .cancel) { _ in reply.send(()) })
        resetRemoteState()
        present(alert, animated: true)
    }

    func webView(_ webView: CWBWebView, runConfirm message: String, completion: @escaping (Bool) -> Void) {
        guard canShowDialog else {
            completion(false)
            return
        }
        let reply = Reply<Bool>(fallback: false, handler: completion)
        let alert = UIAlertController(title: dialogTitle, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in reply.send(true) })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in reply.send(false) })
        resetRemoteState()
        present(alert, animated: true)
    }

    func webView(_ webView: CWBWebView, runPrompt message: String, defaultText: String?, completion: @escaping (String?) -> Void) {
        guard canShowDialog else {
            completion(nil)
            return
        }
        let reply = Reply<String?>(fallback: nil, handler: completion)
        let alert = UIAlertController(title: dialogTitle, message: message, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = defaultText
        }
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak alert] _ in
            reply.send(alert?.textFields?.first?.text ?? "")
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in reply.send(nil) })
        resetRemoteState()
        present(alert, animated: true)
    }

    // MARK: Messages from the page script

    func webView(_ webView: CWBWebView, didReceiveMessage message: [String: Any], fromFrame frame: Any?, isMainFrame: Bool) {
        // Page scripts can reach the message channel too; only the injected script knows the token.
        guard message["token"] as? String == scriptToken, let type = message["type"] as? String else { return }
        let frameID = message["frame"] as? String ?? ""
        let page = (message["page"] as? String).flatMap { URL(string: $0) }

        switch type {
        case "edit":
            askForText(
                current: message["value"] as? String ?? "",
                label: message["label"] as? String ?? "",
                kind: message["kind"] as? String ?? "text",
                secure: message["secure"] as? Bool ?? false,
                frame: frame
            )

        case "select":
            askForOption(
                message["options"] as? [[String: Any]] ?? [],
                label: message["label"] as? String ?? "",
                frame: frame
            )

        case "video":
            videoChanged(
                frameID: frameID,
                frame: frame,
                page: page,
                hasVideo: message["has"] as? Bool ?? false,
                isPlaying: message["playing"] as? Bool ?? false,
                isAudible: message["audible"] as? Bool ?? false,
                source: (message["src"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
            )

        case "stream":
            if let url = (message["url"] as? String).flatMap({ URL(string: $0) }) {
                streamFound(url, frameID: frameID, frame: frame, page: page)
            }

        case "theaterOwner":
            theaterOwnerCandidate = frame

        case "theater":
            if message["on"] as? Bool == true,
               let x = message["x"] as? Double, let y = message["y"] as? Double,
               let width = message["w"] as? Double, let height = message["h"] as? Double {
                showTheater(viewportFraction: CGRect(x: x, y: y, width: width, height: height))
            } else {
                endTheater(tellPage: false)
            }

        default:
            break
        }
    }

    // MARK: Typing

    /// tvOS has no keyboard a page can use, so a click on a text field asks for the text here and
    /// hands it back to the field.
    private func askForText(current: String, label: String, kind: String, secure: Bool, frame: Any?) {
        guard canShowDialog else { return }
        let alert = UIAlertController(title: label.isEmpty ? "Enter Text" : label, message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = current
            field.placeholder = label
            field.isSecureTextEntry = secure
            field.autocorrectionType = .no
            field.autocapitalizationType = .none
            switch kind {
            case "email": field.keyboardType = .emailAddress
            case "url": field.keyboardType = .URL
            case "number", "tel": field.keyboardType = .numbersAndPunctuation
            default: field.keyboardType = .default
            }
        }
        let send: (Bool) -> Void = { [weak self, weak alert] submit in
            let text = alert?.textFields?.first?.text ?? ""
            self?.runCommand("setText", [text, submit], frame: frame)
        }
        alert.addAction(UIAlertAction(title: kind == "search" ? "Search" : "Done and Press Enter", style: .default) { _ in send(true) })
        alert.addAction(UIAlertAction(title: "Done", style: .default) { _ in send(false) })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        resetRemoteState()
        present(alert, animated: true)
    }

    /// Stands in for the pop-up list of a <select>.
    private func askForOption(_ options: [[String: Any]], label: String, frame: Any?) {
        guard canShowDialog, !options.isEmpty else { return }
        let sheet = UIAlertController(title: label.isEmpty ? nil : label, message: nil, preferredStyle: .actionSheet)
        for option in options {
            guard let index = option["index"] as? Int else { continue }
            let name = option["label"] as? String ?? ""
            let selected = option["selected"] as? Bool ?? false
            let title = (selected ? "✓ " : "") + (name.isEmpty ? "(blank)" : name)
            sheet.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                self?.runCommand("setSelected", [index], frame: frame)
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        resetRemoteState()
        present(sheet, animated: true)
    }
}

/// The page shown when an address can't be loaded.
enum ErrorPage {
    static func html(message: String, url: URL?) -> String {
        let address = url?.absoluteString ?? ""
        let retry = address.isEmpty ? "" : "<p><a href=\"\(escape(address))\">Try again</a></p>"
        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Can't open this page</title>
        <style>
        html { background: #101214; color: #e8eaed; font: 22px -apple-system, Helvetica, sans-serif; }
        body { max-width: 900px; margin: 14vh auto; padding: 0 40px; }
        h1 { font-size: 40px; margin-bottom: 12px; }
        p { line-height: 1.5; color: #b6bbc2; word-break: break-word; }
        a { display: inline-block; margin-top: 18px; padding: 14px 32px; border-radius: 12px;
            background: #2ec4b6; color: #06211f; font-weight: 600; text-decoration: none; }
        </style>
        </head>
        <body>
        <h1>Can't open this page</h1>
        <p>\(escape(message))</p>
        <p>\(escape(address))</p>
        \(retry)
        </body>
        </html>
        """
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
