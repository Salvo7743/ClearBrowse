import Combine
import Foundation

/// Which kind of device pages are told they're running on.
enum SiteMode: String, CaseIterable, Identifiable {
    case desktop
    case tablet
    case phone

    var id: String { rawValue }

    var title: String {
        switch self {
        case .desktop: return "Desktop (Mac)"
        case .tablet: return "Tablet (iPad)"
        case .phone: return "Phone (iPhone)"
        }
    }

    /// A Safari user agent matching this tvOS release, so sites serve what Safari would get.
    var userAgent: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let major = max(version.majorVersion, 17)
        let safari = "\(major).\(version.minorVersion)"
        let os = "\(major)_\(version.minorVersion)"
        switch self {
        case .desktop:
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(safari) Safari/605.1.15"
        case .tablet:
            return "Mozilla/5.0 (iPad; CPU OS \(os) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(safari) Mobile/15E148 Safari/604.1"
        case .phone:
            return "Mozilla/5.0 (iPhone; CPU iPhone OS \(os) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(safari) Mobile/15E148 Safari/604.1"
        }
    }
}

enum SearchEngine: String, CaseIterable, Identifiable {
    case google
    case duckDuckGo
    case bing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .google: return "Google"
        case .duckDuckGo: return "DuckDuckGo"
        case .bing: return "Bing"
        }
    }

    func searchURL(for query: String) -> URL? {
        let base: String
        switch self {
        case .google: base = "https://www.google.com/search"
        case .duckDuckGo: base = "https://duckduckgo.com/"
        case .bing: base = "https://www.bing.com/search"
        }
        var components = URLComponents(string: base)
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        return components?.url
    }
}

/// How far the cursor moves for a given swipe.
struct CursorSpeed: Identifiable {
    let title: String
    let value: Double

    var id: Double { value }
}

/// User settings, kept in UserDefaults.
@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    static let zoomSteps = [75, 100, 125, 150, 175, 200, 250]
    static let cursorSpeeds = [
        CursorSpeed(title: "Slow", value: 0.6),
        CursorSpeed(title: "Normal", value: 1.0),
        CursorSpeed(title: "Fast", value: 1.5),
        CursorSpeed(title: "Very Fast", value: 2.2),
    ]

    @Published var siteMode: SiteMode { didSet { defaults.set(siteMode.rawValue, forKey: Key.siteMode) } }
    @Published var searchEngine: SearchEngine { didSet { defaults.set(searchEngine.rawValue, forKey: Key.searchEngine) } }
    @Published var zoomPercent: Int { didSet { defaults.set(zoomPercent, forKey: Key.zoom) } }
    @Published var cursorSpeed: Double { didSet { defaults.set(cursorSpeed, forKey: Key.cursorSpeed) } }
    @Published var blockPopups: Bool { didSet { defaults.set(blockPopups, forKey: Key.blockPopups) } }
    @Published var reopenLastPage: Bool { didSet { defaults.set(reopenLastPage, forKey: Key.reopenLastPage) } }

    /// The page to come back to at the next launch.
    var lastURL: String? {
        get { defaults.string(forKey: Key.lastURL) }
        set { defaults.set(newValue, forKey: Key.lastURL) }
    }

    /// Set while a restored page is loading, so a page that kills the app isn't reopened forever.
    var restoreInProgress: Bool {
        get { defaults.bool(forKey: Key.restoreInProgress) }
        set { defaults.set(newValue, forKey: Key.restoreInProgress) }
    }

    var hasSeenRemoteHint: Bool {
        get { defaults.bool(forKey: Key.remoteHint) }
        set { defaults.set(newValue, forKey: Key.remoteHint) }
    }

    private let defaults = UserDefaults.standard

    private enum Key {
        static let siteMode = "cwb.siteMode"
        static let searchEngine = "cwb.searchEngine"
        static let zoom = "cwb.zoom"
        static let cursorSpeed = "cwb.cursorSpeed"
        static let blockPopups = "cwb.blockPopups"
        static let reopenLastPage = "cwb.reopenLastPage"
        static let lastURL = "cwb.lastURL"
        static let restoreInProgress = "cwb.restoreInProgress"
        static let remoteHint = "cwb.remoteHint"
    }

    private init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            Key.zoom: 150,
            Key.cursorSpeed: 1.0,
            Key.blockPopups: true,
            Key.reopenLastPage: true,
        ])
        siteMode = SiteMode(rawValue: defaults.string(forKey: Key.siteMode) ?? "") ?? .desktop
        searchEngine = SearchEngine(rawValue: defaults.string(forKey: Key.searchEngine) ?? "") ?? .google
        let zoom = defaults.integer(forKey: Key.zoom)
        zoomPercent = Preferences.zoomSteps.contains(zoom) ? zoom : 150
        let speed = defaults.double(forKey: Key.cursorSpeed)
        cursorSpeed = speed > 0 ? speed : 1.0
        blockPopups = defaults.bool(forKey: Key.blockPopups)
        reopenLastPage = defaults.bool(forKey: Key.reopenLastPage)
    }

    /// Moves to the next larger or smaller zoom step. Returns false at either end.
    @discardableResult
    func stepZoom(by direction: Int) -> Bool {
        let steps = Preferences.zoomSteps
        let index = steps.firstIndex(of: zoomPercent) ?? 3
        let next = index + direction
        guard steps.indices.contains(next) else { return false }
        zoomPercent = steps[next]
        return true
    }
}
