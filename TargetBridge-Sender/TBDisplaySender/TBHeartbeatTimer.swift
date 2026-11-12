import Foundation

@MainActor
enum TBHeartbeatTimer {
    static func scheduled(
        interval: TimeInterval = 2,
        send: @escaping @MainActor @Sendable () -> Void
    ) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            // Common-mode delivery must not enqueue another default-mode UI task.
            MainActor.assumeIsolated { send() }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}
