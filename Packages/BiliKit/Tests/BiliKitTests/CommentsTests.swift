@testable import BiliKit
import XCTest

final class CommentsTests: XCTestCase {
    private func json(_ name: String) throws -> JSON {
        try JSON(data: Fixture.data(name))["data"]
    }

    func testHotCommentsPage() throws {
        let (page, next) = API.mainPage(try json("comments_main.json"), first: true)
        XCTAssertEqual(page.comments.count, 3)
        XCTAssertEqual(page.total, 184_139)
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(next, "CAEiAggC")
        let first = page.comments[0]
        XCTAssertEqual(first.id, 1_353_715_029)
        XCTAssertEqual(first.name, "用户1")
        XCTAssertEqual(first.level, 6)
        XCTAssertEqual(first.replyCount, 617)
        XCTAssertEqual(first.message, "示例评论 10")
        XCTAssertFalse(first.isPinned)
        XCTAssertTrue(first.face.hasPrefix("https://"))
    }

    func testLegacyFirstPage() throws {
        let page = API.legacyPage(try json("comments_hot.json"))
        XCTAssertEqual(page.comments.count, 3)
        XCTAssertEqual(page.comments[0].previewReplies.map(\.name), ["用户2", "用户1"])
        XCTAssertTrue(page.comments[0].timeText.hasSuffix("前发布"))
        XCTAssertFalse(page.hasMore, "the legacy endpoint is only a first-page fallback")
    }

    func testLastPageEnds() {
        let one: [String: Any] = ["rpid": 1, "member": ["uname": "A"], "content": ["message": "a"]]
        let d = JSON(["replies": [one], "cursor": ["is_end": true, "all_count": 1, "pagination_reply": ["next_offset": "x"]]])
        let (page, next) = API.mainPage(d, first: false)
        XCTAssertFalse(page.hasMore)
        XCTAssertNil(next)
    }

    func testRepliesPage() throws {
        let page = API.replyPage(try json("comment_replies.json"), page: 1, pageSize: 3)
        XCTAssertEqual(page.comments.map(\.id), [1_353_872_650, 1_354_185_553, 1_354_245_937])
        XCTAssertEqual(page.comments[0].message, "示例评论 16")
        XCTAssertEqual(page.total, 617)
        XCTAssertTrue(page.hasMore)
        XCTAssertFalse(API.replyPage(try json("comment_replies.json"), page: 206, pageSize: 3).hasMore)
    }

    func testPinnedCommentLeadsTheFirstPageOnce() {
        let top: [String: Any] = ["rpid": 9, "member": ["uname": "UP"], "content": ["message": "置顶"], "like": 1]
        let other: [String: Any] = ["rpid": 1, "member": ["uname": "A"], "content": ["message": "a"], "like": 5]
        let d = JSON(["top": ["upper": top], "replies": [other, top], "cursor": ["is_end": true]])
        let first = API.mainPage(d, first: true).page
        XCTAssertEqual(first.comments.map(\.id), [9, 1])
        XCTAssertTrue(first.comments[0].isPinned)
        XCTAssertEqual(API.mainPage(d, first: false).page.comments.map(\.id), [1, 9], "pinned only leads page 1")
    }

    func testMessageWhitespaceIsTidied() {
        XCTAssertEqual(Comment.cleaned("  第一段\r\n\r\n  \r\n\r\n第二段\n "), "第一段\n\n第二段")
    }

    func testPictureOnlyComment() {
        let c = Comment(JSON(["rpid": 1, "member": ["uname": "A"], "content": ["message": "", "pictures": [["img_src": "x"], ["img_src": "y"]]]]))
        XCTAssertEqual(c.displayText, "[图片 ×2]")
    }
}

final class CommentRichContentTests: XCTestCase {
    private func comment(_ content: [String: Any]) -> Comment {
        Comment(JSON(["rpid": 1, "mid": 2, "member": ["uname": "a"], "content": content] as [String: Any]))
    }

    func testPicturesAndEmotesParse() {
        let c = comment(["message": "好耶[doge][未知]！[doge]",
                         "emote": ["[doge]": ["text": "[doge]", "url": "http://i0.hdslb.com/bfs/emote/doge.png"]],
                         "pictures": [["img_src": "//i0.hdslb.com/bfs/new_dyn/p.jpg", "img_width": 1080, "img_height": 1920]]])
        XCTAssertEqual(c.pictures, [CommentPicture(url: "https://i0.hdslb.com/bfs/new_dyn/p.jpg", width: 1080, height: 1920)])
        XCTAssertEqual(c.emotes["[doge]"], "https://i0.hdslb.com/bfs/emote/doge.png")
        let url = "https://i0.hdslb.com/bfs/emote/doge.png"
        XCTAssertEqual(c.segments, [.text("好耶"), .emote("[doge]", url), .text("[未知]！"), .emote("[doge]", url)])
        XCTAssertEqual(c.displayText, "好耶[doge][未知]！[doge]")
    }

    func testPlainAndPictureOnly() {
        XCTAssertEqual(comment(["message": "a [b] c"]).segments, [.text("a [b] c")])
        let pictureOnly = comment(["message": "", "pictures": [["img_src": "https://x/1.jpg"], ["img_src": "https://x/2.jpg"]]])
        XCTAssertEqual(pictureOnly.displayText, "[图片 ×2]")
        XCTAssertEqual(pictureOnly.segments, [.text("[图片 ×2]")])
    }

    func testUnclosedBracket() {
        let c = comment(["message": "[doge] [oops", "emote": ["[doge]": ["url": "https://e/d.png"]]])
        XCTAssertEqual(c.segments, [.emote("[doge]", "https://e/d.png"), .text(" [oops")])
    }
}
