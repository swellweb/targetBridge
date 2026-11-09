import CoreVideo
import Foundation
import Metal

/// Converts 10-bit RGB frames from ScreenCaptureKit ('l10r') into 8-bit NV12
/// on the GPU, with dithering against visible steps in colour gradients.
///
/// Only the rows that will be sent are converted, into one persistent NV12
/// buffer. Rows that are not converted keep their previous content, which is
/// exactly what the receiver already shows.
///
/// The colour math matches what ScreenCaptureKit itself produces for '420v'
/// and what the Receiver expects: BT.709, video range. The dither is an
/// ordered 4×4 Bayer pattern that depends only on the pixel position, never on
/// time, so a still picture stays still. Being periodic, it also keeps LZ4
/// effective: a flat area becomes a pattern that repeats every 4 pixels and
/// every 4 rows, which LZ4 encodes as back references.
final class TBTenBitConverter: @unchecked Sendable {
    static let sourcePixelFormat = kCVPixelFormatType_ARGB2101010LEPacked

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct TBParams {
        uint rowOffset;   // first row of the span, even
        uint rows;        // rows in the span, even
        uint width;
        uint height;
    };

    // 4x4 Bayer thresholds in (0, 1): rounding down after adding them keeps
    // the average level exact while spreading the 10-bit remainder over the
    // 16 positions.
    constant float tb_bayer[16] = {
         0.5 / 16.0,  8.5 / 16.0,  2.5 / 16.0, 10.5 / 16.0,
        12.5 / 16.0,  4.5 / 16.0, 14.5 / 16.0,  6.5 / 16.0,
         3.5 / 16.0, 11.5 / 16.0,  1.5 / 16.0,  9.5 / 16.0,
        15.5 / 16.0,  7.5 / 16.0, 13.5 / 16.0,  5.5 / 16.0,
    };

    static inline float tb_dither(float value, uint x, uint y) {
        return clamp(floor(value + tb_bayer[(y & 3u) * 4u + (x & 3u)]), 0.0, 255.0) / 255.0;
    }

    constant float3 tb_luma = float3(0.2126, 0.7152, 0.0722);

    // One thread per 2x2 block: four Y samples, one averaged CbCr sample.
    kernel void tb_l10r_to_nv12(texture2d<float, access::read>  src   [[texture(0)]],
                                texture2d<float, access::write> dstY  [[texture(1)]],
                                texture2d<float, access::write> dstUV [[texture(2)]],
                                constant TBParams &p [[buffer(0)]],
                                uint2 gid [[thread_position_in_grid]]) {
        uint cx = gid.x;
        uint cy = gid.y + p.rowOffset / 2;
        if (cx * 2 >= p.width || gid.y * 2 >= p.rows || cy * 2 >= p.height) return;

        float3 sum = float3(0.0);
        for (uint dy = 0; dy < 2; ++dy) {
            for (uint dx = 0; dx < 2; ++dx) {
                uint2 pos = uint2(cx * 2 + dx, cy * 2 + dy);
                float3 rgb = saturate(src.read(pos).rgb);
                sum += rgb;
                float y = 16.0 + 219.0 * dot(rgb, tb_luma);
                dstY.write(float4(tb_dither(y, pos.x, pos.y)), pos);
            }
        }
        float3 rgb = sum * 0.25;
        float luma = dot(rgb, tb_luma);
        float cb = 128.0 + 224.0 * (rgb.b - luma) / 1.8556;
        float cr = 128.0 + 224.0 * (rgb.r - luma) / 1.5748;
        // Cr uses the pattern shifted by half a period, so the two chroma
        // channels don't step together.
        dstUV.write(float4(tb_dither(cb, cx, cy), tb_dither(cr, cx + 2u, cy + 2u), 0.0, 1.0), uint2(cx, cy));
    }
    """

    private struct Params {
        var rowOffset: UInt32
        var rows: UInt32
        var width: UInt32
        var height: UInt32
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let textureCache: CVMetalTextureCache
    private var output: CVPixelBuffer?

    /// Nil when this Mac has no usable Metal device; the caller then captures
    /// 8-bit NV12 directly.
    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        do {
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            guard let function = library.makeFunction(name: "tb_l10r_to_nv12") else { return nil }
            pipeline = try device.makeComputePipelineState(function: function)
        } catch {
            TBLog.connection.error("ten-bit: shader setup failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else { return nil }
        self.device = device
        self.queue = queue
        self.textureCache = cache
    }

    private func outputBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        if let output,
           CVPixelBufferGetWidth(output) == width,
           CVPixelBufferGetHeight(output) == height {
            return output
        }
        let attributes: NSDictionary = [
            kCVPixelBufferIOSurfacePropertiesKey: NSDictionary(),
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            attributes, &buffer
        ) == kCVReturnSuccess else { return nil }
        output = buffer
        return buffer
    }

    private func texture(
        for pixelBuffer: CVPixelBuffer,
        format: MTLPixelFormat,
        plane: Int,
        width: Int,
        height: Int
    ) -> CVMetalTexture? {
        var texture: CVMetalTexture?
        let usage = MTLTextureUsage([.shaderRead, .shaderWrite]).rawValue
        let attributes = [kCVMetalTextureUsage: NSNumber(value: usage)] as CFDictionary
        guard CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, attributes,
            format, width, height, plane, &texture
        ) == kCVReturnSuccess else { return nil }
        return texture
    }

    /// Converts `spans` of a 10-bit frame into the persistent NV12 buffer and
    /// returns it, or nil if the frame is not 10-bit or the GPU work failed.
    /// Blocks until the GPU is done (about a millisecond for a whole 5K frame).
    func convert(_ source: CVPixelBuffer, spans: [TBRawRowSpan]) -> CVPixelBuffer? {
        guard CVPixelBufferGetPixelFormatType(source) == Self.sourcePixelFormat else { return nil }
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        guard width > 0, height > 0, width % 2 == 0, height % 2 == 0,
              let output = outputBuffer(width: width, height: height),
              let sourceTexture = texture(for: source, format: .bgr10a2Unorm, plane: 0, width: width, height: height),
              let yTexture = texture(for: output, format: .r8Unorm, plane: 0, width: width, height: height),
              let uvTexture = texture(for: output, format: .rg8Unorm, plane: 1, width: width / 2, height: height / 2),
              let src = CVMetalTextureGetTexture(sourceTexture),
              let dstY = CVMetalTextureGetTexture(yTexture),
              let dstUV = CVMetalTextureGetTexture(uvTexture),
              let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }

        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(src, index: 0)
        encoder.setTexture(dstY, index: 1)
        encoder.setTexture(dstUV, index: 2)
        let threadWidth = pipeline.threadExecutionWidth
        let threadHeight = max(1, pipeline.maxTotalThreadsPerThreadgroup / threadWidth)
        let group = MTLSize(width: threadWidth, height: min(threadHeight, 8), depth: 1)
        for span in spans {
            let start = max(0, span.start) & ~1
            let end = min(height, span.end) & ~1
            guard end > start else { continue }
            var params = Params(
                rowOffset: UInt32(start),
                rows: UInt32(end - start),
                width: UInt32(width),
                height: UInt32(height)
            )
            encoder.setBytes(&params, length: MemoryLayout<Params>.stride, index: 0)
            let blocksWide = width / 2
            let blocksHigh = (end - start) / 2
            let groups = MTLSize(
                width: (blocksWide + group.width - 1) / group.width,
                height: (blocksHigh + group.height - 1) / group.height,
                depth: 1
            )
            encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: group)
        }
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        // The CVMetalTextures must stay alive until the GPU is done.
        withExtendedLifetime((sourceTexture, yTexture, uvTexture)) {}
        CVMetalTextureCacheFlush(textureCache, 0)
        guard commandBuffer.status == .completed else {
            TBLog.connection.error("ten-bit: conversion failed: \(commandBuffer.error?.localizedDescription ?? "unknown", privacy: .public)")
            return nil
        }
        return output
    }
}
