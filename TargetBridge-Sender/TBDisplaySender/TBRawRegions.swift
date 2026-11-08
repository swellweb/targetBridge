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

/// Builds packet type 0x24 (changed rows of a raw NV12 frame) and, for
/// parallel data streams, type 0x26 parts (a frame sequence followed by a 0x24
/// payload). The wire format is documented in the Receiver's raw_regions.h.
enum TBRawRegionPacketBuilder {
    static let headerBytes = 14
    static let bandBytes = 13
    static let maxBands = 4096
    static let flagFullFrame: UInt8 = 0x01
    static let encodingRaw: UInt8 = 0
    static let encodingLZ4: UInt8 = 1
    static let formatNV12: UInt8 = 1
    /// 10-bit RGB as captured ('l10r'): 4 bytes per pixel, one plane.
    static let formatRGB10: UInt8 = 2

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

    /// One packet (type 0x24), as before parallel streams existed.
    static func makePacket(
        pixelBuffer: CVPixelBuffer,
        spans: [TBRawRowSpan],
        fullFrame: Bool,
        compress: Bool
    ) -> (packet: Data, summary: Summary)? {
        guard let built = makePackets(
            pixelBuffer: pixelBuffer,
            spans: spans,
            fullFrame: fullFrame,
            compress: compress,
            parts: 1,
            frameSequence: nil
        ), let packet = built.packets.first else { return nil }
        return (packet, built.summary)
    }

    /// Splits the changed rows into up to `parts` packets of similar size.
    /// With a `frameSequence` they are type 0x26 parts for parallel streams,
    /// otherwise a single type 0x24 packet. Accepts NV12 or 10-bit RGB
    /// ('l10r'). Returns nil if the pixel buffer is neither.
    static func makePackets(
        pixelBuffer: CVPixelBuffer,
        spans: [TBRawRowSpan],
        fullFrame: Bool,
        compress: Bool,
        parts: Int,
        frameSequence: UInt32?
    ) -> (packets: [Data], summary: Summary)? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        // Main plane: Y for NV12, the pixels for RGB10. Second plane: CbCr.
        let format: UInt8
        let width: Int
        let height: Int
        let yBase: UnsafeMutableRawPointer
        let yStride: Int
        let rowBytes: Int
        var uvBase: UnsafeMutableRawPointer?
        var uvStride = 0
        var uvRowBytes = 0
        if CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_ARGB2101010LEPacked {
            guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
            format = formatRGB10
            width = CVPixelBufferGetWidth(pixelBuffer)
            height = CVPixelBufferGetHeight(pixelBuffer)
            yBase = base
            yStride = CVPixelBufferGetBytesPerRow(pixelBuffer)
            rowBytes = width * 4
        } else {
            guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 2,
                  let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
                  let chroma = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else { return nil }
            format = formatNV12
            width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
            height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
            yBase = base
            yStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            rowBytes = width
            uvBase = chroma
            uvStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
            uvRowBytes = width
            guard uvStride >= width, CVPixelBufferGetHeightOfPlane(pixelBuffer, 1) >= height / 2 else { return nil }
        }
        guard width > 0, height > 0, width % 2 == 0, height % 2 == 0, yStride >= rowBytes else { return nil }

        let clamped = spans.compactMap { span -> TBRawRowSpan? in
            let start = max(0, span.start) & ~1
            let end = min(height, span.end) & ~1
            return end > start ? TBRawRowSpan(start: start, end: end) : nil
        }
        let chunks = TBRawRegionPlanner.chunks(clamped)
        guard !chunks.isEmpty, chunks.count <= maxBands else { return nil }

        let rawSizes = chunks.map { rowBytes * $0.rows + uvRowBytes * ($0.rows / 2) }
        let source = Shared(value: (
            y: UnsafeRawPointer(yBase), uv: uvBase.map { UnsafeRawPointer($0) },
            rowBytes: rowBytes, uvRowBytes: uvRowBytes, yStride: yStride, uvStride: uvStride
        ))
        let spansBox = Shared(value: chunks)

        // Copies the rows of chunk `index` into `destination`, tightly packed:
        // main-plane rows, then (NV12 only) CbCr rows.
        @Sendable func pack(_ index: Int, into destination: UnsafeMutableRawPointer) {
            let s = source.value
            let span = spansBox.value[index]
            if s.yStride == s.rowBytes {
                memcpy(destination, s.y + span.start * s.yStride, s.rowBytes * span.rows)
            } else {
                for row in 0..<span.rows {
                    memcpy(destination + row * s.rowBytes, s.y + (span.start + row) * s.yStride, s.rowBytes)
                }
            }
            guard let uv = s.uv, s.uvRowBytes > 0 else { return }
            let uvDestination = destination + s.rowBytes * span.rows
            let uvRows = span.rows / 2
            if s.uvStride == s.uvRowBytes {
                memcpy(uvDestination, uv + (span.start / 2) * s.uvStride, s.uvRowBytes * uvRows)
            } else {
                for row in 0..<uvRows {
                    memcpy(uvDestination + row * s.uvRowBytes, uv + (span.start / 2 + row) * s.uvStride, s.uvRowBytes)
                }
            }
        }

        // Compressed chunks are encoded first, because their sizes decide how
        // they are spread over the parts.
        var compressed: UnsafeMutableBufferPointer<Chunk>?
        var lengths = rawSizes
        var encodings = [UInt8](repeating: encodingRaw, count: chunks.count)
        if compress {
            let results = UnsafeMutableBufferPointer<Chunk>.allocate(capacity: chunks.count)
            results.initialize(repeating: Chunk(data: nil, length: 0, encoding: encodingRaw))
            let resultsBox = Shared(value: results)
            let sizesBox = Shared(value: rawSizes)
            DispatchQueue.concurrentPerform(iterations: chunks.count) { index in
                let rawSize = sizesBox.value[index]
                let packed = UnsafeMutableRawPointer.allocate(byteCount: rawSize, alignment: 16)
                pack(index, into: packed)
                let output = UnsafeMutableRawPointer.allocate(byteCount: rawSize, alignment: 16)
                let scratch = UnsafeMutableRawPointer.allocate(
                    byteCount: max(1, compression_encode_scratch_buffer_size(COMPRESSION_LZ4_RAW)),
                    alignment: 16
                )
                let written = compression_encode_buffer(
                    output.assumingMemoryBound(to: UInt8.self), rawSize,
                    packed.assumingMemoryBound(to: UInt8.self), rawSize,
                    scratch, COMPRESSION_LZ4_RAW
                )
                scratch.deallocate()
                if written > 0, written < rawSize {
                    packed.deallocate()
                    resultsBox.value[index] = Chunk(data: output, length: written, encoding: encodingLZ4)
                } else {
                    output.deallocate()
                    resultsBox.value[index] = Chunk(data: packed, length: rawSize, encoding: encodingRaw)
                }
            }
            for index in 0..<chunks.count {
                lengths[index] = results[index].length
                encodings[index] = results[index].encoding
            }
            compressed = results
        }

        // Spread the chunks over the parts, always onto the lightest one.
        let partCount = max(1, min(parts, chunks.count))
        var groups = [[Int]](repeating: [], count: partCount)
        var groupBytes = [Int](repeating: 0, count: partCount)
        for index in 0..<chunks.count {
            let lightest = groupBytes.indices.min { groupBytes[$0] < groupBytes[$1] } ?? 0
            groups[lightest].append(index)
            groupBytes[lightest] += lengths[index]
        }

        let prefix = frameSequence == nil ? 5 : 9
        var packets: [UnsafeMutableRawPointer] = []
        var packetSizes: [Int] = []
        var chunkTargets = [UnsafeMutableRawPointer?](repeating: nil, count: chunks.count)
        for (groupIndex, group) in groups.enumerated() {
            let tableBytes = headerBytes + bandBytes * group.count
            let size = prefix + tableBytes + groupBytes[groupIndex]
            let packet = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
            packets.append(packet)
            packetSizes.append(size)

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
            put32(size - 4, at: 0)
            if let frameSequence {
                put8(TBMonitorPacketType.rawRegionsPart.rawValue, at: 4)
                put32(Int(frameSequence), at: 5)
            } else {
                put8(TBMonitorPacketType.rawRegions.rawValue, at: 4)
            }
            put8(format, at: prefix)
            put8(fullFrame ? flagFullFrame : 0, at: prefix + 1)
            put32(width, at: prefix + 2)
            put32(height, at: prefix + 6)
            put8(UInt8(truncatingIfNeeded: group.count >> 8), at: prefix + 10)
            put8(UInt8(truncatingIfNeeded: group.count), at: prefix + 11)
            put8(0, at: prefix + 12)
            put8(0, at: prefix + 13)
            var dataOffset = prefix + tableBytes
            for (slot, index) in group.enumerated() {
                let entry = prefix + headerBytes + slot * bandBytes
                put32(chunks[index].start, at: entry)
                put32(chunks[index].rows, at: entry + 4)
                put32(lengths[index], at: entry + 8)
                put8(encodings[index], at: entry + 12)
                chunkTargets[index] = packet + dataOffset
                dataOffset += lengths[index]
            }
        }

        // Fill in the chunk data.
        if let compressed {
            for index in 0..<chunks.count {
                if let data = compressed[index].data, let target = chunkTargets[index] {
                    memcpy(target, data, compressed[index].length)
                    data.deallocate()
                }
            }
            compressed.deallocate()
        } else {
            let targets = Shared(value: chunkTargets)
            DispatchQueue.concurrentPerform(iterations: chunks.count) { index in
                if let target = targets.value[index] {
                    pack(index, into: target)
                }
            }
        }

        let data = zip(packets, packetSizes).map { packet, size in
            Data(bytesNoCopy: packet, count: size, deallocator: .custom { pointer, _ in
                pointer.deallocate()
            })
        }
        let summary = Summary(
            bands: chunks.count,
            rows: chunks.reduce(0) { $0 + $1.rows },
            rawBytes: rawSizes.reduce(0, +),
            wireBytes: packetSizes.reduce(0, +)
        )
        return (data, summary)
    }
}
