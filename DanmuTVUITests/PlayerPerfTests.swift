import XCTest

/// A fixed remote workload during playback, for profiling on the device (attach Instruments while it runs):
/// transport bar, skips, info panel, pause/resume, with danmaku on.
final class PlayerPerfTests: RemoteTestCase {
    /// Popular, danmaku-heavy video (≈6k comments over 48 min).
    static let video = ProcessInfo.processInfo.environment["PERF_BVID"] ?? "BV1iqpt6cEMU"

    func testPlaybackRemoteWorkload() {
        launch("danmutv://play/\(Self.video)?p=1", settle: 20)
        shot("perf-playing")
        let steps: [(XCUIRemote.Button, TimeInterval)] = [
            (.select, 3), (.right, 2), (.right, 2), (.left, 3), (.menu, 3),
            (.down, 3), (.menu, 3),
            (.playPause, 2), (.playPause, 3),
            (.select, 2), (.left, 2), (.left, 2), (.menu, 3),
            (.right, 1), (.right, 1), (.right, 1), (.left, 1), (.left, 3),
        ]
        for (button, wait) in steps {
            log("press \(button.rawValue) at \(Date().timeIntervalSince1970)")
            press(button, wait: wait)
        }
        shot("perf-end")
    }
}
