import XCTest

/// Player features driven by the remote (simulator; muted, closed after each test). State comes from the
/// player's DEBUG marker: "bvid=…;rate=…;status=…;boost=…" (boost = the last hold's rate).
final class PlayerFeatureTests: RemoteTestCase {
    private static let video = "BV1vGp46bEdw"

    private var marker: XCUIElement { app.descendants(matching: .any)["player.state"] }

    private func state() -> [String: String] {
        let value = marker.value as? String ?? ""
        return Dictionary(value.split(separator: ";").compactMap { pair in
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            return kv.count == 2 ? (kv[0], kv[1]) : nil
        }, uniquingKeysWith: { $1 })
    }

    private func waitForPlaying(timeout: TimeInterval = 25) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, state()["status"] != "playing" { Thread.sleep(forTimeInterval: 0.5) }
        XCTAssertEqual(state()["status"], "playing", "playback should start")
    }

    private func play(_ extra: [String] = []) {
        app.launchArguments = ["-muted", "YES", "-deeplink", "danmutv://play/\(Self.video)?p=1"] + extra
        app.launch()
        XCTAssertTrue(marker.waitForExistence(timeout: 15))
        waitForPlaying()
    }

    func testHoldSelectSpeedsUpAndReleaseRestores() {
        play()
        remote.press(.select, forDuration: 3)
        sleep(2)
        let s = state()
        log("after hold: \(s)")
        XCTAssertEqual(s["boost"], "2.0", "holding should play at 2×")
        XCTAssertEqual(s["rate"], "1.0", "release should return to 1×")
        XCTAssertEqual(s["status"], "playing", "the long press must not toggle pause")
        XCTAssertEqual(focusedLabel, "", "no control took focus")
    }

    func testHoldAtTwoTimesGoesToThree() {
        play(["-defaultSpeed", "2"])
        remote.press(.select, forDuration: 3)
        sleep(2)
        let s = state()
        log("after hold at 2×: \(s)")
        XCTAssertEqual(s["boost"], "3.0")
        XCTAssertEqual(s["rate"], "2.0", "back to the chosen 2×")
    }

    func testHoldWhilePausedDoesNothing() {
        play()
        press(.playPause, wait: 2)
        XCTAssertEqual(state()["status"], "paused")
        remote.press(.select, forDuration: 3)
        sleep(2)
        let s = state()
        log("hold while paused: \(s)")
        XCTAssertEqual(s["boost"], "0.0", "no boost while paused")
    }

    /// At the end of a single-part video the player moves on to a related one by itself.
    func testRelatedAutoplayAtEnd() {
        play(["-startAt", "85"])
        XCTAssertEqual(state()["bvid"], Self.video)
        shot("related-upnext")
        // 103 s video started at 85 s: it ends within ~20 s, then the next one loads.
        let moved = NSPredicate(format: "NOT (value CONTAINS %@)", "bvid=\(Self.video);")
        let result = XCTWaiter.wait(for: [expectation(for: moved, evaluatedWith: marker)], timeout: 45)
        log("now playing: \(state()["bvid"] ?? "-")")
        XCTAssertEqual(result, .completed, "the player should continue with a related video")
        shot("related-after")
    }

    /// 弹幕防挡: on a video with a person mask the danmaku mask follows the playhead (frame times advance with it).
    func testDanmakuMaskFollowsPlayback() {
        // Both settings forced on (an earlier run may have switched them off).
        app.launchArguments = ["-muted", "YES", "-danmakuMask", "YES", "-danmakuEnabled", "YES", "-startAt", "30", "-deeplink", "danmutv://play/BV1Lrpu61EPg?p=1"]
        app.launch()
        XCTAssertTrue(marker.waitForExistence(timeout: 15))
        waitForPlaying()
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, Int(state()["mask"] ?? "") ?? -1 < 0 { Thread.sleep(forTimeInterval: 0.5) }
        let first = Int(state()["mask"] ?? "") ?? -1
        let firstPos = Int(state()["pos"] ?? "") ?? 0
        log("mask frame \(first) ms at \(firstPos) s")
        XCTAssertGreaterThanOrEqual(first, 29_000, "a mask frame near the playhead is applied to the danmaku layer")
        shot("danmaku-mask")
        sleep(3)
        let later = Int(state()["mask"] ?? "") ?? -1
        XCTAssertGreaterThan(later, first + 1_500, "the mask moves with the video")
        XCTAssertLessThan(abs(later / 1000 - (Int(state()["pos"] ?? "") ?? 0)), 3, "and stays in sync with it")
    }
}
