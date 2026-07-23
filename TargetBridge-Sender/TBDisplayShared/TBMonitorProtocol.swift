import Foundation

enum TBMonitorPacketType: UInt8 {
    case helloReceiver = 0x10
    case displayProfile = 0x11
    case createSessionAck = 0x12
    case uiLanguage = 0x13
    case paramSets = 0x20
    case frame = 0x21
    case rawFrame = 0x22   // Uncompressed NV12 planes (raw passthrough mode)
    case audioFrame = 0x23
    case heartbeat = 0x30
    case teardown = 0x31
    case cursor = 0x32
    case inputEvent = 0x33
    case inputControlMode = 0x34
    case brightness = 0x35
    case clipboard = 0x36
    case volume = 0x37
    case testData = 0x40
}

struct TBMonitorHelloReceiver: Codable {
    var senderName: String
    var uiLanguage: String?
    var capturePreset: String?
    var captureSource: String?
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
    var supportsHEVCDecode: Bool?
    var inputMonitoringTrusted: Bool?
    var accessibilityTrusted: Bool?
}

struct TBMonitorCreateSessionAck: Codable {
    var accepted: Bool
    var displayName: String
    var displayID: UInt32
}

struct TBMonitorUILanguageUpdate: Codable {
    var uiLanguage: String
}

struct TBMonitorHeartbeat: Codable {
    var sequence: UInt64
}

struct TBMonitorTeardown: Codable {
    var reason: String
}

struct TBMonitorCursor: Codable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int
    var visible: Bool
    var type: Int
}

struct TBMonitorInputEvent: Codable {
    var kind: String
    var dx: Int?
    var dy: Int?
    var scrollX: Int?
    var scrollY: Int?
    var keyCode: UInt16?
}

struct TBMonitorInputControlMode: Codable {
    var mode: String
}

struct TBMonitorBrightness: Codable {
    var level: Double
}

struct TBMonitorVolume: Codable {
    var level: Double
}

struct TBMonitorClipboard: Codable {
    var text: String
}

/// Framing-level corruption that cannot be recovered by waiting for more
/// bytes. The connection carrying the stream should be torn down.
enum TBMonitorProtocolError: Error, Equatable, CustomStringConvertible {
    case invalidPacketLength(UInt32)

    var description: String {
        switch self {
        case .invalidPacketLength(let length):
            return "invalid packet length \(length)"
        }
    }
}

enum TBMonitorProtocol {
    static let port: UInt16 = 54321

    /// Upper bound for a single packet's declared length. Mirrors the
    /// receiver's parser sanity check (net.c) so both ends agree on what a
    /// corrupt length prefix is. Without this cap, a corrupted 4-byte length
    /// (e.g. 0xFFFFFFFF) would make the drain loop buffer inbound data
    /// forever, waiting for a packet that can never complete.
    static let maxPacketLength: UInt32 = 64 * 1024 * 1024

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

    /// Hand-rolled encoder for the input-event hot path. Mouse move/drag events
    /// fire at display refresh rate (or faster with high-poll-rate mice), and a
    /// fresh `JSONEncoder` per event is the busiest allocator in that path. This
    /// emits the same JSON shape `JSONDecoder` reconstructs into a
    /// `TBMonitorInputEvent` (omitted fields decode as nil), mirroring the
    /// receiver's `snprintf`-based emitter. `kind` is always a fixed literal from
    /// the event converter, so no string escaping is required.
    static func makeInputEventPacket(_ event: TBMonitorInputEvent) -> Data {
        var json = "{\"kind\":\"\(event.kind)\""
        if let dx = event.dx { json += ",\"dx\":\(dx)" }
        if let dy = event.dy { json += ",\"dy\":\(dy)" }
        if let scrollX = event.scrollX { json += ",\"scrollX\":\(scrollX)" }
        if let scrollY = event.scrollY { json += ",\"scrollY\":\(scrollY)" }
        if let keyCode = event.keyCode { json += ",\"keyCode\":\(keyCode)" }
        json += "}"
        return makePacket(type: .inputEvent, payload: Data(json.utf8))
    }

    static func decodeJSON<T: Decodable>(_ type: T.Type, from payload: Data) -> T? {
        let decoder = JSONDecoder()
        return try? decoder.decode(type, from: payload)
    }

    /// Drains the next complete packet from `buffer`.
    ///
    /// - Returns: the packet, or `nil` when the buffer does not yet hold a
    ///   complete packet (more bytes are needed).
    /// - Throws: `TBMonitorProtocolError.invalidPacketLength` when the length
    ///   prefix is corrupt (zero or above `maxPacketLength`); the stream is
    ///   unrecoverable and the caller should close the connection.
    ///
    /// Packets with an unrecognized type byte (e.g. from a newer peer) are
    /// skipped and draining continues with the next packet, so one unknown
    /// packet cannot stall the packets queued behind it.
    static func drainPacket(from buffer: inout Data) throws -> (TBMonitorPacketType, Data)? {
        while buffer.count >= 5 {
            let packetLength = readBE32(buffer, offset: 0)
            guard packetLength >= 1, packetLength <= maxPacketLength else {
                throw TBMonitorProtocolError.invalidPacketLength(packetLength)
            }
            let packetEnd = 4 + Int(packetLength)
            guard buffer.count >= packetEnd else { return nil }
            let typeByte = buffer[4]
            let payload = buffer.subdata(in: 5..<packetEnd)
            buffer.removeSubrange(0..<packetEnd)
            if let packetType = TBMonitorPacketType(rawValue: typeByte) {
                return (packetType, payload)
            }
        }
        return nil
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
