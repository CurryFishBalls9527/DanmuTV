@testable import BiliKit
import XCTest

private func stream(_ id: Int, _ codec: Int, fps: Double = 30, urls: [String]? = nil) -> DashStream {
    DashStream(id: id, codecs: codec == 7 ? "avc1.640033" : codec == 12 ? "hev1.1.6.L153.90" : "av01.0.13M.08",
               codecID: codec, width: 1920, height: 1080, frameRate: fps, bandwidth: 1000 * id,
               urls: urls ?? ["https://upos-sz-mirrorcos.bilivideo.com/\(id)-\(codec).m4s"],
               initRange: 0 ... 99, indexRange: 100 ... 199)
}

private func audio(_ codecs: String = "mp4a.40.2", urls: [String] = ["https://upos-sz-mirrorcos.bilivideo.com/a.m4s"]) -> DashStream {
    DashStream(id: 30280, codecs: codecs, codecID: 0, width: 0, height: 0, frameRate: 0, bandwidth: 200_000,
               urls: urls, initRange: 0 ... 99, indexRange: 100 ... 199)
}

private func info(_ videos: [DashStream], audios: [DashStream] = [audio()], dolby: [DashStream] = []) -> PlayInfo {
    var info = PlayInfo(JSON([:] as [String: Any]))
    info.videos = videos
    info.audios = audios
    info.dolbyAudios = dolby
    return info
}

final class SelectorCoverageTests: XCTestCase {
    func testPreferredHEVCLosesWhenItTopsOutLower() throws {
        // New upload: AVC already has 1080P, HEVC only 480P so far.
        let i = info([stream(80, 7), stream(64, 7), stream(32, 12), stream(16, 12)])
        let s = try XCTUnwrap(StreamSelector.select(i, StreamPreferences(preferredCodec: 12)))
        XCTAssertEqual(s.videos.map(\.codecID), [7, 7])
        XCTAssertEqual(s.videos.first?.id, 80)
    }

    func testPreferredHEVCWinsOnTie() throws {
        let s = try XCTUnwrap(StreamSelector.select(info([stream(80, 7), stream(80, 12)]), StreamPreferences(preferredCodec: 12)))
        XCTAssertEqual(s.videos.map(\.codecID), [12])
    }

    func testExplicitAVCPreferenceIsHonoured() throws {
        let s = try XCTUnwrap(StreamSelector.select(info([stream(120, 12), stream(80, 7)]), StreamPreferences(preferredCodec: 7)))
        XCTAssertEqual(s.videos.map(\.id), [80])
    }

    func testHighFrameRateFilterRemoves60fps() throws {
        let i = info([stream(116, 12, fps: 60), stream(80, 12, fps: 30), stream(74, 12, fps: 59.94)])
        XCTAssertEqual(StreamSelector.select(i, StreamPreferences(filterHighFramerate: true))?.videos.map(\.id), [80])
        XCTAssertEqual(StreamSelector.select(i, StreamPreferences())?.videos.map(\.id), [116, 80, 74])
    }

    func testManualQualityCombinedWithCapAndFilter() throws {
        let i = info([stream(120, 12), stream(116, 12, fps: 60), stream(80, 12), stream(64, 12)])
        let prefs = StreamPreferences(maxQuality: 116, filterHighFramerate: true, manualQuality: 120)
        XCTAssertEqual(StreamSelector.select(i, prefs)?.videos.map(\.id), [80], "cap and filter apply before the manual pick")
    }

    func testDolbyOnlyAudio() throws {
        let s = StreamSelector.select(info([stream(80, 12)], audios: [], dolby: [audio("ec-3")]), StreamPreferences())
        XCTAssertEqual(s?.audio.codecs, "ec-3")
        XCTAssertNil(StreamSelector.select(info([stream(80, 12)], audios: [], dolby: [audio("ec-3")]),
                                           StreamPreferences(preferDolbyAudio: false)),
                     "no AAC and Dolby disabled: nothing to play")
    }
}

final class RedundantMasterTests: XCTestCase {
    func testMirrorsDuplicateVariantsWithOwnAudioGroups() throws {
        let sel = StreamSelection(videos: [stream(80, 12), stream(64, 12)], audio: audio("ec-3"))
        let master = HLSPlaylist.master(sel, mirrors: 2, videoURI: { "v\($0)m\($1)" }, audioURI: { "am\($0)" })
        let lines = master.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.filter { $0.hasPrefix("#EXT-X-MEDIA:") }.count, 2)
        XCTAssertTrue(master.contains(#"GROUP-ID="aud1""#))
        XCTAssertTrue(master.contains(#"CHANNELS="6""#), "E-AC-3")
        XCTAssertTrue(master.contains(#"NAME="杜比音效""#))
        // Primary mirror's variants first, then the backups (HLS redundant streams).
        XCTAssertEqual(lines.filter { !$0.hasPrefix("#") }, ["v0m0", "v1m0", "v0m1", "v1m1"])
        let inf = lines.filter { $0.hasPrefix("#EXT-X-STREAM-INF:") }
        XCTAssertTrue(inf[0].contains(#"AUDIO="aud0""#))
        XCTAssertTrue(inf[2].contains(#"AUDIO="aud1""#))
    }
}

final class SidxEdgeCaseTests: XCTestCase {
    private func box(size: UInt32?, largesize: UInt64? = nil, referenceType: UInt32 = 0, trailing: Int = 0) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.bigEndian) { d.append(contentsOf: $0) } }
        func u64(_ v: UInt64) { withUnsafeBytes(of: v.bigEndian) { d.append(contentsOf: $0) } }
        u32(size ?? 0)
        d.append(contentsOf: Array("sidx".utf8))
        if let largesize { u64(largesize) }
        d.append(contentsOf: [0, 0, 0, 0]) // version 0
        u32(1)
        u32(1000)
        u32(0) // earliest pts
        u32(0) // first_offset
        d.append(contentsOf: [0, 0, 0, 1]) // count 1
        u32(referenceType << 31 | 500)
        u32(1000)
        u32(0)
        if size == nil, largesize != nil {
            d.replaceSubrange(8 ..< 16, with: withUnsafeBytes(of: UInt64(d.count).bigEndian) { Data($0) })
        }
        return d + Data(repeating: 0, count: trailing)
    }

    func testSizeZeroExtendsToEnd() throws {
        let data = box(size: 0)
        let index = try SegmentIndex(data: data, boxEnd: data.count - 1)
        XCTAssertEqual(index.segments.first?.offset, data.count)
    }

    func testLargeSizeTrimsTrailingBytes() throws {
        var data = box(size: 1, largesize: 0)
        let real = data.count
        data.replaceSubrange(8 ..< 16, with: withUnsafeBytes(of: UInt64(real).bigEndian) { Data($0) })
        data += Data(repeating: 0, count: 4)
        let index = try SegmentIndex(data: data, boxEnd: data.count - 1)
        XCTAssertEqual(index.segments.first?.offset, real, "segments start right after the box, not after the padding")
    }

    func testNestedReferenceThrows() {
        let data = box(size: nil, referenceType: 1)
        var sized = data
        sized.replaceSubrange(0 ..< 4, with: withUnsafeBytes(of: UInt32(data.count).bigEndian) { Data($0) })
        XCTAssertThrowsError(try SegmentIndex(data: sized, boxEnd: sized.count - 1)) { error in
            XCTAssertEqual(error as? SegmentIndex.ParseError, .nestedIndex)
        }
    }

    func testDeclaredSizeLargerThanDataThrows() {
        XCTAssertThrowsError(try SegmentIndex(data: box(size: 9999), boxEnd: 99))
    }
}

final class HLSSessionTests: XCTestCase {
    private actor Calls {
        var urls: [String] = []
        func add(_ u: String) { urls.append(u) }
    }

    private func sidxBytes() -> Data { Fixture.data("avc480.sidx") }

    private func selection(mirrors: [String]) -> StreamSelection {
        let v = DashStream(id: 32, codecs: "avc1.64001F", codecID: 7, width: 852, height: 480, frameRate: 25, bandwidth: 786_766,
                           urls: mirrors.map { "\($0)/v.m4s" }, initRange: 0 ... 1011, indexRange: 1012 ... 1547)
        let a = DashStream(id: 30280, codecs: "mp4a.40.2", codecID: 0, width: 0, height: 0, frameRate: 0, bandwidth: 200_000,
                           urls: mirrors.map { "\($0)/a.m4s" }, initRange: 0 ... 1011, indexRange: 1012 ... 1547)
        return StreamSelection(videos: [v], audio: a)
    }

    func testMirrorCountAndPerMirrorSegmentURLs() async throws {
        let sidx = sidxBytes()
        let session = HLSSession(selection: selection(mirrors: ["https://m0", "https://m1"]), preferOfficialCDN: false) { _, _ in sidx }
        XCTAssertEqual(session.mirrors, 2)
        let master = session.masterPlaylist(scheme: "bilihls")
        XCTAssertTrue(master.contains("bilihls://play/v0m1.m3u8"))
        XCTAssertTrue(master.contains("bilihls://play/am1.m3u8"))
        let m1 = try await session.mediaPlaylist(named: "v0m1")
        XCTAssertTrue(m1.contains("\nhttps://m1/v.m4s\n"))
        XCTAssertFalse(m1.contains("https://m0/"))
        let audio = try await session.mediaPlaylist(named: "am0")
        XCTAssertTrue(audio.contains("https://m0/a.m4s"))
    }

    func testSidxFetchedOncePerTrackAcrossMirrorsAndConcurrentRequests() async throws {
        let calls = Calls()
        let sidx = sidxBytes()
        let session = HLSSession(selection: selection(mirrors: ["https://m0", "https://m1"]), preferOfficialCDN: false) { url, _ in
            await calls.add(url.absoluteString)
            try await Task.sleep(nanoseconds: 20_000_000)
            return sidx
        }
        async let a = session.mediaPlaylist(named: "v0m0")
        async let b = session.mediaPlaylist(named: "v0m1")
        async let c = session.mediaPlaylist(named: "v0m0")
        _ = try await (a, b, c)
        let urls = await calls.urls
        XCTAssertEqual(urls.count, 1, "one sidx fetch for the video track")
    }

    func testFailsOverToNextMirrorAndRecordsHost() async throws {
        let calls = Calls()
        let sidx = sidxBytes()
        let session = HLSSession(selection: selection(mirrors: ["https://dead", "https://alive"]), preferOfficialCDN: false) { url, _ in
            await calls.add(url.host ?? "")
            if url.host == "dead" { throw URLError(.timedOut) }
            return sidx
        }
        let playlist = try await session.mediaPlaylist(named: "v0m0")
        XCTAssertTrue(playlist.contains("https://dead/v.m4s"), "mirror 0 playlist still points at mirror 0; AVPlayer fails over via redundancy")
        let urls = await calls.urls
        XCTAssertEqual(urls, ["dead", "alive"])
        XCTAssertEqual(session.hosts["v0"], "alive")
    }

    func testFailureIsNotCached() async throws {
        let calls = Calls()
        let sidx = sidxBytes()
        let session = HLSSession(selection: selection(mirrors: ["https://m0"]), preferOfficialCDN: false) { url, _ in
            await calls.add(url.absoluteString)
            if await calls.urls.count == 1 { throw URLError(.timedOut) }
            return sidx
        }
        do {
            _ = try await session.mediaPlaylist(named: "v0m0")
            XCTFail("first attempt should fail")
        } catch {
            XCTAssertNotNil(session.lastError)
        }
        _ = try await session.mediaPlaylist(named: "v0m0")
        let count = await calls.urls.count
        XCTAssertEqual(count, 2)
    }

    func testUnknownPlaylistNames() async {
        let session = HLSSession(selection: selection(mirrors: ["https://m0"]), preferOfficialCDN: false) { _, _ in Data() }
        for name in ["v9m0", "v0m5", "x", "vm"] {
            do {
                _ = try await session.mediaPlaylist(named: name)
                XCTFail("\(name) should not resolve")
            } catch {}
        }
    }

    func testMirrorsCappedAndPCDNOrderedLast() {
        let sel = selection(mirrors: ["https://1.2.3.4:8082", "https://upos-a.bilivideo.com", "https://upos-b.bilivideo.com", "https://upos-c.bilivideo.com"])
        let session = HLSSession(selection: sel, preferOfficialCDN: true) { _, _ in Data() }
        XCTAssertEqual(session.mirrors, HLSSession.maxMirrors)
    }
}

final class PlaybackPolicyTests: XCTestCase {
    func testResumeRules() {
        func resume(_ t: Double, lastCID: Int = 1, cid: Int = 1, duration: Double = 100, enabled: Bool = true) -> Double? {
            PlaybackPolicy.resumePosition(lastPlayTime: t, lastPlayCID: lastCID, cid: cid, duration: duration, enabled: enabled)
        }
        XCTAssertEqual(resume(30), 30)
        XCTAssertNil(resume(5), "records of 5s or less don't count")
        XCTAssertNil(resume(96), "at the very end: start over")
        XCTAssertNil(resume(30, lastCID: 2), "history belongs to another page")
        XCTAssertEqual(resume(30, lastCID: 0), 30, "server didn't say which page")
        XCTAssertNil(resume(30, enabled: false))
        XCTAssertEqual(resume(30, duration: 0), 30, "unknown duration")
    }

    func testResumePage() {
        let pages = (1 ... 3).map { VideoPage(cid: $0 * 10, page: $0, part: "P\($0)", duration: 60) }
        XCTAssertEqual(PlaybackPolicy.resumePage(lastPlayCID: 30, pages: pages, current: 0), 2)
        XCTAssertNil(PlaybackPolicy.resumePage(lastPlayCID: 10, pages: pages, current: 0))
        XCTAssertNil(PlaybackPolicy.resumePage(lastPlayCID: 99, pages: pages, current: 0))
        XCTAssertNil(PlaybackPolicy.resumePage(lastPlayCID: 0, pages: pages, current: 0))
    }

    func testReportInterval() {
        XCTAssertTrue(PlaybackPolicy.shouldReport(second: 15, lastReported: -1, interval: 15, isPlaying: true))
        XCTAssertFalse(PlaybackPolicy.shouldReport(second: 20, lastReported: 15, interval: 15, isPlaying: true))
        XCTAssertTrue(PlaybackPolicy.shouldReport(second: 30, lastReported: 15, interval: 15, isPlaying: true))
        XCTAssertTrue(PlaybackPolicy.shouldReport(second: 3, lastReported: 15, interval: 15, isPlaying: true), "seeked back")
        XCTAssertFalse(PlaybackPolicy.shouldReport(second: 30, lastReported: 15, interval: 15, isPlaying: false))
        XCTAssertFalse(PlaybackPolicy.shouldReport(second: 0, lastReported: -1, interval: 15, isPlaying: true))
    }

    func testUpNext() {
        XCTAssertTrue(PlaybackPolicy.isUpNext(position: 92, duration: 100, hasNext: true, autoPlay: true, leadTime: 10))
        XCTAssertFalse(PlaybackPolicy.isUpNext(position: 80, duration: 100, hasNext: true, autoPlay: true, leadTime: 10))
        XCTAssertFalse(PlaybackPolicy.isUpNext(position: 95, duration: 100, hasNext: false, autoPlay: true, leadTime: 10))
        XCTAssertFalse(PlaybackPolicy.isUpNext(position: 95, duration: 100, hasNext: true, autoPlay: false, leadTime: 10))
        XCTAssertFalse(PlaybackPolicy.isUpNext(position: 95, duration: .nan, hasNext: true, autoPlay: true, leadTime: 10))
    }

    func testPCDNPorts() {
        XCTAssertFalse(CDN.isPCDN("https://upos-sz-mirrorcos.bilivideo.com:443/a"))
        XCTAssertFalse(CDN.isPCDN("not a url"))
        XCTAssertTrue(CDN.isPCDN("https://upos-sz-mirrorcos.bilivideo.com:4483/a"))
    }
}

final class IFrameStreamTests: XCTestCase {
    func testLowestVariantAdvertisedAsIFrameStream() {
        let sel = StreamSelection(videos: [stream(80, 12), stream(16, 12)], audio: audio())
        let master = HLSPlaylist.master(sel, mirrors: 2, iFrameVariant: 1, videoURI: { "v\($0)m\($1)" }, audioURI: { "am\($0)" })
        let line = master.split(separator: "\n").first { $0.hasPrefix("#EXT-X-I-FRAME-STREAM-INF:") }
        XCTAssertNotNil(line)
        XCTAssertTrue(line!.contains(#"URI="v1m0""#))
        XCTAssertTrue(line!.contains(#"CODECS="hev1.1.6.L153.90""#), "video codec only")
        XCTAssertFalse(HLSPlaylist.master(sel, videoURI: { "v\($0)m\($1)" }, audioURI: { "am\($0)" }).contains("I-FRAME"))
    }
}
