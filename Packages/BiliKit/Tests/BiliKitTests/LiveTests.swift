@testable import BiliKit
import XCTest

final class LivePacketTests: XCTestCase {
    func testEncodeHeader() {
        let p = LivePacket.encode(.auth, body: Data("{}".utf8))
        XCTAssertEqual(p.count, 18)
        XCTAssertEqual(Array(p.prefix(16)), [0, 0, 0, 18, 0, 16, 0, 1, 0, 0, 0, 7, 0, 0, 0, 1])
    }

    func testDecodeConcatenatedPlainPackets() {
        let a = LivePacket.encode(.message, body: Data(#"{"cmd":"A"}"#.utf8), version: 0)
        let b = LivePacket.encode(.heartbeatReply, body: Data([0, 0, 1, 0]), version: 1)
        let decoded = LivePacket.decode(a + b)
        XCTAssertEqual(decoded.map(\.operation), [5, 3])
        XCTAssertEqual(String(decoding: decoded[0].body, as: UTF8.self), #"{"cmd":"A"}"#)
    }

    func testDecodeZlibBatch() throws {
        // Server batches several messages into one version-2 packet whose body is zlib.
        let inner = LivePacket.encode(.message, body: Data(#"{"cmd":"X"}"#.utf8), version: 0)
            + LivePacket.encode(.message, body: Data(#"{"cmd":"Y"}"#.utf8), version: 0)
        let deflated = try XCTUnwrap((inner as NSData).compressed(using: .zlib) as Data)
        let zlib = Data([0x78, 0x9C]) + deflated // 2-byte zlib header + raw deflate (checksum not needed)
        let outer = LivePacket.encode(.message, body: zlib, version: 2)
        let decoded = LivePacket.decode(outer)
        XCTAssertEqual(decoded.map { String(decoding: $0.body, as: UTF8.self) }, [#"{"cmd":"X"}"#, #"{"cmd":"Y"}"#])
    }

    func testTruncatedFrameIsIgnored() {
        let p = LivePacket.encode(.message, body: Data("hello".utf8))
        XCTAssertTrue(LivePacket.decode(p.prefix(10)).isEmpty)
        XCTAssertTrue(LivePacket.decode(p.dropLast(2)).isEmpty)
    }
}

final class LiveMessageTests: XCTestCase {
    func testDanmakuMessage() {
        let body = Data(#"{"cmd":"DANMU_MSG:4:0:2:2:2:0","info":[[0,1,25,16777215,1712345678901,0,0,"abcd",0],"主播好！",[123,"观众A"]]}"#.utf8)
        guard case let .danmaku(d, user)? = LiveMessageParser.parse(body) else { return XCTFail() }
        XCTAssertEqual(d.text, "主播好！")
        XCTAssertEqual(d.mode, .scroll)
        XCTAssertEqual(d.color, 0xFFFFFF)
        XCTAssertEqual(user, "观众A")
    }

    func testSuperChat() {
        let body = Data(##"{"cmd":"SUPER_CHAT_MESSAGE","data":{"id":9,"message":"加油","price":30,"time":60,"background_bottom_color":"#2A60B2","user_info":{"uname":"土豪","face":"//i0.hdslb.com/f.jpg"}}}"##.utf8)
        guard case let .superChat(sc)? = LiveMessageParser.parse(body) else { return XCTFail() }
        XCTAssertEqual(sc.price, 30)
        XCTAssertEqual(sc.message, "加油")
        XCTAssertEqual(sc.user, "土豪")
        XCTAssertEqual(sc.color, 0x2A60B2)
        XCTAssertEqual(sc.face, "https://i0.hdslb.com/f.jpg")
    }

    func testOtherCommandsIgnored() {
        XCTAssertNil(LiveMessageParser.parse(Data(#"{"cmd":"INTERACT_WORD","data":{}}"#.utf8)))
        XCTAssertNil(LiveMessageParser.parse(Data("not json".utf8)))
    }
}

final class LiveStreamTests: XCTestCase {
    func info() -> LivePlayInfo {
        LivePlayInfo(JSON([
            "room_id": 1, "uid": 2, "live_status": 1, "is_portrait": true,
            "playurl_info": ["playurl": [
                "g_qn_desc": [["qn": 10000, "desc": "原画"], ["qn": 400, "desc": "蓝光"]],
                "stream": [
                    ["protocol_name": "http_stream", "format": [["format_name": "flv", "codec": [
                        ["codec_name": "avc", "current_qn": 10000, "base_url": "/a.flv?", "url_info": [["host": "https://f1", "extra": "x=1"]]],
                    ]]]],
                    ["protocol_name": "http_hls", "format": [
                        ["format_name": "ts", "codec": [
                            ["codec_name": "avc", "current_qn": 10000, "base_url": "/a.m3u8?", "url_info": [["host": "https://h1", "extra": "x=1"]]],
                        ]],
                        ["format_name": "fmp4", "codec": [
                            ["codec_name": "avc", "current_qn": 10000, "base_url": "/i.m3u8?", "url_info": [["host": "https://h2", "extra": "x=2"], ["host": "https://h3", "extra": "x=3"]]],
                            ["codec_name": "hevc", "current_qn": 10000, "base_url": "/h.m3u8?", "url_info": [["host": "https://h4", "extra": "x=4"]]],
                        ]],
                    ]],
                ],
            ]],
        ] as [String: Any]))
    }

    func testParse() {
        let i = info()
        XCTAssertTrue(i.isLive)
        XCTAssertTrue(i.isPortrait)
        XCTAssertEqual(i.streams.count, 4)
        XCTAssertEqual(i.qualities.map(\.name), ["原画", "蓝光"])
        XCTAssertEqual(i.currentQuality, 10000)
    }

    func testPreferredStream() {
        let i = info()
        XCTAssertEqual(i.preferredStream(useVLC: false, allowHEVC: false)?.urls, ["https://h2/i.m3u8?x=2", "https://h3/i.m3u8?x=3"],
                       "AVPlayer: HLS fMP4 AVC, every route kept")
        XCTAssertEqual(i.preferredStream(useVLC: false, allowHEVC: true)?.codec, "hevc")
        XCTAssertEqual(i.preferredStream(useVLC: true, allowHEVC: false)?.format, "flv", "VLC takes FLV")
    }

    func testRoomParsing() {
        let room = LiveRoom(JSON(["roomid": 5, "title": "<em>标题</em>", "user_cover": "", "keyframe": "//i0/k.jpg",
                                  "uname": "主播", "face": "//i0/f.jpg", "online": 12, "live_status": 0] as [String: Any]))
        XCTAssertEqual(room.title, "标题")
        XCTAssertEqual(room.cover, "https://i0/k.jpg", "empty covers fall through to the keyframe")
        XCTAssertFalse(room.isLive)
    }
}

final class SponsorTests: XCTestCase {
    func testParseFiltersByPageAndAction() {
        let json = JSON([
            ["cid": "42564652953", "category": "sponsor", "actionType": "skip", "segment": [2095.8, 2111.8]],
            ["cid": "999", "category": "sponsor", "actionType": "skip", "segment": [10, 20]],
            ["cid": "42564652953", "category": "sponsor", "actionType": "mute", "segment": [30, 40]],
            ["category": "selfpromo", "actionType": "skip", "segment": [50, 50]],
        ] as [Any])
        let ranges = SkipRange.parseSponsor(json, cid: 42_564_652_953)
        XCTAssertEqual(ranges, [SkipRange(kind: .sponsor, start: 2095.8, end: 2111.8)])
    }
}

final class LiveReviewTests: XCTestCase {
    func testRealZlibFrameWithAdlerAndNestedHeartbeat() {
        // Built with Python zlib.compress (2-byte header + deflate + Adler-32 trailer), like the server.
        let packets = LivePacket.decode(Fixture.data("live_zlib_frame.bin"))
        XCTAssertEqual(packets.map(\.operation), [5, 3])
        guard case let .danmaku(d, user)? = LiveMessageParser.parse(packets[0].body) else { return XCTFail() }
        XCTAssertEqual(d.text, "压缩里的弹幕")
        XCTAssertEqual(user, "u")
        XCTAssertEqual(d.senderHash, CRC32.senderHash(uid: 42))
        XCTAssertEqual(LivePacket.popularity(packets[1].body), 12345)
    }

    func testCRC32SenderHash() {
        XCTAssertEqual(CRC32.checksum(Data("123456789".utf8)), 0xCBF4_3926, "standard check value")
        XCTAssertEqual(CRC32.senderHash(uid: 1), "83dcefb7")
    }

    func testAuthBody() throws {
        let body = try JSON(data: LiveDanmakuClient.authBody(roomID: 5, token: "tok", uid: 0, buvid: "b3"))
        XCTAssertEqual(body["roomid"].intValue, 5)
        XCTAssertEqual(body["key"].stringValue, "tok")
        XCTAssertEqual(body["protover"].intValue, 2, "zlib batches (no brotli)")
        XCTAssertEqual(body["type"].intValue, 2)
        XCTAssertEqual(body["buvid"].stringValue, "b3")
        XCTAssertEqual(body["uid"].intValue, 0)
    }

    func testRealPlayInfoSample() throws {
        let info = LivePlayInfo(try JSON(data: Fixture.data("live_playinfo.json")))
        XCTAssertTrue(info.isLive)
        XCTAssertFalse(info.qualities.isEmpty)
        let hls = try XCTUnwrap(info.preferredStream(useVLC: false, allowHEVC: false))
        XCTAssertTrue(hls.isHLS)
        XCTAssertTrue(hls.urls.allSatisfy { $0.hasPrefix("https://") && $0.contains(".m3u8") })
        XCTAssertEqual(info.preferredStream(useVLC: true, allowHEVC: false)?.format, "flv")
    }

    func testSponsorStringCIDAndMultiPart() {
        let json = JSON([["cid": "7", "actionType": "skip", "segment": [1, 5]], ["actionType": "skip", "segment": [10, 20]]] as [Any])
        XCTAssertEqual(SkipRange.parseSponsor(json, cid: 7).count, 2, "single part: cid-less segments apply")
        XCTAssertEqual(SkipRange.parseSponsor(json, cid: 7, requireCID: true), [SkipRange(kind: .sponsor, start: 1, end: 5)])
        XCTAssertTrue(SkipRange.parseSponsor(json, cid: 8, requireCID: true).isEmpty)
    }

    func testSuperChatColourVariants() {
        for (raw, expected) in [("#E54D4D", UInt32(0xE54D4D)), ("E54D4D", 0xE54D4D), ("", 0x2A60B2)] {
            let body = Data(##"{"cmd":"SUPER_CHAT_MESSAGE","data":{"id":1,"message":"m","price":30,"background_bottom_color":"\##(raw)","user_info":{"uname":"u"}}}"##.utf8)
            guard case let .superChat(sc)? = LiveMessageParser.parse(body) else { return XCTFail() }
            XCTAssertEqual(sc.color, expected, raw)
        }
    }

    func testRecommendLiveItemIdentity() {
        var v = VideoItem(archive: JSON(["id": 5, "title": "直播", "goto": "live"] as [String: Any]))
        v.liveRoomID = 123
        XCTAssertEqual(v.id, "live123", "live cards never collide with video ids")
    }
}
