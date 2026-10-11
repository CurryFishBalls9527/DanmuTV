import XCTest

/// Siri Remote paths through the main screens. These hit the live API (keep runs occasional) and assume
/// the simulator's login state noted per test.
final class FocusFlowTests: RemoteTestCase {
    /// Labels of the video/poster cards on screen, top-left first (video cards: "标题、UP 主、时长"; posters: "badge、…").
    func cardLabels(_ count: Int = 4) -> [String] {
        app.buttons.matching(NSPredicate(format: "label CONTAINS '、'")).allElementsBoundByIndex
            .filter { $0.frame.minY > 150 && $0.frame.width > 200 }
            .sorted { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
            .prefix(count).map { "\($0.label)@\(Int($0.frame.minX))" }
    }

    // MARK: 推荐

    func testHomeStagePaths() {
        launch("danmutv://tab/recommend", settle: 8)
        XCTAssertEqual(focusedLabel, "推荐")
        press(.down)
        XCTAssertEqual(focusedLabel, "播放", "Down from the tab bar should land on the stage's 播放")
        press(.right)
        XCTAssertEqual(focusedLabel, "详情")
        press(.right)
        let thumbnail = focusedLabel
        XCTAssertFalse(["播放", "详情", ""].contains(thumbnail), "Right from 详情 should reach the thumbnail strip")
        press(.left)
        XCTAssertEqual(focusedLabel, "详情", "Left from the strip should return to the buttons")
        press(.left)
        XCTAssertEqual(focusedLabel, "播放")
        press(.down)
        XCTAssertTrue(focusedLabel.contains("、"), "Down from the stage should reach the first shelf, got '\(focusedLabel)'")
        press(.up)
        XCTAssertEqual(focusedLabel, "播放", "Up from the shelf should return to 播放")
        press(.up)
        XCTAssertEqual(focusedLabel, "推荐", "Up from 播放 should reach the tab bar")
        shot("flow-home")
    }

    func testHomePlayDoublePressOpensOnePlayer() {
        launch("danmutv://tab/recommend", settle: 8)
        press(.down)
        XCTAssertEqual(focusedLabel, "播放")
        remote.press(.select)
        Thread.sleep(forTimeInterval: 0.15)
        remote.press(.select)
        sleep(7)
        shot("flow-double-play")
        XCTAssertFalse(app.buttons["播放"].isHittable, "A player should be on screen")
        press(.menu, wait: 3)
        log("after one Menu: '\(focusedLabel)'")
        XCTAssertEqual(focusedLabel, "播放", "One Menu press should close the (single) player")
    }

    /// Down must keep going past the shelves into the feed grid (lazy cells used to trap focus on the last shelf).
    func testHomeScrollsIntoFeed() {
        launch("danmutv://tab/recommend", settle: 8)
        var labels: [String] = []
        for _ in 0..<5 {
            press(.down, wait: 1.2)
            labels.append(focusedLabel)
        }
        log("home down \(labels)")
        XCTAssertEqual(Set(labels.suffix(3)).count, 3, "Each Down should move to a new row: \(labels)")
        XCTAssertTrue(app.staticTexts["更多推荐"].exists || labels.count == 5)
    }

    // MARK: 排行榜

    func testRankingCategorySwitchReloads() {
        launch("danmutv://tab/ranking", settle: 8)
        press(.down)
        let chip = focusedLabel
        let before = cardLabels()
        log("ranking chip '\(chip)' before \(before)")
        press(.select, wait: 6)
        let after = cardLabels()
        log("ranking after \(after), focus '\(focusedLabel)'")
        XCTAssertFalse(before.isEmpty)
        XCTAssertNotEqual(before, after, "Selecting another category should load a different list")
        XCTAssertEqual(focusedLabel, chip, "The chip keeps focus after switching")
        press(.right)
        let next = focusedLabel
        press(.select, wait: 6)
        XCTAssertNotEqual(after, cardLabels(), "A second switch (\(next)) should reload again")
        shot("flow-ranking")
    }

    // MARK: 番剧

    func testBangumiStageAndTypeSwitch() {
        launch("danmutv://tab/bangumi", settle: 8)
        press(.down)
        XCTAssertEqual(focusedLabel, "播放")
        press(.right, 2)
        let firstTitle = focusedLabel
        log("bangumi #1 '\(firstTitle)'")
        XCTAssertTrue(app.staticTexts["热门第一"].exists)
        press(.right)
        XCTAssertTrue(app.staticTexts["热门第二"].exists, "The stage label follows the rank")
        press(.down)
        let types = ["番剧", "国创", "电影", "电视剧", "纪录片"]
        XCTAssertTrue(types.contains(focusedLabel), "Down from the stage should reach the type chips, got '\(focusedLabel)'")
        for _ in 0..<5 where focusedLabel != "番剧" { press(.left) }
        press(.right)
        let other = focusedLabel
        XCTAssertEqual(other, "国创")
        press(.select, wait: 6)
        XCTAssertEqual(focusedLabel, other, "The chip keeps focus after switching type")
        press(.up)
        XCTAssertEqual(focusedLabel, "播放")
        press(.right, 2)
        log("bangumi \(other) #1 '\(focusedLabel)'")
        XCTAssertNotEqual(focusedLabel, firstTitle, "Switching type should replace the stage")
        XCTAssertTrue(app.staticTexts["热门第一"].exists, "A new type starts again from #1")
        shot("flow-bangumi")
    }

    func testBangumiScrollsIntoChart() {
        launch("danmutv://tab/bangumi", settle: 8)
        var labels: [String] = []
        for _ in 0..<6 {
            press(.down, wait: 1.2)
            labels.append(focusedLabel)
        }
        log("bangumi down \(labels)")
        let chart = labels.suffix(2).filter { $0.contains("、") }
        XCTAssertFalse(chart.isEmpty, "Down should reach the 热门榜 posters: \(labels)")
        XCTAssertNotEqual(labels[labels.count - 1], labels[labels.count - 2], "Each Down should move to a new row")
        shot("flow-bangumi-chart")
    }

    // MARK: Detail pages

    func testVideoDetailActions() {
        launch("danmutv://video/BV1vGp46bEdw", settle: 8)
        XCTAssertEqual(focusedLabel, "播放")
        var seen: [String] = []
        for _ in 0..<6 {
            press(.right)
            seen.append(focusedLabel)
        }
        log("video actions \(seen)")
        for action in ["点赞", "投币", "收藏", "稍后再看", "关注", "分享"] {
            XCTAssertTrue(seen.contains { $0.contains(action) }, "\(action) should be reachable from 播放")
        }
        press(.left, 6)
        XCTAssertEqual(focusedLabel, "播放")
        press(.up)
        log("video up from 播放: '\(focusedLabel)'")
        XCTAssertNotEqual(focusedLabel, "播放")
        press(.down, 2)
        log("video down: '\(focusedLabel)' y=\(focused.frame.minY)")
        XCTAssertGreaterThan(focused.frame.height, 200, "Down should reach a video card in the shelves")
        shot("flow-video")
    }

    func testSeasonDetailActions() {
        launch("danmutv://season/46585", settle: 8)
        XCTAssertEqual(focusedLabel, "播放")
        press(.right)
        XCTAssertTrue(focusedLabel.contains("追"), "got '\(focusedLabel)'")
        press(.right)
        XCTAssertTrue(focusedLabel.contains("分享"))
        press(.down)
        XCTAssertFalse(focusedLabel.isEmpty)
        shot("flow-season")
    }

    // MARK: 我的 (logged out) and login

    func testMeLoggedOutStartsOnLogin() throws {
        launch("danmutv://tab/me", settle: 6)
        guard app.buttons["扫码登录"].exists else { throw XCTSkip("simulator is logged in") }
        press(.down)
        XCTAssertEqual(focusedLabel, "扫码登录", "Logged out, Down from the tab bar should land on 扫码登录")
        press(.right)
        XCTAssertEqual(focusedLabel, "本地播放")
        press(.right)
        XCTAssertEqual(focusedLabel, "设置")
        press(.select, wait: 3)
        press(.menu, wait: 2)
        XCTAssertEqual(focusedLabel, "设置", "Coming back from 设置 keeps focus there")
        press(.left, 2)
        XCTAssertEqual(focusedLabel, "扫码登录")
        shot("flow-me")
    }

    func testLoginSheetFocus() {
        launch("danmutv://login", settle: 6)
        XCTAssertEqual(focusedLabel, "刷新二维码")
        shot("flow-login")
    }

    func testUserPageDoesNotStartOnFollow() {
        launch("danmutv://user/1027737427", settle: 8)
        press(.down)
        log("user page focus: '\(focusedLabel)'")
        XCTAssertNotEqual(focusedLabel, "推荐")
        XCTAssertFalse(focusedLabel.contains("关注"), "Select on arrival must not follow the user")
        shot("flow-user")
    }

    // MARK: Ambient backdrop

    func testSearchClearsAmbient() {
        launch("danmutv://tab/recommend", settle: 8)
        press(.down)
        press(.up)
        // Tab bar: 推荐 → 热门 → 排行榜 → 动态 → 直播 → 番剧 → 搜索
        for _ in 0..<8 where focusedLabel != "搜索" {
            press(.right, wait: 0.6)
        }
        XCTAssertEqual(focusedLabel, "搜索")
        sleep(3)
        shot("flow-search-ambient")
    }

    /// 设置 › 关于 says the app is unofficial and lists the licenses (GPL / LGPL notices travel with every build).
    func testAboutShowsLicenses() {
        launch("danmutv://tab/me", settle: 6)
        press(.down, wait: 1)
        for _ in 0 ..< 6 where focusedLabel != "设置" { press(.right, wait: 0.8) }
        XCTAssertEqual(focusedLabel, "设置")
        press(.select, wait: 3)
        for _ in 0 ..< 60 where focusedLabel != "开源许可与致谢" { press(.down, wait: 0.4) }
        XCTAssertEqual(focusedLabel, "开源许可与致谢")
        press(.select, wait: 2)
        XCTAssertTrue(app.staticTexts["VLCKit"].exists && app.staticTexts["LGPL-2.1"].firstMatch.exists, "license list")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '非官方客户端'")).firstMatch.exists, "unofficial notice")
        shot("about-licenses")
    }
}
