@testable import BiliKit
import XCTest

final class DanmakuClockTests: XCTestCase {
    func testNormalPlaybackProducesContiguousWindows() {
        var clock = DanmakuClock()
        XCTAssertEqual(clock.advance(to: 10, rate: 1, elapsed: 1 / 60), .seek(from: 9.9, to: 10), "first frame lands like a seek")
        XCTAssertEqual(clock.advance(to: 10.0167, rate: 1, elapsed: 1 / 60), .window(from: 10, to: 10.0167))
        XCTAssertEqual(clock.advance(to: 10.05, rate: 2, elapsed: 1 / 60), .window(from: 10.0167, to: 10.05))
    }

    func testPauseIsIdleAndScrubWhilePausedIsSeek() {
        var clock = DanmakuClock()
        _ = clock.advance(to: 5, rate: 1, elapsed: 0.016)
        XCTAssertEqual(clock.advance(to: 5, rate: 0, elapsed: 0.016), .idle)
        XCTAssertEqual(clock.advance(to: 5.3, rate: 0, elapsed: 0.016), .seek(from: 5.2, to: 5.3), "moved while paused")
    }

    func testSmallAndBackwardJumpsAreSeeks() {
        var clock = DanmakuClock()
        _ = clock.advance(to: 20, rate: 1, elapsed: 0.016)
        XCTAssertEqual(clock.advance(to: 21, rate: 1, elapsed: 0.016), .seek(from: 20.9, to: 21), "1s jump in one frame")
        XCTAssertEqual(clock.advance(to: 15, rate: 1, elapsed: 0.016), .seek(from: 14.9, to: 15))
    }

    func testMainThreadStallAtDoubleSpeedIsNotASeek() {
        var clock = DanmakuClock()
        _ = clock.advance(to: 30, rate: 2, elapsed: 0.016)
        XCTAssertEqual(clock.advance(to: 31.5, rate: 2, elapsed: 0.75), .window(from: 30, to: 31.5))
    }

    func testLoopBackToZeroShowsCommentsAtZero() {
        var clock = DanmakuClock()
        _ = clock.advance(to: 100, rate: 1, elapsed: 0.016)
        guard case let .seek(from, to) = clock.advance(to: 0, rate: 1, elapsed: 0.016) else { return XCTFail() }
        var t = DanmakuTimeline()
        t.add([Danmaku(id: 1, time: -2, mode: .scroll, text: "clamped to 0")], segment: 1)
        XCTAssertEqual(t.due(from: from, to: to).count, 1)
    }
}

final class TimelineMergeTests: XCTestCase {
    func testMergesAcrossSegmentBoundaryAndKeepsOrder() {
        var t = DanmakuTimeline()
        t.add([Danmaku(id: 1, time: 355, mode: .scroll, text: "前方高能")], segment: 1, mergeWindow: 15)
        t.add([Danmaku(id: 2, time: 361, mode: .scroll, text: "前方 高能"),
               Danmaku(id: 3, time: 362, mode: .top, text: "前方高能"),
               Danmaku(id: 4, time: 380, mode: .scroll, text: "前方高能")], segment: 2, mergeWindow: 15)
        XCTAssertEqual(t.items.map(\.id), [1, 3, 4], "same mode within the window merges; other modes don't")
        XCTAssertEqual(t.items.map(\.count), [2, 1, 1])
    }

    func testOutOfOrderSegmentsStaySorted() {
        var t = DanmakuTimeline()
        t.add([Danmaku(id: 3, time: 400, mode: .scroll, text: "c")], segment: 2)
        t.add([Danmaku(id: 1, time: 1, mode: .scroll, text: "a"), Danmaku(id: 2, time: 300, mode: .scroll, text: "b")], segment: 1)
        XCTAssertEqual(t.items.map(\.id), [1, 2, 3])
    }

    func testRefilter() {
        var t = DanmakuTimeline()
        t.add([Danmaku(id: 1, time: 1, mode: .scroll, text: "keep"), Danmaku(id: 2, time: 2, mode: .scroll, text: "剧透")], segment: 1)
        var f = DanmakuFilter()
        f.addAccountRules([JSON(["type": 0, "filter": "剧透"])])
        t.filter(f.allows)
        XCTAssertEqual(t.items.map(\.id), [1])
        XCTAssertEqual(t.loadedSegments, [1])
    }
}

final class DanmakuFilterRuleTests: XCTestCase {
    func testRegexSlashesStrippedAndRulesIdempotent() {
        var f = DanmakuFilter()
        let rules = [JSON(["type": 1, "filter": "/^6+$/"]), JSON(["type": 0, "filter": "AbC"])]
        f.addAccountRules(rules)
        f.addAccountRules(rules)
        XCTAssertEqual(f.blockedPatterns, ["^6+$"])
        XCTAssertEqual(f.blockedWords, ["abc"])
        XCTAssertFalse(f.allows(Danmaku(id: 1, time: 0, mode: .scroll, text: "6666")))
        XCTAssertFalse(f.allows(Danmaku(id: 2, time: 0, mode: .scroll, text: "xxABCxx")), "keywords match case-insensitively")
        XCTAssertTrue(f.allows(Danmaku(id: 3, time: 0, mode: .scroll, text: "666 好")))
    }

    func testMultiLineTextFlattened() {
        XCTAssertEqual(Danmaku(id: 1, time: 0, mode: .scroll, text: "a\nb/nc").text, "a b c")
    }
}

final class RobustnessTests: XCTestCase {
    func testHugeLengthPrefixDoesNotCrash() {
        // field 1, wire type 2, length = 2^63 (10-byte varint)
        let data = Data([0x0A, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x01])
        XCTAssertThrowsError(try DanmakuParser.parseSegment(data))
    }

    func testHugeVarintFieldsDoNotCrash() {
        // elem { 3: 2^63 (mode), 4: 2^63 (size), 7: "x" }
        let big: [UInt8] = [0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x01]
        let elem: [UInt8] = [0x18] + big + [0x20] + big + [0x3A, 0x01, 0x78]
        let data = Data([0x0A, UInt8(elem.count)] + elem)
        XCTAssertNoThrow(try DanmakuParser.parseSegment(data))
    }

    func testEntities() {
        XCTAssertEqual(BiliText.plain("&amp;lt;b&amp;gt;"), "&lt;b&gt;", "decoded once, not twice")
        XCTAssertEqual(BiliText.plain("&#20013;&#x6587; &quot;ok&quot;"), "中文 \"ok\"")
        XCTAssertEqual(BiliText.plain("AT&T & co &unknown;"), "AT&T & co &unknown;")
        XCTAssertEqual(BiliText.plain("<em class=\"keyword\">x</em>&nbsp;y"), "x y")
    }

    func testSubtitleLookup() {
        let lines = [API.SubtitleLine(from: 1, to: 3, text: "a"), API.SubtitleLine(from: 5, to: 6, text: "b")]
        XCTAssertNil(SubtitleLookup.line(at: 0.5, in: lines))
        XCTAssertEqual(SubtitleLookup.line(at: 1, in: lines)?.text, "a")
        XCTAssertNil(SubtitleLookup.line(at: 4, in: lines), "gap between lines")
        XCTAssertEqual(SubtitleLookup.line(at: 5.5, in: lines)?.text, "b")
        XCTAssertNil(SubtitleLookup.line(at: 6, in: lines))
        XCTAssertNil(SubtitleLookup.line(at: 1, in: []))
    }
}

final class IFramePlaylistTests: XCTestCase {
    func testDedicatedIFramePlaylist() async throws {
        let sidx = Fixture.data("avc480.sidx")
        let v = DashStream(id: 32, codecs: "avc1.64001F", codecID: 7, width: 852, height: 480, frameRate: 25, bandwidth: 786_766,
                           urls: ["https://m0/v.m4s"], initRange: 0 ... 1011, indexRange: 1012 ... 1547)
        let a = DashStream(id: 30280, codecs: "mp4a.40.2", codecID: 0, width: 0, height: 0, frameRate: 0, bandwidth: 1,
                           urls: ["https://m0/a.m4s"], initRange: 0 ... 1011, indexRange: 1012 ... 1547)
        let session = HLSSession(selection: StreamSelection(videos: [v], audio: a), preferOfficialCDN: false) { _, _ in sidx }
        XCTAssertTrue(session.masterPlaylist(scheme: "s").contains(#"URI="s://play/iframe.m3u8""#))
        let playlist = try await session.mediaPlaylist(named: "iframe")
        let lines = playlist.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines.contains("#EXT-X-I-FRAMES-ONLY"))
        XCTAssertFalse(lines.contains("#EXT-X-INDEPENDENT-SEGMENTS"))
        XCTAssertTrue(lines.contains { $0.hasPrefix("#EXT-X-MAP:") })
        XCTAssertEqual(lines.filter { $0.hasPrefix("#EXT-X-BYTERANGE:") }.count, 42)
    }
}
