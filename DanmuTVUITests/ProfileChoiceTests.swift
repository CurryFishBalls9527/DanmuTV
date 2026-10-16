import XCTest

/// tvOS 多用户: 「谁在看？」 (forced in the simulator, which has one Apple TV user and no profiles).
final class ProfileChoiceTests: RemoteTestCase {
    func testAddAnotherAccountOpensLogin() {
        app.launchArguments = ["-muted", "YES", "-forceProfileChoice", "YES"]
        app.launch()
        XCTAssertTrue(app.staticTexts["谁在看？"].waitForExistence(timeout: 10))
        shot("profile-choice")
        XCTAssertEqual(focusedLabel, "登录其他账号", "with no profiles, the add button has focus")
        press(.select, wait: 3)
        XCTAssertFalse(app.staticTexts["谁在看？"].exists, "the question goes away")
        XCTAssertTrue(app.staticTexts["扫码登录"].exists, "login opens")
    }

    func testMenuKeepsCurrentProfile() {
        app.launchArguments = ["-muted", "YES", "-forceProfileChoice", "YES"]
        app.launch()
        XCTAssertTrue(app.staticTexts["谁在看？"].waitForExistence(timeout: 10))
        press(.menu, wait: 2)
        XCTAssertFalse(app.staticTexts["谁在看？"].exists)
    }
}
