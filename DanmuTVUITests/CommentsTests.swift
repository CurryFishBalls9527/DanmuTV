import XCTest

/// 热门评论: shelf on the video page → thread with replies; the full list from the shelf's last card.
final class CommentsTests: RemoteTestCase {
    /// av170001: lots of comments; its top comment has hundreds of replies.
    private static let video = "danmutv://video/BV17x411w7KC"

    /// Presses Down until the focused element's label satisfies `match` (max `limit` presses).
    private func moveDown(until match: (String) -> Bool, limit: Int = 8) -> Bool {
        for _ in 0 ..< limit {
            if match(focusedLabel) { return true }
            press(.down, wait: 1.2)
        }
        return match(focusedLabel)
    }

    func testShelfOpensThreadWithReplies() {
        launch(Self.video, settle: 8)
        XCTAssertTrue(moveDown { $0.contains("LV") }, "Down should reach the 热门评论 shelf, at '\(focusedLabel)'")
        let card = focusedLabel
        log("comment card: \(card.prefix(80))")
        shot("comments-shelf")

        press(.select, wait: 4)
        shot("comments-thread")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS '赞'")).firstMatch.exists, "thread has a like button")
        XCTAssertTrue(app.staticTexts["回复"].exists, "thread has a replies header (the replies themselves are checked by moving into them)")

        XCTAssertTrue(moveDown(until: { $0.contains("LV") }, limit: 3), "Down from 点赞 should reach the replies, at '\(focusedLabel)'")
        press(.down, 3, wait: 1)
        shot("comments-replies-scrolled")
        XCTAssertTrue(focusedLabel.contains("LV"), "still moving through replies")

        press(.menu, wait: 2)
        XCTAssertEqual(focusedLabel, card, "Menu returns to the same comment card")
    }

    /// Logged out (this simulator), Bilibili only gives the top three: the shelf ends with a card that opens login.
    /// (Logged in, the same spot is 全部评论 with the paged list; covered by unit tests and checked on device.)
    func testLoggedOutShelfOffersLogin() {
        launch(Self.video, settle: 8)
        XCTAssertTrue(moveDown { $0.contains("LV") })
        for _ in 0 ..< 12 where focusedLabel != "登录后查看全部评论" { press(.right, wait: 0.6) }
        XCTAssertEqual(focusedLabel, "登录后查看全部评论")
        shot("comments-login-card")
        press(.select, wait: 3)
        XCTAssertTrue(app.staticTexts["扫码登录"].exists, "login opens")
    }
}
