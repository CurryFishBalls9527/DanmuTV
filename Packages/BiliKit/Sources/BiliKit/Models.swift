import Foundation

/// A video card, normalised from the many archive shapes Bilibili returns
/// (feed / popular / ranking / search / history / favourites…).
public struct VideoItem: Identifiable, Hashable, Sendable {
    public var aid: Int
    public var bvid: String
    public var cid: Int
    public var title: String
    public var cover: String
    public var duration: Int
    public var ownerMid: Int
    public var ownerName: String
    public var ownerFace: String
    public var views: Int
    public var danmaku: Int
    public var pubdate: Int
    /// Bangumi episode this archive redirects to (popular/ranking can contain PGC items).
    public var epID: Int
    public var badge: String
    /// Live room shown inside a video feed (推荐里的直播卡片).
    public var liveRoomID = 0

    public var id: String { liveRoomID > 0 ? "live\(liveRoomID)" : (bvid.isEmpty ? "av\(aid)" : bvid) }

    public init(aid: Int = 0, bvid: String = "", cid: Int = 0, title: String = "", cover: String = "", duration: Int = 0,
                ownerMid: Int = 0, ownerName: String = "", ownerFace: String = "", views: Int = 0, danmaku: Int = 0,
                pubdate: Int = 0, epID: Int = 0, badge: String = "")
    {
        self.aid = aid
        self.bvid = bvid
        self.cid = cid
        self.title = title
        self.cover = cover
        self.duration = duration
        self.ownerMid = ownerMid
        self.ownerName = ownerName
        self.ownerFace = ownerFace
        self.views = views
        self.danmaku = danmaku
        self.pubdate = pubdate
        self.epID = epID
        self.badge = badge
    }

    /// Parses any archive-like object. Field names differ per endpoint, so each is tried in turn.
    public init(archive j: JSON) {
        let owner = j["owner"].exists ? j["owner"] : j["upper"]
        let stat = j["stat"].exists ? j["stat"] : j["cnt_info"]
        self.init(
            aid: j["aid"].int ?? j["id"].intValue,
            bvid: j["bvid"].stringValue,
            cid: j["cid"].intValue,
            title: BiliText.plain(j["title"].stringValue),
            cover: BiliText.imageURL(j["pic"].string ?? j["cover"].stringValue),
            // Space uploads (`arc/search`) send `length` "mm:ss" instead of `duration`.
            duration: j["duration"].exists ? BiliText.duration(j["duration"]) : BiliText.duration(j["length"]),
            ownerMid: owner["mid"].int ?? j["mid"].intValue,
            ownerName: owner["name"].string ?? j["author"].stringValue,
            ownerFace: BiliText.imageURL(owner["face"].string ?? j["upic"].stringValue),
            views: stat["view"].int ?? stat["play"].int ?? j["play"].intValue,
            danmaku: stat["danmaku"].int ?? j["video_review"].intValue,
            pubdate: j["pubdate"].int ?? j["created"].int ?? j["ctime"].intValue,
            epID: BiliText.episodeID(fromURL: j["redirect_url"].stringValue),
            badge: j["badge"].string ?? j["rcmd_reason"]["content"].stringValue
        )
    }
}

public struct VideoPage: Identifiable, Hashable, Sendable {
    public var cid: Int
    public var page: Int
    public var part: String
    public var duration: Int
    public var id: Int { cid }

    public init(cid: Int, page: Int, part: String, duration: Int) {
        self.cid = cid
        self.page = page
        self.part = part
        self.duration = duration
    }
}

public struct VideoDetail: Sendable {
    public var item: VideoItem
    public var desc: String
    public var tname: String
    public var likes: Int
    public var coins: Int
    public var favorites: Int
    public var replies: Int
    public var shares: Int
    public var pages: [VideoPage]
    /// Bangumi episode when this archive is really a PGC episode.
    public var redirectEpID: Int
    /// 充电专属: playable only for paying supporters.
    public var isChargeOnly: Bool
    /// 1 原创 (up to 2 coins), 2 转载 (1 coin).
    public var copyright: Int
    /// Built from the `pagelist` fallback (no stats / description / owner) because `/view` was blocked.
    public var isPartial = false
    /// 合集 this video belongs to: title and all its videos in order.
    public var collection: (title: String, items: [VideoItem])?

    public init(_ j: JSON) {
        item = VideoItem(archive: j)
        desc = j["desc"].stringValue
        tname = j["tname"].stringValue
        likes = j["stat"]["like"].intValue
        coins = j["stat"]["coin"].intValue
        favorites = j["stat"]["favorite"].intValue
        replies = j["stat"]["reply"].intValue
        shares = j["stat"]["share"].intValue
        pages = j["pages"].array.map {
            VideoPage(cid: $0["cid"].intValue, page: $0["page"].intValue, part: $0["part"].stringValue, duration: $0["duration"].intValue)
        }
        redirectEpID = BiliText.episodeID(fromURL: j["redirect_url"].stringValue)
        isChargeOnly = j["is_upower_exclusive"].bool
        copyright = j["copyright"].int ?? 1
        let season = j["ugc_season"]
        if season.exists {
            let items = season["sections"].array.flatMap { $0["episodes"].array }.map { e -> VideoItem in
                var v = VideoItem(archive: e["arc"])
                v.aid = e["aid"].int ?? v.aid
                v.bvid = e["bvid"].string ?? v.bvid
                v.cid = e["cid"].int ?? v.cid
                v.title = e["title"].string ?? v.title
                return v
            }
            if !items.isEmpty { collection = (season["title"].stringValue, items) }
        }
    }
}

/// Progressive (single-file) stream for basic playback.
public struct ProgressiveStream: Sendable {
    public var url: URL
    public var quality: Int
    public var qualityName: String
    public var lastPlayTime: Double
    /// True when the server only grants a preview (e.g. unpaid 充电专属 or paid content).
    public var isPreview: Bool
}

public enum QRLoginState: Sendable {
    case waiting
    case scanned
    case expired
    case success(Account)
}

public enum BiliText {
    /// Upgrades protocol-relative / http image URLs to https.
    public static func imageURL(_ s: String) -> String {
        if s.hasPrefix("//") { return "https:" + s }
        if s.hasPrefix("http://") { return "https://" + s.dropFirst(7) }
        return s
    }

    /// Bilibili image CDN resize suffix, e.g. `@640w_360h_1c.webp`.
    public static func thumbnail(_ s: String, width: Int, height: Int) -> URL? {
        let base = imageURL(s)
        guard !base.isEmpty else { return nil }
        guard base.contains("hdslb.com") else { return URL(string: base) }
        return URL(string: "\(base)@\(width)w_\(height)h_1c.webp")
    }

    /// Strips search-highlight tags (`<em class="keyword">`) and decodes HTML entities in one pass
    /// (so `&amp;lt;` stays `&lt;`), including numeric `&#NN;` / `&#xHH;`.
    public static func plain(_ s: String) -> String {
        guard s.contains("<") || s.contains("&") else { return s }
        let stripped = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        guard stripped.contains("&") else { return stripped }
        let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " "]
        var out = ""
        var rest = stripped[...]
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            let after = rest[rest.index(after: amp)...]
            if let semi = after.prefix(10).firstIndex(of: ";") {
                let name = String(after[..<semi])
                var decoded: String?
                if let v = named[name] {
                    decoded = v
                } else if name.hasPrefix("#x") || name.hasPrefix("#X"), let code = UInt32(name.dropFirst(2), radix: 16) {
                    decoded = Unicode.Scalar(code).map(String.init)
                } else if name.hasPrefix("#"), let code = UInt32(name.dropFirst()) {
                    decoded = Unicode.Scalar(code).map(String.init)
                }
                if let decoded {
                    out += decoded
                    rest = after[after.index(after: semi)...]
                    continue
                }
            }
            out += "&"
            rest = after
        }
        return out + rest
    }

    /// Duration in seconds from either an integer or a "h:mm:ss" / "mm:ss" string.
    public static func duration(_ j: JSON) -> Int {
        if let s = j.raw as? String, s.contains(":") {
            return s.split(separator: ":").reduce(0) { $0 * 60 + (Int($1) ?? 0) }
        }
        return j.intValue
    }

    public static func episodeID(fromURL s: String) -> Int {
        guard let range = s.range(of: #"/ep(\d+)"#, options: .regularExpression) else { return 0 }
        return Int(s[range].dropFirst(3)) ?? 0
    }

    public static func formatDuration(_ seconds: Int) -> String {
        let h = seconds / 3600, m = seconds / 60 % 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    public static func formatCount(_ n: Int) -> String {
        if n >= 100_000_000 { return String(format: "%.1f亿", Double(n) / 100_000_000) }
        if n >= 10000 { return String(format: "%.1f万", Double(n) / 10000) }
        return String(n)
    }
}
