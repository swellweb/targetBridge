import AppKit
import XCTest
@testable import TargetBridge

@MainActor
final class TBHeartbeatTimerTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
        func increment() { lock.lock(); defer { lock.unlock() }; count += 1 }
    }

    func testDefaultModeDeliversHeartbeat() { assertDelivery(in: .default) }
    func testMenuTrackingDeliversHeartbeat() { assertDelivery(in: .eventTracking) }
    func testModalPanelDeliversHeartbeat() { assertDelivery(in: .modalPanel) }

    func testDefaultOnlyTimerDoesNotFireDuringMenuTracking() {
        let counter = Counter()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { _ in
            counter.increment()
        }
        defer { timer.invalidate() }
        run(.eventTracking)
        XCTAssertEqual(counter.value, 0)
    }

    func testInvalidationStopsHeartbeats() {
        let counter = Counter()
        let timer = TBHeartbeatTimer.scheduled(interval: 0.01) { _ in counter.increment() }
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
        let timer = TBHeartbeatTimer.scheduled(interval: 0.01) { _ in counter.increment() }
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
