import XCTest
import CoreVideo
import CoreGraphics
import ScreenCaptureKit
import Dispatch
import Metal
@testable import TargetBridge

final class TBPackedRGB10FrameTests: XCTestCase {
    func testCopyDiagnosticsPreservePacketBytesAndUseBalancedReadOnlyLocking() throws {
        let pixelBuffer = try paddedBuffer(width: 17, height: 3, stride: 128)
        _ = try fill(pixelBuffer) { x, y in 0xC000_0000 | UInt32(x + y) }
        let reference = try XCTUnwrap(TBPackedRGB10Frame.makePacket(pixelBuffer: pixelBuffer))
        var diagnostics: TBPackedRGB10Frame.Diagnostics?
        var lockCount = 0, unlockCount = 0
        let measured = try XCTUnwrap(TBPackedRGB10Frame.makePacket(
            pixelBuffer: pixelBuffer, diagnostics: { diagnostics = $0 },
            lockBaseAddress: { buffer, flags in
                XCTAssertEqual(flags, .readOnly)
                lockCount += 1
                return CVPixelBufferLockBaseAddress(buffer, flags)
            }, unlockBaseAddress: { buffer, flags in
                XCTAssertEqual(flags, .readOnly)
                unlockCount += 1
                return CVPixelBufferUnlockBaseAddress(buffer, flags)
            }))
        XCTAssertEqual(Data(measured), Data(reference))
        XCTAssertEqual(lockCount, 1)
        XCTAssertEqual(unlockCount, 1)
        let timing = try XCTUnwrap(diagnostics)
        XCTAssertEqual(timing.sourceStride, 128)
        XCTAssertFalse(timing.iosurfaceBacked)
        XCTAssertEqual(timing.lockResult, kCVReturnSuccess)
        for seconds in [timing.lockSeconds, timing.allocationSeconds, timing.copySeconds, timing.unlockSeconds] {
            XCTAssertTrue(seconds.isFinite)
            XCTAssertGreaterThanOrEqual(seconds, 0)
        }
    }

    func testLockFailureReportsDiagnosticsWithoutReadingOrUnlockingPixels() throws {
        let pixelBuffer = try paddedBuffer(width: 17, height: 3, stride: 128)
        var diagnostics: TBPackedRGB10Frame.Diagnostics?
        var lockCount = 0, unlockCount = 0
        let packet = TBPackedRGB10Frame.makePacket(
            pixelBuffer: pixelBuffer, diagnostics: { diagnostics = $0 },
            lockBaseAddress: { _, flags in
                XCTAssertEqual(flags, .readOnly)
                lockCount += 1
                return kCVReturnError
            }, unlockBaseAddress: { _, _ in
                unlockCount += 1
                return kCVReturnSuccess
            })
        XCTAssertNil(packet)
        XCTAssertEqual(lockCount, 1)
        XCTAssertEqual(unlockCount, 0)
        let timing = try XCTUnwrap(diagnostics)
        XCTAssertEqual(timing.lockResult, kCVReturnError)
        XCTAssertEqual(timing.allocationSeconds, 0)
        XCTAssertEqual(timing.copySeconds, 0)
        XCTAssertEqual(timing.unlockSeconds, 0)
    }

    func testLocalSendCompletionTimingBatchesAndResetsWithoutChangingPacketBudget() throws {
        let budget = TBVideoPacketBudget()
        XCTAssertTrue(budget.tryReserve(limit: 3))
        for invalid in [Double.nan, .infinity, -1] {
            XCTAssertNil(budget.recordLocalCompletion(seconds: invalid))
        }
        for _ in 0..<119 { XCTAssertNil(budget.recordLocalCompletion(seconds: 0.010)) }
        let batch = try XCTUnwrap(budget.recordLocalCompletion(seconds: 0.030))
        XCTAssertEqual(batch.count, 120)
        XCTAssertEqual(batch.meanSeconds, 1.22 / 120, accuracy: 0.00000001)
        XCTAssertEqual(batch.maxSeconds, 0.030)
        XCTAssertEqual(budget.snapshot, 1)
        budget.release()
        XCTAssertEqual(budget.snapshot, 0)
        for _ in 0..<119 { XCTAssertNil(budget.recordLocalCompletion(seconds: 0.002)) }
        let next = try XCTUnwrap(budget.recordLocalCompletion(seconds: 0.002))
        XCTAssertEqual(next.meanSeconds, 0.002, accuracy: 0.00000001)
        XCTAssertEqual(next.maxSeconds, 0.002)
    }

    func testPacketPreservesEveryRGB10LevelAndBothAlphaBits() throws {
        let width = 1024, height = 3
        let pixelBuffer = try paddedBuffer(width: width, height: height, stride: width * 4 + 64)
        let expectedPixels = try fill(pixelBuffer) { x, y in
            (UInt32(x & 3) << 30) | (UInt32(x) << (y * 10))
        }
        let packet = try XCTUnwrap(TBPackedRGB10Frame.makePacket(pixelBuffer: pixelBuffer))
        let wire = Data(packet)
        assertHeader(wire, width: width, height: height)
        XCTAssertEqual(wire.subdata(in: 22..<wire.count), expectedPixels)

        var remaining = wire
        let (type, payload) = try XCTUnwrap(try TBMonitorProtocol.drainPacket(from: &remaining))
        XCTAssertEqual(type, .rawFrame)
        XCTAssertEqual(payload.first, 2)
        XCTAssertEqual(payload.dropFirst(17), expectedPixels)
        XCTAssertTrue(remaining.isEmpty)
    }

    func testPaddedSourceCanBeOverwrittenAndReleasedBeforeAsynchronousPacketRead() throws {
        let released = expectation(description: "CoreVideo released the borrowed source")
        let width = 17, height = 3, sourceStride = 128
        let retained: (DispatchData, Data) = try autoreleasepool {
            let pixelBuffer = try paddedBuffer(width: width, height: height,
                                               stride: sourceStride, released: released)
            let expectedPixels = try fill(pixelBuffer) { x, y in
                let blue = UInt32((x + y) & 1023)
                let green = UInt32((x * 13 + y) & 1023)
                let red = UInt32((x * 29 + y) & 1023)
                return (UInt32((x + y) & 3) << 30) | (red << 20) | (green << 10) | blue
            }
            let packet = try XCTUnwrap(TBPackedRGB10Frame.makePacket(pixelBuffer: pixelBuffer))
            XCTAssertEqual(packet.count, 22 + width * height * 4)
            let replacement = try fill(pixelBuffer) { _, _ in 0xEFFF_FFFF }
            let newerPacket = try XCTUnwrap(TBPackedRGB10Frame.makePacket(pixelBuffer: pixelBuffer))
            XCTAssertEqual(Data(newerPacket).dropFirst(22), replacement)
            return (packet, expectedPixels)
        }
        wait(for: [released], timeout: 2)

        let read = expectation(description: "packet remains valid after source destruction")
        DispatchQueue(label: "test.raw10.owned-packet").async {
            let wire = Data(retained.0)
            XCTAssertEqual(wire.dropFirst(22), retained.1)
            XCTAssertEqual(wire.count, 22 + width * height * 4)
            read.fulfill()
        }
        wait(for: [read], timeout: 2)
    }

    func testFourPointFiveKFrameUsesOneTight32BitPixelPerSample() throws {
        let width = 4480, height = 2520
        let pixelBuffer = try paddedBuffer(width: width, height: height, stride: width * 4)
        let packet = try XCTUnwrap(TBPackedRGB10Frame.makePacket(pixelBuffer: pixelBuffer))
        XCTAssertEqual(packet.count, 45_158_422)
        XCTAssertLessThan(packet.count - 4, Int(TBMonitorProtocol.maxPacketLength))
        assertHeader(Data(packet.subdata(in: 0..<22)), width: width, height: height,
                     completePacketCount: packet.count)
    }

    func testPackedDimensionLimitsAcceptEdgesAndRejectOversizedBuffers() throws {
        for (width, height) in [(1, 1), (5120, 1), (1, 2880)] {
            let pixelBuffer = try paddedBuffer(width: width, height: height, stride: width * 4)
            let packet = try XCTUnwrap(TBPackedRGB10Frame.makePacket(pixelBuffer: pixelBuffer))
            assertHeader(Data(packet), width: width, height: height)
        }
        for (width, height) in [(5121, 1), (1, 2881)] {
            let pixelBuffer = try paddedBuffer(width: width, height: height, stride: width * 4)
            XCTAssertNil(TBPackedRGB10Frame.makePacket(pixelBuffer: pixelBuffer))
        }
    }

    func testEightBitRGBAndPlanarNV12AreRejected() throws {
        for format in [kCVPixelFormatType_32BGRA, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange] {
            var pixelBuffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, format, nil, &pixelBuffer),
                           kCVReturnSuccess)
            XCTAssertNil(TBPackedRGB10Frame.makePacket(pixelBuffer: try XCTUnwrap(pixelBuffer)))
        }
    }

    func testRawRGB10RequiresExplicitReceiverCapabilityAndRequest() {
        for capability: Bool? in [nil, false] {
            XCTAssertEqual(TBVideoTransport.resolve(supportsRawNV12: true, rawOverride: true,
                                                    wantsRawRGB10: true, supportsRawRGB10: capability), .encoded)
        }
        XCTAssertEqual(TBVideoTransport.resolve(supportsRawNV12: nil, rawOverride: false,
                                                wantsRawRGB10: true, supportsRawRGB10: true), .rawRGB10Bit)
        XCTAssertEqual(TBVideoTransport.resolve(supportsRawNV12: true, rawOverride: false,
                                                wantsRawRGB10: false, supportsRawRGB10: true), .encoded)

    }

    func testLegacyReceiverProfileDoesNotAcquireRawRGB10Capability() throws {
        let oldProfile = Data("""
        {"receiverName":"Old Receiver","panelWidth":4480,"panelHeight":2520,
         "modeWidth":2240,"modeHeight":1260,"refreshRate":60,"hiDPI":true,
         "captureWidth":4480,"captureHeight":2520,"supportsRawNV12":true}
        """.utf8)
        let decoded = try JSONDecoder().decode(TBMonitorDisplayProfile.self, from: oldProfile)
        XCTAssertNil(decoded.supportsRawRGB10)
        for capability: Bool? in [nil, false, true] {
            var profile = decoded
            profile.supportsRawRGB10 = capability
            let roundTrip = try JSONDecoder().decode(TBMonitorDisplayProfile.self,
                                                     from: JSONEncoder().encode(profile))
            XCTAssertEqual(roundTrip.supportsRawRGB10, capability)
        }
    }

    func testRawRGB10PresetCapturesNativeFourPointFiveKWithTenBitDisplayP3() {
        let preset = TBDisplayCapturePreset.native4_5kRGB10Raw60
        XCTAssertEqual(preset.width, 4480)
        XCTAssertEqual(preset.height, 2520)
        XCTAssertEqual(preset.expectedFrameRate, 60)
        XCTAssertTrue(preset.isRawRGB10)
        XCTAssertFalse(preset.rendersAtNativeScale)
        XCTAssertEqual(preset.renderMatchedDisplayMode.width, 2240)
        XCTAssertEqual(preset.renderMatchedDisplayMode.height, 1260)
        let configuration = SCStreamConfiguration()
        TBVideoTransport.rawRGB10Bit.configureCapture(configuration)
        XCTAssertEqual(configuration.pixelFormat, kCVPixelFormatType_ARGB2101010LEPacked)
        XCTAssertEqual(configuration.colorSpaceName, CGColorSpace.displayP3)
    }

    func testRawDiagnosticsUseTheSameElapsedWindowAsFPS() throws {
        var statistics = TBVideoSubmissionStatistics()
        let before = statistics.snapshot(at: 10)
        for _ in 0..<120 {
            statistics.record(packetBytes: 45_158_422, rgb: .init(
                width: 4480, height: 2520, encodePacketSeconds: 0.0008,
                usesGPU: false, isUncompressed: true))
        }
        let rate = TBVideoSubmissionStatistics.rate(from: before, to: statistics.snapshot(at: 12))
        let raw = try XCTUnwrap(rate.rgb)
        XCTAssertEqual(rate.framesPerSecond, 60, accuracy: 0.0001)
        XCTAssertTrue(raw.isUncompressed)
        XCTAssertEqual(raw.captureWidth, 4480)
        XCTAssertEqual(raw.captureHeight, 2520)
        XCTAssertEqual(raw.submittedGbps, 21.67604256, accuracy: 0.00000001)
        XCTAssertEqual(try XCTUnwrap(raw.meanPacketMB), 45.158422, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(raw.meanEncodePacketMS), 0.8, accuracy: 0.0001)
    }

    func testRawIdleWindowPreservesTransportButDoesNotReuseOldRatesAfterRestart() throws {
        var statistics = TBVideoSubmissionStatistics()
        statistics.record(packetBytes: 45_158_422, rgb: .init(
            width: 4480, height: 2520, encodePacketSeconds: 0.001,
            usesGPU: false, isUncompressed: true))
        let before = statistics.snapshot(at: 1)
        let idle = TBVideoSubmissionStatistics.rate(from: before, to: statistics.snapshot(at: 2))
        let raw = try XCTUnwrap(idle.rgb)
        XCTAssertTrue(raw.isUncompressed)
        XCTAssertEqual(idle.framesPerSecond, 0)
        XCTAssertEqual(raw.submittedGbps, 0)
        XCTAssertNil(raw.meanPacketMB)
        XCTAssertNil(raw.meanEncodePacketMS)
        let restarted = TBVideoSubmissionStatistics.rate(
            from: before, to: TBVideoSubmissionStatistics().snapshot(at: 3))
        XCTAssertNil(restarted.rgb)
    }



    private func paddedBuffer(width: Int, height: Int, stride: Int,
                              released: XCTestExpectation? = nil) throws -> CVPixelBuffer {
        let source = try XCTUnwrap(calloc(height, stride))
        // Nonzero padding catches accidental transmission of capture row padding.
        memset(source, 0xA5, height * stride)
        let context = released.map { Unmanaged.passRetained($0).toOpaque() }
        var pixelBuffer: CVPixelBuffer?
        let result = CVPixelBufferCreateWithBytes(kCFAllocatorDefault, width, height,
            kCVPixelFormatType_ARGB2101010LEPacked, source, stride, { context, bytes in
                free(UnsafeMutableRawPointer(mutating: bytes))
                if let context {
                    Unmanaged<XCTestExpectation>.fromOpaque(context).takeRetainedValue().fulfill()
                }
            }, context, nil, &pixelBuffer)
        guard result == kCVReturnSuccess else {
            free(source)
            if let context { Unmanaged<XCTestExpectation>.fromOpaque(context).release() }
            XCTFail("CVPixelBufferCreateWithBytes failed: \(result)")
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(result))
        }
        return try XCTUnwrap(pixelBuffer)
    }

    private func fill(_ pixelBuffer: CVPixelBuffer, pixel: (Int, Int) -> UInt32) throws -> Data {
        XCTAssertEqual(CVPixelBufferLockBaseAddress(pixelBuffer, []), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixelBuffer))
        let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        var expected = Data(capacity: width * height * 4)
        for y in 0..<height {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt32.self)
            for x in 0..<width {
                let value = pixel(x, y)
                row[x] = value.littleEndian
                expected.append(contentsOf: [UInt8(truncatingIfNeeded: value),
                    UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value >> 16),
                    UInt8(truncatingIfNeeded: value >> 24)])
            }
        }
        return expected
    }

    private func assertHeader(_ wire: Data, width: Int, height: Int,
                              completePacketCount: Int? = nil,
                              file: StaticString = #filePath, line: UInt = #line) {
        let expectedCount = 22 + width * height * 4
        XCTAssertEqual(completePacketCount ?? wire.count, expectedCount, file: file, line: line)
        guard wire.count >= 22 else { XCTFail("Truncated raw header", file: file, line: line); return }
        XCTAssertEqual(TBMonitorProtocol.readBE32(wire, offset: 0), UInt32(expectedCount - 4), file: file, line: line)
        XCTAssertEqual(wire[4], 0x22, file: file, line: line)
        XCTAssertEqual(wire[5], 2, file: file, line: line)
        XCTAssertEqual(TBMonitorProtocol.readBE32(wire, offset: 6), UInt32(width), file: file, line: line)
        XCTAssertEqual(TBMonitorProtocol.readBE32(wire, offset: 10), UInt32(height), file: file, line: line)
        XCTAssertEqual(TBMonitorProtocol.readBE32(wire, offset: 14), UInt32(width * 4), file: file, line: line)
        XCTAssertEqual(TBMonitorProtocol.readBE32(wire, offset: 18), 0, file: file, line: line)
    }
}

final class TBPackedRGB10PacketPoolTests: XCTestCase {
    private final class Allocator: @unchecked Sendable {
        private let lock = NSLock()
        private var failNext = false
        private var allocations = 0
        private var frees = 0

        var counts: (allocations: Int, frees: Int) {
            lock.lock(); defer { lock.unlock() }
            return (allocations, frees)
        }

        func failNextAllocation() {
            lock.lock(); failNext = true; lock.unlock()
        }

        func allocate(_ count: Int) -> UnsafeMutableRawPointer? {
            lock.lock()
            if failNext { failNext = false; lock.unlock(); return nil }
            lock.unlock()
            guard let bytes = malloc(count) else { return nil }
            lock.lock(); allocations += 1; lock.unlock()
            return bytes
        }

        func deallocate(_ bytes: UnsafeMutableRawPointer) {
            free(bytes)
            lock.lock(); frees += 1; lock.unlock()
        }
    }

    func testSubrangeAndConcatenationKeepStorageLeasedAfterSendCompletion() throws {
        let recycler = DispatchQueue(label: "test.raw10.pool.references")
        let pool = TBPackedRGB10PacketPool(limit: 1, recycler: recycler)
        defer { pool.close() }
        let buffer = try makeBuffer(width: 1024, height: 3, padding: 64, seed: 7)
        let expected = Data(try XCTUnwrap(TBPackedRGB10Frame.makePacket(pixelBuffer: buffer)))
        var subrange: DispatchData?
        var concatenation: DispatchData?
        try autoreleasepool {
            let packet = try XCTUnwrap(TBPackedRGB10Frame.makePacket(pixelBuffer: buffer, pool: pool))
            XCTAssertEqual(Data(packet), expected)
            subrange = packet.subdata(in: 22..<packet.count)
            var joined = Data([0x5A]).withUnsafeBytes { DispatchData(bytes: $0) }
            joined.append(subrange!)
            concatenation = joined
        }
        // A local Network completion is only a send-budget event. The original
        // allocation still backs both DispatchData objects held above.
        let budget = TBVideoPacketBudget()
        XCTAssertTrue(budget.tryReserve(limit: 3))
        budget.release()
        XCTAssertEqual(budget.snapshot, 0)
        XCTAssertNil(TBPackedRGB10Frame.makePacket(pixelBuffer: buffer, pool: pool))
        XCTAssertEqual(Data(try XCTUnwrap(subrange)), expected.dropFirst(22))
        autoreleasepool { subrange = nil }
        recycler.sync {}
        XCTAssertEqual(pool.snapshot.idle, 0)
        XCTAssertNil(TBPackedRGB10Frame.makePacket(pixelBuffer: buffer, pool: pool))
        XCTAssertEqual(Data(try XCTUnwrap(concatenation)).dropFirst(), expected.dropFirst(22))
        autoreleasepool { concatenation = nil }
        recycler.sync {}
        XCTAssertEqual(pool.snapshot.allocated, 1)
        XCTAssertEqual(pool.snapshot.idle, 1)
        XCTAssertNotNil(TBPackedRGB10Frame.makePacket(pixelBuffer: buffer, pool: pool))
    }

    func testQueuedRecyclersStillOccupyAllThreeSlotsWithoutExtraAllocations() throws {
        let recycler = DispatchQueue(label: "test.raw10.pool.blocked")
        let allocator = Allocator()
        let pool = TBPackedRGB10PacketPool(limit: 3, recycler: recycler,
                                          allocate: { allocator.allocate($0) }, deallocate: { allocator.deallocate($0) })
        let buffer = try makeBuffer(width: 17, height: 3, padding: 60, seed: 1)
        recycler.suspend()
        do {
            defer { recycler.resume() }
            try autoreleasepool {
                var held: [DispatchData] = []
                var expected: [Data] = []
                for frame in 0..<3 {
                    let source = try makeBuffer(width: 17, height: 3, padding: 60, seed: UInt32(frame * 257))
                    expected.append(Data(try XCTUnwrap(TBPackedRGB10Frame.makePacket(pixelBuffer: source))))
                    held.append(try XCTUnwrap(TBPackedRGB10Frame.makePacket(pixelBuffer: source, pool: pool)))
                }
                for (packet, bytes) in zip(held, expected) { XCTAssertEqual(Data(packet), bytes) }
                XCTAssertEqual(pool.snapshot.allocated, 3)
                held.removeAll()
            }
            XCTAssertEqual(pool.snapshot.idle, 0)
            var locks = 0
            for _ in 0..<10 {
                XCTAssertNil(TBPackedRGB10Frame.makePacket(pixelBuffer: buffer, pool: pool, diagnostics: nil,
                    lockBaseAddress: { _, _ in locks += 1; return kCVReturnSuccess },
                    unlockBaseAddress: { _, _ in XCTFail("Full pool must not lock pixels"); return kCVReturnSuccess }))
            }
            XCTAssertEqual(locks, 0)
            XCTAssertEqual(pool.snapshot.allocated, 3)
            XCTAssertEqual(pool.snapshot.capacityMisses, 10)
            XCTAssertEqual(allocator.counts.allocations, 3)
        }
        recycler.sync {}
        XCTAssertEqual(pool.snapshot.idle, 3)
        try autoreleasepool {
            XCTAssertNotNil(try XCTUnwrap(TBPackedRGB10Frame.makePacket(pixelBuffer: buffer, pool: pool)))
        }
        recycler.sync {}
        XCTAssertEqual(allocator.counts.allocations, 3)
        pool.close()
        XCTAssertEqual(allocator.counts.frees, 3)
    }

    func testCloseFreesIdleAndLatePacketsCannotEnterAnotherSession() throws {
        let recycler = DispatchQueue(label: "test.raw10.pool.close")
        let allocator = Allocator()
        let pool = TBPackedRGB10PacketPool(limit: 2, recycler: recycler,
                                          allocate: { allocator.allocate($0) }, deallocate: { allocator.deallocate($0) })
        let buffer = try makeBuffer(width: 17, height: 3, padding: 60, seed: 0x123)
        var held: DispatchData? = TBPackedRGB10Frame.makePacket(pixelBuffer: buffer, pool: pool)
        let expected = Data(try XCTUnwrap(TBPackedRGB10Frame.makePacket(pixelBuffer: buffer)))
        try autoreleasepool {
            _ = try XCTUnwrap(TBPackedRGB10Frame.makePacket(pixelBuffer: buffer, pool: pool))
        }
        recycler.sync {}
        XCTAssertEqual(pool.snapshot.idle, 1)
        pool.close()
        pool.close()
        XCTAssertTrue(pool.snapshot.isClosed)
        XCTAssertEqual(pool.snapshot.allocated, 1)
        XCTAssertEqual(allocator.counts.frees, 1)
        XCTAssertNil(TBPackedRGB10Frame.makePacket(pixelBuffer: buffer, pool: pool))
        XCTAssertEqual(Data(try XCTUnwrap(held)), expected)

        let next = TBPackedRGB10PacketPool(limit: 1, recycler: recycler)
        defer { next.close() }
        let replacement = try makeBuffer(width: 31, height: 5, padding: 4, seed: 0x321)
        let newPacket = try XCTUnwrap(TBPackedRGB10Frame.makePacket(pixelBuffer: replacement, pool: next))
        let newBytes = Data(newPacket)
        autoreleasepool { held = nil }
        recycler.sync {}
        XCTAssertEqual(pool.snapshot.allocated, 0)
        XCTAssertEqual(allocator.counts.frees, 2)
        XCTAssertEqual(next.snapshot.allocated, 1)
        XCTAssertEqual(next.snapshot.idle, 0)
        XCTAssertEqual(Data(newPacket), newBytes)
    }

    func testResizeReusesOnlyIdleStorageAndPreservesExactFrameBytes() throws {
        let recycler = DispatchQueue(label: "test.raw10.pool.resize")
        let allocator = Allocator()
        let pool = TBPackedRGB10PacketPool(limit: 1, recycler: recycler,
                                          allocate: { allocator.allocate($0) }, deallocate: { allocator.deallocate($0) })
        for (width, height, padding, seed) in [(1024, 3, 64, 7), (17, 3, 60, 55), (2048, 4, 32, 99)] {
            let buffer = try makeBuffer(width: width, height: height, padding: padding, seed: UInt32(seed))
            let expected = Data(try XCTUnwrap(TBPackedRGB10Frame.makePacket(pixelBuffer: buffer)))
            try autoreleasepool {
                let packet = try XCTUnwrap(TBPackedRGB10Frame.makePacket(pixelBuffer: buffer, pool: pool))
                XCTAssertEqual(packet.count, 22 + width * height * 4)
                XCTAssertEqual(Data(packet), expected)
                // Recycle the capture source while the owned network frame lives.
                XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
                memset(CVPixelBufferGetBaseAddress(buffer), 0, CVPixelBufferGetBytesPerRow(buffer) * height)
                CVPixelBufferUnlockBaseAddress(buffer, [])
                XCTAssertEqual(Data(packet), expected)
            }
            recycler.sync {}
            XCTAssertEqual(pool.snapshot.allocated, 1)
            XCTAssertEqual(pool.snapshot.idle, 1)
            XCTAssertEqual(allocator.counts.allocations, width == 2048 ? 2 : 1)
        }
        XCTAssertEqual(allocator.counts.frees, 1)
        pool.close()
        XCTAssertEqual(allocator.counts.frees, 2)
    }

    func testAllocationAndPixelLockFailuresReturnReservedCapacity() throws {
        let recycler = DispatchQueue(label: "test.raw10.pool.failure")
        let allocator = Allocator()
        let pool = TBPackedRGB10PacketPool(limit: 1, recycler: recycler,
                                          allocate: { allocator.allocate($0) }, deallocate: { allocator.deallocate($0) })
        let buffer = try makeBuffer(width: 17, height: 3, padding: 60, seed: 9)
        allocator.failNextAllocation()
        XCTAssertNil(TBPackedRGB10Frame.makePacket(pixelBuffer: buffer, pool: pool))
        XCTAssertEqual(pool.snapshot.allocated, 0)
        XCTAssertEqual(pool.snapshot.capacityMisses, 0)
        XCTAssertNil(TBPackedRGB10Frame.makePacket(pixelBuffer: buffer, pool: pool, diagnostics: nil,
            lockBaseAddress: { _, _ in kCVReturnError },
            unlockBaseAddress: { _, _ in XCTFail("Failed lock must not unlock"); return kCVReturnSuccess }))
        XCTAssertEqual(pool.snapshot.allocated, 1)
        XCTAssertEqual(pool.snapshot.idle, 1)
        try autoreleasepool {
            _ = try XCTUnwrap(TBPackedRGB10Frame.makePacket(pixelBuffer: buffer, pool: pool))
        }
        recycler.sync {}
        XCTAssertEqual(allocator.counts.allocations, 1)
        let bigger = try makeBuffer(width: 1024, height: 3, padding: 64, seed: 12)
        allocator.failNextAllocation()
        XCTAssertNil(TBPackedRGB10Frame.makePacket(pixelBuffer: bigger, pool: pool))
        XCTAssertEqual(pool.snapshot.allocated, 0)
        XCTAssertEqual(allocator.counts.frees, 1)
        pool.close()
    }

    func testPacketOwnsPoolUntilFinalReleaseWithoutRetainingPipeline() throws {
        let recycler = DispatchQueue(label: "test.raw10.pool.lifetime")
        let allocator = Allocator()
        var pool: TBPackedRGB10PacketPool? = TBPackedRGB10PacketPool(limit: 1, recycler: recycler,
            allocate: { allocator.allocate($0) }, deallocate: { allocator.deallocate($0) })
        weak var weakPool = pool
        let buffer = try makeBuffer(width: 17, height: 3, padding: 60, seed: 0)
        var packet: DispatchData? = TBPackedRGB10Frame.makePacket(pixelBuffer: buffer, pool: pool)
        XCTAssertNotNil(packet)
        pool = nil
        XCTAssertNotNil(weakPool)
        autoreleasepool { packet = nil }
        recycler.sync {}
        XCTAssertNil(weakPool)
        XCTAssertEqual(allocator.counts.allocations, 1)
        XCTAssertEqual(allocator.counts.frees, 1)
    }

    private func makeBuffer(width: Int, height: Int, padding: Int, seed: UInt32) throws -> CVPixelBuffer {
        let stride = width * 4 + padding
        let bytes = try XCTUnwrap(malloc(stride * height))
        memset(bytes, 0xA5, stride * height)
        for y in 0..<height {
            let row = bytes.advanced(by: y * stride).assumingMemoryBound(to: UInt32.self)
            for x in 0..<width {
                let n = UInt32(x) &+ seed
                row[x] = ((n & 3) << 30 | ((n & 1023) << 20) |
                    (((n &* 13) & 1023) << 10) | ((n &+ UInt32(y)) & 1023)).littleEndian
            }
        }
        var buffer: CVPixelBuffer?
        let result = CVPixelBufferCreateWithBytes(kCFAllocatorDefault, width, height,
            kCVPixelFormatType_ARGB2101010LEPacked, bytes, stride,
            { _, p in free(UnsafeMutableRawPointer(mutating: p)) }, nil, nil, &buffer)
        if result != kCVReturnSuccess { free(bytes) }
        XCTAssertEqual(result, kCVReturnSuccess)
        return try XCTUnwrap(buffer)
    }
}

// Add `import Metal` to TBPackedRGB10FrameTests.swift when appending this class.
final class TBPackedRGB10GPUCopierTests: XCTestCase {
    private struct GPUContext {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let cache: CVMetalTextureCache
        let producer: MTLComputePipelineState
    }
    private struct Source {
        let pixelBuffer: CVPixelBuffer
        let view: CVMetalTexture
        let texture: MTLTexture
    }

    private func context() throws -> GPUContext {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal device unavailable") }
        let queue = try XCTUnwrap(device.makeCommandQueue())
        var cache: CVMetalTextureCache?
        XCTAssertEqual(CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache), kCVReturnSuccess)
        let library = try device.makeLibrary(source: """
        #include <metal_stdlib>
        using namespace metal;
        kernel void fill(texture2d<float, access::write> output [[texture(0)]],
                         constant uint& seed [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {
            if (p.x >= output.get_width() || p.y >= output.get_height()) return;
            uint b = (p.x + seed) & 1023u;
            uint g = (p.x * 5u + p.y + seed) & 1023u;
            uint r = (p.x * 13u + p.y * 7u + seed) & 1023u;
            uint a = (p.x + p.y + seed) & 3u;
            output.write(float4(float(r)/1023.0f, float(g)/1023.0f,
                                float(b)/1023.0f, float(a)/3.0f), p);
        }
        """, options: nil)
        let producer = try device.makeComputePipelineState(function: XCTUnwrap(library.makeFunction(name: "fill")))
        return GPUContext(device: device, queue: queue, cache: try XCTUnwrap(cache), producer: producer)
    }

    private func source(_ context: GPUContext, width: Int, height: Int) throws -> Source {
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferBytesPerRowAlignmentKey as String: 256
        ]
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height,
            kCVPixelFormatType_ARGB2101010LEPacked, attributes as CFDictionary, &pixelBuffer), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixelBuffer)
        var view: CVMetalTexture?
        let usage: MTLTextureUsage = [.shaderRead, .shaderWrite]
        XCTAssertEqual(CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, context.cache, buffer,
            [kCVMetalTextureUsage as String: usage.rawValue] as CFDictionary, .bgr10a2Unorm,
            width, height, 0, &view), kCVReturnSuccess)
        let retainedView = try XCTUnwrap(view)
        return Source(pixelBuffer: buffer, view: retainedView,
                      texture: try XCTUnwrap(CVMetalTextureGetTexture(retainedView)))
    }

    private func produce(_ source: Source, context: GPUContext, seed: UInt32) throws {
        let command = try XCTUnwrap(context.queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(command.makeComputeCommandEncoder())
        encoder.setComputePipelineState(context.producer)
        encoder.setTexture(source.texture, index: 0)
        var value = seed
        encoder.setBytes(&value, length: MemoryLayout<UInt32>.size, index: 0)
        encoder.dispatchThreads(MTLSize(width: source.texture.width, height: source.texture.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 32, height: 8, depth: 1))
        encoder.endEncoding()
        command.commit()
        withExtendedLifetime(source) { command.waitUntilCompleted() }
        XCTAssertEqual(command.status, .completed, String(describing: command.error))
    }

    private static func packedPixel(x: Int, y: Int, seed: UInt32) -> UInt32 {
        let x = UInt32(x), y = UInt32(y)
        return ((x + seed) & 1023) | (((x * 5 + y + seed) & 1023) << 10)
            | (((x * 13 + y * 7 + seed) & 1023) << 20) | (((x + y + seed) & 3) << 30)
    }

    func testGPUCopyPreservesAllRGBAndAlphaBitsAfterSourceReuseAndFinalPacketSubrangeRelease() throws {
        let context = try context()
        var source: Source? = try source(context, width: 1024, height: 4)
        try produce(try XCTUnwrap(source), context: context, seed: 17)
        let recycler = DispatchQueue(label: "test.raw10.gpu.ownership")
        let pool = TBPackedRGB10PacketPool(limit: 1, device: context.device, recycler: recycler)
        defer { pool.close() }
        let copier = try XCTUnwrap(TBPackedRGB10GPUCopier(device: context.device))
        var timing: TBPackedRGB10Frame.Diagnostics?
        var packet = copier.makePacket(pixelBuffer: try XCTUnwrap(source).pixelBuffer, pool: pool,
                                       diagnostics: { timing = $0 })
        XCTAssertNotNil(packet)
        let measured = try XCTUnwrap(timing)
        XCTAssertTrue(measured.usesGPU)
        XCTAssertEqual(measured.lockSeconds, 0)
        XCTAssertEqual(measured.copySeconds, 0)
        XCTAssertEqual(measured.unlockSeconds, 0)
        XCTAssertGreaterThanOrEqual(measured.gpuCompletionSeconds, measured.gpuSubmitSeconds)
        // The CPU packer is the independent wire-format and byte oracle.
        let reference = Data(try XCTUnwrap(TBPackedRGB10Frame.makePacket(
            pixelBuffer: try XCTUnwrap(source).pixelBuffer)))
        // Do not map the body before rewriting the source: Foundation could
        // otherwise cache a contiguous copy and mask a borrowed-source bug.
        var regionSizes: [Int] = []
        var actualHeader = Data()
        packet!.enumerateBytes { bytes, offset, _ in
            regionSizes.append(bytes.count)
            if offset == 0 { actualHeader = Data(bytes: bytes.baseAddress!, count: bytes.count) }
        }
        XCTAssertEqual(regionSizes, [22, 1024 * 4 * 4])
        XCTAssertEqual(actualHeader, reference.prefix(22))
        var retainedBody: DispatchData? = packet!.subdata(in: 22..<packet!.count)
        packet = nil
        recycler.sync {}
        XCTAssertEqual(pool.snapshot.idle, 0)
        XCTAssertNil(copier.makePacket(pixelBuffer: try XCTUnwrap(source).pixelBuffer, pool: pool))
        XCTAssertEqual(pool.snapshot.allocated, 1)
        // The producer rewrites and releases the IOSurface before delayed packet
        // reading. Only the independent output buffer may back network bytes.
        try produce(try XCTUnwrap(source), context: context, seed: 733)
        source = nil
        CVMetalTextureCacheFlush(context.cache, 0)
        autoreleasepool { XCTAssertEqual(Data(retainedBody!), reference.dropFirst(22)) }
        retainedBody = nil
        recycler.sync {}
        XCTAssertEqual(pool.snapshot.idle, 1)
        XCTAssertEqual(pool.snapshot.allocated, 1)
    }

    func testGPUCopyFullIMac4_5KChecksEveryPackedPixel() throws {
        let context = try context()
        let source = try source(context, width: 4480, height: 2520)
        try produce(source, context: context, seed: 31)
        let pool = TBPackedRGB10PacketPool(device: context.device)
        defer { pool.close() }
        let copier = try XCTUnwrap(TBPackedRGB10GPUCopier(device: context.device))
        let packet = try XCTUnwrap(copier.makePacket(pixelBuffer: source.pixelBuffer, pool: pool))
        XCTAssertEqual(packet.count, 45_158_422)
        let data = Data(packet)
        XCTAssertEqual(Array(data.prefix(22)), [0x02, 0xB1, 0x10, 0x12, 0x22, 0x02,
                                              0x00, 0x00, 0x11, 0x80, 0x00, 0x00, 0x09, 0xD8,
                                              0x00, 0x00, 0x46, 0x00, 0x00, 0x00, 0x00, 0x00])
        let allPixelsMatch = data.withUnsafeBytes { bytes in
            for y in 0..<2520 {
                for x in 0..<4480 {
                    let value = bytes.loadUnaligned(fromByteOffset: 22 + (y * 4480 + x) * 4, as: UInt32.self)
                    if value != Self.packedPixel(x: x, y: y, seed: 31) { return false }
                }
            }
            return true
        }
        XCTAssertTrue(allPixelsMatch)
    }

    func testMetalAllocationFailureFallsBackWithinSameSlot() throws {
        let context = try context()
        let source = try source(context, width: 64, height: 4)
        try produce(source, context: context, seed: 31)
        let pool = TBPackedRGB10PacketPool(limit: 1, device: context.device,
                                           makeMetalBuffer: { _, _ in nil })
        defer { pool.close() }
        let copier = try XCTUnwrap(TBPackedRGB10GPUCopier(device: context.device))
        XCTAssertNil(copier.makePacket(pixelBuffer: source.pixelBuffer, pool: pool))
        XCTAssertEqual(pool.snapshot.allocated, 1)
        XCTAssertEqual(pool.snapshot.idle, 1)
        let packet = try XCTUnwrap(TBPackedRGB10Frame.makePacket(pixelBuffer: source.pixelBuffer, pool: pool))
        XCTAssertEqual(Data(packet), Data(try XCTUnwrap(TBPackedRGB10Frame.makePacket(pixelBuffer: source.pixelBuffer))))
        XCTAssertEqual(pool.snapshot.allocated, 1)
        XCTAssertNil(copier.makePacket(pixelBuffer: source.pixelBuffer, pool: pool))
        XCTAssertNil(TBPackedRGB10Frame.makePacket(pixelBuffer: source.pixelBuffer, pool: pool))
        XCTAssertEqual(pool.snapshot.allocated, 1)
    }

    func testNonAlignedWidthUsesCPUFallbackWithSameMetalPoolAndNoWirePadding() throws {
        let context = try context()
        let source = try source(context, width: 65, height: 7)
        try produce(source, context: context, seed: 7)
        XCTAssertGreaterThan(CVPixelBufferGetBytesPerRow(source.pixelBuffer), 65 * 4)
        let pool = TBPackedRGB10PacketPool(limit: 1, device: context.device)
        defer { pool.close() }
        let copier = try XCTUnwrap(TBPackedRGB10GPUCopier(device: context.device))
        XCTAssertNil(copier.makePacket(pixelBuffer: source.pixelBuffer, pool: pool))
        XCTAssertEqual(pool.snapshot.allocated, 0)
        var timing: TBPackedRGB10Frame.Diagnostics?
        let packet = try XCTUnwrap(TBPackedRGB10Frame.makePacket(pixelBuffer: source.pixelBuffer,
            pool: pool, diagnostics: { timing = $0 }))
        XCTAssertFalse(try XCTUnwrap(timing).usesGPU)
        XCTAssertEqual(packet.count, 22 + 65 * 7 * 4)
        XCTAssertEqual(pool.snapshot.allocated, 1)
        let reference = Data(try XCTUnwrap(TBPackedRGB10Frame.makePacket(pixelBuffer: source.pixelBuffer)))
        XCTAssertEqual(Data(packet), reference)
    }
}
