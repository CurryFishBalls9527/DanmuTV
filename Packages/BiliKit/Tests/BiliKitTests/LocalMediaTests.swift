@testable import BiliKit
import XCTest

final class SMBAddressTests: XCTestCase {
    func testParse() {
        XCTAssertEqual(SMBAddress.parse("nas.local")?.host, "nas.local")
        XCTAssertEqual(SMBAddress.parse(" SMB://NAS:445 \n").map { "\($0.host):\($0.port ?? 0)" }, "nas:445")
        XCTAssertEqual(SMBAddress.parse("192.168.1.10")?.host, "192.168.1.10")
        XCTAssertNil(SMBAddress.parse("nas.local/Movies"), "paths belong to shares/folders, not the server")
        XCTAssertNil(SMBAddress.parse("user@nas"))
        XCTAssertNil(SMBAddress.parse("http://nas"))
        XCTAssertNil(SMBAddress.parse(""))
        XCTAssertNil(SMBAddress.parse("nas:99999"))
    }

    func testMediaURLEncoding() {
        let url = SMBAddress.mediaURL(host: "nas", port: 445, share: "影视 库", path: "/动画/第1集 #1?.mkv")
        XCTAssertEqual(url?.absoluteString, "smb://nas:445/%E5%BD%B1%E8%A7%86%20%E5%BA%93/%E5%8A%A8%E7%94%BB/%E7%AC%AC1%E9%9B%86%20%231%3F.mkv")
        XCTAssertEqual(SMBAddress.serverURL(host: "nas", port: nil)?.absoluteString, "smb://nas")
    }
}

final class LocalListingTests: XCTestCase {
    func testVisibleFiltersAndSorts() {
        let raw = [
            LocalEntry(name: "第10集.mkv", path: "/a/第10集.mkv", isDirectory: false, size: 1),
            LocalEntry(name: "第2集.mkv", path: "/a/第2集.mkv", isDirectory: false, size: 1),
            LocalEntry(name: "封面.jpg", path: "/a/封面.jpg", isDirectory: false, size: 1),
            LocalEntry(name: "@eaDir", path: "/a/@eaDir", isDirectory: true, size: 0),
            LocalEntry(name: "$RECYCLE.BIN", path: "/a/$RECYCLE.BIN", isDirectory: true, size: 0),
            LocalEntry(name: ".hidden.mp4", path: "/a/.hidden.mp4", isDirectory: false, size: 1),
            LocalEntry(name: "特典", path: "/a/特典", isDirectory: true, size: 0),
        ]
        XCTAssertEqual(LocalListing.visible(raw).map(\.name), ["特典", "第2集.mkv", "第10集.mkv"])
    }
}

final class SidecarTests: XCTestCase {
    func testDanmakuMatching() {
        XCTAssertEqual(Sidecar.danmaku(for: "EP01.mkv", in: ["ep01.XML", "EP02.xml"]), "ep01.XML")
        XCTAssertEqual(Sidecar.danmaku(for: "EP01.mkv", in: ["EP01.xml", "EP01.danmaku.xml"]), "EP01.danmaku.xml", "specific name wins")
        XCTAssertEqual(Sidecar.danmaku(for: "EP01.mkv", in: ["EP01.cmt.xml"]), "EP01.cmt.xml")
        XCTAssertNil(Sidecar.danmaku(for: "EP01.mkv", in: ["EP011.xml"]))
    }

    func testSubtitleMatching() {
        XCTAssertEqual(Sidecar.subtitles(for: "Movie.mkv", in: ["Movie.srt", "Movie.zh.ass", "Movie2.srt", "Movie.nfo"]),
                       ["Movie.srt", "Movie.zh.ass"])
    }
}

final class LocalResumeTests: XCTestCase {
    func testStartPosition() {
        XCTAssertEqual(LocalResume.startPosition(saved: 120, length: 1000), 120)
        XCTAssertNil(LocalResume.startPosition(saved: 3, length: 1000))
        XCTAssertNil(LocalResume.startPosition(saved: 995, length: 1000), "at the end: start over")
        XCTAssertEqual(LocalResume.startPosition(saved: 120, length: 0), 120, "unknown length")
    }

    func testCompletion() {
        XCTAssertTrue(LocalResume.isCompletion(time: 995, length: 1000))
        XCTAssertFalse(LocalResume.isCompletion(time: 0, length: 1000), "ended right after opening = failure, not completion")
        XCTAssertFalse(LocalResume.isCompletion(time: 0, length: 0))
    }
}

final class MediaTimeSmootherTests: XCTestCase {
    func testQuantizedTimeBecomesSmoothAndMonotonic() {
        var s = MediaTimeSmoother()
        var out: [Double] = []
        // VLC reports 10.00 for 15 frames then 10.25…
        for frame in 0 ..< 60 {
            let reported = 10 + Double(frame / 15) * 0.25
            out.append(s.update(reported: reported, playing: true, rate: 1, elapsed: 1.0 / 60))
        }
        XCTAssertEqual(out, out.sorted(), "never goes backwards")
        XCTAssertGreaterThan(Set(out.map { ($0 * 1000).rounded() }).count, 30, "advances between samples")
        XCTAssertLessThan(out.last! - (10 + 0.75), 0.6, "stays close to reported time")
    }

    func testSeekSnapsAndPauseHolds() {
        var s = MediaTimeSmoother()
        _ = s.update(reported: 10, playing: true, rate: 1, elapsed: 0.016)
        XCTAssertEqual(s.update(reported: 300, playing: true, rate: 1, elapsed: 0.016), 300)
        let paused = s.update(reported: 300, playing: false, rate: 1, elapsed: 0.5)
        XCTAssertEqual(paused, 300)
    }
}
