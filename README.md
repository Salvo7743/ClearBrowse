# Clearbrowse

A web browser for Apple TV (tvOS 17+) that plays web video, built to be sideloaded with
[atvloadly](https://github.com/bitxeno/atvloadly).

- **Real web pages.** Uses the WebKit engine that tvOS ships but doesn't offer to apps.
- **Video plays in the page**, including streaming players, and goes **full screen** from the
  menu or the site's own full-screen button.
- **Apple TV player** for videos that have a plain address (MP4 or HLS), with the page's cookies.
- A cursor driven by the Siri Remote, an on-screen keyboard for text fields, bookmarks, history,
  page zoom, desktop/tablet/phone modes, and pop-up blocking.

Apple doesn't allow this on the App Store, because the web engine is reached through private
system classes. It is for personal, sideloaded use.

## Remote

| Remote | What it does |
| --- | --- |
| Swipe | Move the cursor. Push against an edge to scroll. |
| Click | Click what's under the cursor. Text fields open the keyboard. |
| Arrow buttons | Scroll. In full-screen video: skip back / forward 10 seconds. |
| Play/Pause | Open the menu, which offers **Full Screen Video** when the page has one. In full screen: pause and resume. |
| Back | Leave full screen, then go back a page. With nowhere to go back to, leaves the app. |

A site's own full-screen button works too.

## Getting the IPA

tvOS apps can only be compiled with Xcode on macOS, so the repo builds itself on a GitHub Actions
macOS runner. Every push to `main` publishes a release (`v1.1.<run number>`) with
`Clearbrowse.ipa` attached; you can also start a build by hand from **Actions → Build tvOS IPA →
Run workflow**. Install the IPA with atvloadly the same way as any other.

## What doesn't work

- **Copy-protected streaming** (Netflix, Disney+, Prime Video and similar). Use their own apps.
- **Sites that insist on a real finger or mouse.** Clicks are simulated, so a few "prove you're
  human" checks and some hover-only menus don't respond.
- **Downloads and file uploads.** tvOS has nowhere to put files.
- **Some sign-ins after a restart.** Cookies are kept, but tvOS doesn't keep the rest of a site's
  storage once the app is closed.

If a site misbehaves, try **Settings → Show sites as → Tablet** or **Phone**.

## How it works

| Path | What it is |
| --- | --- |
| `project.yml` | XcodeGen spec; CI turns it into `Clearbrowse.xcodeproj` |
| `Clearbrowse/Bridge` | Objective-C wrapper that finds `WKWebView` at runtime and drives it |
| `Clearbrowse/Web/PageScript.swift` | Script injected into every frame: clicks, typing, scrolling, video, full screen |
| `Clearbrowse/Browser` | The browser screen, remote handling, full-screen video, Apple TV player |
| `Clearbrowse/UI` | The menu, History and Settings (SwiftUI) |
| `Clearbrowse/Store` | Settings, bookmarks, history, cookie backup |

tvOS never sends touches to a web page, so the app turns the cursor position into mouse events
inside the page. Full screen is done by magnifying the page until the video fills the TV, because
the engine's own full-screen presentation isn't usable on tvOS.

Loading `WKWebView` by name on tvOS is the approach shown by the
[tvOSBrowser](https://github.com/jvanakker/tvOSBrowser) project. Clearbrowse is independent code
and isn't affiliated with Apple.
