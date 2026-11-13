import Foundation

// The lock protects cancellation, sequence and delivery as one operation.
// A recursive lock also permits a send callback to invalidate its own timer.
final class TBHeartbeatTimer: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var source: DispatchSourceTimer?
    private var sequence: UInt64 = 0

    var isValid: Bool {
        lock.lock()
        defer { lock.unlock() }
        return source != nil
    }

    static func scheduled(
        interval: TimeInterval = 2,
        queue: DispatchQueue = DispatchQueue(label: "com.targetbridge.sender.heartbeat", qos: .userInitiated),
        send: @escaping @Sendable (UInt64) -> Void
    ) -> TBHeartbeatTimer {
        precondition(interval > 0 && interval.isFinite)
        return TBHeartbeatTimer(interval: interval, queue: queue, send: send)
    }

    private init(interval: TimeInterval, queue: DispatchQueue, send: @escaping @Sendable (UInt64) -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        source = timer
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            guard self.source != nil else { return }
            self.sequence &+= 1
            send(self.sequence)
        }
        timer.activate()
    }

    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        source?.cancel()
        source = nil
    }

    deinit { invalidate() }
}
