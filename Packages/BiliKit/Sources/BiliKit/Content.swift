import Foundation

// MARK: Bangumi / 影视 (PGC)

public enum SeasonType: Int, CaseIterable, Identifiable, Sendable {
    // Declaration order = display order.
    case anime = 1, guochuang = 4, movie = 2, tv = 5, documentary = 3

    public var id: Int { rawValue }
    public var title: String {
        switch self {
        case .anime: return "番剧"
        case .guochuang: return "国创"
        case .movie: return "电影"
        case .tv: return "电视剧"
        case .documentary: return "纪录片"
        }
    }

    /// Has a weekly release schedule (时间表).
    public var hasTimeline: Bool { self == .anime || self == .guochuang }
}

/// A season card in rankings, search, 追番 lists.
public struct SeasonItem: Identifiable, Hashable, Sendable {
    public var seasonID: Int
    public var title: String
    public var cover: String
    /// e.g. "更新至第12话" / "全24话".
    public var subtitle: String
    public var badge: String
    /// 16:9 artwork when the API has one (for banners).
    public var horizontalCover: String
    public var id: Int { seasonID }

    public init(seasonID: Int, title: String, cover: String, subtitle: String = "", badge: String = "", horizontalCover: String = "") {
        self.seasonID = seasonID
        self.title = title
        self.cover = cover
        self.subtitle = subtitle
        self.badge = badge
        self.horizontalCover = horizontalCover
    }

    init(_ j: JSON) {
        self.init(seasonID: j["season_id"].intValue,
                  title: BiliText.plain(j["title"].stringValue),
                  cover: BiliText.imageURL(j["cover"].string ?? j["ss_horizontal_cover"].stringValue),
                  subtitle: j["new_ep"]["index_show"].string ?? j["index_show"].string ?? j["progress"].stringValue,
                  badge: j["badge"].string ?? j["badge_info"]["text"].stringValue,
                  horizontalCover: BiliText.imageURL(j["ss_horizontal_cover"].stringValue))
    }
}

public struct SkipRange: Equatable, Hashable, Sendable {
    public enum Kind: Sendable { case opening, ending, sponsor }
    public var kind: Kind
    public var start: Double
    public var end: Double

    public init(kind: Kind, start: Double, end: Double) {
        self.kind = kind
        self.start = start
        self.end = end
    }

    /// From playurl `clip_info_list` (CLIP_TYPE_OP / CLIP_TYPE_ED) or episode `skip` {op, ed}.
    static func parse(clips: JSON, skip: JSON) -> [SkipRange] {
        var out: [SkipRange] = clips.array.compactMap { c in
            let type = c["clipType"].stringValue
            let kind: Kind? = type.hasSuffix("OP") ? .opening : type.hasSuffix("ED") ? .ending : nil
            guard let kind, c["end"].doubleValue > c["start"].doubleValue else { return nil }
            return SkipRange(kind: kind, start: c["start"].doubleValue, end: c["end"].doubleValue)
        }
        if out.isEmpty {
            for (key, kind) in [("op", Kind.opening), ("ed", Kind.ending)] {
                let r = skip[key]
                if r["end"].doubleValue > r["start"].doubleValue {
                    out.append(SkipRange(kind: kind, start: r["start"].doubleValue, end: r["end"].doubleValue))
                }
            }
        }
        return out
    }
}

public struct Episode: Identifiable, Hashable, Sendable {
    public var epID: Int
    public var aid: Int
    public var bvid: String
    public var cid: Int
    /// Short title like "1" or "SP".
    public var index: String
    public var longTitle: String
    public var cover: String
    public var badge: String
    /// Requires 大会员 (status 13 / "会员" badge).
    public var isVIP: Bool
    public var duration: Double
    public var skips: [SkipRange]
    public var id: Int { epID }

    public var displayTitle: String {
        let head = Int(index) != nil ? "第\(index)话" : index
        return longTitle.isEmpty ? head : "\(head) \(longTitle)"
    }

    init(_ j: JSON) {
        epID = j["id"].int ?? j["ep_id"].intValue
        aid = j["aid"].intValue
        bvid = j["bvid"].stringValue
        cid = j["cid"].intValue
        index = j["title"].stringValue
        longTitle = j["long_title"].stringValue
        cover = BiliText.imageURL(j["cover"].stringValue)
        badge = j["badge"].string.flatMap { $0.isEmpty ? nil : $0 } ?? j["badge_info"]["text"].stringValue
        isVIP = j["status"].intValue == 13 || badge.contains("会员")
        duration = j["duration"].doubleValue / 1000
        skips = SkipRange.parse(clips: JSON(nil), skip: j["skip"])
    }

    /// Trailers/PVs mixed into a season (去除番剧里夹带的预告).
    public var isTrailer: Bool {
        badge.contains("预告") || index.contains("预告") || longTitle.hasPrefix("预告") || index.uppercased().hasPrefix("PV")
    }
}

public struct Season: Sendable {
    public var seasonID: Int
    public var title: String
    public var cover: String
    public var evaluate: String
    public var rating: Double
    public var subtitle: String
    public var episodes: [Episode]
    /// Extra sections (SP, PV…), trailers removed.
    public var extras: [(title: String, episodes: [Episode])]
    public var isFollowing: Bool
    public var lastEpisodeID: Int
    public var lastTime: Double
    public var areas: [String]
    /// 港澳台-only seasons (watchable only with an appropriate network; marked, never bypassed).
    public var isOversea: Bool
    /// 1 番剧, 2 电影, 3 纪录片, 4 国创, 5 电视剧 (PGC sub_type for progress reports).
    public var type: Int
    /// e.g. "2026年10月17日开播" for seasons without episodes yet.
    public var publishText: String

    public init(_ r: JSON) {
        seasonID = r["season_id"].intValue
        title = r["title"].stringValue
        cover = BiliText.imageURL(r["cover"].stringValue)
        evaluate = r["evaluate"].stringValue
        rating = r["rating"]["score"].doubleValue
        subtitle = r["new_ep"]["desc"].string ?? r["subtitle"].stringValue
        episodes = r["episodes"].array.map(Episode.init).filter { !$0.isTrailer }
        extras = r["section"].array.compactMap { s in
            let eps = s["episodes"].array.map(Episode.init).filter { !$0.isTrailer }
            return eps.isEmpty ? nil : (s["title"].stringValue, eps)
        }
        isFollowing = r["user_status"]["follow"].bool
        lastEpisodeID = r["user_status"]["progress"]["last_ep_id"].intValue
        lastTime = r["user_status"]["progress"]["last_time"].doubleValue
        areas = r["areas"].array.map { $0["name"].stringValue }
        let t = r["title"].stringValue
        isOversea = t.contains("僅限") || t.contains("仅限港澳台") || t.contains("港澳台")
        type = r["type"].int ?? 1
        publishText = r["publish"]["pub_time_show"].string ?? r["publish"]["release_date_show"].stringValue
    }
}

// MARK: People, folders, history

public struct UserItem: Identifiable, Hashable, Sendable {
    public var mid: Int
    public var name: String
    public var face: String
    public var sign: String
    public var fans: Int
    public var isFollowing: Bool
    public var id: Int { mid }

    public init(mid: Int, name: String, face: String, sign: String = "", fans: Int = 0, isFollowing: Bool = false) {
        self.mid = mid
        self.name = name
        self.face = face
        self.sign = sign
        self.fans = fans
        self.isFollowing = isFollowing
    }
}

public struct FavFolder: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case created
        /// Someone else's favourites folder the account subscribed to.
        case collected
        /// A subscribed UGC collection (合集).
        case season
    }

    public var id: Int
    public var title: String
    public var count: Int
    public var cover: String
    public var kind: Kind
    /// Whether the video being favourited is already in it (when listed for a video).
    public var containsVideo: Bool
}

public struct HistoryEntry: Identifiable, Hashable, Sendable {
    public var item: VideoItem
    /// Seconds watched; -1 = finished.
    public var progress: Int
    public var viewAt: Int
    public var business: String
    public var seasonID: Int
    public var subtitle: String
    /// Bilibili `dt`: where it was watched (1/3/4/5/6/7 phones and tablets, 2 web, 33 TV).
    public var device = 0
    public var id: String { "\(business)-\(item.id)-\(item.epID)" }
}

/// A 稍后再看 entry with when it was added.
public struct WatchLaterEntry: Hashable, Sendable {
    public var item: VideoItem
    /// Unix seconds.
    public var addedAt: Int

    public init(item: VideoItem, addedAt: Int) {
        self.item = item
        self.addedAt = addedAt
    }
}

/// Like / coin / favourite / follow state of a video for the account.
public struct Relation: Equatable, Sendable {
    public var liked: Bool
    public var coins: Int
    public var favorited: Bool
    public var followingOwner: Bool

    public init(liked: Bool = false, coins: Int = 0, favorited: Bool = false, followingOwner: Bool = false) {
        self.liked = liked
        self.coins = coins
        self.favorited = favorited
        self.followingOwner = followingOwner
    }
}

// MARK: Endpoints

extension API {
    // PGC

    public static func season(seasonID: Int? = nil, epID: Int? = nil) async throws -> Season {
        var p: [String: String] = [:]
        if let seasonID { p["season_id"] = String(seasonID) }
        if let epID { p["ep_id"] = String(epID) }
        return Season(try await client.get("https://api.bilibili.com/pgc/view/web/season", p)["result"])
    }

    /// PGC playurl: DASH like UGC plus OP/ED clips. Region-locked titles fail with -10403.
    public static func pgcPlayInfo(epID: Int, cid: Int) async throws -> PlayInfo {
        PlayInfo(try await client.get("https://api.bilibili.com/pgc/player/web/playurl",
                                      ["ep_id": String(epID), "cid": String(cid), "qn": "127", "fnval": "4048", "fnver": "0", "fourk": "1"])["result"])
    }

    public static func pgcRank(_ type: SeasonType) async throws -> [SeasonItem] {
        try await client.get("https://api.bilibili.com/pgc/web/rank/list", ["day": "3", "season_type": String(type.rawValue)])["result"]["list"]
            .array.map(SeasonItem.init)
    }

    public struct TimelineDay: Identifiable, Sendable {
        public var date: String
        public var weekday: Int
        public var isToday: Bool
        public var items: [(season: SeasonItem, time: String, episode: String, published: Bool)]
        public var id: String { date }
    }

    /// 时间表: releases around today. Unreleased episodes are marked (`published == false`).
    public static func timeline(_ type: SeasonType) async throws -> [TimelineDay] {
        try await client.get("https://api.bilibili.com/pgc/web/timeline", ["types": String(type.rawValue), "before": "3", "after": "3"])["result"]
            .array.map { d in
                TimelineDay(date: d["date"].stringValue, weekday: d["day_of_week"].intValue, isToday: d["is_today"].bool,
                            items: d["episodes"].array.map { e in
                                (SeasonItem(seasonID: e["season_id"].intValue, title: e["title"].stringValue,
                                            cover: BiliText.imageURL(e["cover"].stringValue)),
                                 e["pub_time"].stringValue, e["pub_index"].stringValue, e["published"].bool)
                            })
            }
    }

    /// 我的追番 (type 1) / 追剧 (type 2).
    public static func followedSeasons(mid: Int, type: Int, page: Int) async throws -> (items: [SeasonItem], hasMore: Bool) {
        let d = try await client.get("https://api.bilibili.com/x/space/bangumi/follow/list",
                                     ["type": String(type), "vmid": String(mid), "pn": String(page), "ps": "30"])["data"]
        let items = d["list"].array.map(SeasonItem.init)
        return (items, page * 30 < d["total"].intValue)
    }

    public static func setSeasonFollow(_ seasonID: Int, following: Bool) async throws {
        _ = try await client.post("https://api.bilibili.com/pgc/web/follow/\(following ? "add" : "del")",
                                  ["season_id": String(seasonID)], csrf: true)
    }

    // Search

    public static func hotSearch() async throws -> [String] {
        try await client.get("https://api.bilibili.com/x/web-interface/wbi/search/square", ["limit": "10"], sign: .wbi)["data"]["trending"]["list"]
            .array.map { $0["keyword"].stringValue }.filter { !$0.isEmpty }
    }

    public enum SearchKind: String, CaseIterable, Identifiable, Sendable {
        case video, bangumi = "media_bangumi", movie = "media_ft", user = "bili_user", live = "live_room"
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .video: return "视频"
            case .bangumi: return "番剧"
            case .movie: return "影视"
            case .user: return "UP 主"
            case .live: return "直播"
            }
        }
    }

    /// Video results (also works logged out, unlike the typed endpoint).
    public static func searchVideos(_ keyword: String, page: Int) async throws -> (items: [VideoItem], hasMore: Bool) {
        let d = try await client.get("https://api.bilibili.com/x/web-interface/wbi/search/all/v2", ["keyword": keyword, "page": String(page)], sign: .wbi)["data"]
        let videos = d["result"].array.first { $0["result_type"].stringValue == "video" }?["data"].array ?? []
        return (videos.map(VideoItem.init(archive:)), page < d["numPages"].intValue)
    }

    /// Typed search: raw result objects, mapped by the caller per kind.
    public static func search(_ keyword: String, kind: SearchKind, page: Int) async throws -> (results: [JSON], hasMore: Bool) {
        let d = try await client.get("https://api.bilibili.com/x/web-interface/wbi/search/type",
                                     ["keyword": keyword, "search_type": kind.rawValue, "page": String(page)], sign: .wbi)["data"]
        if d["v_voucher"].exists, !d["result"].exists { throw BiliError.api(code: -352, message: "") }
        // live_room nests its rooms under result.live_room.
        let results = d["result"]["live_room"].exists ? d["result"]["live_room"].array : d["result"].array
        return (results, page < d["numPages"].intValue)
    }

    public static func seasonItem(fromSearch j: JSON) -> SeasonItem {
        SeasonItem(seasonID: j["season_id"].intValue, title: BiliText.plain(j["title"].stringValue),
                   cover: BiliText.imageURL(j["cover"].stringValue), subtitle: j["index_show"].stringValue)
    }

    public static func userItem(fromSearch j: JSON) -> UserItem {
        UserItem(mid: j["mid"].intValue, name: j["uname"].stringValue, face: BiliText.imageURL(j["upic"].stringValue),
                 sign: j["usign"].stringValue, fans: j["fans"].intValue)
    }

    // Feed / history / lists

    /// 动态: videos from followed uploaders. Pass the returned offset for the next page.
    public static func dynamicVideos(offset: String) async throws -> (items: [VideoItem], offset: String, hasMore: Bool) {
        let d = try await client.get("https://api.bilibili.com/x/polymer/web-dynamic/v1/feed/all",
                                     ["type": "video", "offset": offset, "timezone_offset": "-480", "features": "itemOpusStyle"])["data"]
        let items: [VideoItem] = d["items"].array.compactMap { item in
            let modules = item["modules"]
            let archive = modules["module_dynamic"]["major"]["archive"]
            guard archive.exists else { return nil }
            var v = VideoItem(archive: archive)
            let author = modules["module_author"]
            v.ownerMid = author["mid"].intValue
            v.ownerName = author["name"].stringValue
            v.ownerFace = BiliText.imageURL(author["face"].stringValue)
            v.pubdate = author["pub_ts"].intValue
            v.duration = BiliText.duration(archive["duration_text"])
            v.views = BiliText.count(archive["stat"]["play"].stringValue)
            v.badge = ""
            return v
        }
        return (items, d["offset"].stringValue, d["has_more"].bool)
    }

    public struct HistoryCursor: Sendable {
        public var max = 0
        public var viewAt = 0
        public var business = ""
        public init() {}
    }

    public static func history(after cursor: HistoryCursor) async throws -> (items: [HistoryEntry], next: HistoryCursor, hasMore: Bool) {
        let d = try await client.get("https://api.bilibili.com/x/web-interface/history/cursor",
                                     ["max": String(cursor.max), "view_at": String(cursor.viewAt), "business": cursor.business, "ps": "30"])["data"]
        let items: [HistoryEntry] = d["list"].array.compactMap { j in
            let h = j["history"]
            let business = h["business"].stringValue
            guard business == "archive" || business == "pgc" else { return nil }
            let item = VideoItem(aid: h["oid"].intValue, bvid: h["bvid"].stringValue, cid: h["cid"].intValue,
                                 title: j["title"].stringValue, cover: BiliText.imageURL(j["cover"].string ?? j["covers"][0].stringValue),
                                 duration: j["duration"].intValue, ownerMid: j["author_mid"].intValue, ownerName: j["author_name"].stringValue,
                                 ownerFace: BiliText.imageURL(j["author_face"].stringValue), epID: h["epid"].intValue, badge: j["badge"].stringValue)
            return HistoryEntry(item: item, progress: j["progress"].intValue, viewAt: j["view_at"].intValue, business: business,
                                seasonID: j["kid"].intValue, subtitle: j["show_title"].stringValue, device: h["dt"].intValue)
        }
        var next = HistoryCursor()
        next.max = d["cursor"]["max"].intValue
        next.viewAt = d["cursor"]["view_at"].intValue
        next.business = d["cursor"]["business"].stringValue
        // Paging follows the raw list: a page of only live/article entries (filtered out) isn't the end.
        return (items, next, !d["list"].array.isEmpty && next.max != 0)
    }

    public static func watchLater() async throws -> [VideoItem] {
        try await watchLaterEntries().map(\.item)
    }

    public static func watchLaterEntries() async throws -> [WatchLaterEntry] {
        try await client.get("https://api.bilibili.com/x/v2/history/toview")["data"]["list"].array.map {
            WatchLaterEntry(item: VideoItem(archive: $0), addedAt: $0["add_at"].intValue)
        }
    }

    /// 不感兴趣 on a home-feed card (web feed feedback). Best effort: the card is hidden either way.
    public static func dislikeRecommendation(aid: Int, ownerMid: Int) async throws {
        _ = try await client.post("https://api.bilibili.com/x/web-interface/feedback/dislike",
                                  ["app_id": "100", "feedback_page": "1", "goto": "av", "id": String(aid), "mid": String(ownerMid),
                                   "reason_id": "1"], csrf: true)
    }

    public static func setWatchLater(aid: Int, added: Bool) async throws {
        _ = try await client.post("https://api.bilibili.com/x/v2/history/toview/\(added ? "add" : "del")", ["aid": String(aid)], csrf: true)
    }

    /// The account's folders; with `aid`, each says whether that video is in it.
    public static func favFolders(mid: Int, aid: Int? = nil) async throws -> [FavFolder] {
        var p = ["up_mid": String(mid)]
        if let aid { p["rid"] = String(aid); p["type"] = "2" }
        return try await client.get("https://api.bilibili.com/x/v3/fav/folder/created/list-all", p)["data"]["list"].array.map {
            FavFolder(id: $0["id"].intValue, title: $0["title"].stringValue, count: $0["media_count"].intValue,
                      cover: BiliText.imageURL($0["cover"].stringValue), kind: .created, containsVideo: $0["fav_state"].intValue == 1)
        }
    }

    /// Subscribed folders and collections (订阅的收藏).
    public static func collectedFolders(mid: Int, page: Int) async throws -> (items: [FavFolder], hasMore: Bool) {
        let d = try await client.get("https://api.bilibili.com/x/v3/fav/folder/collected/list",
                                     ["up_mid": String(mid), "pn": String(page), "ps": "20", "platform": "web"])["data"]
        let items = d["list"].array.map {
            FavFolder(id: $0["id"].intValue, title: $0["title"].stringValue, count: $0["media_count"].intValue,
                      cover: BiliText.imageURL($0["cover"].stringValue), kind: $0["type"].intValue == 21 ? .season : .collected,
                      containsVideo: false)
        }
        return (items, d["has_more"].bool)
    }

    public static func folderContents(_ folder: FavFolder, page: Int) async throws -> (items: [VideoItem], hasMore: Bool) {
        if folder.kind == .season {
            let d = try await client.get("https://api.bilibili.com/x/space/fav/season/list",
                                         ["season_id": String(folder.id), "pn": String(page), "ps": "20"])["data"]
            let items = d["medias"].array.map(VideoItem.init(archive:))
            return (items, page * 20 < d["info"]["media_count"].intValue)
        }
        let d = try await client.get("https://api.bilibili.com/x/v3/fav/resource/list",
                                     ["media_id": String(folder.id), "pn": String(page), "ps": "20", "platform": "web"])["data"]
        // type 2 = video; 24 = PGC episode (linked via ogv).
        let items = d["medias"].array.filter { [2, 24].contains($0["type"].intValue) }.map { j -> VideoItem in
            var v = VideoItem(archive: j)
            if j["type"].intValue == 24 { v.epID = BiliText.episodeID(fromURL: j["link"].stringValue) }
            return v
        }
        return (items, d["has_more"].bool)
    }

    public static func followings(mid: Int, page: Int) async throws -> (items: [UserItem], hasMore: Bool) {
        let d = try await client.get("https://api.bilibili.com/x/relation/followings",
                                     ["vmid": String(mid), "pn": String(page), "ps": "50", "order": "desc"])["data"]
        let items = d["list"].array.map {
            UserItem(mid: $0["mid"].intValue, name: $0["uname"].stringValue, face: BiliText.imageURL($0["face"].stringValue),
                     sign: $0["sign"].stringValue, isFollowing: true)
        }
        return (items, page * 50 < d["total"].intValue)
    }

    // Uploader

    public static func userCard(mid: Int) async throws -> UserItem {
        let d = try await client.get("https://api.bilibili.com/x/web-interface/card", ["mid": String(mid)])["data"]
        let c = d["card"]
        return UserItem(mid: mid, name: c["name"].stringValue, face: BiliText.imageURL(c["face"].stringValue),
                        sign: c["sign"].stringValue, fans: d["follower"].int ?? c["fans"].intValue, isFollowing: d["following"].bool)
    }

    public enum UserVideoOrder: String, CaseIterable, Identifiable, Sendable {
        case latest = "pubdate", mostViewed = "click"
        public var id: String { rawValue }
        public var title: String { self == .latest ? "最新发布" : "最多播放" }
    }

    /// 投稿 list. `dm_img_*` are the browser fingerprint fields the space API wants to avoid -352.
    public static func userVideos(mid: Int, order: UserVideoOrder, page: Int) async throws -> (items: [VideoItem], hasMore: Bool) {
        let d = try await client.get("https://api.bilibili.com/x/space/wbi/arc/search",
                                     ["mid": String(mid), "order": order.rawValue, "pn": String(page), "ps": "30",
                                      "dm_img_list": "[]", "dm_img_str": "V2ViR0wgMS4wIChPcGVuR0wgRVMgMi4wIENocm9taXVtKQ",
                                      "dm_cover_img_str": "QU5HTEUgKEludGVsLCBJbnRlbChSKSBVSEQgR3JhcGhpY3MgNjIwIERpcmVjdDNEMTEgdnNfNV8wIHBzXzVfMCwgRDNEMTEp"],
                                     sign: .wbi)["data"]
        let items = d["list"]["vlist"].array.map(VideoItem.init(archive:))
        return (items, page * 30 < d["page"]["count"].intValue)
    }

    public static func setFollow(mid: Int, following: Bool) async throws {
        _ = try await client.post("https://api.bilibili.com/x/relation/modify",
                                  ["fid": String(mid), "act": following ? "1" : "2", "re_src": "11"], csrf: true)
    }

    // Video interactions

    public static func relation(aid: Int, bvid: String) async throws -> Relation {
        let d = try await client.get("https://api.bilibili.com/x/web-interface/archive/relation", ["aid": String(aid), "bvid": bvid])["data"]
        return Relation(liked: d["like"].bool, coins: d["coin"].intValue, favorited: d["favorite"].bool, followingOwner: d["attention"].bool)
    }

    public static func like(aid: Int, _ liked: Bool) async throws {
        _ = try await client.post("https://api.bilibili.com/x/web-interface/archive/like", ["aid": String(aid), "like": liked ? "1" : "2"], csrf: true)
    }

    public static func coin(aid: Int, count: Int, alsoLike: Bool) async throws {
        _ = try await client.post("https://api.bilibili.com/x/web-interface/coin/add",
                                  ["aid": String(aid), "multiply": String(count), "select_like": alsoLike ? "1" : "0"], csrf: true)
    }

    public static func setFavorite(aid: Int, add: [Int], remove: [Int]) async throws {
        _ = try await client.post("https://api.bilibili.com/x/v3/fav/resource/deal",
                                  ["rid": String(aid), "type": "2",
                                   "add_media_ids": add.map(String.init).joined(separator: ","),
                                   "del_media_ids": remove.map(String.init).joined(separator: ",")], csrf: true)
    }

    public static func tags(bvid: String) async throws -> [String] {
        try await client.get("https://api.bilibili.com/x/tag/archive/tags", ["bvid": bvid])["data"].array.map { $0["tag_name"].stringValue }
    }

    /// PGC progress goes through the web player heartbeat, which records episode + season
    /// (`user_status.progress` on the season page reads this).
    public static func reportPGCProgress(aid: Int, cid: Int, epID: Int, seasonID: Int, seasonType: Int, seconds: Int) async throws {
        let mid = client.currentAccount?.mid ?? 0
        _ = try await client.post("https://api.bilibili.com/x/click-interface/web/heartbeat",
                                  ["aid": String(aid), "cid": String(cid), "epid": String(epID), "sid": String(seasonID),
                                   "mid": String(mid), "played_time": String(seconds), "real_played_time": String(seconds),
                                   "type": "4", "sub_type": String(seasonType), "dt": "2", "play_type": "0"], csrf: true)
    }

    /// Whether the video is in 稍后再看.
    public static func isInWatchLater(aid: Int) async throws -> Bool {
        try await client.get("https://api.bilibili.com/x/v2/history/toview")["data"]["list"].array.contains { $0["aid"].intValue == aid }
    }

    /// Clean share link (no tracking parameters).
    public static func shareURL(bvid: String? = nil, epID: Int? = nil) -> String {
        if let epID, epID > 0 { return "https://www.bilibili.com/bangumi/play/ep\(epID)" }
        return "https://www.bilibili.com/video/\(bvid ?? "")"
    }
}

extension BiliText {
    /// "1.2万" / "3.4亿" / "1234" → number.
    public static func count(_ s: String) -> Int {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.hasSuffix("亿"), let v = Double(t.dropLast()) { return Int(v * 100_000_000) }
        if t.hasSuffix("万"), let v = Double(t.dropLast()) { return Int(v * 10000) }
        return Int(t) ?? 0
    }
}
