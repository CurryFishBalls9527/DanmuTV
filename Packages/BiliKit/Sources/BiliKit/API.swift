import Foundation

/// Bilibili endpoints. Shapes verified against live responses (2026-10); the API is
/// unofficial and changes, so parsing is deliberately lenient.
public enum API {
    static var client: BiliClient { .shared }

    // MARK: Account

    /// `/nav`: login state, profile and WBI keys. Returns `data` even when logged out.
    /// `as:` checks an account that isn't active yet (e.g. right after QR login).
    public static func nav(as account: Account? = nil) async throws -> JSON {
        do {
            return try await client.get("https://api.bilibili.com/x/web-interface/nav", as: account)["data"]
        } catch BiliError.api(-101, _) {
            return JSON(["isLogin": false])
        }
    }

    /// TV QR login, step 1. Returns the URL to encode in the QR code and the code to poll with.
    public static func tvQRCode() async throws -> (url: String, authCode: String) {
        let d = try await client.post("https://passport.bilibili.com/x/passport-tv-login/qrcode/auth_code", [:], sign: .app)["data"]
        return (d["url"].stringValue, d["auth_code"].stringValue)
    }

    /// TV QR login, step 2. Poll every ~2s until `.success` or `.expired`.
    public static func tvQRPoll(authCode: String) async throws -> QRLoginState {
        do {
            let d = try await client.post("https://passport.bilibili.com/x/passport-tv-login/qrcode/poll", ["auth_code": authCode], sign: .app)["data"]
            var cookies: [String: String] = [:]
            for c in d["cookie_info"]["cookies"].array {
                cookies[c["name"].stringValue] = c["value"].stringValue
            }
            let account = Account(
                mid: d["mid"].intValue,
                name: "",
                face: "",
                cookies: cookies,
                accessToken: d["access_token"].stringValue,
                refreshToken: d["refresh_token"].stringValue,
                expiresAt: Date().addingTimeInterval(TimeInterval(d["expires_in"].int ?? 30 * 86400))
            )
            return .success(account)
        } catch let BiliError.api(code, _) {
            switch code {
            case 86039: return .waiting // not scanned yet
            case 86090: return .scanned // scanned, waiting for confirmation
            case 86038: return .expired
            default: throw BiliError.api(code: code, message: "二维码状态异常")
            }
        }
    }

    /// Refreshes an app access token; returns the updated account.
    public static func refresh(_ account: Account) async throws -> Account {
        let d = try await client.post("https://passport.bilibili.com/api/v2/oauth2/refresh_token",
                                      ["access_key": account.accessToken, "refresh_token": account.refreshToken],
                                      sign: .app)["data"]
        var updated = account
        let token = d["token_info"]
        updated.accessToken = token["access_token"].string ?? updated.accessToken
        updated.refreshToken = token["refresh_token"].string ?? updated.refreshToken
        updated.expiresAt = Date().addingTimeInterval(TimeInterval(token["expires_in"].int ?? 30 * 86400))
        for c in d["cookie_info"]["cookies"].array {
            updated.cookies[c["name"].stringValue] = c["value"].stringValue
        }
        return updated
    }

    // MARK: Browse

    /// Personalised home feed. `freshIndex` increments per page.
    public static func recommend(freshIndex: Int) async throws -> [VideoItem] {
        let d = try await client.get("https://api.bilibili.com/x/web-interface/wbi/index/top/feed/rcmd",
                                     ["fresh_type": "4", "ps": "30", "fresh_idx": String(freshIndex), "fresh_idx_1h": String(freshIndex)],
                                     sign: .wbi)["data"]
        return d["item"].array.compactMap { j -> VideoItem? in
            switch j["goto"].stringValue {
            case "av":
                return VideoItem(archive: j)
            case "live":
                var v = VideoItem(archive: j)
                v.liveRoomID = j["room_info"]["room_id"].int ?? Int(URL(string: j["uri"].stringValue)?.lastPathComponent ?? "") ?? 0
                v.views = j["room_info"]["watched_show"]["num"].int ?? v.views
                v.duration = 0
                return v.liveRoomID > 0 ? v : nil
            default:
                return nil
            }
        }
    }

    /// 热门. `anonymous` drops login cookies so results aren't personalised.
    public static func popular(page: Int, anonymous: Bool = false) async throws -> (items: [VideoItem], noMore: Bool) {
        let d = try await client.get("https://api.bilibili.com/x/web-interface/popular",
                                     ["ps": "20", "pn": String(page)], anonymous: anonymous)["data"]
        return (d["list"].array.map(VideoItem.init(archive:)), d["no_more"].bool)
    }

    public struct RankingCategory: Identifiable, Hashable, Sendable {
        public let id: Int
        public let name: String
    }

    public static let rankingCategories: [RankingCategory] = [
        .init(id: 0, name: "全站"), .init(id: 1, name: "动画"), .init(id: 3, name: "音乐"),
        .init(id: 129, name: "舞蹈"), .init(id: 4, name: "游戏"), .init(id: 36, name: "知识"),
        .init(id: 188, name: "科技"), .init(id: 234, name: "运动"), .init(id: 223, name: "汽车"),
        .init(id: 160, name: "生活"), .init(id: 211, name: "美食"), .init(id: 217, name: "动物圈"),
        .init(id: 119, name: "鬼畜"), .init(id: 155, name: "时尚"), .init(id: 5, name: "娱乐"),
        .init(id: 181, name: "影视"),
    ]

    public static func ranking(categoryID: Int) async throws -> [VideoItem] {
        let d = try await client.get("https://api.bilibili.com/x/web-interface/ranking/v2",
                                     ["rid": String(categoryID), "type": "all"], sign: .wbi)["data"]
        return d["list"].array.map(VideoItem.init(archive:))
    }

    // MARK: Video

    public static func videoDetail(bvid: String) async throws -> VideoDetail {
        try await videoDetail(["bvid": bvid])
    }

    public static func videoDetail(aid: Int) async throws -> VideoDetail {
        try await videoDetail(["aid": String(aid)])
    }

    /// `/view` is aggressively rate-limited per IP (HTTP 412). When it is blocked, try the WBI twin, and
    /// if that is masked too (it answers a fake -404), fall back to `pagelist`, which is rarely limited:
    /// enough to play, without stats or description.
    private static func videoDetail(_ params: [String: String]) async throws -> VideoDetail {
        do {
            return VideoDetail(try await client.get("https://api.bilibili.com/x/web-interface/view", params)["data"])
        } catch BiliError.http(412) {
            Log.network.notice("/view blocked by risk control, using fallbacks")
        }
        if let detail = try? VideoDetail(await client.get("https://api.bilibili.com/x/web-interface/wbi/view", params, sign: .wbi)["data"]) {
            return detail
        }
        let pages = try await client.get("https://api.bilibili.com/x/player/pagelist", params)["data"]
        // Opened by aid (投屏): the bvid is needed later (playurl, history), and it's derived from the aid.
        let aid = params["aid"].flatMap(Int.init) ?? params["bvid"].flatMap(BVID.aid(from:)) ?? 0
        let bvid = params["bvid"] ?? (aid > 0 ? BVID.bvid(from: aid) : "")
        var detail = VideoDetail(JSON(["bvid": bvid, "aid": aid,
                                       "cid": pages[0]["cid"].intValue, "pages": pages.raw ?? []] as [String: Any]))
        detail.isPartial = true
        detail.item.duration = pages[0]["duration"].intValue
        if detail.item.title.isEmpty { detail.item.title = pages[0]["part"].stringValue }
        return detail
    }

    public static func related(bvid: String) async throws -> [VideoItem] {
        try await client.get("https://api.bilibili.com/x/web-interface/archive/related", ["bvid": bvid])["data"]
            .array.map(VideoItem.init(archive:))
    }

    /// DASH streams for a UGC video: every quality/codec the account may watch
    /// (fnval 4048 = DASH + HDR + 4K + Dolby audio + Dolby Vision + 8K + AV1).
    public static func playInfo(bvid: String, cid: Int) async throws -> PlayInfo {
        PlayInfo(try await client.get("https://api.bilibili.com/x/player/wbi/playurl",
                                      ["bvid": bvid, "cid": String(cid), "qn": "127", "fnval": "4048", "fnver": "0", "fourk": "1"],
                                      sign: .wbi)["data"])
    }

    /// Player info: video-level watch history (which page, when), subtitles, chapters and the danmaku mask.
    /// Unlike `playurl`, its `last_play_cid` names the page last watched even when asked about another page.
    public static func playerInfo(bvid: String, cid: Int) async throws -> JSON {
        try await client.get("https://api.bilibili.com/x/player/wbi/v2", ["bvid": bvid, "cid": String(cid)], sign: .wbi)["data"]
    }

    // MARK: Danmaku & subtitles

    /// One 6-minute protobuf danmaku segment (1-based). Falls back to the legacy XML list on failure.
    public static func danmakuSegment(cid: Int, segment: Int) async throws -> [Danmaku] {
        let query = Signing.wbiSigned(["type": "1", "oid": String(cid), "segment_index": String(segment)],
                                      mixinKey: try await client.wbiKeyForSigning())
        let url = URL(string: "https://api.bilibili.com/x/v2/dm/wbi/web/seg.so?" + query)!
        return try DanmakuParser.parseSegment(try await client.data(url))
    }

    /// Whole-video XML danmaku (capped by the server); the fallback when segments fail.
    public static func danmakuXML(cid: Int) async throws -> [Danmaku] {
        let data = try await client.data(URL(string: "https://api.bilibili.com/x/v1/dm/list.so?oid=\(cid)")!)
        // Served as raw deflate; URLSession usually inflates it, but not always.
        if data.first == UInt8(ascii: "<") { return DanmakuParser.parseXML(data) }
        guard let inflated = try? (data as NSData).decompressed(using: .zlib) as Data else { throw BiliError.invalidResponse }
        return DanmakuParser.parseXML(inflated)
    }

    /// The account's cloud danmaku block list (屏蔽词 synced from the account).
    public static func danmakuFilterRules() async throws -> [JSON] {
        try await client.get("https://api.bilibili.com/x/dm/filter/user")["data"]["rule"].array
    }

    public struct Subtitle: Identifiable, Hashable, Sendable {
        public var id: String { language }
        public var language: String
        public var name: String
        public var url: URL
        public var isAI: Bool
    }

    public static func subtitles(fromPlayerInfo info: JSON) -> [Subtitle] {
        info["subtitle"]["subtitles"].array.compactMap { s in
            guard let url = URL(string: BiliText.imageURL(s["subtitle_url"].stringValue)), url.host != nil else { return nil }
            let lan = s["lan"].stringValue
            return Subtitle(language: lan, name: s["lan_doc"].stringValue, url: url,
                            isAI: lan.hasPrefix("ai-") || s["ai_type"].intValue > 0 || s["type"].intValue == 1)
        }
    }

    public struct SubtitleLine: Equatable, Sendable {
        public var from: Double
        public var to: Double
        public var text: String
    }

    public static func subtitleLines(_ subtitle: Subtitle) async throws -> [SubtitleLine] {
        try JSON(data: try await client.data(subtitle.url))["body"].array.map {
            SubtitleLine(from: $0["from"].doubleValue, to: $0["to"].doubleValue, text: $0["content"].stringValue)
        }
    }

    /// UGC chapters (分段章节) from player info `view_points`.
    public static func chapters(fromPlayerInfo info: JSON) -> [(title: String, from: Double, to: Double)] {
        info["view_points"].array.compactMap { p in
            let to = p["to"].doubleValue
            guard to > p["from"].doubleValue else { return nil }
            return (p["content"].stringValue, p["from"].doubleValue, to)
        }
    }

    /// Reports watch progress to the account's history (继续播放 on every device reads this).
    /// `seconds` = -1 marks the video as finished.
    public static func reportProgress(aid: Int, cid: Int, seconds: Int) async throws {
        _ = try await client.post("https://api.bilibili.com/x/v2/history/report",
                                  ["aid": String(aid), "cid": String(cid), "progress": String(seconds), "platform": "android"],
                                  csrf: true)
    }

    /// Basic single-file MP4 stream (≤720p via the html5 platform, which also needs no Referer).
    /// The fallback when a video has no DASH streams (DASH→HLS covers 1080p+/HDR).
    public static func progressiveStream(bvid: String, cid: Int) async throws -> ProgressiveStream {
        let d = try await client.get("https://api.bilibili.com/x/player/wbi/playurl",
                                     ["bvid": bvid, "cid": String(cid), "qn": "80", "fnval": "1", "fnver": "0",
                                      "platform": "html5", "high_quality": "1"],
                                     sign: .wbi)["data"]
        guard let url = URL(string: d["durl"][0]["url"].stringValue) else { throw BiliError.invalidResponse }
        let quality = d["quality"].intValue
        let qualities = d["accept_quality"].array.map(\.intValue)
        let names = d["accept_description"].array.map(\.stringValue)
        let name = qualities.firstIndex(of: quality).flatMap { names.indices.contains($0) ? names[$0] : nil } ?? "\(quality)"
        return ProgressiveStream(url: url, quality: quality, qualityName: name,
                                 lastPlayTime: Double(d["last_play_time"].intValue) / 1000,
                                 isPreview: d["is_preview"].bool)
    }
}
