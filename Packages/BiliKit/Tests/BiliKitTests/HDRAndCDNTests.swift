@testable import BiliKit
import XCTest

private func v(_ id: Int, _ codecs: String, codecID: Int = 12, height: Int = 2160, bw: Int = 10_000_000) -> DashStream {
    DashStream(id: id, codecs: codecs, codecID: codecID, width: height * 16 / 9, height: height, frameRate: 60,
               bandwidth: bw, urls: ["https://upos-sz-mirrorcos.bilivideo.com/\(id).m4s?e=1&deadline=2"],
               initRange: 0 ... 9, indexRange: 10 ... 19)
}

private func a(_ id: Int, _ codecs: String, bw: Int = 192_000) -> DashStream {
    DashStream(id: id, codecs: codecs, codecID: 0, width: 0, height: 0, frameRate: 0, bandwidth: bw,
               urls: ["https://upos-sz-mirrorcos.bilivideo.com/a\(id).m4s"], initRange: 0 ... 9, indexRange: 10 ... 19)
}

private func info(videos: [DashStream], dolby: [DashStream] = [], atmos: Bool = false, flac: DashStream? = nil) -> PlayInfo {
    var i = PlayInfo(JSON([:] as [String: Any]))
    i.videos = videos
    i.audios = [a(30280, "mp4a.40.2")]
    i.dolbyAudios = dolby
    i.dolbyIsAtmos = atmos
    i.flacAudio = flac
    return i
}

final class HDRMappingTests: XCTestCase {
    /// Fallback heuristics only (used when the init segment can't be read); MP4InitTests cover the real path.
    func testFallbackCodecAndRangeMapping() {
        XCTAssertEqual(v(126, "dvh1.08.07").hlsVideo.codecs, "hvc1.2.4.L153.b0")
        XCTAssertEqual(v(126, "dvh1.08.07").hlsVideo.supplemental, "dvh1.08.07/db4h")
        XCTAssertEqual(v(126, "dvh1.08.07").hlsVideo.range, "HLG", "profile 8.4")
        XCTAssertEqual(v(126, "dvh1.08.06").hlsVideo.supplemental, "dvh1.08.06/db1p")
        XCTAssertEqual(v(126, "dvh1.08.06").hlsVideo.range, "PQ")
        XCTAssertEqual(v(126, "dvh1.05.06").hlsVideo.codecs, "dvh1.05.06", "profile 5 stays dvh1")
        XCTAssertNil(v(126, "dvh1.05.06").hlsVideo.supplemental)
        XCTAssertEqual(v(126, "dvh1.05.06").hlsVideo.range, "PQ")
        XCTAssertEqual(v(125, "hev1.2.4.L153.90").hlsVideo.range, "PQ", "HDR10")
        XCTAssertEqual(v(120, "hev1.1.6.L153.90").hlsVideo.range, "SDR")
    }
}

final class HDRSelectionTests: XCTestCase {
    let all = [v(126, "dvh1.08.07"), v(125, "hev1.2.4.L153.90"), v(120, "hev1.1.6.L153.90"),
               v(80, "hev1.1.6.L120.90", height: 1080), v(80, "avc1.640032", codecID: 7, height: 1080)]

    func testHDRRungOnTopOfSDRLadder() {
        let s = StreamSelector.select(info(videos: all), StreamPreferences(allowHDR: true, allowDolbyVision: true))!
        XCTAssertEqual(s.videos.map(\.id), [126, 120, 80], "DV preferred over HDR10, then the SDR HEVC ladder")
        XCTAssertTrue(s.hasHDR)
        let noDV = StreamSelector.select(info(videos: all), StreamPreferences(allowHDR: true, allowDolbyVision: false))!
        XCTAssertEqual(noDV.videos.map(\.id), [125, 120, 80])
        let sdr = StreamSelector.select(info(videos: all), StreamPreferences(allowHDR: false, allowDolbyVision: false))!
        XCTAssertEqual(sdr.videos.map(\.id), [120, 80])
        XCTAssertFalse(sdr.hasHDR)
    }

    func testCapAndManualQuality() {
        XCTAssertEqual(StreamSelector.select(info(videos: all), StreamPreferences(maxQuality: 80, allowHDR: true, allowDolbyVision: true))?
            .videos.map(\.id), [80], "capped below 4K: no HDR")
        XCTAssertEqual(StreamSelector.select(info(videos: all), StreamPreferences(allowHDR: true, allowDolbyVision: true, manualQuality: 125))?
            .videos.map(\.id), [125], "a manual HDR10 pick wins even when Dolby Vision is allowed")
        XCTAssertEqual(StreamSelector.select(info(videos: all), StreamPreferences(allowHDR: true, allowDolbyVision: false, manualQuality: 125))?
            .videos.map(\.id), [125])
        XCTAssertEqual(StreamSelector.select(info(videos: all), StreamPreferences(onlyHighest: true, allowHDR: true, allowDolbyVision: true))?
            .videos.map(\.id), [126, 120], "only-highest keeps the SDR fallback under HDR")
    }

    func testAudioChoice() {
        let dolby = [a(30250, "ec-3", bw: 640_000)]
        let flac = a(30251, "fLaC", bw: 1_000_000)
        let atmos = StreamSelector.select(info(videos: all, dolby: dolby, atmos: true, flac: flac), StreamPreferences(preferLosslessAudio: true))!
        XCTAssertEqual(atmos.audio.codecs, "ec-3")
        XCTAssertTrue(atmos.audioIsAtmos)
        let lossless = StreamSelector.select(info(videos: all, dolby: dolby, flac: flac),
                                             StreamPreferences(preferDolbyAudio: false, preferLosslessAudio: true))!
        XCTAssertEqual(lossless.audio.codecs, "fLaC")
        XCTAssertFalse(lossless.audioIsAtmos)
        let aac = StreamSelector.select(info(videos: all, dolby: dolby, flac: flac), StreamPreferences(preferDolbyAudio: false))!
        XCTAssertEqual(aac.audio.codecs, "mp4a.40.2")
    }

    func testMasterAttributes() {
        let s = StreamSelection(videos: [v(126, "dvh1.08.07"), v(120, "hev1.1.6.L153.90")], audio: a(30250, "ec-3"), audioIsAtmos: true)
        let master = HLSPlaylist.master(s, videoURI: { "v\($0)m\($1)" }, audioURI: { "am\($0)" })
        let inf = master.split(separator: "\n").filter { $0.hasPrefix("#EXT-X-STREAM-INF:") }
        XCTAssertTrue(inf[0].contains(#"CODECS="hvc1.2.4.L153.b0,ec-3""#))
        XCTAssertTrue(inf[0].contains(#"SUPPLEMENTAL-CODECS="dvh1.08.07/db4h""#))
        XCTAssertTrue(inf[0].contains("VIDEO-RANGE=HLG"))
        XCTAssertTrue(inf[1].contains("VIDEO-RANGE=SDR"))
        XCTAssertFalse(inf[1].contains("SUPPLEMENTAL"))
        XCTAssertTrue(master.contains(#"CHANNELS="16/JOC""#))
        XCTAssertTrue(master.contains(#"NAME="杜比全景声""#))
        let flac = HLSPlaylist.master(StreamSelection(videos: [v(80, "avc1.640032", codecID: 7)], audio: a(30251, "flac")),
                                      videoURI: { "v\($0)m\($1)" }, audioURI: { "am\($0)" })
        XCTAssertTrue(flac.contains(#"CODECS="avc1.640032,fLaC""#))
    }
}

final class CDNPolicyTests: XCTestCase {
    let official = "https://upos-sz-mirrorcos.bilivideo.com/upgcxcode/1/2/3.m4s?e=1&deadline=2&upsig=x"
    let akamai = "https://upos-hz-mirrorakam.akamaized.net/upgcxcode/1/2/3.m4s?e=1"
    let pcdn = "https://xy1x2x3x4xy.mcdn.bilivideo.cn:4483/upgcxcode/1/2/3.m4s?e=1"

    func testBlacklistAndBadHostsButNeverEmpty() {
        let p = CDNPolicy(blacklist: ["upos-sz-mirrorcos.bilivideo.com"])
        XCTAssertEqual(CDN.ordered([official, akamai], policy: p, badHosts: []), [akamai])
        XCTAssertEqual(CDN.ordered([official, akamai], policy: CDNPolicy(), badHosts: ["upos-hz-mirrorakam.akamaized.net"]), [official])
        XCTAssertEqual(CDN.ordered([official], policy: p, badHosts: []), [official], "everything blocked: keep the original")
    }

    func testRewriteKeepsQueryAndOriginalsAsFallback() {
        let p = CDNPolicy(rewriteHost: "upos-sz-mirrorali.bilivideo.com")
        let list = CDN.ordered([pcdn, official], policy: p, badHosts: [])
        XCTAssertEqual(list.first, "https://upos-sz-mirrorali.bilivideo.com/upgcxcode/1/2/3.m4s?e=1&deadline=2&upsig=x")
        XCTAssertEqual(Array(list.dropFirst()), [pcdn, official])
        XCTAssertEqual(CDN.ordered([pcdn], policy: p, badHosts: []), [pcdn], "PCDN URLs aren't rewritten")
    }

    func testAkamaiAndOfficialOrdering() {
        XCTAssertEqual(CDN.ordered([official, pcdn, akamai], policy: CDNPolicy(preferAkamai: true), badHosts: []), [akamai, official, pcdn])
        XCTAssertEqual(CDN.ordered([pcdn, official], policy: CDNPolicy(preferOfficial: true), badHosts: []), [official, pcdn])
    }

    func testCertificateErrorsDetected() {
        XCTAssertTrue(CDNHealth.isCertificateError(URLError(.serverCertificateUntrusted)))
        XCTAssertFalse(CDNHealth.isCertificateError(URLError(.timedOut)))
    }

    func testFastLoadUsesOneMirrorAndNoThumbnails() {
        let s = StreamSelection(videos: [v(80, "avc1", codecID: 7)], audio: a(30280, "mp4a.40.2"))
        var multi = s
        multi.videos[0].urls = [official, akamai]
        multi.audio.urls = [official, akamai]
        let fast = HLSSession(selection: multi, policy: CDNPolicy(), fastLoad: true) { _, _ in Data() }
        XCTAssertEqual(fast.mirrors, 1)
        let normal = HLSSession(selection: multi, policy: CDNPolicy(), fastLoad: false) { _, _ in Data() }
        XCTAssertEqual(normal.mirrors, 2)
    }
}

final class DisplayPlanTests: XCTestCase {
    func plan(_ mode: DisplayMatchMode, _ range: String = "SDR", fps: Double = 25, forced: Double = 0, sdr: Bool = false) -> DisplayPlan {
        DisplayPlan.make(mode: mode, contentRange: range, contentFrameRate: fps, forcedRefreshRate: forced, forceSDR: sdr)
    }

    func testModes() {
        XCTAssertEqual(plan(.off, "PQ"), DisplayPlan(automatic: false, manualRefreshRate: nil, manualRange: "SDR"))
        XCTAssertEqual(plan(.off, "PQ", forced: 59.94), DisplayPlan(automatic: false, manualRefreshRate: nil, manualRange: "SDR"),
                       "matching off never touches the TV, even with a forced rate")
        XCTAssertEqual(plan(.hdrOnly, "SDR", forced: 59.94).manualRefreshRate, nil, "HDR-only leaves SDR content alone")
        XCTAssertEqual(plan(.always, "PQ").automatic, true)
        XCTAssertEqual(plan(.hdrOnly, "SDR").automatic, false, "SDR content leaves the TV alone")
        XCTAssertEqual(plan(.hdrOnly, "HLG"), DisplayPlan(automatic: true, manualRefreshRate: nil, manualRange: "HLG"))
    }

    func testForcedRateAndSDR() {
        XCTAssertEqual(plan(.always, "PQ", forced: 59.94), DisplayPlan(automatic: false, manualRefreshRate: 59.94, manualRange: "PQ"))
        XCTAssertEqual(plan(.always, "PQ", forced: 59.94, sdr: true).manualRange, "SDR")
        XCTAssertEqual(plan(.always, "PQ", fps: 24, sdr: true), DisplayPlan(automatic: false, manualRefreshRate: 24, manualRange: "SDR"),
                       "force SDR still matches the frame rate")
        XCTAssertEqual(plan(.always, "SDR", fps: 29.412, sdr: true).manualRefreshRate, 29.97, "odd encoder rates snap to broadcast rates")
        XCTAssertEqual(plan(.hdrOnly, "PQ", sdr: true).automatic, false)
    }
}

final class MP4InitTests: XCTestCase {
    private func box(_ type: String, _ body: Data) -> Data {
        var d = Data()
        withUnsafeBytes(of: UInt32(8 + body.count).bigEndian) { d.append(contentsOf: $0) }
        d.append(contentsOf: Array(type.utf8))
        return d + body
    }

    /// ftyp + moov/trak/mdia/minf/stbl/stsd with one video sample entry and the given child boxes.
    private func initSegment(entry: String, children: [Data]) -> Data {
        let visualFields = Data(count: 78)
        let sampleEntry = box(entry, visualFields + children.reduce(Data(), +))
        let stsd = box("stsd", Data([0, 0, 0, 0, 0, 0, 0, 1]) + sampleEntry)
        let moov = box("moov", box("trak", box("mdia", box("minf", box("stbl", stsd)))))
        return box("ftyp", Data(Array("iso5".utf8)) + Data(count: 4)) + moov
    }

    private func dvcC(profile: Int, level: Int, compat: Int) -> Data {
        let b2 = UInt8((profile << 1) | (level >> 5)), b3 = UInt8(((level & 0x1F) << 3) | 0b101), b4 = UInt8(compat << 4)
        return box("dvcC", Data([1, 0, b2, b3, b4]) + Data(count: 19))
    }

    private func colr(transfer: UInt16) -> Data {
        var body = Data(Array("nclx".utf8))
        for v: UInt16 in [9, transfer, 9] { withUnsafeBytes(of: v.bigEndian) { body.append(contentsOf: $0) } }
        return box("colr", body + Data([0x80]))
    }

    private func hvcC(level: UInt8) -> Data {
        var body = Data(count: 23)
        body[0] = 1
        body[1] = 2 // Main 10
        body[12] = level
        return box("hvcC", body)
    }

    func testProfile84HLG() throws {
        let info = try XCTUnwrap(MP4Init.parse(initSegment(entry: "hvc1", children: [hvcC(level: 153), dvcC(profile: 8, level: 6, compat: 4), colr(transfer: 18)])))
        XCTAssertEqual(info.sampleEntry, "hvc1")
        XCTAssertEqual(info.dvProfile, 8)
        XCTAssertEqual(info.dvLevel, 6)
        XCTAssertEqual(info.dvCompatibility, 4)
        let hls = info.hls(fallbackCodecs: "dvh1.08.06")
        XCTAssertEqual(hls.codecs, "hvc1.2.4.L153.b0")
        XCTAssertEqual(hls.supplemental, "dvh1.08.06/db4h", "level 06 is 4K24; HLG comes from the compatibility id")
        XCTAssertEqual(hls.range, "HLG")
    }

    func testProfile81PQAt4K60() throws {
        let info = try XCTUnwrap(MP4Init.parse(initSegment(entry: "hev1", children: [hvcC(level: 156), dvcC(profile: 8, level: 9, compat: 1)])))
        let hls = info.hls(fallbackCodecs: "dvh1.08.09")
        XCTAssertEqual(hls.codecs, "hvc1.2.4.L156.b0", "base level comes from hvcC")
        XCTAssertEqual(hls.supplemental, "dvh1.08.09/db1p")
        XCTAssertEqual(hls.range, "PQ")
    }

    func testProfile5IsDolbyVisionOnly() throws {
        let info = try XCTUnwrap(MP4Init.parse(initSegment(entry: "dvh1", children: [dvcC(profile: 5, level: 6, compat: 0)])))
        let hls = info.hls(fallbackCodecs: "dvh1.05.06")
        XCTAssertEqual(hls.codecs, "dvh1.05.06")
        XCTAssertNil(hls.supplemental)
        XCTAssertEqual(hls.range, "PQ")
    }

    func testHDR10AndHLGFromColr() throws {
        let pq = try XCTUnwrap(MP4Init.parse(initSegment(entry: "hev1", children: [hvcC(level: 153), colr(transfer: 16)])))
        XCTAssertEqual(pq.hls(fallbackCodecs: "hev1.2.4.L153.90").range, "PQ")
        XCTAssertEqual(pq.hls(fallbackCodecs: "hev1.2.4.L153.90").codecs, "hev1.2.4.L153.90")
        let hlg = try XCTUnwrap(MP4Init.parse(initSegment(entry: "hev1", children: [colr(transfer: 18)])))
        XCTAssertEqual(hlg.hls(fallbackCodecs: "x").range, "HLG", "phone-shot HDR 真彩 is often HLG")
        let sdr = try XCTUnwrap(MP4Init.parse(initSegment(entry: "avc1", children: [colr(transfer: 1)])))
        XCTAssertEqual(sdr.hls(fallbackCodecs: "avc1").range, "SDR")
    }

    func testGarbageIsRejected() {
        XCTAssertNil(MP4Init.parse(Data("not an mp4".utf8)))
        XCTAssertNil(MP4Init.parse(Data()))
    }
}

final class CDNRewriteTests: XCTestCase {
    let official = "https://upos-sz-mirrorcos.bilivideo.com/upgcxcode/1/2/3.m4s?e=1"
    let akamai = "https://upos-hz-mirrorakam.akamaized.net/upgcxcode/1/2/3.m4s?e=1"
    let pcdn = "https://xy1x2xy.mcdn.bilivideo.cn:4483/upgcxcode/1/2/3.m4s?e=1"

    func testRewriteRespectsBlacklistAndBadHosts() {
        let target = "upos-sz-mirrorali.bilivideo.com"
        XCTAssertEqual(CDN.ordered([official], policy: CDNPolicy(rewriteHost: target, blacklist: [target]), badHosts: []), [official])
        XCTAssertEqual(CDN.ordered([official], policy: CDNPolicy(rewriteHost: target), badHosts: [target]), [official])
    }

    func testAkamaiPinsOnlyARealRewrite() {
        // Nothing rewritable (PCDN + a non-upos Akamai edge): no pinned rewrite, Akamai first.
        let edge = "https://cn-edge.akamaized.net/upgcxcode/1/2/3.m4s?e=1"
        XCTAssertEqual(CDN.ordered([pcdn, edge], policy: CDNPolicy(preferAkamai: true, rewriteHost: "x.bilivideo.com"), badHosts: []),
                       [edge, pcdn])
    }

    func testSuffixBlacklist() {
        XCTAssertEqual(CDN.ordered([pcdn, official], policy: CDNPolicy(blacklist: [".mcdn.bilivideo.cn"]), badHosts: []), [official])
        XCTAssertEqual(CDN.ordered([pcdn, official], policy: CDNPolicy(blacklist: ["*.mcdn.bilivideo.cn"]), badHosts: []), [official])
    }

    func testCertificateErrorCodes() {
        XCTAssertTrue(CDNHealth.isCertificateError(domain: NSURLErrorDomain, code: -1202))
        XCTAssertFalse(CDNHealth.isCertificateError(domain: NSURLErrorDomain, code: -1200), "generic TLS failure isn't a cert verdict")
        XCTAssertFalse(CDNHealth.isCertificateError(URLError(.secureConnectionFailed)))
        XCTAssertFalse(CDNHealth.isCertificateError(domain: "CoreMediaErrorDomain", code: -1202))
    }

    func testIFrameUsesLowestSDRWithRange() {
        let hdr = DashStream(id: 126, codecs: "dvh1.08.06", codecID: 12, width: 3840, height: 2160, frameRate: 24, bandwidth: 1,
                             urls: [official], initRange: 0 ... 9, indexRange: 10 ... 19)
        let sdr = DashStream(id: 80, codecs: "hev1.1.6.L120.90", codecID: 12, width: 1920, height: 1080, frameRate: 24, bandwidth: 1,
                             urls: [official], initRange: 0 ... 9, indexRange: 10 ... 19)
        let audio = DashStream(id: 30280, codecs: "mp4a.40.2", codecID: 0, width: 0, height: 0, frameRate: 0, bandwidth: 1,
                               urls: [official], initRange: 0 ... 9, indexRange: 10 ... 19)
        let onlyHDR = HLSSession(selection: StreamSelection(videos: [hdr], audio: audio), policy: CDNPolicy(), fastLoad: false) { _, _ in Data() }
        XCTAssertFalse(onlyHDR.masterPlaylist(scheme: "s").contains("I-FRAME"), "no SDR variant: no thumbnail stream")
        let both = HLSSession(selection: StreamSelection(videos: [hdr, sdr], audio: audio), policy: CDNPolicy(), fastLoad: true) { _, _ in Data() }
        let master = both.masterPlaylist(scheme: "s")
        let iframe = master.split(separator: "\n").first { $0.hasPrefix("#EXT-X-I-FRAME") }
        XCTAssertTrue(iframe?.contains("VIDEO-RANGE=SDR") == true)
        XCTAssertTrue(iframe?.contains("RESOLUTION=1920x1080") == true)
        let firstVariant = master.split(separator: "\n").first { $0.hasPrefix("s://play/v") }
        XCTAssertEqual(firstVariant, "s://play/v1m0.m3u8", "fast load starts on the 1080P SDR variant")
    }

    func testSingleMirrorPlaylistPointsAtTheHostThatAnswered() async throws {
        let sidx = Fixture.data("avc480.sidx")
        let v = DashStream(id: 32, codecs: "avc1", codecID: 7, width: 852, height: 480, frameRate: 25, bandwidth: 1,
                           urls: ["https://dead/v.m4s", "https://alive/v.m4s"], initRange: 0 ... 1011, indexRange: 1012 ... 1547)
        let a = DashStream(id: 30280, codecs: "mp4a.40.2", codecID: 0, width: 0, height: 0, frameRate: 0, bandwidth: 1,
                           urls: ["https://dead/a.m4s", "https://alive/a.m4s"], initRange: 0 ... 1011, indexRange: 1012 ... 1547)
        let session = HLSSession(selection: StreamSelection(videos: [v], audio: a), policy: CDNPolicy(), fastLoad: true) { url, _ in
            if url.host == "dead" { throw URLError(.timedOut) }
            return sidx
        }
        let playlist = try await session.mediaPlaylist(named: "v0m0")
        XCTAssertTrue(playlist.contains("https://alive/v.m4s"))
        XCTAssertFalse(playlist.contains("https://dead/"))
    }
}
