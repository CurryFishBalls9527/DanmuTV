import XCTest

/// 互动视频: the choices at the end of a module lead to the chosen branch.
final class InteractiveTests: RemoteTestCase {
    /// av73267982 (the story graph used in the public API docs).
    private static let video = "BV1UE411y7Wy"

    private var marker: XCUIElement { app.descendants(matching: .any)["player.state"] }

    private func state() -> [String: String] {
        let value = marker.value as? String ?? ""
        return Dictionary(value.split(separator: ";").compactMap { pair in
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            return kv.count == 2 ? (kv[0], kv[1]) : nil
        }, uniquingKeysWith: { $1 })
    }

    private func wait(_ timeout: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return condition()
    }

    /// The first module starts at its end (`-startAt`), so its choices come up at once.
    func testChoosingABranch() {
        app.launchArguments = ["-muted", "YES", "-startAt", "100000", "-deeplink", "danmutv://play/\(Self.video)?p=1"]
        app.launch()
        XCTAssertTrue(marker.waitForExistence(timeout: 15))
        XCTAssertTrue(wait(25) { (Int(state()["story"] ?? "") ?? -1) >= 0 }, "story graph loaded: \(state())")
        log("start: \(state())")
        let choice = app.buttons["story.choice.0"]
        XCTAssertTrue(choice.waitForExistence(timeout: 30), "choices at the end of the module")
        sleep(1)
        XCTAssertEqual(focusedLabel, choice.label, "the default choice has focus")
        shot("story-choices")
        let firstCID = state()["cid"]
        press(.select, wait: 3)
        XCTAssertTrue(wait(20) { state()["cid"] != firstCID && state()["status"] == "playing" }, "the chosen branch plays: \(state())")
        XCTAssertEqual(state()["depth"], "1")
        log("after choice: \(state())")
        shot("story-branch")
    }
}
