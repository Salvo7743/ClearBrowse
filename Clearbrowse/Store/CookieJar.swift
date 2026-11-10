import Foundation

/// Keeps a copy of the web engine's cookies on disk.
///
/// tvOS apps get very little durable storage, and the engine's own cookie file doesn't reliably
/// survive the app being closed, so sign-ins would be lost. The copy lives in Caches (the one
/// place tvOS lets an app write files) and is put back into the engine at launch.
enum CookieJar {
    private static let limit = 3000

    private static var fileURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("clearbrowse-cookies.plist")
    }

    static func load() -> [HTTPCookie] {
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let list = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [[String: Any]]
        else { return [] }

        let now = Date()
        return list.compactMap { entry -> HTTPCookie? in
            var properties: [HTTPCookiePropertyKey: Any] = [:]
            for (key, value) in entry {
                properties[HTTPCookiePropertyKey(key)] = value
            }
            guard let cookie = HTTPCookie(properties: properties) else { return nil }
            if let expires = cookie.expiresDate, expires < now { return nil }
            return cookie
        }
    }

    static func save(_ cookies: [HTTPCookie]) {
        guard let fileURL else { return }
        let list: [[String: Any]] = cookies.prefix(limit).compactMap { cookie -> [String: Any]? in
            guard let properties = cookie.properties else { return nil }
            var entry: [String: Any] = [:]
            for (key, value) in properties where PropertyListSerialization.propertyList(value, isValidFor: .binary) {
                entry[key.rawValue] = value
            }
            return entry.isEmpty ? nil : entry
        }
        DispatchQueue.global(qos: .utility).async {
            guard let data = try? PropertyListSerialization.data(fromPropertyList: list, format: .binary, options: 0) else { return }
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    static func clear() {
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }
}
