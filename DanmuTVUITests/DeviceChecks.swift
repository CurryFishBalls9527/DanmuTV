import XCTest

/// Checks that need a real Apple TV with a signed-in account. Skipped unless `DEVICE_CHECKS=1`
/// (`TEST_RUNNER_DEVICE_CHECKS=1 xcodebuild test … -destination 'platform=tvOS,id=<UDID>' -only-testing:DanmuTVUITests/DeviceChecks`).
/// Screenshots end up in the result bundle; they show the account, so don't publish them.
final class DeviceChecks: RemoteTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DEVICE_CHECKS"] == "1", "device-only checks")
    }

    private var marker: XCUIElement { app.descendants(matching: .any)["player.state"] }

    private func state() -> [String: String] {
        let value = marker.exists ? marker.value as? String ?? "" : ""
        return Dictionary(value.split(separator: ";").compactMap { pair in
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            return kv.count == 2 ? (kv[0], kv[1]) : nil
        }, uniquingKeysWith: { $1 })
    }

    /// After the rename the saved login is adopted: 我的 shows the account, not the QR login.
    func testSignedInAfterRename() {
        launch("danmutv://tab/me", settle: 8)
        shot("device-me")
        XCTAssertFalse(app.staticTexts["扫码登录"].exists, "should still be signed in (no QR login)")
        XCTAssertFalse(app.staticTexts["欢迎使用 Danmu TV"].exists, "should show the account, not the welcome")
    }

    /// Signed in, comments page past the first 20 in the full list.
    func testCommentsPageWhenSignedIn() {
        launch("danmutv://video/BV17x411w7KC", settle: 9)
        for _ in 0 ..< 8 where !focusedLabel.contains("LV") { press(.down, wait: 1.2) }
        XCTAssertTrue(focusedLabel.contains("LV"), "comment shelf reached")
        for _ in 0 ..< 12 where focusedLabel != "全部评论" { press(.right, wait: 0.6) }
        XCTAssertEqual(focusedLabel, "全部评论", "signed in, the shelf ends with 全部评论")
        shot("device-comments-shelf")
        press(.select, wait: 4)
        var seen = Set<String>()
        for _ in 0 ..< 14 {
            seen.insert(focusedLabel)
            press(.down, wait: 1.2)
        }
        log("distinct comments visited: \(seen.count)")
        shot("device-comments-page2")
        XCTAssertGreaterThanOrEqual(seen.count, 13, "moved through rows on the second page")
    }

    /// Home screen after leaving the app: the new name, and Top Shelf (继续观看 when the icon is in the top row).
    func testHomeScreenAndTopShelf() {
        launch("danmutv://tab/recommend", settle: 6)
        XCUIRemote.shared.press(.home)
        sleep(4)
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "device-home"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// 弹幕防挡 workload for profiling: the masked, danmaku-dense video for 40 s with the mask on, then 40 s off.
    func testMaskPlaybackWorkload() {
        for maskOn in [true, false] {
            app.launchArguments = ["-muted", "YES", "-danmakuEnabled", "YES", "-danmakuMask", maskOn ? "YES" : "NO",
                                   "-startAt", "20", "-deeplink", "danmutv://play/BV1Lrpu61EPg?p=1"]
            app.launch()
            XCTAssertTrue(marker.waitForExistence(timeout: 20))
            sleep(10)
            log("mask \(maskOn ? "on" : "off") start at \(Date().timeIntervalSince1970): \(state())")
            shot("device-mask-\(maskOn ? "on" : "off")")
            sleep(30)
            log("mask \(maskOn ? "on" : "off") end at \(Date().timeIntervalSince1970): \(state())")
            if maskOn { XCTAssertGreaterThanOrEqual(Int(state()["mask"] ?? "") ?? -1, 0, "mask applied on device") }
            app.terminate()
            sleep(3)
        }
    }

    /// 画中画 (the simulator has no PiP): the system button (last in the transport bar's trailing row; AVKit's buttons
    /// aren't exposed to UI tests, so the row is walked by position) puts the player in a corner; it keeps playing
    /// while the app is browsed and after Home, and 全屏 brings it back.
    func testPictureInPicture() {
        app.launchArguments = ["-muted", "YES", "-deeplink", "danmutv://play/BV1vGp46bEdw?p=1"]
        app.launch()
        XCTAssertTrue(marker.waitForExistence(timeout: 20))
        sleep(8)
        press(.playPause, wait: 2)
        press(.up, wait: 1.5)
        press(.right, 8, wait: 0.6)
        shot("device-pip-button")
        press(.select, wait: 4)
        press(.playPause, wait: 3)
        let pos = Int(state()["pos"] ?? "") ?? 0
        shot("device-pip-corner")
        sleep(5)
        log("pip: \(state())")
        XCTAssertGreaterThan(Int(state()["pos"] ?? "") ?? 0, pos, "playing in the corner")
        XCUIRemote.shared.press(.home)
        sleep(5)
        let home = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        home.name = "device-pip-home"
        home.lifetime = .keepAlways
        add(home)
        app.activate()
        sleep(3)
        log("after home: \(state())")
    }
}
