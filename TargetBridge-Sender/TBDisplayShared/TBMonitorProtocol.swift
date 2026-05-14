import Foundation

enum TBMonitorPacketType: UInt8 {
    case helloReceiver = 0x10
    case displayProfile = 0x11
    case createSessionAck = 0x12
    case paramSets = 0x20
    case frame = 0x21
    case heartbeat = 0x30
    case teardown = 0x31
}

struct TBMonitorHelloReceiver: Codable {
    var senderName: String
    var capturePreset: String?
    var captureWidth: Int?
    var captureHeight: Int?
    var codec: String?
}

struct TBMonitorDisplayProfile: Codable {
    var receiverName: String
    var panelWidth: Int
    var panelHeight: Int
    var modeWidth: Int
    var modeHeight: Int
    var refreshRate: Double
    var hiDPI: Bool
    var captureWidth: Int
    var captureHeight: Int
}

struct TBMonitorCreateSessionAck: Codable {
    var accepted: Bool
    var displayName: String
    var displayID: UInt32
}

struct TBMonitorHeartbeat: Codable {
    var sequence: UInt64
}

struct TBMonitorTeardown: Codable {
    var reason: String
}

enum TBMonitorProtocol {
    static let port: UInt16 = 54321

    static func makePacket(type: TBMonitorPacketType, payload: Data) -> Data {
        var packet = Data()
        appendBE32(&packet, UInt32(1 + payload.count))
        packet.append(type.rawValue)
        packet.append(payload)
        return packet
    }

    static func makeJSONPacket<T: Encodable>(type: TBMonitorPacketType, value: T) -> Data? {
        let encoder = JSONEncoder()
        guard let payload = try? encoder.encode(value) else { return nil }
        return makePacket(type: type, payload: payload)
    }

    static func decodeJSON<T: Decodable>(_ type: T.Type, from payload: Data) -> T? {
        let decoder = JSONDecoder()
        return try? decoder.decode(type, from: payload)
    }

    static func drainPacket(from buffer: inout Data) -> (TBMonitorPacketType, Data)? {
        guard buffer.count >= 5 else { return nil }
        let packetLength = Int(readBE32(buffer, offset: 0))
        guard packetLength >= 1, buffer.count >= 4 + packetLength else { return nil }
        let typeByte = buffer[4]
        let payload = buffer.subdata(in: 5..<(4 + packetLength))
        buffer.removeSubrange(0..<(4 + packetLength))
        guard let packetType = TBMonitorPacketType(rawValue: typeByte) else { return nil }
        return (packetType, payload)
    }

    static func appendBE32(_ data: inout Data, _ value: UInt32) {
        var be = value.bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }

    static func readBE32(_ data: Data, offset: Int) -> UInt32 {
        data.subdata(in: offset..<(offset + 4)).withUnsafeBytes {
            $0.load(as: UInt32.self).bigEndian
        }
    }
}
