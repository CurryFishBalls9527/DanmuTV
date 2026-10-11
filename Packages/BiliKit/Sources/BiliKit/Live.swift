import Foundation

// MARK: Rooms & streams

public struct LiveRoom: Identifiable, Hashable, Sendable {
    public var roomID: Int
    public var title: String
    public var cover: String
    public var uname: String
    public var face: String
    public var area: String
    public var online: Int
    public var isLive: Bool
    public var id: Int { roomID }

    public init(roomID: Int, title: String, cover: String, uname: String, face: String, area: String = "", online: Int = 0, isLive: Bool = true) {
        self.roomID = roomID
        self.title = title
        self.cover = cover
        self.uname = uname
        self.face = face
        self.area = area
        self.online = online
        self.isLive = isLive
    }

    init(_ j: JSON) {
        self.init(roomID: j["roomid"].int ?? j["room_id"].intValue,
                  title: BiliText.plain(j["title"].stringValue),
                  cover: BiliText.imageURL(j["cover"].string.flatMap { $0.isEmpty ? nil : $0 }
                      ?? j["user_cover"].string.flatMap { $0.isEmpty ? nil : $0 }
                      ?? j["room_cover"].string.flatMap { $0.isEmpty ? nil : $0 }
                      ?? j["keyframe"].stringValue),
                  uname: BiliText.plain(j["uname"].stringValue),
                  face: BiliText.imageURL(j["face"].string ?? j["uface"].stringValue),
                  area: j["area_v2_name"].string ?? j["area_name"].stringValue,
                  online: j["online"].int ?? j["watched_show"]["num"].intValue,
                  isLive: j["live_status"].exists ? j["live_status"].intValue == 1 : true)
    }
}

/// One playable live stream variant.
public struct LiveStream: Equatable, Sendable {
    /// "http_hls" / "http_stream".
    public var protocolName: String
    /// "fmp4" / "ts" / "flv".
    public var format: String
    /// "avc" / "hevc".
    public var codec: String
    public var quality: Int
    /// Full URLs, one per CDN host (线路).
    public var urls: [String]

    public var isHLS: Bool { protocolName == "http_hls" }
    public var isFLV: Bool { format == "flv" }
}

public struct LivePlayInfo: Sendable {
    public var roomID: Int
    public var uid: Int
    public var isLive: Bool
    /// 竖屏直播间 (shown letterboxed, never cropped).
    public var isPortrait: Bool
    public var streams: [LiveStream]
    public var qualities: [(qn: Int, name: String)]
    public var currentQuality: Int

    public init(_ d: JSON) {
        roomID = d["room_id"].intValue
        uid = d["uid"].intValue
        isLive = d["live_status"].intValue == 1
        isPortrait = d["is_portrait"].bool
        let playurl = d["playurl_info"]["playurl"]
        qualities = playurl["g_qn_desc"].array.map { ($0["qn"].intValue, $0["desc"].stringValue) }
        var streams: [LiveStream] = []
        var current = 0
        for s in playurl["stream"].array {
            for f in s["format"].array {
                for c in f["codec"].array {
                    let urls = c["url_info"].array.map { $0["host"].stringValue + c["base_url"].stringValue + $0["extra"].stringValue }
                    current = max(current, c["current_qn"].intValue)
                    streams.append(LiveStream(protocolName: s["protocol_name"].stringValue, format: f["format_name"].stringValue,
                                              codec: c["codec_name"].stringValue, quality: c["current_qn"].intValue, urls: urls))
                }
            }
        }
        self.streams = streams
        currentQuality = current
    }

    /// The stream to play. AVPlayer takes HLS (fMP4 first, then TS); FLV is only for the VLC player.
    public func preferredStream(useVLC: Bool, allowHEVC: Bool) -> LiveStream? {
        func rank(_ s: LiveStream) -> Int {
            var score = 0
            if useVLC { score += s.isFLV ? 100 : 0 } else { score += s.isHLS ? 100 : 0 }
            if s.format == "fmp4" { score += 10 } else if s.format == "ts" { score += 5 }
            if s.codec == "hevc" { score += allowHEVC ? 2 : -50 }
            return score
        }
        let usable = streams.filter { !$0.urls.isEmpty && (useVLC || $0.isHLS) }
        return usable.max { rank($0) < rank($1) }
    }
}

// MARK: Live danmaku wire protocol

/// Bilibili live chat packets: 16-byte big-endian header (total length, header length 16,
/// protocol version, operation, sequence) + body.
public enum LivePacket {
    public enum Operation: UInt32 {
        case heartbeat = 2, heartbeatReply = 3, message = 5, auth = 7, authReply = 8
    }

    public static func encode(_ op: Operation, body: Data, version: UInt16 = 1) -> Data {
        var data = Data()
        func put32(_ v: UInt32) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
        func put16(_ v: UInt16) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
        put32(UInt32(16 + body.count))
        put16(16)
        put16(version)
        put32(op.rawValue)
        put32(1)
        data.append(body)
        return data
    }

    public struct Decoded: Equatable {
        public var operation: UInt32
        public var version: UInt16
        public var body: Data
    }

    /// Splits a frame into packets, expanding zlib (version 2) batches recursively.
    public static func decode(_ frame: Data) -> [Decoded] {
        var out: [Decoded] = []
        var offset = frame.startIndex
        while frame.endIndex - offset >= 16 {
            func u32(_ at: Int) -> UInt32 { frame[at ..< at + 4].reduce(0) { $0 << 8 | UInt32($1) } }
            func u16(_ at: Int) -> UInt16 { frame[at ..< at + 2].reduce(0) { $0 << 8 | UInt16($1) } }
            let total = Int(u32(offset))
            let header = Int(u16(offset + 4))
            guard total >= header, header >= 16, offset + total <= frame.endIndex else { break }
            let version = u16(offset + 6)
            let op = u32(offset + 8)
            let body = frame.subdata(in: offset + header ..< offset + total)
            if version == 2, op == Operation.message.rawValue, let inflated = inflateZlib(body) {
                out += decode(inflated)
            } else {
                out.append(Decoded(operation: op, version: version, body: body))
            }
            offset += total
        }
        return out
    }

    /// zlib stream (2-byte header + raw deflate).
    static func inflateZlib(_ data: Data) -> Data? {
        guard data.count > 2 else { return nil }
        return try? (data.dropFirst(2) as NSData).decompressed(using: .zlib) as Data
    }
}

public enum LiveEvent: Sendable {
    case danmaku(Danmaku, user: String)
    case superChat(SuperChat)
    /// 人气 / watched count updates.
    case popularity(Int)
    case connected
    case disconnected(String)
}

public struct SuperChat: Identifiable, Hashable, Sendable {
    public var id: Int
    public var user: String
    public var face: String
    public var message: String
    /// RMB.
    public var price: Int
    /// 0xRRGGBB background.
    public var color: UInt32
    /// How long it stays pinned, in seconds.
    public var duration: Int
}

public enum LiveMessageParser {
    /// Parses one JSON chat command.
    public static func parse(_ body: Data) -> LiveEvent? {
        guard let json = try? JSON(data: body) else { return nil }
        let cmd = json["cmd"].stringValue
        if cmd.hasPrefix("DANMU_MSG") {
            let info = json["info"]
            let text = info[1].stringValue
            guard !text.isEmpty else { return nil }
            let meta = info[0]
            let mode = Danmaku.mode(meta[1].intValue) ?? .scroll
            let d = Danmaku(id: Int64(meta[4].intValue), time: 0, mode: mode, fontSize: meta[2].int ?? 25,
                            color: UInt32(truncatingIfNeeded: meta[3].int ?? 0xFFFFFF), text: text, weight: 10,
                            // Same hash scheme as VOD danmaku, so the account's per-user blocks apply.
                            senderHash: CRC32.senderHash(uid: info[2][0].intValue))
            return .danmaku(d, user: info[2][1].stringValue)
        }
        if cmd == "SUPER_CHAT_MESSAGE" {
            let d = json["data"]
            let hex = d["background_bottom_color"].stringValue.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
            let color = UInt32(hex, radix: 16) ?? 0x2A60B2
            return .superChat(SuperChat(id: d["id"].intValue, user: d["user_info"]["uname"].stringValue,
                                        face: BiliText.imageURL(d["user_info"]["face"].stringValue), message: d["message"].stringValue,
                                        price: d["price"].intValue, color: color, duration: d["time"].int ?? 60))
        }
        if cmd == "WATCHED_CHANGE" {
            return .popularity(json["data"]["num"].intValue)
        }
        return nil
    }
}

/// WebSocket client for a room's chat: auth, 30 s heartbeat, reconnect with backoff.
/// Mutable state is lock-protected; `stop()` always closes the socket, even mid-connect.
public final class LiveDanmakuClient: @unchecked Sendable {
    private let roomID: Int
    private let lock = NSLock()
    private var socket: URLSessionWebSocketTask?
    private var loop: Task<Void, Never>?
    private var continuation: AsyncStream<LiveEvent>.Continuation?
    private var stopped = false

    public init(roomID: Int) {
        self.roomID = roomID
    }

    public func events() -> AsyncStream<LiveEvent> {
        AsyncStream { continuation in
            lock.withLock { self.continuation = continuation }
            let task = Task { await self.run() }
            lock.withLock { self.loop = task }
            continuation.onTermination = { [weak self] _ in self?.stop() }
        }
    }

    public func stop() {
        let (task, socket) = lock.withLock { () -> (Task<Void, Never>?, URLSessionWebSocketTask?) in
            stopped = true
            defer { self.socket = nil }
            return (loop, self.socket)
        }
        task?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
    }

    private func yield(_ event: LiveEvent) {
        _ = lock.withLock { continuation }?.yield(event)
    }

    private var isStopped: Bool { lock.withLock { stopped } }

    private func run() async {
        var attempt = 0
        while !Task.isCancelled, !isStopped {
            do {
                try await connectOnce { attempt = 0 }
            } catch {
                guard !Task.isCancelled, !isStopped else { break }
                yield(.disconnected(error.localizedDescription))
            }
            attempt += 1
            // Reconnect: 1 s, 2 s, 4 s … capped at 30 s; reset after a successful auth.
            try? await Task.sleep(nanoseconds: UInt64(min(30, 1 << min(attempt - 1, 5))) * 1_000_000_000)
        }
        lock.withLock { continuation }?.finish()
    }

    private func connectOnce(onAuthenticated: () -> Void) async throws {
        let info = try await API.danmuInfo(roomID: roomID)
        guard let host = info.hosts.first else { throw BiliError.invalidResponse }
        var request = URLRequest(url: URL(string: "wss://\(host)/sub")!)
        request.setValue(BiliClient.userAgent, forHTTPHeaderField: "User-Agent")
        let socket = BiliClient.shared.session.webSocketTask(with: request)
        let alreadyStopped = lock.withLock { () -> Bool in
            if !stopped { self.socket = socket }
            return stopped
        }
        guard !alreadyStopped, !Task.isCancelled else {
            socket.cancel()
            return
        }
        socket.resume()

        try await socket.send(.data(LivePacket.encode(.auth, body: Self.authBody(roomID: roomID, token: info.token))))

        let heartbeat = Task {
            while !Task.isCancelled {
                try? await socket.send(.data(LivePacket.encode(.heartbeat, body: Data("[object Object]".utf8))))
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
        defer {
            heartbeat.cancel()
            socket.cancel(with: .goingAway, reason: nil)
        }

        try await withTaskCancellationHandler {
            while !Task.isCancelled {
                let message = try await socket.receive()
                guard case let .data(frame) = message else { continue }
                for packet in LivePacket.decode(frame) {
                    switch packet.operation {
                    case LivePacket.Operation.authReply.rawValue:
                        let code = (try? JSON(data: packet.body))?["code"].int ?? 0
                        guard code == 0 else { throw BiliError.api(code: code, message: "弹幕服务器认证失败") }
                        onAuthenticated()
                        yield(.connected)
                    case LivePacket.Operation.message.rawValue:
                        if let event = LiveMessageParser.parse(packet.body) { yield(event) }
                    case LivePacket.Operation.heartbeatReply.rawValue:
                        if let n = LivePacket.popularity(packet.body) { yield(.popularity(n)) }
                    default:
                        break
                    }
                }
            }
        } onCancel: {
            socket.cancel(with: .goingAway, reason: nil)
        }
    }

    /// Auth packet body: uid 0 + buvid when logged out (names are then masked by the server).
    static func authBody(roomID: Int, token: String, uid: Int = BiliClient.shared.currentAccount?.mid ?? 0,
                         buvid: String = BiliClient.shared.currentBuvid) -> Data
    {
        let body: [String: Any] = ["uid": uid, "roomid": roomID, "protover": 2, "platform": "web", "type": 2, "key": token, "buvid": buvid]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }
}

extension LivePacket {
    /// Heartbeat reply body: 4-byte big-endian popularity.
    static func popularity(_ body: Data) -> Int? {
        guard body.count >= 4 else { return nil }
        return body.prefix(4).reduce(0) { $0 << 8 | Int($1) }
    }
}

/// CRC-32 (IEEE), as Bilibili uses for danmaku sender hashes (hex of crc32 of the uid string).
public enum CRC32 {
    private static let table: [UInt32] = (0 ..< 256).map { i in
        (0 ..< 8).reduce(UInt32(i)) { c, _ in c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
    }

    public static func checksum(_ data: Data) -> UInt32 {
        ~data.reduce(~UInt32(0)) { table[Int(($0 ^ UInt32($1)) & 0xFF)] ^ ($0 >> 8) }
    }

    public static func senderHash(uid: Int) -> String {
        String(checksum(Data(String(uid).utf8)), radix: 16)
    }
}

// MARK: Endpoints

extension API {
    /// 直播推荐 (works logged out).
    public static func liveRecommend() async throws -> [LiveRoom] {
        try await client.get("https://api.live.bilibili.com/xlive/web-interface/v1/webMain/getMoreRecList", ["platform": "web"])["data"]["recommend_room_list"]
            .array.map(LiveRoom.init)
    }

    /// Followed streamers, live ones first.
    public static func liveFollowing(page: Int) async throws -> (items: [LiveRoom], hasMore: Bool) {
        let d = try await client.get("https://api.live.bilibili.com/xlive/web-ucenter/user/following",
                                     ["page": String(page), "page_size": "29", "ignoreRecord": "1", "hit_ab": "true"])["data"]
        let items = d["list"].array.map(LiveRoom.init)
        return (items, page < d["totalPage"].intValue)
    }

    public static func livePlayInfo(roomID: Int, quality: Int = 10000) async throws -> LivePlayInfo {
        LivePlayInfo(try await client.get("https://api.live.bilibili.com/xlive/web-room/v2/index/getRoomPlayInfo",
                                          ["room_id": String(roomID), "protocol": "0,1", "format": "0,1,2", "codec": "0,1",
                                           "qn": String(quality), "platform": "web", "ptype": "8", "dolby": "5"])["data"])
    }

    public static func liveRoomInfo(roomID: Int) async throws -> LiveRoom {
        var room = LiveRoom(try await client.get("https://api.live.bilibili.com/room/v1/Room/get_info", ["room_id": String(roomID)])["data"])
        room.roomID = roomID
        return room
    }

    public static func danmuInfo(roomID: Int) async throws -> (token: String, hosts: [String]) {
        let d = try await client.get("https://api.live.bilibili.com/xlive/web-room/v1/index/getDanmuInfo",
                                     ["id": String(roomID), "type": "0", "web_location": "444.8"], sign: .wbi)["data"]
        let hosts = d["host_list"].array.map { "\($0["host"].stringValue):\($0["wss_port"].int ?? 443)" }
        return (d["token"].stringValue, hosts.isEmpty ? ["broadcastlv.chat.bilibili.com:443"] : hosts)
    }

    public static func liveRoom(fromSearch j: JSON) -> LiveRoom {
        LiveRoom(roomID: j["roomid"].intValue, title: BiliText.plain(j["title"].stringValue),
                 cover: BiliText.imageURL(j["user_cover"].string ?? j["cover"].stringValue),
                 uname: BiliText.plain(j["uname"].stringValue), face: BiliText.imageURL(j["uface"].stringValue),
                 area: j["cate_name"].stringValue, online: j["online"].intValue, isLive: j["live_status"].int.map { $0 == 1 } ?? true)
    }
}

// MARK: Sponsor segments (广告 / 恰饭片段跳过)

extension API {
    /// Community-maintained segments (BilibiliSponsorBlock) for one page.
    public static func sponsorSegments(bvid: String, cid: Int, multiPart: Bool = false,
                                       categories: [String] = ["sponsor", "selfpromo", "interaction"]) async throws -> [SkipRange] {
        var c = URLComponents(string: "https://bsbsb.top/api/skipSegments")!
        c.queryItems = [URLQueryItem(name: "videoID", value: bvid)] + categories.map { URLQueryItem(name: "category", value: $0) }
        var request = URLRequest(url: c.url!, timeoutInterval: 6)
        request.setValue("DanmuTV (tvOS)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        // 404 = no segments for this video.
        if (response as? HTTPURLResponse)?.statusCode == 404 { return [] }
        return SkipRange.parseSponsor(try JSON(data: data), cid: cid, requireCID: multiPart)
    }
}

extension SkipRange {
    /// `requireCID`: on multi-part videos, segments without a cid can't be placed and are dropped.
    static func parseSponsor(_ j: JSON, cid: Int, requireCID: Bool = false) -> [SkipRange] {
        j.array.compactMap { s in
            guard s["actionType"].string ?? "skip" == "skip" else { return nil }
            let segmentCID = s["cid"].intValue // string or number
            if segmentCID == 0, requireCID { return nil }
            if segmentCID != 0, cid != 0, segmentCID != cid { return nil }
            let start = s["segment"][0].doubleValue, end = s["segment"][1].doubleValue
            guard end > start else { return nil }
            return SkipRange(kind: .sponsor, start: start, end: end)
        }
    }
}
