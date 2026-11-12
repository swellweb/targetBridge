import AppKit
import Darwin
import Foundation

@MainActor
private final class HeartbeatSession {
    let socket: Int32
    var heartbeatTimer: Timer?
    var sent = 0
    init(socket: Int32) { self.socket = socket }
    func sendHeartbeat() {
        if tb_heartbeat_write(socket) == 0 { sent += 1 }
    }
    /* PRODUCTION_HEARTBEAT_METHOD */
}

@main
struct HeartbeatModeFixture {
    @MainActor
    static func main() {
        _ = NSApplication.shared
        let name = CommandLine.arguments[1]
        let expectedHealthy = CommandLine.arguments[2] == "healthy"
        let mode: RunLoop.Mode = name == "tracking" ? .eventTracking : name == "modal" ? .modalPanel : .default
        var sockets: [Int32] = [-1, -1]
        guard sockets.withUnsafeMutableBufferPointer({ tb_heartbeat_loopback($0.baseAddress!) }) == 0
        else { fatalError("Unable to create isolated loopback sockets") }
        defer { sockets.forEach { _ = close($0) } }
        let session = HeartbeatSession(socket: sockets[0])
        session.startHeartbeat()
        let original = session.heartbeatTimer
        session.startHeartbeat()
        precondition(original?.isValid == false, "Restart must invalidate the previous timer")
        let pulse = Timer(timeInterval: 0.02, repeats: true) { _ in }
        RunLoop.main.add(pulse, forMode: mode)
        defer { session.heartbeatTimer?.invalidate(); pulse.invalidate() }
        let start = ProcessInfo.processInfo.systemUptime
        var last = UInt64(start * 1000)
        var received = 0
        var expired = false
        let timeout: UInt64 = RECEIVER_TIMEOUT_MS
        while ProcessInfo.processInfo.systemUptime - start < Double(timeout) / 1000 + 2 {
            RunLoop.main.run(mode: mode, before: Date(timeIntervalSinceNow: 0.02))
            let now = UInt64(ProcessInfo.processInfo.systemUptime * 1000)
            if tb_heartbeat_read(sockets[1]) > 0 { last = now; received += 1 }
            var elapsed: UInt64 = 0
            if tb_idle_watchdog_check(now, &last, timeout, &elapsed) == TB_IDLE_WATCHDOG_EXPIRED {
                expired = true
                break
            }
        }
        let healthy = !expired && received > 0 && session.sent > 0
        print("mode=\(name) sent=\(session.sent) received=\(received) expired=\(expired) elapsed=\(ProcessInfo.processInfo.systemUptime - start)")
        exit(healthy == expectedHealthy ? 0 : 1)
    }
}
