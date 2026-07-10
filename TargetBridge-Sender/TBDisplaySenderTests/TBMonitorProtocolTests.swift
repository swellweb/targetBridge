import XCTest
@testable import TargetBridge

/// Wire-protocol unit tests. These run with no network, no Thunderbolt hardware,
/// and no receiver — they pin down the framing invariants both apps rely on:
/// `[4B BE length][1B type][payload]` where length counts type + payload.
final class TBMonitorProtocolTests: XCTestCase {

    // MARK: - BE32 primitives

    func testBE32RoundTrip() {
        let values: [UInt32] = [0, 1, 0xFF, 0x1234_5678, 0x7FFF_FFFF, 0xFFFF_FFFF]
        for value in values {
            var data = Data()
            TBMonitorProtocol.appendBE32(&data, value)
            XCTAssertEqual(data.count, 4)
            XCTAssertEqual(TBMonitorProtocol.readBE32(data, offset: 0), value, "round trip failed for \(value)")
        }
    }

    func testAppendBE32IsBigEndian() {
        var data = Data()
        TBMonitorProtocol.appendBE32(&data, 0x0102_0304)
        XCTAssertEqual([UInt8](data), [0x01, 0x02, 0x03, 0x04])
    }

    func testReadBE32HonorsOffset() {
        var data = Data()
        TBMonitorProtocol.appendBE32(&data, 0xAAAA_AAAA)
        TBMonitorProtocol.appendBE32(&data, 0x0000_BEEF)
        XCTAssertEqual(TBMonitorProtocol.readBE32(data, offset: 4), 0x0000_BEEF)
    }

    // MARK: - Packet framing

    func testMakePacketLayout() {
        let packet = TBMonitorProtocol.makePacket(type: .heartbeat, payload: Data([0xAA, 0xBB, 0xCC]))
        // length = 1 (type byte) + 3 (payload) = 4
        XCTAssertEqual([UInt8](packet), [0x00, 0x00, 0x00, 0x04, 0x30, 0xAA, 0xBB, 0xCC])
    }

    func testDrainPacketRoundTrip() throws {
        let payload = Data("hello receiver".utf8)
        var buffer = TBMonitorProtocol.makePacket(type: .helloReceiver, payload: payload)

        let drained = try TBMonitorProtocol.drainPacket(from: &buffer)
        XCTAssertNotNil(drained)
        XCTAssertEqual(drained?.0, .helloReceiver)
        XCTAssertEqual(drained?.1, payload)
        XCTAssertTrue(buffer.isEmpty, "drain must consume the packet")
    }

    func testDrainPacketEmptyPayload() throws {
        var buffer = TBMonitorProtocol.makePacket(type: .teardown, payload: Data())
        let drained = try TBMonitorProtocol.drainPacket(from: &buffer)
        XCTAssertEqual(drained?.0, .teardown)
        XCTAssertEqual(drained?.1, Data())
        XCTAssertTrue(buffer.isEmpty)
    }

    func testDrainPacketWaitsForCompleteHeader() {
        var buffer = Data([0x00, 0x00, 0x00, 0x04]) // header missing its 5th byte
        XCTAssertNil(try TBMonitorProtocol.drainPacket(from: &buffer))
        XCTAssertEqual(buffer.count, 4, "incomplete data must not be consumed")
    }

    func testDrainPacketWaitsForCompletePayload() {
        let full = TBMonitorProtocol.makePacket(type: .frame, payload: Data(repeating: 0x42, count: 100))
        var buffer = full.prefix(50) as Data
        XCTAssertNil(try TBMonitorProtocol.drainPacket(from: &buffer))
        XCTAssertEqual(buffer.count, 50, "incomplete data must not be consumed")
    }

    func testDrainTwoContiguousPackets() throws {
        var buffer = TBMonitorProtocol.makePacket(type: .cursor, payload: Data([0x01]))
        buffer.append(TBMonitorProtocol.makePacket(type: .brightness, payload: Data([0x02, 0x03])))

        let first = try TBMonitorProtocol.drainPacket(from: &buffer)
        XCTAssertEqual(first?.0, .cursor)
        XCTAssertEqual(first?.1, Data([0x01]))

        let second = try TBMonitorProtocol.drainPacket(from: &buffer)
        XCTAssertEqual(second?.0, .brightness)
        XCTAssertEqual(second?.1, Data([0x02, 0x03]))

        XCTAssertTrue(buffer.isEmpty)
    }

    /// Simulates TCP fragmentation: the packet arrives one byte at a time and
    /// must only drain once the final byte lands.
    func testDrainPacketAcrossSplitFeeds() throws {
        let packet = TBMonitorProtocol.makePacket(type: .clipboard, payload: Data("copy me".utf8))
        var buffer = Data()

        for (index, byte) in packet.enumerated() {
            buffer.append(byte)
            let drained = try TBMonitorProtocol.drainPacket(from: &buffer)
            if index < packet.count - 1 {
                XCTAssertNil(drained, "must not drain before byte \(packet.count - 1), drained at \(index)")
            } else {
                XCTAssertEqual(drained?.0, .clipboard)
                XCTAssertEqual(drained?.1, Data("copy me".utf8))
            }
        }
    }

    // MARK: - Corrupt and unknown framing

    func testDrainPacketThrowsOnZeroLength() {
        var buffer = Data([0x00, 0x00, 0x00, 0x00, 0x30])
        XCTAssertThrowsError(try TBMonitorProtocol.drainPacket(from: &buffer)) { error in
            XCTAssertEqual(error as? TBMonitorProtocolError, .invalidPacketLength(0))
        }
    }

    func testDrainPacketThrowsOnOversizedLength() {
        var buffer = Data()
        TBMonitorProtocol.appendBE32(&buffer, TBMonitorProtocol.maxPacketLength + 1)
        buffer.append(0x21)
        XCTAssertThrowsError(try TBMonitorProtocol.drainPacket(from: &buffer)) { error in
            XCTAssertEqual(error as? TBMonitorProtocolError, .invalidPacketLength(TBMonitorProtocol.maxPacketLength + 1))
        }
    }

    /// A corrupted length like 0xFFFFFFFF must fail fast instead of making the
    /// drain loop buffer inbound data forever for a packet that never completes.
    func testDrainPacketThrowsOnAllOnesLength() {
        var buffer = Data([0xFF, 0xFF, 0xFF, 0xFF, 0x21, 0x00])
        XCTAssertThrowsError(try TBMonitorProtocol.drainPacket(from: &buffer)) { error in
            XCTAssertEqual(error as? TBMonitorProtocolError, .invalidPacketLength(0xFFFF_FFFF))
        }
    }

    func testDrainPacketAcceptsLengthAtCapWhileWaitingForPayload() {
        var buffer = Data()
        TBMonitorProtocol.appendBE32(&buffer, TBMonitorProtocol.maxPacketLength)
        buffer.append(0x21)
        // Length is legal but the payload has not arrived: need more data, no throw.
        XCTAssertNil(try TBMonitorProtocol.drainPacket(from: &buffer))
        XCTAssertEqual(buffer.count, 5)
    }

    func testDrainPacketThrowsOnCorruptLengthBehindValidPacket() throws {
        var buffer = TBMonitorProtocol.makePacket(type: .heartbeat, payload: Data([0x01]))
        buffer.append(Data([0xFF, 0xFF, 0xFF, 0xFF, 0x21]))

        let first = try TBMonitorProtocol.drainPacket(from: &buffer)
        XCTAssertEqual(first?.0, .heartbeat)

        XCTAssertThrowsError(try TBMonitorProtocol.drainPacket(from: &buffer))
    }

    /// An unrecognized type byte (e.g. a packet from a newer peer) must be
    /// skipped so it cannot stall valid packets queued behind it.
    func testDrainPacketSkipsUnknownTypeAndReturnsNextPacket() throws {
        var buffer = Data()
        TBMonitorProtocol.appendBE32(&buffer, 3)
        buffer.append(contentsOf: [0xEE, 0x00, 0x00]) // unknown type 0xEE + 2 payload bytes
        buffer.append(TBMonitorProtocol.makePacket(type: .heartbeat, payload: Data([0x07])))

        let drained = try TBMonitorProtocol.drainPacket(from: &buffer)
        XCTAssertEqual(drained?.0, .heartbeat)
        XCTAssertEqual(drained?.1, Data([0x07]))
        XCTAssertTrue(buffer.isEmpty)
    }

    func testDrainPacketConsumesLoneUnknownType() throws {
        var buffer = Data()
        TBMonitorProtocol.appendBE32(&buffer, 1)
        buffer.append(0xEE)

        XCTAssertNil(try TBMonitorProtocol.drainPacket(from: &buffer))
        XCTAssertTrue(buffer.isEmpty, "unknown packet must be consumed, not left to stall the stream")
    }

    // MARK: - JSON payloads

    func testJSONPacketRoundTrip() throws {
        let heartbeat = TBMonitorHeartbeat(sequence: 42)
        guard var buffer = TBMonitorProtocol.makeJSONPacket(type: .heartbeat, value: heartbeat) else {
            XCTFail("encode failed"); return
        }
        guard let (type, payload) = try TBMonitorProtocol.drainPacket(from: &buffer) else {
            XCTFail("drain failed"); return
        }
        XCTAssertEqual(type, .heartbeat)
        XCTAssertEqual(TBMonitorProtocol.decodeJSON(TBMonitorHeartbeat.self, from: payload)?.sequence, 42)
    }

    // MARK: - Hand-rolled input-event encoder parity
    //
    // `makeInputEventPacket` documents this invariant: "emits the same JSON shape
    // `JSONDecoder` reconstructs into a `TBMonitorInputEvent` (omitted fields
    // decode as nil)". These tests guard it, since the receiver's snprintf-based
    // emitter mirrors the same shape.

    private func makeEvent(
        kind: String,
        dx: Int? = nil,
        dy: Int? = nil,
        scrollX: Int? = nil,
        scrollY: Int? = nil,
        keyCode: UInt16? = nil
    ) -> TBMonitorInputEvent {
        TBMonitorInputEvent(kind: kind, dx: dx, dy: dy, scrollX: scrollX, scrollY: scrollY, keyCode: keyCode)
    }

    private func assertEncoderParity(
        _ event: TBMonitorInputEvent,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var buffer = TBMonitorProtocol.makeInputEventPacket(event)
        guard let (type, payload) = try? TBMonitorProtocol.drainPacket(from: &buffer) ?? nil else {
            XCTFail("packet did not drain", file: file, line: line)
            return
        }
        XCTAssertEqual(type, .inputEvent, file: file, line: line)
        guard let decoded = TBMonitorProtocol.decodeJSON(TBMonitorInputEvent.self, from: payload) else {
            XCTFail("payload did not decode as TBMonitorInputEvent: \(String(decoding: payload, as: UTF8.self))",
                    file: file, line: line)
            return
        }
        XCTAssertEqual(decoded.kind, event.kind, file: file, line: line)
        XCTAssertEqual(decoded.dx, event.dx, file: file, line: line)
        XCTAssertEqual(decoded.dy, event.dy, file: file, line: line)
        XCTAssertEqual(decoded.scrollX, event.scrollX, file: file, line: line)
        XCTAssertEqual(decoded.scrollY, event.scrollY, file: file, line: line)
        XCTAssertEqual(decoded.keyCode, event.keyCode, file: file, line: line)
    }

    func testInputEventEncoderParityMouseMove() {
        assertEncoderParity(makeEvent(kind: "move", dx: 5, dy: -3))
    }

    func testInputEventEncoderParityScroll() {
        assertEncoderParity(makeEvent(kind: "scroll", scrollX: -120, scrollY: 42))
    }

    func testInputEventEncoderParityKeyDown() {
        assertEncoderParity(makeEvent(kind: "keyDown", keyCode: 0x24))
    }

    func testInputEventEncoderParityAllFields() {
        assertEncoderParity(makeEvent(kind: "drag", dx: 1, dy: 2, scrollX: 3, scrollY: 4, keyCode: UInt16.max))
    }

    func testInputEventEncoderParityNoOptionalFields() {
        assertEncoderParity(makeEvent(kind: "leftUp"))
    }

    func testInputEventEncoderParityExtremeValues() {
        assertEncoderParity(makeEvent(kind: "move", dx: Int.min, dy: Int.max))
    }
}
