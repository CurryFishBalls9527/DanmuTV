import XCTest

/// Screenshots for README.md (logged out, muted). Run on purpose:
/// `TEST_RUNNER_SHOT_DIR=$PWD/docs/screenshots/raw xcodebuild test … -only-testing:DanmuTVUITests/ReadmeScreenshots`
/// (an absolute path: the runner's working directory isn't the repository). Blur commenters' names before publishing.
final class ReadmeScreenshots: RemoteTestCase {
    private func moveDown(until match: (String) -> Bool, limit: Int = 8) -> Bool {
        for _ in 0 ..< limit {
            if match(focusedLabel) { return true }
            press(.down, wait: 1.2)
        }
        return match(focusedLabel)
    }

    func testHomeAndBrowsing() {
        launch("danmutv://tab/recommend", settle: 10)
        press(.down, wait: 3)
        shot("home")
        press(.down, wait: 3)
        shot("home-shelves")
        press(.up, 3, wait: 1)
        for _ in 0 ..< 2 { press(.right, wait: 1.5) }
        press(.down, wait: 6)
        shot("ranking")
        press(.up, 3, wait: 1)
        for _ in 0 ..< 3 { press(.right, wait: 1.5) }
        press(.down, wait: 6)
        shot("live")
        press(.up, 3, wait: 1)
        press(.right, wait: 1.5)
        press(.down, wait: 6)
        shot("bangumi")
    }

    func testVideoPageAndComments() {
        launch("danmutv://video/BV17x411w7KC", settle: 9)
        shot("video")
        XCTAssertTrue(moveDown { $0.contains("LV") })
        sleep(2)
        shot("comments")
        press(.select, wait: 4)
        shot("comment-thread")
    }

    func testPlayerWithDanmaku() {
        app.launchArguments = ["-muted", "YES", "-danmakuMask", "YES", "-danmakuEnabled", "YES", "-startAt", "44",
                               "-deeplink", "danmutv://play/BV1Lrpu61EPg?p=1"]
        app.launch()
        sleep(12)
        shot("player-danmaku")
        press(.select, wait: 1.5)
        shot("player-controls")
    }

    func testLogin() {
        launch("danmutv://login", settle: 6)
        shot("login")
    }
}
