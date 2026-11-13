import AppKit
import Darwin
import Foundation

@main
struct HeartbeatStallFixture {
    @MainActor
    static func main() {
        _ = NSApplication.shared
        var sockets: [Int32] = [-1, -1]
        guard sockets.withUnsafeMutableBufferPointer({ tb_heartbeat_loopback($0.baseAddress!) }) == 0,
              let monitor = tb_heartbeat_monitor_start(sockets[1], 10_000)
        else { fatalError("Unable to create isolated TCP monitor") }
        defer { tb_heartbeat_monitor_stop(monitor); sockets.forEach { _ = close($0) } }
        let socket = sockets[0]
        let timer = TBHeartbeatTimer.scheduled { HEARTBEAT_SEQUENCE_ARGUMENT
            _ = tb_heartbeat_write(socket)
        }
        defer { timer.invalidate() }
        // Only this disposable fixture's main thread is blocked, never the app.
        Thread.sleep(forTimeInterval: 12)
        let expired = tb_heartbeat_monitor_expired(monitor) != 0
        let received = tb_heartbeat_monitor_received(monitor)
        print("main_block=12s receiver_thread=independent received=\(received) expired=\(expired)")
        let expectedExpiry = CommandLine.arguments[1] == "expired"
        precondition(expired == expectedExpiry && (expectedExpiry || received > 0),
                     "Unexpected Receiver watchdog result")
    }
}
