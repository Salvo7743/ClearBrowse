import Combine
import Foundation

struct Bookmark: Codable, Identifiable, Hashable {
    var title: String
    var url: String

    var id: String { url }
    var host: String { URL(string: url)?.host?.replacingOccurrences(of: "www.", with: "") ?? url }
}

struct HistoryItem: Codable, Identifiable, Hashable {
    var title: String
    var url: String
    var date: Date

    var id: String { url }
    var host: String { URL(string: url)?.host?.replacingOccurrences(of: "www.", with: "") ?? url }
}

/// Bookmarks and browsing history. Both stay on the Apple TV.
@MainActor
final class Library: ObservableObject {
    static let shared = Library()

    @Published private(set) var bookmarks: [Bookmark] = []
    @Published private(set) var history: [HistoryItem] = []

    private let defaults = UserDefaults.standard
    private let bookmarksKey = "cwb.bookmarks"
    private let historyKey = "cwb.history"
    private let historyLimit = 150

    private static let starterBookmarks = [
        Bookmark(title: "Google", url: "https://www.google.com/"),
        Bookmark(title: "YouTube", url: "https://www.youtube.com/"),
        Bookmark(title: "Twitch", url: "https://www.twitch.tv/"),
        Bookmark(title: "Vimeo", url: "https://vimeo.com/watch"),
        Bookmark(title: "Dailymotion", url: "https://www.dailymotion.com/"),
        Bookmark(title: "Internet Archive", url: "https://archive.org/details/movies"),
        Bookmark(title: "Wikipedia", url: "https://www.wikipedia.org/"),
    ]

    private init() {
        if let data = defaults.data(forKey: bookmarksKey),
           let saved = try? JSONDecoder().decode([Bookmark].self, from: data) {
            bookmarks = saved
        } else {
            bookmarks = Library.starterBookmarks
        }
        if let data = defaults.data(forKey: historyKey),
           let saved = try? JSONDecoder().decode([HistoryItem].self, from: data) {
            history = saved
        }
    }

    // MARK: Bookmarks

    func isBookmarked(_ url: URL?) -> Bool {
        guard let key = url?.absoluteString else { return false }
        return bookmarks.contains { $0.url == key }
    }

    func toggleBookmark(title: String, url: URL) {
        let key = url.absoluteString
        if let index = bookmarks.firstIndex(where: { $0.url == key }) {
            bookmarks.remove(at: index)
        } else {
            let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
            bookmarks.insert(Bookmark(title: name.isEmpty ? (url.host ?? key) : name, url: key), at: 0)
        }
        saveBookmarks()
    }

    func removeBookmark(_ bookmark: Bookmark) {
        bookmarks.removeAll { $0.url == bookmark.url }
        saveBookmarks()
    }

    private func saveBookmarks() {
        if let data = try? JSONEncoder().encode(bookmarks) {
            defaults.set(data, forKey: bookmarksKey)
        }
    }

    // MARK: History

    func recordVisit(title: String?, url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
        let key = url.absoluteString
        let name = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        history.removeAll { $0.url == key }
        history.insert(HistoryItem(title: name.isEmpty ? (url.host ?? key) : name, url: key, date: Date()), at: 0)
        if history.count > historyLimit {
            history.removeLast(history.count - historyLimit)
        }
        saveHistory()
    }

    func removeHistory(_ item: HistoryItem) {
        history.removeAll { $0.url == item.url }
        saveHistory()
    }

    func clearHistory() {
        history.removeAll()
        saveHistory()
    }

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(history) {
            defaults.set(data, forKey: historyKey)
        }
    }
}
