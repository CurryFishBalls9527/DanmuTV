import Foundation

/// The Top Shelf's 继续观看 row: written by the app from the account's history, read by the Top Shelf
/// extension (which has no login of its own) through the shared App Group.
public enum ContinueWatchingShelf {
    /// `group.<bundle id>`, from the app's / extension's Info.plist (set by Config/Signing.xcconfig).
    public static let appGroup = Bundle.main.object(forInfoDictionaryKey: "DanmuTVAppGroup") as? String ?? "group.com.example.DanmuTV"
    static let key = "topshelf.continueWatching"

    public struct Entry: Codable, Equatable, Sendable {
        public var bvid: String
        public var epID: Int
        public var seasonID: Int
        public var title: String
        public var subtitle: String
        public var cover: String
        /// 0–1 watched.
        public var progress: Double

        public var isPGC: Bool { epID > 0 }
        /// Opens the detail page.
        public var openURL: URL? { URL(string: isPGC ? "danmutv://season/\(seasonID)" : "danmutv://video/\(bvid)") }
        /// Resumes playback where the account left off.
        public var playURL: URL? { URL(string: isPGC ? "danmutv://ep/\(epID)" : "danmutv://play/\(bvid)") }
    }

    public static var sharedDefaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    /// Unfinished videos and episodes, most recent first.
    public static func entries(from history: [HistoryEntry], limit: Int = 10) -> [Entry] {
        history.compactMap { h -> Entry? in
            let duration = h.item.duration
            guard h.progress > 0, duration <= 0 || h.progress < duration - 10 else { return nil }
            let pgc = h.business == "pgc" && h.item.epID > 0
            guard pgc ? h.seasonID > 0 : !h.item.bvid.isEmpty else { return nil }
            return Entry(bvid: h.item.bvid, epID: pgc ? h.item.epID : 0, seasonID: pgc ? h.seasonID : 0, title: h.item.title,
                         subtitle: h.subtitle, cover: h.item.cover,
                         progress: duration > 0 ? min(1, Double(h.progress) / Double(duration)) : 0)
        }
        .prefix(limit).map { $0 }
    }

    public static func save(_ entries: [Entry], to defaults: UserDefaults? = sharedDefaults) {
        guard let defaults else { return }
        if entries.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(try? JSONEncoder().encode(entries), forKey: key)
        }
    }

    public static func load(from defaults: UserDefaults? = sharedDefaults) -> [Entry] {
        guard let data = defaults?.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }
}
