@testable import BiliKit
import XCTest

final class ContinueWatchingTests: XCTestCase {
    private func entry(_ bvid: String, progress: Int, duration: Int = 600, business: String = "archive", epID: Int = 0,
                       seasonID: Int = 0) -> HistoryEntry {
        HistoryEntry(item: VideoItem(aid: 1, bvid: bvid, title: bvid, cover: "c", duration: duration, epID: epID),
                     progress: progress, viewAt: 0, business: business, seasonID: seasonID, subtitle: "s")
    }

    func testOnlyUnfinishedEntriesInOrder() {
        let history = [entry("BVa", progress: 120), entry("BVdone", progress: -1), entry("BVend", progress: 595),
                       entry("BVnew", progress: 0), entry("BVb", progress: 300)]
        let shelf = ContinueWatchingShelf.entries(from: history)
        XCTAssertEqual(shelf.map(\.bvid), ["BVa", "BVb"])
        XCTAssertEqual(shelf[0].progress, 0.2, accuracy: 0.001)
    }

    func testEpisodesLinkToTheirSeasonAndEpisode() {
        let ep = entry("BVep", progress: 100, business: "pgc", epID: 77, seasonID: 9)
        let shelf = ContinueWatchingShelf.entries(from: [ep])
        XCTAssertEqual(shelf.first?.openURL?.absoluteString, "danmutv://season/9")
        XCTAssertEqual(shelf.first?.playURL?.absoluteString, "danmutv://ep/77")
        let video = ContinueWatchingShelf.entries(from: [entry("BVv", progress: 100)]).first
        XCTAssertEqual(video?.openURL?.absoluteString, "danmutv://video/BVv")
        XCTAssertEqual(video?.playURL?.absoluteString, "danmutv://play/BVv")
    }

    func testRoundTripAndClear() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "test.continueWatching.\(UUID().uuidString)"))
        let shelf = ContinueWatchingShelf.entries(from: [entry("BVa", progress: 120)])
        ContinueWatchingShelf.save(shelf, to: defaults)
        XCTAssertEqual(ContinueWatchingShelf.load(from: defaults), shelf)
        ContinueWatchingShelf.save([], to: defaults)
        XCTAssertEqual(ContinueWatchingShelf.load(from: defaults), [])
    }

    func testLimit() {
        let history = (0 ..< 20).map { entry("BV\($0)", progress: 10) }
        XCTAssertEqual(ContinueWatchingShelf.entries(from: history, limit: 10).count, 10)
    }
}
