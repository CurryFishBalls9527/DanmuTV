import BiliKit
import TVServices

/// Top Shelf, when DanmuTV sits in the top row of the Home screen: 继续观看 (shared by the app through the
/// App Group) and trending videos. Selecting opens the detail page; Play starts or resumes playback.
final class ContentProvider: TVTopShelfContentProvider {
    private static let cacheKey = "topshelf.lastItems"

    override func loadTopShelfContent() async -> TVTopShelfContent? {
        // Fall back to the last good list when the request fails (risk control, offline).
        var videos = (try? await API.popular(page: 1, anonymous: true).items) ?? []
        if videos.isEmpty {
            videos = Self.cached()
        } else {
            Self.cache(videos)
        }
        var sections: [TVTopShelfItemCollection<TVTopShelfSectionedItem>] = []
        let resume = ContinueWatchingShelf.load().compactMap(Self.item(for:))
        if !resume.isEmpty {
            let section = TVTopShelfItemCollection(items: resume)
            section.title = "继续观看"
            sections.append(section)
        }
        let items: [TVTopShelfSectionedItem] = videos.prefix(16).compactMap { video in
            guard !video.bvid.isEmpty,
                  let open = URL(string: "danmutv://video/\(video.bvid)"),
                  let play = URL(string: "danmutv://play/\(video.bvid)")
            else { return nil }
            let item = TVTopShelfSectionedItem(identifier: video.bvid)
            item.title = video.title
            item.imageShape = .hdtv
            if let url = Self.jpegURL(video.cover) { item.setImageURL(url, for: [.screenScale1x, .screenScale2x]) }
            item.displayAction = TVTopShelfAction(url: open)
            item.playAction = TVTopShelfAction(url: play)
            return item
        }
        if !items.isEmpty {
            let section = TVTopShelfItemCollection(items: items)
            section.title = "热门"
            sections.append(section)
        }
        return sections.isEmpty ? nil : TVTopShelfSectionedContent(sections: sections)
    }

    private static func item(for entry: ContinueWatchingShelf.Entry) -> TVTopShelfSectionedItem? {
        guard let open = entry.openURL, let play = entry.playURL else { return nil }
        let item = TVTopShelfSectionedItem(identifier: "resume-\(entry.epID > 0 ? "ep\(entry.epID)" : entry.bvid)")
        item.title = entry.subtitle.isEmpty ? entry.title : "\(entry.title) · \(entry.subtitle)"
        item.imageShape = .hdtv
        item.playbackProgress = entry.progress
        if let url = jpegURL(entry.cover) { item.setImageURL(url, for: [.screenScale1x, .screenScale2x]) }
        item.displayAction = TVTopShelfAction(url: open)
        item.playAction = TVTopShelfAction(url: play)
        return item
    }

    /// JPEG (not WebP) for the system shelf.
    private static func jpegURL(_ cover: String) -> URL? {
        let cover = BiliText.imageURL(cover)
        return URL(string: cover.contains("hdslb.com") ? "\(cover)@960w_540h_1c.jpg" : cover)
    }

    private static func cache(_ videos: [VideoItem]) {
        let rows = videos.prefix(16).map { ["bvid": $0.bvid, "title": $0.title, "cover": $0.cover] }
        UserDefaults.standard.set(rows, forKey: cacheKey)
    }

    private static func cached() -> [VideoItem] {
        (UserDefaults.standard.array(forKey: cacheKey) as? [[String: String]] ?? []).map {
            VideoItem(bvid: $0["bvid"] ?? "", title: $0["title"] ?? "", cover: $0["cover"] ?? "")
        }
    }
}
