@testable import BiliKit
import XCTest

final class ContentParsingTests: XCTestCase {
    func testSkipRangesFromClipsAndEpisodeFallback() {
        let clips = JSON([["clipType": "CLIP_TYPE_OP", "start": 23, "end": 45], ["clipType": "CLIP_TYPE_ED", "start": 1300, "end": 1390],
                          ["clipType": "CLIP_TYPE_OP", "start": 0, "end": 0]] as [Any])
        XCTAssertEqual(SkipRange.parse(clips: clips, skip: JSON(nil)),
                       [SkipRange(kind: .opening, start: 23, end: 45), SkipRange(kind: .ending, start: 1300, end: 1390)])
        let skip = JSON(["op": ["start": 10, "end": 100], "ed": ["start": 0, "end": 0]] as [String: Any])
        XCTAssertEqual(SkipRange.parse(clips: JSON(nil), skip: skip), [SkipRange(kind: .opening, start: 10, end: 100)],
                       "episode `skip` is the fallback; empty ranges dropped")
    }

    func testEpisodeVIPAndTrailer() {
        let vip = Episode(JSON(["id": 1, "title": "12", "long_title": "终章", "status": 13, "badge": "",
                                "badge_info": ["text": "会员"], "duration": 1_440_000] as [String: Any]))
        XCTAssertTrue(vip.isVIP)
        XCTAssertEqual(vip.badge, "会员")
        XCTAssertEqual(vip.duration, 1440)
        XCTAssertEqual(vip.displayTitle, "第12话 终章")
        let pv = Episode(JSON(["id": 2, "title": "PV1", "badge": "预告", "status": 2] as [String: Any]))
        XCTAssertTrue(pv.isTrailer)
        XCTAssertEqual(pv.displayTitle, "PV1")
    }

    func testSeason() {
        let s = Season(JSON([
            "season_id": 9, "title": "某番（僅限港澳台地區）", "type": 4, "evaluate": "e",
            "rating": ["score": 9.6],
            "episodes": [["id": 1, "title": "1"], ["id": 2, "title": "PV", "badge": "预告"], ["id": 3, "title": "2"]],
            "section": [["title": "PV&其他", "episodes": [["id": 4, "title": "预告", "badge": "预告"]]],
                        ["title": "SP", "episodes": [["id": 5, "title": "SP1"]]]],
            "user_status": ["follow": 1, "progress": ["last_ep_id": 3, "last_time": 300]],
            "publish": ["pub_time_show": "10月17日开播"],
            "areas": [["name": "日本"]],
        ] as [String: Any]))
        XCTAssertEqual(s.episodes.map(\.epID), [1, 3], "trailers removed from the main list")
        XCTAssertEqual(s.extras.map(\.title), ["SP"], "a section of only trailers disappears")
        XCTAssertTrue(s.isFollowing)
        XCTAssertEqual(s.lastEpisodeID, 3)
        XCTAssertEqual(s.lastTime, 300)
        XCTAssertTrue(s.isOversea)
        XCTAssertEqual(s.type, 4)
        XCTAssertEqual(s.publishText, "10月17日开播")
        XCTAssertEqual(s.areas, ["日本"])
        XCTAssertEqual(s.rating, 9.6)
    }

    func testSeasonItemPrefersHorizontalArtForBanner() {
        let item = SeasonItem(JSON(["season_id": 1, "title": "t", "cover": "//a/b.jpg", "ss_horizontal_cover": "http://a/h.jpg",
                                    "new_ep": ["index_show": "更新至第3话"]] as [String: Any]))
        XCTAssertEqual(item.cover, "https://a/b.jpg")
        XCTAssertEqual(item.horizontalCover, "https://a/h.jpg")
        XCTAssertEqual(item.subtitle, "更新至第3话")
    }

    func testCounts() {
        XCTAssertEqual(BiliText.count("1.2万"), 12000)
        XCTAssertEqual(BiliText.count("3亿"), 300_000_000)
        XCTAssertEqual(BiliText.count("987"), 987)
        XCTAssertEqual(BiliText.count("--"), 0)
        XCTAssertEqual(BiliText.count("10万+"), 0, "unparseable stays 0 rather than guessing")
    }

    func testSpaceUploadUsesLength() {
        let v = VideoItem(archive: JSON(["aid": 1, "bvid": "BV1", "title": "t", "length": "12:34", "play": 5, "created": 100] as [String: Any]))
        XCTAssertEqual(v.duration, 754)
        XCTAssertEqual(v.pubdate, 100)
    }

    func testCollectionAndCopyright() {
        let d = VideoDetail(JSON([
            "aid": 1, "bvid": "BV1", "copyright": 2,
            "ugc_season": ["title": "合集", "sections": [["episodes": [
                ["aid": 1, "bvid": "BV1", "cid": 11, "title": "一", "arc": ["pic": "//p/1.jpg", "duration": 60]],
                ["aid": 2, "bvid": "BV2", "cid": 22, "title": "二", "arc": ["pic": "//p/2.jpg", "duration": 90]],
            ]]]],
        ] as [String: Any]))
        XCTAssertEqual(d.copyright, 2)
        XCTAssertEqual(d.collection?.title, "合集")
        XCTAssertEqual(d.collection?.items.map(\.bvid), ["BV1", "BV2"])
        XCTAssertEqual(d.collection?.items.map(\.duration), [60, 90])
        XCTAssertEqual(d.collection?.items.last?.cover, "https://p/2.jpg")
    }
}
