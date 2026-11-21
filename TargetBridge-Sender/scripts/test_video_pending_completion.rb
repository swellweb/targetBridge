# Execute the production pending budget and RAW send path with synthetic capture
# callbacks and a separate mock Network queue. No capture, sockets or GPU work.
require 'tmpdir'

root = File.expand_path('..', __dir__)
source = File.read(File.join(root, 'TBDisplaySender/TBDisplaySenderService.swift'))
budget = source[/final class TBVideoPacketBudget: @unchecked Sendable \{.*?(?=\n\/\/\/ Reserve network capacity)/m]
packed = source[/    private func sendRawRGB10Frame\(.*?(?=\n    \/\/\/ Legacy NV12)/m]
abort 'missing production pending budget or RAW send path' unless budget && packed
raw = source[/    private func sendRawFrame\(.*?(?=\n    private func buildParamSetsPacket)/m]
encoded = source[/    private func handleEncoded\(.*?(?=\n    private var loggedRawRGB10Format)/m]
[packed, raw, encoded].each do |path|
  abort 'video completion must release its own budget directly' unless path&.include?('[budget = videoPacketBudget]') && path.include?('budget.release()')
  abort 'video completion still depends on capture scheduling' if path.include?('self.queue.async')
end
abort 'RAW must reserve capacity before reading planes' unless raw.index('videoPacketBudget.tryReserve(') < raw.index('CVPixelBufferLockBaseAddress(')
abort 'RAW early returns must release capacity' unless raw.include?('defer { if !submitted { videoPacketBudget.release() } }')

fixture = <<~'SWIFT'
import Foundation
import Dispatch
struct PixelBuffer { var encodable = true }
struct CMSampleBuffer { var image = PixelBuffer() }
func CMSampleBufferGetImageBuffer(_ b: CMSampleBuffer) -> PixelBuffer? { b.image }
func CVPixelBufferGetPixelFormatType(_ b: PixelBuffer) -> UInt32 { 0 }
func CVPixelBufferGetWidth(_ b: PixelBuffer) -> Int { 4480 }
func CVPixelBufferGetHeight(_ b: PixelBuffer) -> Int { 2520 }
struct Preset { let maxPendingVideoPackets = 3 }
struct Logger { func info(_ s: String) {}; func error(_ s: String) {} }
struct TBLog { static let connection = Logger() }
struct TBVideoSubmissionStatistics {
    struct RGBFrame { let width: Int; let height: Int; let encodePacketSeconds: Double; let usesGPU: Bool; let isUncompressed: Bool }
}
typealias CVPixelBuffer = PixelBuffer
class TBPackedRGB10PacketPool {
    struct Snapshot { var allocated = 3, idle = 0, capacityMisses = 0 }
    var snapshot: Snapshot { Snapshot() }
}
enum TBPackedRGB10Frame {
    struct Diagnostics {
        var sourceStride = 0, iosurfaceBacked = false, usesGPU = false
        var lockSeconds = 0.0, allocationSeconds = 0.0, copySeconds = 0.0, unlockSeconds = 0.0
        var gpuSubmitSeconds = 0.0, gpuCompletionSeconds = 0.0, gpuExecutionSeconds = 0.0
    }
    static func makePacket(pixelBuffer: PixelBuffer, pool: TBPackedRGB10PacketPool,
                           diagnostics: ((Diagnostics) -> Void)?) -> DispatchData? {
        guard pixelBuffer.encodable else { return nil }
        diagnostics?(Diagnostics())
        return Data(repeating: 0, count: 128).withUnsafeBytes { DispatchData(bytes: $0) }
    }
}
class TBPackedRGB10GPUCopier {
    func makePacket(pixelBuffer: PixelBuffer, pool: TBPackedRGB10PacketPool,
                    diagnostics: ((TBPackedRGB10Frame.Diagnostics) -> Void)?) -> DispatchData? { nil }
}
enum Completion { case contentProcessed((Error?) -> Void) }
final class FakeConnection: @unchecked Sendable {
    let networkQueue = DispatchQueue(label: "test.connection")
    private let lock = NSLock()
    private var _sent = 0, _completed = 0
    private var waiting: [Completion] = []
    var completeImmediately = true
    var counts: (sent: Int, completed: Int) {
        lock.lock(); defer { lock.unlock() }
        return (_sent, _completed)
    }
    private func finish(_ completion: Completion) {
        lock.lock(); _completed += 1; lock.unlock()
        if case let .contentProcessed(callback) = completion { callback(nil) }
    }
    func send(content: DispatchData, completion: Completion) {
        lock.lock(); _sent += 1
        let immediate = completeImmediately
        if !immediate { waiting.append(completion) }
        lock.unlock()
        guard immediate else { return }
        // A writable transport may complete before the next queued capture.
        // Run on another queue and make that ordering deterministic.
        let completed = DispatchSemaphore(value: 0)
        networkQueue.async { self.finish(completion); completed.signal() }
        precondition(completed.wait(timeout: .now() + 2) == .success)
    }
    func completeAll() {
        lock.lock(); let callbacks = waiting; waiting.removeAll(); lock.unlock()
        networkQueue.sync { for callback in callbacks { finish(callback) } }
    }
}
final class Pipeline: @unchecked Sendable {
    let queue = DispatchQueue(label: "test.capture.serial")
    let connection = FakeConnection()
    let preset = Preset()
    let videoPacketBudget = TBVideoPacketBudget()
    var pendingVideoPackets: Int { videoPacketBudget.snapshot }
    var running = true, usesRawRGB10 = true
    var droppedBeforeEncodeFrames = 0
    var rawRGB10Pool: TBPackedRGB10PacketPool? = TBPackedRGB10PacketPool()
    var rawGPUCopier: TBPackedRGB10GPUCopier?
    var rawCopyTotals = TBPackedRGB10Frame.Diagnostics()
    var rawMeasuredGPUFrames = 0
    var loggedRawRGB10Format = false
    var capturedFrames = 0, droppedByFrameRatePacer = 0
    var rawMeasuredFrames = 0, rawMeasuredBytes = 0
    var rawMeasuredSeconds = 0.0
    var rawMeasuredSendSeconds = 0.0
    var falseDrops = 0
    func acknowledgeFirstFrame() {}
    func recordVideoSubmission(packetBytes: Int, rgb: TBVideoSubmissionStatistics.RGBFrame?) {}
SWIFT

tests = <<~'SWIFT'
    func capture(encodable: Bool = true) {
        let before = droppedBeforeEncodeFrames
        capturedFrames += 1
        sendRawRGB10Frame(PixelBuffer(encodable: encodable))
        let counts = connection.counts
        if encodable && droppedBeforeEncodeFrames > before && counts.sent == counts.completed { falseDrops += 1 }
    }
    func burst(_ count: Int, encodable: Bool = true) {
        let gate = DispatchSemaphore(value: 0)
        queue.async { gate.wait() }
        for _ in 0..<count { queue.async { self.capture(encodable: encodable) } }
        gate.signal()
        queue.sync {}
    }
}

// Reproduces a full SCK queue (default depth 8) ahead of the accounting work.
// The old queue.async decrement sends 3 and falsely drops the remaining 5,
// although all 3 Network completions have already run.
let burst = Pipeline()
burst.burst(8)
precondition(burst.connection.counts.sent == 8 && burst.falseDrops == 0)
precondition(burst.pendingVideoPackets == 0)

// Genuine transport backpressure still enforces the unchanged three-slot cap.
let slow = Pipeline()
slow.connection.completeImmediately = false
slow.burst(8)
precondition(slow.connection.counts.sent == 3 && slow.pendingVideoPackets == 3)
precondition(slow.droppedBeforeEncodeFrames == 5 && slow.falseDrops == 0)
let blocked = DispatchSemaphore(value: 0), entered = DispatchSemaphore(value: 0)
slow.queue.async { entered.signal(); blocked.wait() }
precondition(entered.wait(timeout: .now() + 2) == .success)
slow.connection.completeAll()
precondition(slow.pendingVideoPackets == 0) // capture queue is still blocked
blocked.signal()
slow.queue.sync {}
slow.connection.completeImmediately = true
slow.burst(8)
precondition(slow.connection.counts.sent == 11 && slow.pendingVideoPackets == 0)

// Invalid/failed encodes release their early reservation, including bursts.
let invalid = Pipeline()
invalid.burst(8, encodable: false)
precondition(invalid.pendingVideoPackets == 0 && invalid.connection.counts.sent == 0)
invalid.burst(8)
precondition(invalid.connection.counts.sent == 8)

// Late completions retain only the retired pipeline's budget. They neither
// keep that pipeline alive nor release a replacement pipeline's capacity.
var retired: Pipeline? = Pipeline()
retired!.connection.completeImmediately = false
retired!.burst(1)
let oldConnection = retired!.connection
weak var oldPipeline = retired
weak var oldBudget = retired!.videoPacketBudget
retired!.queue.sync { retired!.running = false; retired!.rawRGB10Pool = nil }
retired = nil
precondition(oldPipeline == nil && oldBudget?.snapshot == 1)
let replacement = Pipeline()
replacement.connection.completeImmediately = false
replacement.burst(1)
oldConnection.completeAll()
precondition(oldBudget == nil && replacement.pendingVideoPackets == 1)
replacement.connection.completeAll()

// VT converts capacity already reserved by the queue's in-flight count into
// a pending submission, without a second admission check or reference drop.
for limit in 1...12 {
    for pending in 0..<limit {
        let budget = TBVideoPacketBudget()
        for _ in 0..<pending { precondition(budget.tryReserve(limit: limit)) }
        var inFlight = limit - pending
        while inFlight > 0 {
            inFlight -= 1
            budget.recordEncodedSubmission()
            precondition(budget.snapshot + inFlight == limit)
        }
        precondition(!budget.tryReserve(limit: limit))
        for _ in 0..<limit { budget.release() }
        precondition(budget.snapshot == 0)
    }
}
print("PASS production RAW pending: 8-frame burst, immediate/delayed completions, blocked capture queue, failed encode, pipeline retirement, VT reservation transfer")
SWIFT

Dir.mktmpdir('tb-pending-completion.') do |dir|
  file = File.join(dir, 'main.swift')
  File.write(file, fixture.sub('final class Pipeline:', budget + "\nfinal class Pipeline:") + packed + tests)
  abort 'compile failed' unless system('swiftc', '-module-cache-path', File.join(dir, 'cache'), file, '-o', File.join(dir, 'test'))
  abort 'tests failed' unless system(File.join(dir, 'test'))
end
