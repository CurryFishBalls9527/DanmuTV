import XCTest

/// Base for remote-driven checks: launches muted, optionally at a deep link, and saves screenshots
/// to `SHOT_DIR` (pass `TEST_RUNNER_SHOT_DIR=… xcodebuild test`) as well as attaching them.
class RemoteTestCase: XCTestCase {
    let app = XCUIApplication()
    let remote = XCUIRemote.shared

    override func setUp() {
        continueAfterFailure = true
    }

    override func tearDown() {
        // Never leave a player (or its audio) running after a check.
        app.terminate()
    }

    func launch(_ deeplink: String? = nil, settle: TimeInterval = 6) {
        app.launchArguments = ["-muted", "YES"]
        if let deeplink { app.launchArguments += ["-deeplink", deeplink] }
        app.launch()
        sleep(UInt32(settle))
    }

    var focused: XCUIElement {
        app.descendants(matching: .any).element(matching: NSPredicate(format: "hasFocus == true"))
    }

    /// Label of the focused element ("" when nothing reports focus).
    var focusedLabel: String {
        let element = focused
        return element.exists ? element.label : ""
    }

    func press(_ button: XCUIRemote.Button, _ times: Int = 1, wait: TimeInterval = 0.8) {
        for _ in 0..<times {
            remote.press(button)
            Thread.sleep(forTimeInterval: wait)
        }
    }

    func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["SHOT_DIR"] {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    func log(_ message: String) {
        print("[UITEST] \(message)")
    }
}
