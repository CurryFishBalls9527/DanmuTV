@testable import BiliKit
import XCTest

final class SigningTests: XCTestCase {
    let mixin = Signing.mixinKey(imgURL: "https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png",
                                 subURL: "https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png")

    func testMixinKey() {
        XCTAssertEqual(mixin, "ea1db124af3c7062474693fa704f4ff8")
    }

    func testWbiSignature() {
        let q = Signing.wbiSigned(["foo": "one one four", "bar": "五一四", "baz": "1919810", "x": "a!b'c(d)e*f"],
                                  mixinKey: mixin, timestamp: 1_702_204_169)
        XCTAssertEqual(q, "bar=%E4%BA%94%E4%B8%80%E5%9B%9B&baz=1919810&foo=one%20one%20four&wts=1702204169&x=abcdef&w_rid=b257789bd05ecf89447caafee185ac64")
    }

    func testAppSignature() {
        XCTAssertEqual(Signing.appSigned(["auth_code": "abc"], timestamp: 1_700_000_000),
                       "appkey=5ae412b53418aac5&auth_code=abc&local_id=0&mobi_app=iphone&ts=1700000000&sign=8c2e05445133d4d394a5566c3020853e")
    }
}

final class ParsingTests: XCTestCase {
    func testDurations() {
        XCTAssertEqual(BiliText.duration(JSON("1:02:03")), 3723)
        XCTAssertEqual(BiliText.duration(JSON("9:13")), 553)
        XCTAssertEqual(BiliText.duration(JSON(42)), 42)
    }

    func testText() {
        XCTAssertEqual(BiliText.plain("<em class=\"keyword\">进击</em> &amp; 巨人"), "进击 & 巨人")
        XCTAssertEqual(BiliText.imageURL("//i0.hdslb.com/a.jpg"), "https://i0.hdslb.com/a.jpg")
        XCTAssertEqual(BiliText.episodeID(fromURL: "https://www.bilibili.com/bangumi/play/ep3854819"), 3_854_819)
    }

    func testSearchShapedArchive() {
        let item = VideoItem(archive: JSON(["aid": 1, "bvid": "BV1", "title": "t", "duration": "3:00",
                                            "author": "up", "mid": 9, "play": "123", "video_review": 4] as [String: Any]))
        XCTAssertEqual(item.duration, 180)
        XCTAssertEqual(item.ownerName, "up")
        XCTAssertEqual(item.views, 123)
        XCTAssertEqual(item.danmaku, 4)
    }
}
