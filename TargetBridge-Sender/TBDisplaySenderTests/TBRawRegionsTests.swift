import Compression
import CoreGraphics
import CoreVideo
import XCTest
@testable import TargetBridge

final class TBRawRegionsTests: XCTestCase {
    // MARK: - Row planning

    func testRectsBecomeEvenRowSpansClampedToTheFrame() {
        let spans = TBRawRegionPlanner.rowSpans(
            for: [CGRect(x: 10, y: 3, width: 20, height: 4), CGRect(x: 0, y: 95, width: 10, height: 20)],
            frameHeight: 100
        )
        XCTAssertEqual(spans, [TBRawRowSpan(start: 2, end: 8), TBRawRowSpan(start: 94, end: 100)])
    }

    func testEmptyAndOutsideRectsAreIgnored() {
        let spans = TBRawRegionPlanner.rowSpans(
            for: [.null, .zero, CGRect(x: 0, y: 200, width: 10, height: 10)],
            frameHeight: 100
        )
        XCTAssertEqual(spans, [])
    }

    func testCloseSpansMergeAndDistantSpansStaySeparate() {
        let spans = TBRawRegionPlanner.merge([
            TBRawRowSpan(start: 100, end: 110),
            TBRawRowSpan(start: 0, end: 10),
            TBRawRowSpan(start: 20, end: 30),
        ])
        XCTAssertEqual(spans, [TBRawRowSpan(start: 0, end: 30), TBRawRowSpan(start: 100, end: 110)])
    }

    func testTooManySpansCollapseIntoOne() {
        let many = (0..<(TBRawRegionPlanner.maxSpans + 5)).map {
            TBRawRowSpan(start: $0 * 100, end: $0 * 100 + 2)
        }
        let spans = TBRawRegionPlanner.merge(many)
        XCTAssertEqual(spans, [TBRawRowSpan(start: 0, end: many.last!.end)])
    }

    func testChunksStayEvenAndCoverTheSpan() {
        let chunks = TBRawRegionPlanner.chunks([TBRawRowSpan(start: 10, end: 150)], maxRows: 64)
        XCTAssertEqual(chunks, [
            TBRawRowSpan(start: 10, end: 74),
            TBRawRowSpan(start: 74, end: 138),
            TBRawRowSpan(start: 138, end: 150),
        ])
    }

    func testPixelRectsAreKeptAsTheyAre() {
        let rects = [CGRect(x: 0, y: 2000, width: 100, height: 10)]
        let result = TBRawRegionPlanner.pixelRects(
            dirtyRects: rects,
            contentSize: CGSize(width: 2560, height: 1440),
            scaleFactor: 2,
            pixelWidth: 5120,
            pixelHeight: 2880
        )
        XCTAssertEqual(result, rects, "a rect beyond the point size can only be in pixels")
    }

    func testAmbiguousRectsAreSentInBothReadings() {
        let rect = CGRect(x: 10, y: 100, width: 50, height: 10)
        let result = TBRawRegionPlanner.pixelRects(
            dirtyRects: [rect],
            contentSize: CGSize(width: 2560, height: 1440),
            scaleFactor: 2,
            pixelWidth: 5120,
            pixelHeight: 2880
        )
        XCTAssertEqual(result, [rect, CGRect(x: 20, y: 200, width: 100, height: 20)])
    }

    func testNoScalingWhenContentMatchesPixels() {
        let rect = CGRect(x: 10, y: 100, width: 50, height: 10)
        let result = TBRawRegionPlanner.pixelRects(
            dirtyRects: [rect],
            contentSize: CGSize(width: 1920, height: 1080),
            scaleFactor: 1,
            pixelWidth: 1920,
            pixelHeight: 1080
        )
        XCTAssertEqual(result, [rect])
    }

    // MARK: - Packet layout

    private func makeNV12(width: Int, height: Int, y: (Int) -> UInt8, uv: (Int) -> UInt8) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            nil, &buffer
        )
        let pixelBuffer = try XCTUnwrap(buffer)
        XCTAssertEqual(status, kCVReturnSuccess)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)!
        let uvBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)!
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        for row in 0..<height {
            memset(yBase + row * yStride, Int32(y(row)), width)
        }
        for row in 0..<(height / 2) {
            memset(uvBase + row * uvStride, Int32(uv(row)), width)
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        return pixelBuffer
    }

    private func be32(_ bytes: [UInt8], _ offset: Int) -> Int {
        Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
    }

    func testUncompressedPacketCarriesOnlyTheChangedRows() throws {
        let pixelBuffer = try makeNV12(width: 6, height: 8, y: { UInt8($0) }, uv: { UInt8(100 + $0) })
        let built = try XCTUnwrap(TBRawRegionPacketBuilder.makePacket(
            pixelBuffer: pixelBuffer,
            spans: [TBRawRowSpan(start: 2, end: 6)],
            fullFrame: false,
            compress: false
        ))
        let bytes = [UInt8](built.packet)

        XCTAssertEqual(be32(bytes, 0), bytes.count - 4, "length prefix")
        XCTAssertEqual(bytes[4], TBMonitorPacketType.rawRegions.rawValue)
        XCTAssertEqual(bytes[5], 1, "NV12")
        XCTAssertEqual(bytes[6], 0, "not a full frame")
        XCTAssertEqual(be32(bytes, 7), 6)
        XCTAssertEqual(be32(bytes, 11), 8)
        XCTAssertEqual(Int(bytes[15]) << 8 | Int(bytes[16]), 1, "one band")

        let entry = 5 + TBRawRegionPacketBuilder.headerBytes
        XCTAssertEqual(be32(bytes, entry), 2, "first row")
        XCTAssertEqual(be32(bytes, entry + 4), 4, "row count")
        XCTAssertEqual(be32(bytes, entry + 8), 6 * 4 + 6 * 2, "raw length")
        XCTAssertEqual(bytes[entry + 12], TBRawRegionPacketBuilder.encodingRaw)

        let data = Array(bytes[(entry + TBRawRegionPacketBuilder.bandBytes)...])
        XCTAssertEqual(data.count, 36)
        XCTAssertEqual(Array(data[0..<6]), [UInt8](repeating: 2, count: 6), "Y row 2, stride removed")
        XCTAssertEqual(Array(data[18..<24]), [UInt8](repeating: 5, count: 6), "Y row 5")
        XCTAssertEqual(Array(data[24..<30]), [UInt8](repeating: 101, count: 6), "CbCr row 1")
        XCTAssertEqual(Array(data[30..<36]), [UInt8](repeating: 102, count: 6), "CbCr row 2")
        XCTAssertEqual(built.summary.rows, 4)
    }

    func testCompressedBandsDecodeToTheSameRows() throws {
        let width = 256
        let height = 160
        let pixelBuffer = try makeNV12(width: width, height: height, y: { UInt8($0 % 7) }, uv: { _ in 128 })
        let built = try XCTUnwrap(TBRawRegionPacketBuilder.makePacket(
            pixelBuffer: pixelBuffer,
            spans: TBRawRegionPlanner.fullFrame(height: height),
            fullFrame: true,
            compress: true
        ))
        let bytes = [UInt8](built.packet)
        XCTAssertEqual(bytes[6], TBRawRegionPacketBuilder.flagFullFrame)
        let bands = Int(bytes[15]) << 8 | Int(bytes[16])
        XCTAssertEqual(bands, 3, "160 rows in chunks of 64")
        XCTAssertLessThan(built.summary.wireBytes, built.summary.rawBytes / 4, "uniform rows compress well")

        var dataOffset = 5 + TBRawRegionPacketBuilder.headerBytes + bands * TBRawRegionPacketBuilder.bandBytes
        for band in 0..<bands {
            let entry = 5 + TBRawRegionPacketBuilder.headerBytes + band * TBRawRegionPacketBuilder.bandBytes
            let firstRow = be32(bytes, entry)
            let rows = be32(bytes, entry + 4)
            let length = be32(bytes, entry + 8)
            XCTAssertEqual(bytes[entry + 12], TBRawRegionPacketBuilder.encodingLZ4)

            let decodedSize = width * rows + width * rows / 2
            var decoded = [UInt8](repeating: 0, count: decodedSize)
            let written = bytes.withUnsafeBufferPointer { source in
                decoded.withUnsafeMutableBufferPointer { target in
                    compression_decode_buffer(
                        target.baseAddress!, decodedSize,
                        source.baseAddress! + dataOffset, length,
                        nil, COMPRESSION_LZ4_RAW
                    )
                }
            }
            XCTAssertEqual(written, decodedSize)
            XCTAssertEqual(decoded[0], UInt8(firstRow % 7))
            XCTAssertEqual(decoded[width * (rows - 1)], UInt8((firstRow + rows - 1) % 7))
            XCTAssertEqual(decoded[width * rows], 128)
            dataOffset += length
        }
        XCTAssertEqual(dataOffset, bytes.count)
    }

    func testOlderProfilesDoNotAdvertiseRegions() throws {
        XCTAssertEqual(TBMonitorPacketType.rawRegions.rawValue, 0x24)
        let profile = try JSONDecoder().decode(TBMonitorDisplayProfile.self, from: Data("""
        {"receiverName":"R","panelWidth":5120,"panelHeight":2880,"modeWidth":2560,"modeHeight":1440,
         "refreshRate":60,"hiDPI":true,"captureWidth":5120,"captureHeight":2880,"supportsRawNV12":true}
        """.utf8))
        XCTAssertNil(profile.supportsRawRegions)
        XCTAssertNil(profile.supportsRawLZ4)
    }

    func testLZ4PreferenceUsesRawFrames() {
        XCTAssertTrue(TBDisplayCodecPreference.uncompressed.usesRawFrames)
        XCTAssertTrue(TBDisplayCodecPreference.uncompressedLZ4.usesRawFrames)
        XCTAssertFalse(TBDisplayCodecPreference.automatic.usesRawFrames)
    }

    func testTenBitPreferencesUseLZ4AndParallelStreams() {
        for preference in [TBDisplayCodecPreference.uncompressedEnhanced, .uncompressedFull10Bit] {
            XCTAssertTrue(preference.usesRawFrames)
            XCTAssertTrue(preference.compressesRawFrames)
            XCTAssertTrue(preference.usesParallelStreams)
        }
        XCTAssertFalse(TBDisplayCodecPreference.uncompressed.compressesRawFrames)
        // All uncompressed modes can use parallel connections; codec modes can't.
        XCTAssertTrue(TBDisplayCodecPreference.uncompressedLZ4.usesParallelStreams)
        XCTAssertTrue(TBDisplayCodecPreference.uncompressed.usesParallelStreams)
        XCTAssertFalse(TBDisplayCodecPreference.hevc.usesParallelStreams)
    }

    func testPartsSplitTheRowsEvenlyAndCarryTheSequence() throws {
        let width = 64
        let height = 512
        let pixelBuffer = try makeNV12(width: width, height: height, y: { UInt8($0 & 0xFF) }, uv: { _ in 128 })
        let built = try XCTUnwrap(TBRawRegionPacketBuilder.makePackets(
            pixelBuffer: pixelBuffer,
            spans: TBRawRegionPlanner.fullFrame(height: height),
            fullFrame: true,
            compress: false,
            parts: 4,
            frameSequence: 42
        ))
        XCTAssertEqual(built.packets.count, 4)
        var rows = Set<Int>()
        for packet in built.packets {
            let bytes = [UInt8](packet)
            XCTAssertEqual(be32(bytes, 0), bytes.count - 4)
            XCTAssertEqual(bytes[4], TBMonitorPacketType.rawRegionsPart.rawValue)
            XCTAssertEqual(be32(bytes, 5), 42, "frame sequence")
            let header = 9
            XCTAssertEqual(bytes[header], TBRawRegionPacketBuilder.formatNV12)
            let bands = Int(bytes[header + 10]) << 8 | Int(bytes[header + 11])
            XCTAssertEqual(bands, 2, "8 chunks of 64 rows over 4 parts")
            XCTAssertEqual(bytes[header + 12], 4, "part count")
            for band in 0..<bands {
                let entry = header + TBRawRegionPacketBuilder.headerBytes + band * TBRawRegionPacketBuilder.bandBytes
                let first = be32(bytes, entry)
                for row in first..<(first + be32(bytes, entry + 4)) {
                    XCTAssertTrue(rows.insert(row).inserted, "row \(row) sent twice")
                }
            }
        }
        XCTAssertEqual(rows.count, height, "every row sent exactly once")
    }

    func testTenBitRGBPacketCarriesFourBytesPerPixel() throws {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(
            kCFAllocatorDefault, 4, 4, kCVPixelFormatType_ARGB2101010LEPacked, nil, &buffer
        ), kCVReturnSuccess)
        let pixelBuffer = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        let base = CVPixelBufferGetBaseAddress(pixelBuffer)!
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        for row in 0..<4 {
            memset(base + row * stride, Int32(row + 1), 16)
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        let built = try XCTUnwrap(TBRawRegionPacketBuilder.makePacket(
            pixelBuffer: pixelBuffer,
            spans: [TBRawRowSpan(start: 2, end: 4)],
            fullFrame: false,
            compress: false
        ))
        let bytes = [UInt8](built.packet)
        XCTAssertEqual(bytes[5], TBRawRegionPacketBuilder.formatRGB10)
        let entry = 5 + TBRawRegionPacketBuilder.headerBytes
        XCTAssertEqual(be32(bytes, entry + 8), 4 * 4 * 2, "two rows of four 4-byte pixels")
        let data = Array(bytes[(entry + TBRawRegionPacketBuilder.bandBytes)...])
        XCTAssertEqual(data.count, 32)
        XCTAssertEqual(data[0], 3, "row 2")
        XCTAssertEqual(data[31], 4, "row 3")
    }
}
