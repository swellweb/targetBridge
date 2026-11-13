import XCTest
@testable import TargetBridge

final class TBHeartbeatStopTests: XCTestCase {
    private final class Owner: @unchecked Sendable {
        private let lock = NSLock()
        private var timer: TBHeartbeatTimer?
        func install(_ value: TBHeartbeatTimer) { lock.lock(); timer = value; lock.unlock() }
        func stop() {
            lock.lock()
            let value = timer
            timer = nil
            lock.unlock()
            value?.invalidate()
        }
    }

    func testCallbackCanInvalidateItsOwnHeartbeat() {
        let owner = Owner()
        let delivered = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "heartbeat.test.self-stop")
        queue.suspend()
        let timer = TBHeartbeatTimer.scheduled(interval: 0.01, queue: queue) { _ in
            owner.stop()
            delivered.signal()
        }
        owner.install(timer)
        queue.resume()
        XCTAssertEqual(delivered.wait(timeout: .now() + 1), .success)
        XCTAssertFalse(timer.isValid)
    }

    func testInvalidationWaitsForAnAlreadyRunningSend() {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let invalidating = DispatchSemaphore(value: 0)
        let timer = TBHeartbeatTimer.scheduled(interval: 1) { _ in
            entered.signal()
            _ = release.wait(timeout: .now() + 2)
        }
        defer { release.signal(); timer.invalidate() }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        DispatchQueue.global().async {
            invalidating.signal()
            timer.invalidate()
            finished.signal()
        }
        XCTAssertEqual(invalidating.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(finished.wait(timeout: .now() + 0.03), .timedOut)
        release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)
        XCTAssertFalse(timer.isValid)
    }
}
