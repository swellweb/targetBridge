import Foundation
import Network

// Inert transport/protocol collaborators for the extracted production method.
// Only ephemeral localhost sockets carry these packets; no Receiver is discovered.
final class HeartbeatFixtureConnection: @unchecked Sendable {
    private let socket: Int32
    private let lock = NSLock()
    private var count = 0
    init(socket: Int32) { self.socket = socket }
    var sent: Int { lock.lock(); defer { lock.unlock() }; return count }

    func legacySend() {
        if tb_heartbeat_write(socket) == 0 { increment() }
    }

    func send(content: Data?, completion: NWConnection.SendCompletion) {
        let success = content.map { data in
            data.withUnsafeBytes { tb_heartbeat_write_data(socket, $0.baseAddress, $0.count) == 0 }
        } ?? false
        if success { increment() }
        if case .contentProcessed(let callback) = completion {
            callback(success ? nil : .posix(.EIO))
        }
    }

    private func increment() { lock.lock(); defer { lock.unlock() }; count += 1 }
}

struct TBMonitorHeartbeat: Encodable { let sequence: UInt64 }
enum TBMonitorPacketType { case heartbeat }
enum TBMonitorProtocol {
    static func makeJSONPacket<T: Encodable>(type: TBMonitorPacketType, value: T) -> Data? {
        guard let payload = try? JSONEncoder().encode(value) else { return nil }
        var size = UInt32(payload.count + 1).bigEndian
        var packet = withUnsafeBytes(of: &size) { Data($0) }
        packet.append(0x30)
        packet.append(payload)
        return packet
    }
}
