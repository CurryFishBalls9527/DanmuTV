@testable import BiliKit
import XCTest

final class DanmakuParserTests: XCTestCase {
    func testRealProtobufSegment() throws {
        let items = try DanmakuParser.parseSegment(Fixture.data("danmaku_seg1.pb"))
        XCTAssertEqual(items.count, 249)
        XCTAssertEqual(items.filter { $0.mode == .top }.count, 102)
        XCTAssertEqual(items.filter { $0.mode == .bottom }.count, 1)
        XCTAssertEqual(items.filter { $0.mode == .scroll }.count, 146)
        XCTAssertEqual(items.first?.text, "神作，千万别退出！")
        XCTAssertEqual(items.first?.time ?? 0, 0.062, accuracy: 0.0001)
        XCTAssertTrue(items.last!.time < 360, "segment 1 covers the first 6 minutes")
        XCTAssertEqual(items, items.sorted { $0.time < $1.time })
        XCTAssertTrue(items.allSatisfy { !$0.senderHash.isEmpty && (0 ... 11).contains($0.weight) })
    }

    func testXML() {
        let items = DanmakuParser.parseXML(Fixture.data("danmaku_sample.xml"))
        XCTAssertEqual(items.count, 20)
        let first = items.first { $0.text == "我是一万个点赞，正在反复横跳" }
        XCTAssertEqual(first?.mode, .bottom)
        XCTAssertEqual(first?.color, 15_138_834)
        XCTAssertEqual(first?.weight, 10)
        XCTAssertEqual(first?.senderHash, "9e5adeaa")
    }

    func testNegativeTimeClampsAndUnknownModesDropped() {
        let xml = Data("""
        <i><d p="-3.5,1,25,16777215,0,0,h,1,5">early</d><d p="10,7,25,16777215,0,0,h,2,5">[advanced]</d><d p="12,8,25,16777215,0,0,h,3,5">code</d></i>
        """.utf8)
        let items = DanmakuParser.parseXML(xml)
        XCTAssertEqual(items.map(\.text), ["early"])
        XCTAssertEqual(items.first?.time, 0)
    }

    func testTruncatedProtobufThrows() throws {
        let data = Fixture.data("danmaku_seg1.pb")
        XCTAssertThrowsError(try DanmakuParser.parseSegment(data.prefix(data.count - 7)))
    }
}

final class DanmakuFilterTests: XCTestCase {
    func d(_ text: String, mode: Danmaku.Mode = .scroll, color: UInt32 = 0xFFFFFF, weight: Int = 10, id: Int64 = 1, hash: String = "u") -> Danmaku {
        Danmaku(id: id, time: 1, mode: mode, color: color, text: text, weight: weight, senderHash: hash)
    }

    func testRules() {
        var f = DanmakuFilter()
        XCTAssertTrue(f.allows(d("hi")))
        f.minWeight = 5
        XCTAssertFalse(f.allows(d("spam", weight: 3)))
        f.showTop = false
        XCTAssertFalse(f.allows(d("top", mode: .top)))
        XCTAssertTrue(f.allows(d("scroll")))
        f.showColored = false
        XCTAssertFalse(f.allows(d("red", color: 0xFF0000)))
        f.blockedWords = ["前方高能"]
        XCTAssertFalse(f.allows(d("前方高能！！")))
        f.blockedPatterns = ["^2+3+$"]
        XCTAssertFalse(f.allows(d("2333")))
        XCTAssertTrue(f.allows(d("哈哈2333")))
        f.blockedSenders = ["bad"]
        XCTAssertFalse(f.allows(d("x", hash: "bad")))
    }

    func testAccountRules() {
        var f = DanmakuFilter()
        f.addAccountRules([JSON(["type": 0, "filter": "剧透"]), JSON(["type": 1, "filter": "^a+$"]),
                           JSON(["type": 2, "filter": "abcd1234"]), JSON(["type": 1, "filter": "(unclosed"])])
        XCTAssertEqual(f.blockedWords, ["剧透"])
        XCTAssertEqual(f.blockedPatterns, ["^a+$"], "invalid regex skipped")
        XCTAssertEqual(f.blockedSenders, ["abcd1234"])
    }

    func testDensityIsStableSampling() {
        var f = DanmakuFilter()
        f.density = 0.5
        let items = (0 ..< 1000).map { d("x", id: Int64($0)) }
        let kept = items.filter(f.allows).count
        XCTAssertEqual(kept, 500)
        XCTAssertEqual(items.filter(f.allows).map(\.id), items.filter(f.allows).map(\.id))
    }

    func testMerge() {
        let items = [
            Danmaku(id: 1, time: 1, mode: .scroll, text: "哈哈哈"),
            Danmaku(id: 2, time: 3, mode: .scroll, text: "哈 哈哈"),
            Danmaku(id: 3, time: 5, mode: .scroll, text: "other"),
            Danmaku(id: 4, time: 30, mode: .scroll, text: "哈哈哈"),
        ]
        let merged = DanmakuMerger.merge(items, window: 15)
        XCTAssertEqual(merged.map(\.id), [1, 3, 4])
        XCTAssertEqual(merged.map(\.count), [2, 1, 1])
    }
}

final class DanmakuTimelineTests: XCTestCase {
    func testSegmentsAndDueWindow() {
        XCTAssertEqual(DanmakuTimeline.segment(for: 0), 1)
        XCTAssertEqual(DanmakuTimeline.segment(for: 359.9), 1)
        XCTAssertEqual(DanmakuTimeline.segment(for: 360), 2)
        var t = DanmakuTimeline()
        t.add([Danmaku(id: 3, time: 400, mode: .scroll, text: "c")], segment: 2)
        t.add([Danmaku(id: 1, time: 1, mode: .scroll, text: "a"), Danmaku(id: 2, time: 2, mode: .top, text: "b")], segment: 1)
        XCTAssertEqual(t.items.map(\.id), [1, 2, 3])
        XCTAssertEqual(t.loadedSegments, [1, 2])
        XCTAssertEqual(t.due(from: 0, to: 1).map(\.id), [1], "inclusive end")
        XCTAssertEqual(t.due(from: 1, to: 2).map(\.id), [2], "exclusive start")
        XCTAssertEqual(t.due(from: 2, to: 399).map(\.id), [])
        XCTAssertEqual(t.due(from: 5, to: 1).map(\.id), [], "backwards window is empty")
    }
}

final class DanmakuLayoutTests: XCTestCase {
    func testScrollLanesFillThenFreeUp() {
        var layout = DanmakuLayout(width: 1000, lanes: 2, scrollDuration: 10, gap: 0)
        XCTAssertEqual(layout.place(.scroll, textWidth: 100, now: 0)?.lane, 0)
        XCTAssertEqual(layout.place(.scroll, textWidth: 100, now: 0)?.lane, 1)
        XCTAssertNil(layout.place(.scroll, textWidth: 100, now: 0.05), "both lanes busy: dropped")
        // Lane 0's comment (speed 110/s) has fully entered after ~0.91s; same-width follower can't catch it.
        XCTAssertEqual(layout.place(.scroll, textWidth: 100, now: 1)?.lane, 0)
    }

    func testFasterFollowerMustNotCatchUp() {
        var layout = DanmakuLayout(width: 1000, lanes: 1, scrollDuration: 10, gap: 0)
        _ = layout.place(.scroll, textWidth: 50, now: 0)
        // A much longer (faster) comment right after would overtake the short one before it leaves.
        XCTAssertNil(layout.place(.scroll, textWidth: 900, now: 1))
        XCTAssertNotNil(layout.place(.scroll, textWidth: 900, now: 6))
    }

    func testPositionsFollowMediaTime() {
        let layout = DanmakuLayout(width: 1000, lanes: 1, scrollDuration: 10)
        XCTAssertEqual(layout.x(start: 5, textWidth: 0, now: 5), 1000)
        XCTAssertEqual(layout.x(start: 5, textWidth: 0, now: 10), 500)
        XCTAssertEqual(layout.x(start: 5, textWidth: 0, now: 15), 0)
    }

    func testFixedLanes() {
        var layout = DanmakuLayout(width: 1000, lanes: 2, fixedDuration: 4)
        XCTAssertEqual(layout.place(.top, textWidth: 10, now: 0)?.lane, 0)
        XCTAssertEqual(layout.place(.top, textWidth: 10, now: 1)?.lane, 1)
        XCTAssertNil(layout.place(.top, textWidth: 10, now: 2))
        XCTAssertEqual(layout.place(.top, textWidth: 10, now: 4)?.lane, 0)
        XCTAssertEqual(layout.place(.bottom, textWidth: 10, now: 2)?.lane, 0, "bottom lanes are independent")
    }
}

final class PlayerInfoParsingTests: XCTestCase {
    func testSubtitlesAndChapters() throws {
        let info = try JSON(data: Data("""
        {"subtitle": {"subtitles": [
            {"lan": "ai-zh", "lan_doc": "中文（自动生成）", "subtitle_url": "//aisubtitle.hdslb.com/bfs/ai_subtitle/prod/1.json", "ai_type": 0, "type": 1},
            {"lan": "zh-CN", "lan_doc": "中文（中国）", "subtitle_url": "https://aisubtitle.hdslb.com/bfs/subtitle/2.json", "type": 0},
            {"lan": "en", "lan_doc": "English", "subtitle_url": ""}]},
         "view_points": [
            {"type": 2, "from": 0, "to": 75, "content": "开头"},
            {"type": 2, "from": 75, "to": 75, "content": "empty"},
            {"type": 2, "from": 75, "to": 300, "content": "正文"}]}
        """.utf8))
        let subs = API.subtitles(fromPlayerInfo: info)
        XCTAssertEqual(subs.map(\.language), ["ai-zh", "zh-CN"], "entries without a URL are dropped")
        XCTAssertEqual(subs.map(\.isAI), [true, false])
        XCTAssertEqual(subs[0].url.absoluteString, "https://aisubtitle.hdslb.com/bfs/ai_subtitle/prod/1.json")
        let chapters = API.chapters(fromPlayerInfo: info)
        XCTAssertEqual(chapters.map(\.title), ["开头", "正文"], "zero-length chapters are dropped")
        XCTAssertEqual(chapters.last?.to, 300)
    }
}
