import Foundation

/// A comment (评论) or a reply to one.
public struct Comment: Identifiable, Hashable, Sendable {
    /// rpid.
    public var id: Int
    public var mid: Int
    public var name: String
    public var face: String
    /// 0–6 (硬核 6 shows as 6).
    public var level: Int
    public var isVIP: Bool
    public var message: String
    public var likes: Int
    /// Replies under it (0 for replies themselves).
    public var replyCount: Int
    /// Unix seconds.
    public var time: Int
    /// Bilibili's own phrasing, e.g. "3天前发布" (empty when absent).
    public var timeText: String
    /// e.g. "IP属地：上海" (empty when absent).
    public var location: String
    /// UP 主置顶.
    public var isPinned: Bool
    /// The uploader liked it (UP主觉得很赞).
    public var upLiked: Bool
    /// The account liked it.
    public var liked: Bool
    /// The first few replies, as shown under the comment.
    public var previewReplies: [Comment]
    /// Attached pictures (not shown on TV; a picture-only comment says so).
    public var pictureCount: Int

    public init(id: Int, mid: Int = 0, name: String, face: String = "", level: Int = 0, isVIP: Bool = false, message: String,
                likes: Int = 0, replyCount: Int = 0, time: Int = 0, timeText: String = "", location: String = "",
                isPinned: Bool = false, upLiked: Bool = false, liked: Bool = false, previewReplies: [Comment] = [],
                pictureCount: Int = 0)
    {
        self.id = id
        self.mid = mid
        self.name = name
        self.face = face
        self.level = level
        self.isVIP = isVIP
        self.message = message
        self.likes = likes
        self.replyCount = replyCount
        self.time = time
        self.timeText = timeText
        self.location = location
        self.isPinned = isPinned
        self.upLiked = upLiked
        self.liked = liked
        self.previewReplies = previewReplies
        self.pictureCount = pictureCount
    }

    /// The text to show: the message, or a note for picture-only comments.
    public var displayText: String {
        if message.isEmpty { return pictureCount > 0 ? "[图片 ×\(pictureCount)]" : "" }
        return pictureCount > 0 ? message + "  [图片]" : message
    }

    init(_ j: JSON, pinned: Bool = false) {
        let member = j["member"]
        let control = j["reply_control"]
        self.init(id: j["rpid"].intValue,
                  mid: j["mid"].intValue,
                  name: member["uname"].stringValue,
                  face: member["avatar"].stringValue,
                  level: member["level_info"]["current_level"].intValue,
                  isVIP: member["vip"]["vipStatus"].intValue == 1,
                  message: Comment.cleaned(j["content"]["message"].stringValue),
                  likes: j["like"].intValue,
                  replyCount: j["rcount"].intValue,
                  time: j["ctime"].intValue,
                  timeText: control["time_desc"].stringValue,
                  location: control["location"].stringValue,
                  isPinned: pinned,
                  upLiked: j["up_action"]["like"].bool,
                  liked: j["action"].intValue == 1,
                  previewReplies: j["replies"].array.map { Comment($0) },
                  pictureCount: j["content"]["pictures"].array.count)
    }

    /// Trims the whitespace runs people paste in, keeping paragraph breaks.
    static func cleaned(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "[ \t]+\n", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// One page of comments.
public struct CommentPage: Sendable {
    public var comments: [Comment]
    /// All comments, replies included (as Bilibili counts them).
    public var total: Int
    public var hasMore: Bool
}

extension API {
    /// 热门评论 of a video or episode (`aid`), as the web's 热门 sort, 20 at a time. `offset` is the previous page's
    /// `nextOffset` ("" for the first page, where the uploader's pinned comment leads). Signed (wbi): unsigned
    /// requests get -352 after a page or two. If the signed endpoint fails on the first page, the legacy one
    /// (most liked, only 3 when logged out) stands in.
    public static func comments(aid: Int, offset: String = "") async throws -> (page: CommentPage, nextOffset: String?) {
        let pagination = (try? JSONSerialization.data(withJSONObject: ["offset": offset])).flatMap { String(data: $0, encoding: .utf8) } ?? "{\"offset\":\"\"}"
        do {
            let d = try await client.get("https://api.bilibili.com/x/v2/reply/wbi/main",
                                         ["oid": String(aid), "type": "1", "mode": "3", "pagination_str": pagination,
                                          "plat": "1", "web_location": "1315875"], sign: .wbi)["data"]
            return mainPage(d, first: offset.isEmpty)
        } catch where offset.isEmpty && !BiliClient.isCancellation(error) {
            let d = try await client.get("https://api.bilibili.com/x/v2/reply",
                                         ["type": "1", "oid": String(aid), "sort": "1", "ps": "20", "pn": "1"])["data"]
            return (legacyPage(d), nil)
        }
    }

    static func mainPage(_ d: JSON, first: Bool) -> (page: CommentPage, nextOffset: String?) {
        var comments = d["replies"].array.map { Comment($0) }
        if first, d["top"]["upper"].exists {
            let pinned = Comment(d["top"]["upper"], pinned: true)
            comments.removeAll { $0.id == pinned.id }
            comments.insert(pinned, at: 0)
        }
        let cursor = d["cursor"]
        let next = cursor["pagination_reply"]["next_offset"].stringValue
        let more = !cursor["is_end"].bool && !next.isEmpty && !d["replies"].array.isEmpty
        return (CommentPage(comments: comments, total: cursor["all_count"].intValue, hasMore: more), more ? next : nil)
    }

    /// The legacy endpoint's first page (no further pages are fetched from it).
    static func legacyPage(_ d: JSON) -> CommentPage {
        var comments = d["replies"].array.map { Comment($0) }
        if d["upper"]["top"].exists {
            let pinned = Comment(d["upper"]["top"], pinned: true)
            comments.removeAll { $0.id == pinned.id }
            comments.insert(pinned, at: 0)
        }
        return CommentPage(comments: comments, total: d["page"]["acount"].int ?? d["page"]["count"].intValue, hasMore: false)
    }

    /// Replies to the comment `root`, oldest first.
    public static func commentReplies(aid: Int, root: Int, page: Int, pageSize: Int = 20) async throws -> CommentPage {
        let d = try await client.get("https://api.bilibili.com/x/v2/reply/reply",
                                     ["type": "1", "oid": String(aid), "root": String(root), "ps": String(pageSize), "pn": String(page)])["data"]
        return replyPage(d, page: page, pageSize: pageSize)
    }

    static func replyPage(_ d: JSON, page: Int, pageSize: Int) -> CommentPage {
        let replies = d["replies"].array.map { Comment($0) }
        let count = d["page"]["count"].intValue
        return CommentPage(comments: replies, total: count, hasMore: replies.count >= pageSize && page * pageSize < count)
    }

    /// 点赞 / 取消点赞 a comment.
    public static func likeComment(aid: Int, rpid: Int, like: Bool) async throws {
        _ = try await client.post("https://api.bilibili.com/x/v2/reply/action",
                                  ["type": "1", "oid": String(aid), "rpid": String(rpid), "action": like ? "1" : "0"], csrf: true)
    }
}
