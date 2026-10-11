@testable import BiliKit
import XCTest

final class AutoPlayTests: XCTestCase {
    func testAutoPlayPicksFirstUnplayedVideo() {
        var live = VideoItem(aid: 9, bvid: "BV9")
        live.liveRoomID = 5
        let related = [live, VideoItem(aid: 1, bvid: "BVcur"), VideoItem(aid: 2, bvid: "BV2"), VideoItem(aid: 3, bvid: "BV3")]
        XCTAssertEqual(AutoPlay.next(after: "BVcur", related: related, played: [])?.bvid, "BV2")
        XCTAssertEqual(AutoPlay.next(after: "BVcur", related: related, played: ["BV2"])?.bvid, "BV3")
        XCTAssertNil(AutoPlay.next(after: "BVcur", related: related, played: ["BV2", "BV3"]))
    }
}
