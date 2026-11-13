import AppKit
import Darwin
import Foundation

@MainActor
private final class HeartbeatSession {
    let connection: HeartbeatFixtureConnection?
    var heartbeatTimer: HEARTBEAT_TIMER_TYPE?
    var sent: Int { connection?.sent ?? 0 }
    init(socket: Int32) { connection = HeartbeatFixtureConnection(socket: socket) }
    func sendHeartbeat() { connection?.legacySend() }
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
        let timeout: UInt64 = RECEIVER_TIMEOUT_MS
        guard let monitor = tb_heartbeat_monitor_start(sockets[1], timeout)
        else { fatalError("Unable to create independent Receiver monitor") }
        defer { tb_heartbeat_monitor_stop(monitor); sockets.forEach { _ = close($0) } }
        let session = HeartbeatSession(socket: sockets[0])
        session.startHeartbeat()
        let original = session.heartbeatTimer
        session.startHeartbeat()
        precondition(original?.isValid == false, "Restart must invalidate the previous timer")
        let pulse = Timer(timeInterval: 0.02, repeats: true) { _ in }
        RunLoop.main.add(pulse, forMode: mode)
        defer { session.heartbeatTimer?.invalidate(); pulse.invalidate() }
        let start = ProcessInfo.processInfo.systemUptime
        let duration = ProcessInfo.processInfo.environment["TB_HEARTBEAT_DURATION_SECONDS"].flatMap(Double.init)
            ?? Double(timeout) / 1000 + 2
        precondition(duration > Double(timeout) / 1000)
        while ProcessInfo.processInfo.systemUptime - start < duration {
            RunLoop.main.run(mode: mode, before: Date(timeIntervalSinceNow: 0.02))
            if tb_heartbeat_monitor_expired(monitor) != 0 { break }
        }
        let expired = tb_heartbeat_monitor_expired(monitor) != 0
        let received = tb_heartbeat_monitor_received(monitor)
        let healthy = !expired && received > 0 && session.sent > 0
        print("mode=\(name) sent=\(session.sent) received=\(received) expired=\(expired) elapsed=\(ProcessInfo.processInfo.systemUptime - start)")
        precondition(healthy == expectedHealthy, "Unexpected Receiver watchdog result")
    }
}
