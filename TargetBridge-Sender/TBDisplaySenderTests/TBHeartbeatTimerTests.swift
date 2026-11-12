import AppKit
import XCTest
@testable import TargetBridge

@MainActor
final class TBHeartbeatTimerTests: XCTestCase {
    @MainActor private final class Counter { var value = 0 }

    func testDefaultModeDeliversHeartbeat() { assertDelivery(in: .default) }
    func testMenuTrackingDeliversHeartbeat() { assertDelivery(in: .eventTracking) }
    func testModalPanelDeliversHeartbeat() { assertDelivery(in: .modalPanel) }

    func testDefaultOnlyTimerDoesNotFireDuringMenuTracking() {
        let counter = Counter()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { _ in
            MainActor.assumeIsolated { counter.value += 1 }
        }
        defer { timer.invalidate() }
        run(.eventTracking)
        XCTAssertEqual(counter.value, 0)
    }

    func testInvalidationStopsHeartbeats() {
        let counter = Counter()
        let timer = TBHeartbeatTimer.scheduled(interval: 0.01) { counter.value += 1 }
        run(.eventTracking)
        XCTAssertGreaterThan(counter.value, 0)
        timer.invalidate()
        let before = counter.value
        run(.eventTracking)
        XCTAssertEqual(counter.value, before)
        XCTAssertFalse(timer.isValid)
    }

    private func assertDelivery(in mode: RunLoop.Mode) {
        let counter = Counter()
        let timer = TBHeartbeatTimer.scheduled(interval: 0.01) { counter.value += 1 }
        defer { timer.invalidate() }
        run(mode)
        XCTAssertGreaterThan(counter.value, 0, "No heartbeat in \(mode)")
    }

    private func run(_ mode: RunLoop.Mode) {
        _ = NSApplication.shared
        let pulse = Timer(timeInterval: 0.01, repeats: true) { _ in }
        RunLoop.main.add(pulse, forMode: mode)
        defer { pulse.invalidate() }
        let end = Date(timeIntervalSinceNow: 0.12)
        while Date() < end { RunLoop.main.run(mode: mode, before: end) }
    }
}
