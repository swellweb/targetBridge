import CoreGraphics
import XCTest
@testable import TargetBridge

final class TBInjectedClickStateTrackerTests: XCTestCase {
    func testConsecutiveNearbyClicksIncrementTheClickState() {
        var tracker = TBInjectedClickStateTracker()

        XCTAssertEqual(tracker.registerClick(at: CGPoint(x: 10, y: 10), timestamp: 1, doubleClickInterval: 0.5), 1)
        XCTAssertEqual(tracker.registerClick(at: CGPoint(x: 12, y: 11), timestamp: 1.4, doubleClickInterval: 0.5), 2)
        XCTAssertEqual(tracker.currentClickState, 2)
    }

    func testClickAfterTheSystemIntervalStartsANewSequence() {
        var tracker = TBInjectedClickStateTracker()

        XCTAssertEqual(tracker.registerClick(at: .zero, timestamp: 1, doubleClickInterval: 0.5), 1)
        XCTAssertEqual(tracker.registerClick(at: .zero, timestamp: 1.6, doubleClickInterval: 0.5), 1)
    }

    func testDistantClickStartsANewSequence() {
        var tracker = TBInjectedClickStateTracker()

        XCTAssertEqual(tracker.registerClick(at: .zero, timestamp: 1, doubleClickInterval: 0.5), 1)
        XCTAssertEqual(tracker.registerClick(at: CGPoint(x: 5, y: 0), timestamp: 1.2, doubleClickInterval: 0.5), 1)
    }

    func testResetClearsTheCurrentClickState() {
        var tracker = TBInjectedClickStateTracker()
        _ = tracker.registerClick(at: .zero, timestamp: 1, doubleClickInterval: 0.5)

        tracker.reset()

        XCTAssertEqual(tracker.currentClickState, 0)
        XCTAssertEqual(tracker.registerClick(at: .zero, timestamp: 1.2, doubleClickInterval: 0.5), 1)
    }
}
