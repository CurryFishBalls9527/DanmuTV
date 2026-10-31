@testable import BiliKit
import XCTest

final class PlaybackPhaseTests: XCTestCase {
    private struct Page: Equatable {
        var index: Int
        var startAt: Double?
    }

    func testStartingHasNothingAttached() {
        var phase = PlaybackPhase.starting(Page(index: 0))
        phase.target.index = 2 // 继续播放 picks another page before anything attaches
        phase.beginSwitch(to: Page(index: 3))
        XCTAssertNil(phase.attached)
        XCTAssertFalse(phase.isSwitching)
        XCTAssertNil(phase.rollBack())
        XCTAssertEqual(phase.target, Page(index: 3))
        phase.attach()
        XCTAssertEqual(phase.attached, Page(index: 3))
    }

    func testWritesDuringASwitchNeverReachTheAttachedItem() {
        var phase = PlaybackPhase.playing(Page(index: 0))
        phase.beginSwitch(to: Page(index: 1))
        phase.target.startAt = 30 // e.g. a cast seek while the next page loads
        XCTAssertEqual(phase.attached, Page(index: 0))
        XCTAssertEqual(phase.target, Page(index: 1, startAt: 30))
        XCTAssertEqual(phase.rollBack(), Page(index: 0))
        XCTAssertEqual(phase.target, Page(index: 0))
        XCTAssertFalse(phase.isSwitching)
        XCTAssertNil(phase.rollBack(), "not switching any more")
    }

    func testAttachPromotesTheTarget() {
        var phase = PlaybackPhase.playing(Page(index: 0))
        phase.beginSwitch(to: Page(index: 1))
        phase.attach()
        XCTAssertEqual(phase.attached, Page(index: 1))
        XCTAssertNil(phase.rollBack())
    }

    func testRetargetingKeepsTheItemToGoBackTo() {
        var phase = PlaybackPhase.playing(Page(index: 0))
        phase.beginSwitch(to: Page(index: 0)) // related video: the target is known only after a lookup
        phase.beginSwitch(to: Page(index: 7))
        XCTAssertEqual(phase.target, Page(index: 7))
        XCTAssertEqual(phase.rollBack(), Page(index: 0))
    }

    func testWritesWhilePlayingAreTheAttachedItems() {
        var phase = PlaybackPhase.playing(Page(index: 0))
        phase.target.startAt = 12
        XCTAssertEqual(phase.attached, Page(index: 0, startAt: 12))
    }
}
