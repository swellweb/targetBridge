import XCTest
@testable import TargetBridge

final class TBHeartbeatCancellationTests: XCTestCase {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        private var values: [UInt64] = []
        func append(_ value: UInt64) { lock.lock(); defer { lock.unlock() }; values.append(value) }
        var snapshot: [UInt64] { lock.lock(); defer { lock.unlock() }; return values }
    }

    func testMainThreadDoesNotNeedToPumpItsRunLoop() {
        let state = State()
        let timer = TBHeartbeatTimer.scheduled(interval: 0.01) { state.append($0) }
        defer { timer.invalidate() }
        Thread.sleep(forTimeInterval: 0.12)
        XCTAssertGreaterThan(state.snapshot.count, 0)
    }

    func testSequenceIsMonotonicAndUnique() {
        let state = State()
        let timer = TBHeartbeatTimer.scheduled(interval: 0.01) { state.append($0) }
        Thread.sleep(forTimeInterval: 0.12)
        timer.invalidate()
        let values = state.snapshot
        guard !values.isEmpty else { XCTFail("No heartbeat received"); return }
        XCTAssertEqual(values, (1...values.count).map(UInt64.init))
    }

    func testQueuedEventCannotSendAfterInvalidation() {
        let queue = DispatchQueue(label: "heartbeat.test.blocked")
        let state = State()
        queue.suspend()
        let timer = TBHeartbeatTimer.scheduled(interval: 0.01, queue: queue) { state.append($0) }
        Thread.sleep(forTimeInterval: 0.04)
        timer.invalidate()
        timer.invalidate()
        queue.resume()
        queue.sync {}
        XCTAssertTrue(state.snapshot.isEmpty)
        XCTAssertFalse(timer.isValid)
    }

    func testDroppingOwnerCancelsTimer() {
        let state = State()
        let queue = DispatchQueue(label: "heartbeat.test.deinit")
        queue.suspend()
        var timer: TBHeartbeatTimer? = .scheduled(interval: 0.01, queue: queue) { state.append($0) }
        weak var previous = timer
        timer = nil
        XCTAssertNil(previous)
        queue.resume()
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertTrue(state.snapshot.isEmpty)
    }

    func testOldHeartbeatStaysStoppedWhenReplacementStarts() {
        let old = State(), replacement = State()
        let first = TBHeartbeatTimer.scheduled(interval: 0.01) { old.append($0) }
        Thread.sleep(forTimeInterval: 0.04)
        first.invalidate()
        let oldCount = old.snapshot.count
        let second = TBHeartbeatTimer.scheduled(interval: 0.01) { replacement.append($0) }
        Thread.sleep(forTimeInterval: 0.06)
        second.invalidate()
        XCTAssertEqual(old.snapshot.count, oldCount)
        XCTAssertGreaterThan(replacement.snapshot.count, 0)
    }
}
