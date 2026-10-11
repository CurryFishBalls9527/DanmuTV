@testable import BiliKit
import XCTest

final class SidxTests: XCTestCase {
    func testRealSidx() throws {
        // AVC 480p representation: index_range 1012-1547 (verified against Python parsing of the same bytes).
        let index = try SegmentIndex(data: Fixture.data("avc480.sidx"), boxEnd: 1547)
        XCTAssertEqual(index.timescale, 16000)
        XCTAssertEqual(index.segments.count, 42)
        XCTAssertEqual(index.segments[0], .init(offset: 1548, length: 349_141, duration: 5.0))
        XCTAssertEqual(index.segments[1].offset, 1548 + 349_141)
        XCTAssertEqual(index.totalDuration, 212.24, accuracy: 0.01)
        XCTAssertEqual(index.maxDuration, 7.24, accuracy: 0.001, "last segment is the longest")
        // Segments are contiguous.
        for (a, b) in zip(index.segments, index.segments.dropFirst()) {
            XCTAssertEqual(a.offset + a.length, b.offset)
        }
    }

    func testVersion1AndTrailingBytes() throws {
        var box = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.bigEndian) { box.append(contentsOf: $0) } }
        func u64(_ v: UInt64) { withUnsafeBytes(of: v.bigEndian) { box.append(contentsOf: $0) } }
        u32(0) // size, patched below
        box.append(contentsOf: Array("sidx".utf8))
        box.append(contentsOf: [1, 0, 0, 0]) // version 1
        u32(1) // reference id
        u32(1000) // timescale
        u64(0) // earliest pts
        u64(10) // first_offset
        box.append(contentsOf: [0, 0, 0, 2]) // reserved + count 2
        u32(100); u32(2000); u32(0)
        u32(200); u32(1500); u32(0)
        let size = UInt32(box.count)
        box.replaceSubrange(0 ..< 4, with: withUnsafeBytes(of: size.bigEndian) { Data($0) })
        let padded = box + Data([0xFF, 0xFF]) // range longer than the box
        let index = try SegmentIndex(data: padded, boxEnd: 999 + padded.count)
        // box occupies 1000 ..< 1000+size; segments start 10 bytes after it.
        XCTAssertEqual(index.segments.map(\.offset), [1000 + Int(size) + 10, 1000 + Int(size) + 110])
        XCTAssertEqual(index.segments.map(\.duration), [2.0, 1.5])
    }

    func testRejectsGarbage() {
        XCTAssertThrowsError(try SegmentIndex(data: Data("not a box at all".utf8), boxEnd: 15))
        XCTAssertThrowsError(try SegmentIndex(data: Data([0, 0, 0, 40] + Array("sidx".utf8)), boxEnd: 7))
    }
}

final class PlayInfoTests: XCTestCase {
    func info() throws -> PlayInfo {
        PlayInfo(try JSON(data: Fixture.data("playurl_dash.json")))
    }

    func testParsesRealPlayurl() throws {
        let info = try info()
        XCTAssertTrue(info.hasDash)
        XCTAssertEqual(info.videos.count, 6)
        XCTAssertEqual(info.audios.count, 3)
        XCTAssertTrue(info.dolbyAudios.isEmpty)
        XCTAssertNil(info.flacAudio)
        let avc = try XCTUnwrap(info.videos.first { $0.id == 32 && $0.codecID == 7 })
        XCTAssertEqual(avc.initRange, 0 ... 1011)
        XCTAssertEqual(avc.indexRange, 1012 ... 1547)
        XCTAssertEqual(avc.frameRate, 25)
        XCTAssertEqual(avc.urls.count, 2, "base + backup")
        XCTAssertEqual(info.qualityName(32), "清晰 480P")
    }

    func testFrameRateFormats() {
        XCTAssertEqual(DashStream.frameRate("30000/1001"), 29.97, accuracy: 0.001)
        XCTAssertEqual(DashStream.frameRate("59.940"), 59.94, accuracy: 0.001)
        XCTAssertEqual(DashStream.frameRate(""), 0)
    }
}

final class StreamSelectorTests: XCTestCase {
    func stream(_ id: Int, _ codec: Int, fps: Double = 30, bw: Int = 1000) -> DashStream {
        DashStream(id: id, codecs: codec == 7 ? "avc1.640033" : codec == 12 ? "hev1.1.6.L153.90" : "av01.0.13M.08",
                   codecID: codec, width: 1920, height: 1080, frameRate: fps, bandwidth: bw * id,
                   urls: ["https://upos-sz-mirrorcos.bilivideo.com/\(id)-\(codec).m4s"], initRange: 0 ... 99, indexRange: 100 ... 199)
    }

    func info(_ videos: [DashStream], dolby: Bool = false) -> PlayInfo {
        var info = PlayInfo(JSON([:] as [String: Any]))
        info.videos = videos
        info.audios = [
            DashStream(id: 30280, codecs: "mp4a.40.2", codecID: 0, width: 0, height: 0, frameRate: 0, bandwidth: 200_000,
                       urls: ["a"], initRange: 0 ... 1, indexRange: 2 ... 3),
            DashStream(id: 30232, codecs: "mp4a.40.2", codecID: 0, width: 0, height: 0, frameRate: 0, bandwidth: 100_000,
                       urls: ["b"], initRange: 0 ... 1, indexRange: 2 ... 3),
        ]
        if dolby {
            info.dolbyAudios = [DashStream(id: 30250, codecs: "ec-3", codecID: 0, width: 0, height: 0, frameRate: 0, bandwidth: 448_000,
                                           urls: ["d"], initRange: 0 ... 1, indexRange: 2 ... 3)]
        }
        return info
    }

    func testPrefersHEVCLadderBestFirst() throws {
        let i = info([stream(80, 7), stream(80, 12), stream(120, 12), stream(64, 12), stream(64, 7), stream(80, 13)])
        let s = try XCTUnwrap(StreamSelector.select(i, StreamPreferences()))
        XCTAssertEqual(s.videos.map(\.id), [120, 80, 64])
        XCTAssertTrue(s.videos.allSatisfy { $0.codecID == 12 })
        XCTAssertEqual(s.audio.id, 30280, "highest-bitrate AAC")
    }

    func testFallsBackToAVCWhenNoHEVC() throws {
        let s = try XCTUnwrap(StreamSelector.select(info([stream(80, 7), stream(64, 7)]), StreamPreferences(preferredCodec: 12)))
        XCTAssertEqual(s.videos.map(\.codecID), [7, 7])
    }

    func testUnsupportedAV1IsSkipped() {
        XCTAssertNil(StreamSelector.select(info([stream(127, 13)]), StreamPreferences(preferredCodec: 13, supportedCodecs: [7, 12])))
    }

    func testFiltersAndCaps() throws {
        let i = info([stream(116, 12, fps: 120), stream(80, 12), stream(120, 12), stream(125, 12)])
        let s = try XCTUnwrap(StreamSelector.select(i, StreamPreferences(maxQuality: 116, filterHighFramerate: true)))
        XCTAssertEqual(s.videos.map(\.id), [80], "4K capped, 120fps filtered, HDR excluded")
    }

    func testOnlyHighestAndManualQuality() throws {
        let i = info([stream(120, 12), stream(80, 12), stream(64, 12)])
        XCTAssertEqual(StreamSelector.select(i, StreamPreferences(onlyHighest: true))?.videos.map(\.id), [120])
        XCTAssertEqual(StreamSelector.select(i, StreamPreferences(manualQuality: 80))?.videos.map(\.id), [80])
        XCTAssertEqual(StreamSelector.select(i, StreamPreferences(manualQuality: 112))?.videos.map(\.id), [80], "nearest lower")
        XCTAssertEqual(StreamSelector.select(i, StreamPreferences(manualQuality: 16))?.videos.map(\.id), [120, 80, 64],
                       "no quality at or below the pick: stay adaptive")
    }

    func testDolbyAudioPreference() throws {
        let i = info([stream(80, 12)], dolby: true)
        XCTAssertEqual(StreamSelector.select(i, StreamPreferences())?.audio.codecs, "ec-3")
        XCTAssertEqual(StreamSelector.select(i, StreamPreferences(preferDolbyAudio: false))?.audio.id, 30280)
    }
}

final class HLSPlaylistTests: XCTestCase {
    func testMasterPlaylist() throws {
        let info = PlayInfo(try JSON(data: Fixture.data("playurl_dash.json")))
        let selection = try XCTUnwrap(StreamSelector.select(info, StreamPreferences(preferredCodec: 7)))
        let master = HLSPlaylist.master(selection, videoURI: { i, _ in "bilihls://v/\(i).m3u8" }, audioURI: { _ in "bilihls://a.m3u8" })
        XCTAssertTrue(master.hasPrefix("#EXTM3U\n#EXT-X-VERSION:7\n"))
        XCTAssertTrue(master.contains(#"#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud0""#))
        XCTAssertTrue(master.contains(#"CHANNELS="2""#))
        XCTAssertTrue(master.contains(#"URI="bilihls://a.m3u8""#))
        let inf = master.split(separator: "\n").filter { $0.hasPrefix("#EXT-X-STREAM-INF:") }
        XCTAssertEqual(inf.count, 2, "480P and 360P AVC")
        XCTAssertTrue(inf[0].contains(#"CODECS="avc1.64001F,mp4a.40.2""#))
        XCTAssertTrue(inf[0].contains("RESOLUTION=852x480"))
        XCTAssertTrue(inf[0].contains("FRAME-RATE=25.000"))
        let avg = selection.videos[0].bandwidth + selection.audio.bandwidth
        XCTAssertTrue(inf[0].contains("AVERAGE-BANDWIDTH=\(avg)"))
        XCTAssertTrue(inf[0].contains("BANDWIDTH=\(avg * 3 / 2)"))
        XCTAssertTrue(master.contains("\nbilihls://v/0.m3u8\n"))
    }

    func testMediaPlaylist() throws {
        let info = PlayInfo(try JSON(data: Fixture.data("playurl_dash.json")))
        let stream = try XCTUnwrap(info.videos.first { $0.id == 32 && $0.codecID == 7 })
        let index = try SegmentIndex(data: Fixture.data("avc480.sidx"), boxEnd: stream.indexRange.upperBound)
        let url = "https://cdn.example/v.m4s?a=1&b=2"
        let media = HLSPlaylist.media(stream, url: url, index: index)
        let lines = media.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines.contains("#EXT-X-TARGETDURATION:8"), "ceil of the 7.24s max segment")
        XCTAssertTrue(lines.contains(#"#EXT-X-MAP:URI="https://cdn.example/v.m4s?a=1&b=2",BYTERANGE="1012@0""#))
        XCTAssertEqual(lines.filter { $0.hasPrefix("#EXTINF:") }.count, 42)
        XCTAssertEqual(lines.filter { $0 == url }.count, 42)
        XCTAssertTrue(lines.contains("#EXT-X-BYTERANGE:349141@1548"))
        XCTAssertEqual(lines.last, "#EXT-X-ENDLIST")
    }
}

final class CDNTests: XCTestCase {
    func testPCDNDetection() {
        XCTAssertTrue(CDN.isPCDN("https://xy123x45x67x89xy.mcdn.bilivideo.cn:4483/upgcxcode/a.m4s"))
        XCTAssertTrue(CDN.isPCDN("https://123.45.67.89:8082/v1/resource/a.m4s"))
        XCTAssertTrue(CDN.isPCDN("https://abc.szbdyd.com/a.m4s"))
        XCTAssertFalse(CDN.isPCDN("https://upos-sz-mirrorcos.bilivideo.com/upgcxcode/a.m4s"))
        XCTAssertFalse(CDN.isPCDN("https://upos-hz-mirrorakam.akamaized.net/a.m4s"))
    }

    func testOrdering() {
        let urls = ["https://1.2.3.4:8082/a", "https://upos-sz-mirrorcos.bilivideo.com/a", "https://x.mcdn.bilivideo.cn/a"]
        XCTAssertEqual(CDN.ordered(urls, preferOfficial: false), urls)
        XCTAssertEqual(CDN.ordered(urls, preferOfficial: true).first, "https://upos-sz-mirrorcos.bilivideo.com/a")
    }
}

final class BVIDTests: XCTestCase {
    func testKnownPairs() {
        XCTAssertEqual(BVID.aid(from: "BV1GJ411x7h7"), 80_433_022)
        XCTAssertEqual(BVID.aid(from: "BV1VeHQ6tEaS"), 117_404_491_450_249)
        XCTAssertEqual(BVID.bvid(from: 80_433_022), "BV1GJ411x7h7")
        XCTAssertEqual(BVID.bvid(from: 117_404_491_450_249), "BV1VeHQ6tEaS")
        XCTAssertNil(BVID.aid(from: "BV1GJ411x7h"))
        XCTAssertNil(BVID.aid(from: "BV1GJ411x7h0"), "0 is not in the alphabet")
    }
}
