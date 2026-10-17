@testable import BiliKit
import XCTest

/// Input from the network (cast senders on the LAN, media files) and ordering edge cases that must not crash or lose data.
final class HardeningTests: XCTestCase {
    func testIntFromHostileStrings() {
        XCTAssertNil(JSON("1e300").int)
        XCTAssertNil(JSON("nan").int)
        XCTAssertNil(JSON("-inf").int)
        XCTAssertEqual(JSON("12.9").int, 12)
        XCTAssertEqual(JSON("42").int, 42)
    }

    func testCastTimesFromHostileStrings() {
        XCTAssertNil(SOAP.seconds(fromTime: "nan"))
        XCTAssertNil(SOAP.seconds(fromTime: "1e300"))
        XCTAssertNil(SOAP.seconds(fromTime: "-5"))
        XCTAssertEqual(SOAP.seconds(fromTime: "01:02:03"), 3723)
        XCTAssertEqual(SOAP.time(1e300), "277777:46:40")
        XCTAssertEqual(SOAP.time(.nan), "00:00:00")
    }

    func testCastStartAtFromHostileJSON() {
        XCTAssertEqual(CastRequest.parse(JSON(["aid": 1, "cid": 2, "seekTs": 1e300] as [String: Any]))?.startAt, 0)
        XCTAssertEqual(CastRequest.parse(JSON(["aid": 1, "cid": 2, "seekTs": 30] as [String: Any]))?.startAt, 30)
    }

    func testNvaExtIsNotEchoed() {
        let uri = "http://example.com/a.mp4?x=1&_nva_ext_=SECRET&y=2"
        let redacted = SOAP.redactingNvaExt(uri: uri)
        XCTAssertFalse(redacted.contains("SECRET"))
        XCTAssertTrue(redacted.contains("x=1") && redacted.contains("y=2"))
        XCTAssertEqual(SOAP.redactingNvaExt(uri: "bilibili://projection"), "bilibili://projection")

        let didl = #"<DIDL-Lite><item><dc:title>t</dc:title><upnp:longDescription>SECRET</upnp:longDescription></item></DIDL-Lite>"#
        let plain = SOAP.redactingNvaExt(metadata: didl)
        XCTAssertFalse(plain.contains("SECRET"))
        XCTAssertTrue(plain.contains("<dc:title>t</dc:title>"))
        let escaped = SOAP.redactingNvaExt(metadata: SOAP.escape(didl))
        XCTAssertFalse(escaped.contains("SECRET"))
        XCTAssertTrue(escaped.contains("&lt;dc:title&gt;t&lt;/dc:title&gt;"))
    }

    func testNvaExtRemovedEvenWhereStructureDoesNotHelp() {
        // URLComponents rejects this (a space and a raw "|"): the key must still not come back.
        let broken = "http://example.com/a b|c?x=1&_nva_ext_=SECRET"
        XCTAssertFalse(SOAP.redactingNvaExt(uri: broken).contains("SECRET"))
        XCTAssertFalse(SOAP.redactingNvaExt(uri: "http://e.com/?nva_ext=SECRET").contains("SECRET"))
        XCTAssertFalse(SOAP.redactingNvaExt(uri: "http://e.com/?%5Fnva%5Fext%5F=SECRET").contains("SECRET"))

        // The same URI repeated in <res>, plain and entity-escaped.
        let didl = #"<DIDL-Lite><item><res protocolInfo="http-get:*:video/mp4:*">http://e.com/a.mp4?_nva_ext_=SECRET&amp;y=2</res></item></DIDL-Lite>"#
        let plain = SOAP.redactingNvaExt(metadata: didl)
        XCTAssertFalse(plain.contains("SECRET"))
        XCTAssertTrue(plain.contains("y=2"))
        XCTAssertFalse(SOAP.redactingNvaExt(metadata: SOAP.escape(didl)).contains("SECRET"))
    }

    func testMP4LargesizeOverflowDoesNotTrap() {
        var data = Data([0, 0, 0, 1]) + Data("moov".utf8)
        data += Data([0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        data += Data(count: 16)
        XCTAssertTrue(MP4Init.boxes(in: data, range: 0 ..< data.count).isEmpty)
    }

    /// Resumed late in the video, then seeked back: an early segment's repeats stay in that segment.
    func testEarlierSegmentLoadedLaterIsNotMergedForward() {
        var t = DanmakuTimeline()
        t.add([Danmaku(id: 10, time: 1860, mode: .scroll, text: "哈哈哈")], segment: 6, mergeWindow: 15)
        t.add([Danmaku(id: 1, time: 5, mode: .scroll, text: "哈哈哈")], segment: 1, mergeWindow: 15)
        XCTAssertEqual(t.items.map(\.id), [1, 10])
        XCTAssertEqual(t.items.map(\.count), [1, 1])
    }
}

@MainActor
final class FeedRefreshRaceTests: XCTestCase {
    /// A load-more while a refresh of a shown list is in flight would page off the old list (skipping page 2 after
    /// the refresh, or moving a cursor past it).
    func testNoLoadMoreDuringRefresh() async {
        var hold: CheckedContinuation<Void, Never>?
        var requested: [Int] = []
        var refreshes = 0
        let model = FeedModel { page in
            requested.append(page)
            if page == 1 {
                refreshes += 1
                if refreshes == 2 { await withCheckedContinuation { hold = $0 } }
                return ((1 ... 10).map { VideoItem(aid: $0, bvid: "BV\($0)") }, true)
            }
            return ((page * 100 ... page * 100 + 2).map { VideoItem(aid: $0, bvid: "BV\($0)") }, true)
        }
        await model.refresh()
        let refresh = Task { await model.refresh() }
        while hold == nil { await Task.yield() }
        await model.loadMore()
        hold?.resume()
        await refresh.value
        await model.loadMore()
        XCTAssertEqual(requested, [1, 1, 2])
        XCTAssertEqual(model.items.map(\.aid), Array(1 ... 10) + [200, 201, 202])
    }

    /// History hides live / article entries: a page of only those isn't the end of the list.
    func testFilteredEmptyPagesAreSkipped() async {
        let model = FeedModel { page in
            switch page {
            case 1, 2: return ([], true)
            case 3: return ([VideoItem(aid: 1, bvid: "BV1")], true)
            case 4: return ([], true)
            default: return ([VideoItem(aid: page, bvid: "BV\(page)")], false)
            }
        }
        await model.refresh()
        XCTAssertEqual(model.items.map(\.aid), [1], "page 1 empty after filtering must not read as 还没有记录")
        await model.loadMore()
        XCTAssertEqual(model.items.map(\.aid), [1, 5])
        XCTAssertFalse(model.hasMore)
    }
}
