@testable import BiliKit
import XCTest

@MainActor
final class FeedModelTests: XCTestCase {
    private func items(_ ids: ClosedRange<Int>) -> [VideoItem] {
        ids.map { VideoItem(aid: $0, bvid: "BV\($0)") }
    }

    func testRefreshThenPagingDeduplicates() async {
        let model = FeedModel { page in
            page == 1 ? (self.items(1 ... 10), true) : (self.items(8 ... 15), false)
        }
        await model.refresh()
        XCTAssertEqual(model.items.count, 10)
        XCTAssertEqual(model.phase, .loaded)
        await model.loadMore()
        XCTAssertEqual(model.items.map(\.aid), Array(1 ... 15))
        XCTAssertFalse(model.hasMore)
    }

    func testRemovedItemStaysGoneAcrossPages() async {
        let model = FeedModel { page in
            page == 1 ? (self.items(1 ... 5), true) : (self.items(3 ... 8), false)
        }
        await model.refresh()
        model.remove(id: VideoItem(aid: 4, bvid: "BV4").id)
        XCTAssertEqual(model.items.map(\.aid), [1, 2, 3, 5])
        await model.loadMore()
        XCTAssertEqual(model.items.map(\.aid), [1, 2, 3, 5, 6, 7, 8], "a later page must not bring it back")
    }

    func testEmptyPageStopsPaging() async {
        let model = FeedModel { page in page == 1 ? (self.items(1 ... 3), true) : ([], true) }
        await model.refresh()
        await model.loadMore()
        XCTAssertFalse(model.hasMore)
    }

    func testLoadMoreFinishingAfterRefreshIsDropped() async {
        var release: CheckedContinuation<Void, Never>?
        var requested: [Int] = []
        var refreshes = 0
        let model = FeedModel { page in
            requested.append(page)
            if page == 1 {
                refreshes += 1
                return (refreshes == 1 ? self.items(1 ... 10) : self.items(100 ... 105), true)
            }
            if requested.filter({ $0 == 2 }).count == 1 {
                await withCheckedContinuation { release = $0 } // hold the first page 2 until refresh is done
            }
            return (self.items(page * 1000 ... page * 1000 + 2), true)
        }
        await model.refresh()
        let staleLoad = Task { await model.loadMore() }
        while release == nil { await Task.yield() }
        await model.refresh()
        release?.resume()
        await staleLoad.value

        XCTAssertEqual(model.items.map(\.aid), Array(100 ... 105), "stale page 2 must not be appended")
        XCTAssertFalse(model.isLoadingMore)
        await model.loadMore()
        XCTAssertEqual(requested, [1, 2, 1, 2], "paging restarts at page 2 after a refresh")
        XCTAssertEqual(model.items.count, 9)
    }

    func testFirstLoadFailureShowsErrorAndRetryRecovers() async {
        var fail = true
        let model = FeedModel { _ in
            if fail { throw BiliError.http(500) }
            return (self.items(1 ... 2), false)
        }
        await model.refresh()
        guard case .failed = model.phase else { return XCTFail("expected failed phase") }
        fail = false
        await model.refresh()
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(model.items.count, 2)
    }

    func testRefreshFailureKeepsItemsAndAllowsPaging() async {
        var failRefresh = false
        let model = FeedModel { page in
            if page == 1, failRefresh { throw BiliError.http(500) }
            return (self.items(page * 10 ... page * 10 + 2), true)
        }
        await model.refresh()
        failRefresh = true
        await model.refresh()
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertNotNil(model.refreshError)
        XCTAssertEqual(model.items.count, 3)
        await model.loadMore()
        XCTAssertEqual(model.items.count, 6)
    }

    func testLoadMoreFailureSetsErrorAndRetryClearsIt() async {
        var failPage2 = true
        let model = FeedModel { page in
            if page == 2, failPage2 { throw BiliError.http(502) }
            return (self.items(page * 10 ... page * 10 + 2), true)
        }
        await model.refresh()
        await model.loadMore()
        XCTAssertNotNil(model.loadMoreError)
        // loadMoreIfNeeded must not hammer while the error is shown.
        await model.loadMoreIfNeeded(current: model.items.last!)
        XCTAssertEqual(model.items.count, 3)
        failPage2 = false
        await model.loadMore()
        XCTAssertNil(model.loadMoreError)
        XCTAssertEqual(model.items.count, 6)
    }

    func testCancelledFirstLoadReturnsToIdle() async {
        let model = FeedModel { _ in throw URLError(.cancelled) }
        await model.refresh()
        XCTAssertEqual(model.phase, .idle, "a cancelled load must retry on next appearance, not show an error")
    }
}
