import Compression
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

/// Rows `start ..< end` of a frame. Both bounds are even, because NV12 shares
/// one CbCr row between two picture rows.
struct TBRawRowSpan: Equatable, Sendable {
    var start: Int
    var end: Int

    var rows: Int { end - start }
}

/// Decides which rows of a raw NV12 frame have to be sent. Pure functions, so
/// they are unit tested.
enum TBRawRegionPlanner {
    /// Changed rows closer together than this are sent as one band: a few
    /// unchanged rows cost less than an extra band.
    static let mergeGap = 16
    /// With more separate bands than this, one band from the first to the last
    /// changed row is sent instead.
    static let maxSpans = 32
    /// Bands are cut into chunks of at most this many rows, so the chunks can
    /// be copied and compressed in parallel on both Macs.
    static let chunkRows = 64

    static func fullFrame(height: Int) -> [TBRawRowSpan] {
        height >= 2 ? [TBRawRowSpan(start: 0, end: height & ~1)] : []
    }

    /// Row spans covering `rects` (pixel coordinates, top-left origin),
    /// clamped to the frame, aligned to even rows and merged.
    static func rowSpans(for rects: [CGRect], frameHeight: Int) -> [TBRawRowSpan] {
        let height = frameHeight & ~1
        guard height > 0 else { return [] }
        var spans: [TBRawRowSpan] = []
        for rect in rects where !rect.isNull && !rect.isEmpty && rect.minY.isFinite && rect.maxY.isFinite {
            var start = Int(rect.minY.rounded(.down))
            var end = Int(rect.maxY.rounded(.up))
            start = max(0, min(start, height)) & ~1
            end = min(height, max(end, 0))
            end = min(height, (end + 1) & ~1)
            if end > start {
                spans.append(TBRawRowSpan(start: start, end: end))
            }
        }
        return merge(spans)
    }

    /// Sorts and joins spans that overlap or lie within `mergeGap` rows.
    static func merge(_ spans: [TBRawRowSpan]) -> [TBRawRowSpan] {
        let sorted = spans.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        var merged: [TBRawRowSpan] = []
        for span in sorted {
            if let last = merged.last, span.start <= last.end + mergeGap {
                merged[merged.count - 1].end = max(last.end, span.end)
            } else {
                merged.append(span)
            }
        }
        if merged.count > maxSpans, let first = merged.first, let last = merged.last {
            return [TBRawRowSpan(start: first.start, end: last.end)]
        }
        return merged
    }

    static func union(_ lhs: [TBRawRowSpan], _ rhs: [TBRawRowSpan]) -> [TBRawRowSpan] {
        if lhs.isEmpty { return rhs }
        if rhs.isEmpty { return lhs }
        return merge(lhs + rhs)
    }

    /// Cuts spans into chunks of at most `maxRows` rows (kept even).
    static func chunks(_ spans: [TBRawRowSpan], maxRows: Int = chunkRows) -> [TBRawRowSpan] {
        let step = max(2, maxRows & ~1)
        var result: [TBRawRowSpan] = []
        for span in spans {
            var start = span.start
            while start < span.end {
                let end = min(span.end, start + step)
                result.append(TBRawRowSpan(start: start, end: end))
                start = end
            }
        }
        return result
    }

    /// ScreenCaptureKit reports dirty rects relative to the captured content.
    /// It is not documented whether that is in points or in output pixels, so
    /// this converts them conservatively: rects that only make sense as
    /// pixels are used as they are; rects that fit the content size in points
    /// are sent in both readings. Sending a few extra rows is harmless,
    /// missing rows would leave stale pixels on the receiver.
    static func pixelRects(
        dirtyRects: [CGRect],
        contentSize: CGSize?,
        scaleFactor: Double?,
        pixelWidth: Int,
        pixelHeight: Int
    ) -> [CGRect] {
        guard !dirtyRects.isEmpty, pixelWidth > 0, pixelHeight > 0 else { return dirtyRects }
        var factor = 1.0
        if let contentSize, contentSize.height > 0 {
            factor = Double(pixelHeight) / Double(contentSize.height)
        } else if let scaleFactor, scaleFactor > 0 {
            factor = scaleFactor
        }
        guard factor > 1.01 else { return dirtyRects }

        let pointWidth = Double(pixelWidth) / factor
        let pointHeight = Double(pixelHeight) / factor
        let fitPoints = dirtyRects.allSatisfy {
            Double($0.maxX) <= pointWidth + 1 && Double($0.maxY) <= pointHeight + 1
        }
        guard fitPoints else { return dirtyRects }
        let scale = CGFloat(factor)
        let scaled = dirtyRects.map {
            CGRect(x: $0.minX * scale, y: $0.minY * scale, width: $0.width * scale, height: $0.height * scale)
        }
        return dirtyRects + scaled
    }
}

enum TBRawDirtyRects {
    /// Changed areas of a ScreenCaptureKit frame in pixel coordinates, or nil
    /// if the frame carries no usable dirty-rect information (then the whole
    /// frame has to be sent).
    static func pixelRects(in sampleBuffer: CMSampleBuffer, pixelWidth: Int, pixelHeight: Int) -> [CGRect]? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let rawRects = info[SCStreamFrameInfo.dirtyRects] as? [Any] else {
            return nil
        }
        var rects: [CGRect] = []
        rects.reserveCapacity(rawRects.count)
        for value in rawRects {
            guard let dictionary = value as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dictionary as CFDictionary) else {
                return nil
            }
            rects.append(rect)
        }
        var contentSize: CGSize?
        if let dictionary = info[SCStreamFrameInfo.contentRect] as? NSDictionary,
           let contentRect = CGRect(dictionaryRepresentation: dictionary as CFDictionary) {
            contentSize = contentRect.size
        }
        let scaleFactor = (info[SCStreamFrameInfo.scaleFactor] as? NSNumber)?.doubleValue
        return TBRawRegionPlanner.pixelRects(
            dirtyRects: rects,
            contentSize: contentSize,
            scaleFactor: scaleFactor,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )
    }
}

/// Builds packet type 0x24 (changed rows of a raw NV12 frame). The wire format
/// is documented in the Receiver's raw_regions.h.
enum TBRawRegionPacketBuilder {
    static let headerBytes = 14
    static let bandBytes = 13
    static let maxBands = 4096
    static let flagFullFrame: UInt8 = 0x01
    static let encodingRaw: UInt8 = 0
    static let encodingLZ4: UInt8 = 1

    struct Summary {
        var bands: Int
        var rows: Int
        var rawBytes: Int
        var wireBytes: Int
    }

    private struct Shared<T>: @unchecked Sendable {
        let value: T
    }

    private struct Chunk {
        var data: UnsafeMutableRawPointer?
        var length: Int
        var encoding: UInt8
    }

    /// Returns the complete packet (length prefix and type included), or nil
    /// if the pixel buffer is not usable NV12.
    static func makePacket(
        pixelBuffer: CVPixelBuffer,
        spans: [TBRawRowSpan],
        fullFrame: Bool,
        compress: Bool
    ) -> (packet: Data, summary: Summary)? {
        guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 2 else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let uvBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        guard width > 0, height > 0, width % 2 == 0, height % 2 == 0,
              yStride >= width, uvStride >= width,
              CVPixelBufferGetHeightOfPlane(pixelBuffer, 1) >= height / 2 else { return nil }

        let clamped = spans.compactMap { span -> TBRawRowSpan? in
            let start = max(0, span.start) & ~1
            let end = min(height, span.end) & ~1
            return end > start ? TBRawRowSpan(start: start, end: end) : nil
        }
        let chunks = TBRawRegionPlanner.chunks(clamped)
        guard !chunks.isEmpty, chunks.count <= maxBands else { return nil }

        let rawSizes = chunks.map { width * $0.rows + width * ($0.rows / 2) }
        let rawTotal = rawSizes.reduce(0, +)
        let tableBytes = headerBytes + bandBytes * chunks.count

        let source = Shared(value: (
            y: UnsafeRawPointer(yBase), uv: UnsafeRawPointer(uvBase),
            width: width, yStride: yStride, uvStride: uvStride
        ))
        let spansBox = Shared(value: chunks)

        // Copies the rows of chunk `index` into `destination`, tightly packed:
        // Y rows, then CbCr rows.
        @Sendable func pack(_ index: Int, into destination: UnsafeMutableRawPointer) {
            let s = source.value
            let span = spansBox.value[index]
            if s.yStride == s.width {
                memcpy(destination, s.y + span.start * s.yStride, s.width * span.rows)
            } else {
                for row in 0..<span.rows {
                    memcpy(destination + row * s.width, s.y + (span.start + row) * s.yStride, s.width)
                }
            }
            let uvDestination = destination + s.width * span.rows
            let uvRows = span.rows / 2
            if s.uvStride == s.width {
                memcpy(uvDestination, s.uv + (span.start / 2) * s.uvStride, s.width * uvRows)
            } else {
                for row in 0..<uvRows {
                    memcpy(uvDestination + row * s.width, s.uv + (span.start / 2 + row) * s.uvStride, s.width)
                }
            }
        }

        var lengths = rawSizes
        var encodings = [UInt8](repeating: encodingRaw, count: chunks.count)
        let packetBytes: Int
        let packet: UnsafeMutableRawPointer

        if compress {
            // Pack and compress every chunk in parallel, then assemble.
            let results = UnsafeMutableBufferPointer<Chunk>.allocate(capacity: chunks.count)
            results.initialize(repeating: Chunk(data: nil, length: 0, encoding: encodingRaw))
            let resultsBox = Shared(value: results)
            let sizesBox = Shared(value: rawSizes)
            DispatchQueue.concurrentPerform(iterations: chunks.count) { index in
                let rawSize = sizesBox.value[index]
                let packed = UnsafeMutableRawPointer.allocate(byteCount: rawSize, alignment: 16)
                pack(index, into: packed)
                let compressed = UnsafeMutableRawPointer.allocate(byteCount: rawSize, alignment: 16)
                let scratch = UnsafeMutableRawPointer.allocate(
                    byteCount: max(1, compression_encode_scratch_buffer_size(COMPRESSION_LZ4_RAW)),
                    alignment: 16
                )
                let written = compression_encode_buffer(
                    compressed.assumingMemoryBound(to: UInt8.self), rawSize,
                    packed.assumingMemoryBound(to: UInt8.self), rawSize,
                    scratch, COMPRESSION_LZ4_RAW
                )
                scratch.deallocate()
                if written > 0, written < rawSize {
                    packed.deallocate()
                    resultsBox.value[index] = Chunk(data: compressed, length: written, encoding: encodingLZ4)
                } else {
                    compressed.deallocate()
                    resultsBox.value[index] = Chunk(data: packed, length: rawSize, encoding: encodingRaw)
                }
            }
            for index in 0..<chunks.count {
                lengths[index] = results[index].length
                encodings[index] = results[index].encoding
            }
            packetBytes = 5 + tableBytes + lengths.reduce(0, +)
            packet = UnsafeMutableRawPointer.allocate(byteCount: packetBytes, alignment: 16)
            var offset = 5 + tableBytes
            for index in 0..<chunks.count {
                if let data = results[index].data {
                    memcpy(packet + offset, data, results[index].length)
                    data.deallocate()
                }
                offset += results[index].length
            }
            results.deallocate()
        } else {
            // Copy every chunk straight into its place in the packet.
            packetBytes = 5 + tableBytes + rawTotal
            packet = UnsafeMutableRawPointer.allocate(byteCount: packetBytes, alignment: 16)
            var offsets: [Int] = []
            offsets.reserveCapacity(chunks.count)
            var offset = 5 + tableBytes
            for size in rawSizes {
                offsets.append(offset)
                offset += size
            }
            let target = Shared(value: (packet: packet, offsets: offsets))
            DispatchQueue.concurrentPerform(iterations: chunks.count) { index in
                pack(index, into: target.value.packet + target.value.offsets[index])
            }
        }

        // Length prefix, type and table.
        func put32(_ value: Int, at offset: Int) {
            let v = UInt32(truncatingIfNeeded: value)
            packet.storeBytes(of: UInt8(truncatingIfNeeded: v >> 24), toByteOffset: offset, as: UInt8.self)
            packet.storeBytes(of: UInt8(truncatingIfNeeded: v >> 16), toByteOffset: offset + 1, as: UInt8.self)
            packet.storeBytes(of: UInt8(truncatingIfNeeded: v >> 8), toByteOffset: offset + 2, as: UInt8.self)
            packet.storeBytes(of: UInt8(truncatingIfNeeded: v), toByteOffset: offset + 3, as: UInt8.self)
        }
        func put8(_ value: UInt8, at offset: Int) {
            packet.storeBytes(of: value, toByteOffset: offset, as: UInt8.self)
        }
        put32(packetBytes - 4, at: 0)
        put8(TBMonitorPacketType.rawRegions.rawValue, at: 4)
        put8(1, at: 5)                                   // format: NV12
        put8(fullFrame ? flagFullFrame : 0, at: 6)
        put32(width, at: 7)
        put32(height, at: 11)
        put8(UInt8(truncatingIfNeeded: chunks.count >> 8), at: 15)
        put8(UInt8(truncatingIfNeeded: chunks.count), at: 16)
        put8(0, at: 17)
        put8(0, at: 18)
        for (index, chunk) in chunks.enumerated() {
            let entry = 5 + headerBytes + index * bandBytes
            put32(chunk.start, at: entry)
            put32(chunk.rows, at: entry + 4)
            put32(lengths[index], at: entry + 8)
            put8(encodings[index], at: entry + 12)
        }

        let data = Data(bytesNoCopy: packet, count: packetBytes, deallocator: .custom { pointer, _ in
            pointer.deallocate()
        })
        let summary = Summary(
            bands: chunks.count,
            rows: chunks.reduce(0) { $0 + $1.rows },
            rawBytes: rawTotal,
            wireBytes: packetBytes
        )
        return (data, summary)
    }
}
