@testable import BiliKit
import XCTest

final class ClientTests: XCTestCase {
    func testCancellationClassification() {
        XCTAssertTrue(BiliClient.isCancellation(CancellationError()))
        XCTAssertTrue(BiliClient.isCancellation(URLError(.cancelled)))
        XCTAssertFalse(BiliClient.isCancellation(URLError(.timedOut)))
        XCTAssertFalse(BiliClient.isTransient(URLError(.cancelled)))
    }

    func testRetryPolicy() {
        XCTAssertTrue(BiliClient.isTransient(URLError(.timedOut)))
        XCTAssertTrue(BiliClient.isTransient(URLError(.networkConnectionLost)))
        XCTAssertTrue(BiliClient.isTransient(BiliError.http(503)))
        // Risk control: retrying only extends the lockout.
        XCTAssertFalse(BiliClient.isTransient(BiliError.http(412)))
        XCTAssertFalse(BiliClient.isTransient(BiliError.api(code: -352, message: "")))
        XCTAssertFalse(BiliClient.isTransient(BiliError.http(404)))
    }

    func testCookiesOnlyGoToBilibili() {
        XCTAssertTrue(BiliClient.sendsCookies(to: URL(string: "https://api.bilibili.com/x/nav")))
        XCTAssertTrue(BiliClient.sendsCookies(to: URL(string: "https://passport.bilibili.com/x")))
        XCTAssertFalse(BiliClient.sendsCookies(to: URL(string: "https://i0.hdslb.com/bfs/a.jpg")))
        XCTAssertFalse(BiliClient.sendsCookies(to: URL(string: "https://upos-sz-mirrorcos.bilivideo.com/x.m4s")))
        XCTAssertFalse(BiliClient.sendsCookies(to: URL(string: "https://evilbilibili.com/")))
    }

    func testRiskControlMessages() {
        XCTAssertTrue(BiliError.http(412).errorDescription!.contains("风控"))
        XCTAssertTrue(BiliError.api(code: -352, message: "").errorDescription!.contains("风控"))
        XCTAssertEqual(BiliError.api(code: 62002, message: "稿件不可见").errorDescription, "稿件不可见 (62002)")
    }
}

final class QueryEncodingTests: XCTestCase {
    func testSortedAndRFC3986Encoded() {
        XCTAssertEqual(Signing.query(["b": "a b", "a": "x&y=z", "c": "~-._"]), "a=x%26y%3Dz&b=a%20b&c=~-._")
        XCTAssertEqual(Signing.query([:]), "")
        XCTAssertEqual(Signing.query(["k": "中"]), "k=%E4%B8%AD")
    }
}

final class DetailParsingTests: XCTestCase {
    func testVideoDetail() throws {
        let json = try JSON(data: Data("""
        {"aid": 80433022, "bvid": "BV1GJ411x7h7", "cid": 137649199, "title": "Never Gonna Give You Up",
         "pic": "http://i0.hdslb.com/a.jpg", "duration": 213, "desc": "d", "tname": "音乐",
         "owner": {"mid": 1, "name": "up", "face": "//i0.hdslb.com/f.jpg"},
         "stat": {"view": 100, "danmaku": 2, "like": 3, "coin": 4, "favorite": 5, "reply": 6, "share": 7},
         "pages": [{"cid": 137649199, "page": 1, "part": "P1", "duration": 213},
                   {"cid": 2, "page": 2, "part": "P2", "duration": 10}],
         "is_upower_exclusive": true,
         "redirect_url": "https://www.bilibili.com/bangumi/play/ep123"}
        """.utf8))
        let d = VideoDetail(json)
        XCTAssertEqual(d.item.bvid, "BV1GJ411x7h7")
        XCTAssertEqual(d.item.cover, "https://i0.hdslb.com/a.jpg")
        XCTAssertEqual(d.item.ownerFace, "https://i0.hdslb.com/f.jpg")
        XCTAssertEqual(d.pages.map(\.cid), [137_649_199, 2])
        XCTAssertEqual([d.likes, d.coins, d.favorites, d.replies, d.shares], [3, 4, 5, 6, 7])
        XCTAssertTrue(d.isChargeOnly)
        XCTAssertEqual(d.redirectEpID, 123)
    }

    func testFeedItemWithStringNumbersAndMissingFields() throws {
        let json = try JSON(data: Data(#"{"id": "42", "goto": "av", "stat": {"view": "1000"}}"#.utf8))
        let item = VideoItem(archive: json)
        XCTAssertEqual(item.aid, 42)
        XCTAssertEqual(item.views, 1000)
        XCTAssertEqual(item.id, "av42")
        XCTAssertEqual(item.title, "")
    }
}
