import XCTest

/// Card long-press menu (稍后再看 / 不感兴趣 / UP 主页). The simulator is logged out; account-backed parts are checked on device.
final class CardMenuTests: RemoteTestCase {
    /// Focus the first card of the feed grid below the stage and shelves.
    private func focusFeedCard() {
        launch("danmutv://tab/recommend", settle: 8)
        for _ in 0..<3 { press(.down, wait: 1.2) }
    }

    private func element(_ label: String) -> XCUIElement {
        app.descendants(matching: .any)[label]
    }

    func testCardMenuOffersActions() {
        focusFeedCard()
        let card = focusedLabel
        log("card: '\(card)'")
        remote.press(.select, forDuration: 1.5)
        sleep(2)
        shot("card-menu")
        XCTAssertTrue(element("稍后再看").exists)
        XCTAssertTrue(element("不感兴趣").exists, "the home feed offers 不感兴趣")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'UP 主'")).firstMatch.exists,
                      "the uploader's page")
    }

    func testCardMenuOpensUploaderPage() {
        focusFeedCard()
        remote.press(.select, forDuration: 1.5)
        sleep(2)
        let up = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'UP 主'")).firstMatch
        XCTAssertTrue(up.exists)
        let name = up.label.replacingOccurrences(of: "UP 主：", with: "")
        // 稍后再看 / 不感兴趣 / UP 主: the third item.
        press(.down, 2)
        press(.select, wait: 5)
        shot("card-menu-up")
        log("uploader '\(name)' page shown: \(app.staticTexts[name].exists)")
        XCTAssertTrue(app.staticTexts[name].exists, "the UP page should open")
    }

    func testNotInterestedRemovesCard() {
        focusFeedCard()
        let card = focusedLabel
        let frame = focused.frame
        remote.press(.select, forDuration: 1.5)
        sleep(2)
        press(.down)
        press(.select, wait: 0.8)
        // Logged out (simulator) it's only hidden; logged in it also tells Bilibili.
        XCTAssertTrue(app.staticTexts["已隐藏"].exists || app.staticTexts["将减少这类推荐"].exists)
        shot("not-interested")
        let replacement = app.buttons.allElementsBoundByIndex.first { abs($0.frame.minX - frame.minX) < 30 && abs($0.frame.minY - frame.minY) < 30 }
        log("was '\(card)', now '\(replacement?.label ?? "-")'")
        XCTAssertNotEqual(replacement?.label, card)
    }

    func testWatchLaterLoggedOutExplains() {
        focusFeedCard()
        remote.press(.select, forDuration: 1.5)
        sleep(2)
        press(.select, wait: 1)  // 稍后再看 is first
        XCTAssertTrue(app.staticTexts["登录后可以使用稍后再看"].exists)
        shot("watch-later-logged-out")
    }

}
