import XCTest
import CoreGraphics
import CoreMedia
import CoreVideo
import ScreenCaptureKit
@testable import TargetBridge

final class TBCaptureHealthTests: XCTestCase {
    func testStartupTimeoutWithoutCallbacks() {
        let health = TBCaptureHealth(now: 100)
        XCTAssertFalse(health.shouldRestart(now: 107.999))
        XCTAssertTrue(health.shouldRestart(now: 108))
    }

    func testActiveCaptureStillDetectsSilentStall() {
        var health = TBCaptureHealth(now: 0)
        health.recordFrame(now: 2)
        XCTAssertFalse(health.shouldRestart(now: 9.9))
        XCTAssertTrue(health.shouldRestart(now: 10))
    }

    func testSingleIdleEventCanRemainHealthyForHours() {
        var health = TBCaptureHealth(now: 0)
        health.recordFrame(now: 1)
        health.observe(.idle, now: 2)
        XCTAssertFalse(health.shouldRestart(now: 10))
        XCTAssertFalse(health.shouldRestart(now: 86_400))
        XCTAssertEqual(health.frameCount, 1)
        XCTAssertEqual(health.idleCount, 1)
    }

    func testRepeatedIdleDoesNotInflateFrameCount() {
        var health = TBCaptureHealth(now: 0)
        health.recordFrame(now: 1)
        for time in 2...600 { health.observe(.idle, now: Double(time)) }
        XCTAssertFalse(health.shouldRestart(now: 900))
        XCTAssertEqual(health.frameCount, 1)
        XCTAssertEqual(health.idleCount, 599)
    }

    func testIdleCannotMaskMissingFirstFrame() {
        var health = TBCaptureHealth(now: 0)
        for time in 1...9 { health.observe(.idle, now: Double(time)) }
        XCTAssertTrue(health.shouldRestart(now: 10))
        XCTAssertNil(health.lastFrameAt)
    }

    func testNewFramesResumeAfterLongIdle() {
        var health = TBCaptureHealth(now: 0)
        health.recordFrame(now: 1)
        health.observe(.idle, now: 2)
        health.observe(.active, now: 600)
        health.recordFrame(now: 600)
        XCTAssertEqual(health.state, .active)
        XCTAssertEqual(health.frameCount, 2)
        XCTAssertFalse(health.shouldRestart(now: 607.9))
        XCTAssertTrue(health.shouldRestart(now: 608))
    }

    func testResumedStatusGetsGraceButCannotMaskMissingFrames() {
        var health = TBCaptureHealth(now: 0)
        health.recordFrame(now: 1)
        health.observe(.idle, now: 2)
        for time in 600...607 { health.observe(.active, now: Double(time)) }
        XCTAssertFalse(health.shouldRestart(now: 607.9))
        XCTAssertTrue(health.shouldRestart(now: 608))
    }

    func testBlankDoesNotTriggerWakeLoop() {
        var health = TBCaptureHealth(now: 0)
        health.observe(.blank, now: 1)
        XCTAssertFalse(health.shouldRestart(now: 3600))
        health.observe(.active, now: 3601)
        XCTAssertFalse(health.shouldRestart(now: 3608))
        XCTAssertTrue(health.shouldRestart(now: 3609))
    }

    func testSuspendedDoesNotTriggerWakeLoop() {
        var health = TBCaptureHealth(now: 0)
        health.recordFrame(now: 1)
        health.observe(.suspended, now: 2)
        XCTAssertFalse(health.shouldRestart(now: 3600))
        health.recordFrame(now: 3601)
        XCTAssertFalse(health.shouldRestart(now: 3602))
    }

    func testStoppedAfterIdleRequiresRecovery() {
        var health = TBCaptureHealth(now: 0)
        health.recordFrame(now: 1)
        health.observe(.idle, now: 2)
        health.observe(.stopped, now: 3)
        XCTAssertTrue(health.shouldRestart(now: 3))
    }

    func testUnknownStatusDoesNotDisableWatchdog() {
        var health = TBCaptureHealth(now: 0)
        health.recordFrame(now: 1)
        health.observe(.unknown, now: 7)
        XCTAssertTrue(health.shouldRestart(now: 9))
    }

    func testFreshPipelineDoesNotInheritOldIdleState() {
        var old = TBCaptureHealth(now: 0)
        old.recordFrame(now: 1)
        old.observe(.idle, now: 2)
        let fresh = TBCaptureHealth(now: 100)
        XCTAssertFalse(old.shouldRestart(now: 200))
        XCTAssertTrue(fresh.shouldRestart(now: 108))
        XCTAssertEqual(fresh.frameCount, 0)
    }

    func testRecoveryRecheckCancelsAfterAFrameArrives() {
        var health = TBCaptureHealth(now: 0)
        health.recordFrame(now: 1)
        XCTAssertTrue(health.shouldRestart(now: 10))
        health.recordFrame(now: 10.2)
        XCTAssertFalse(health.shouldRestart(now: 10.5))
    }

    func testRecoveryRecheckCancelsAfterIdleNotification() {
        var health = TBCaptureHealth(now: 0)
        health.recordFrame(now: 1)
        XCTAssertTrue(health.shouldRestart(now: 10))
        health.observe(.idle, now: 10.2)
        XCTAssertFalse(health.shouldRestart(now: 10.5))
    }

    func testScreenCaptureKitMappingsAndFiltering() {
        for (status, expected) in [(SCFrameStatus.complete, TBCaptureHealth.State.active),
                                   (.started, .active), (.idle, .idle), (.blank, .blank),
                                   (.suspended, .suspended), (.stopped, .stopped)] {
            XCTAssertEqual(TBCaptureHealth.State(status), expected)
            XCTAssertEqual(expected.canContainFrame, expected == .active)
        }
        XCTAssertTrue(TBCaptureHealth.State.unknown.canContainFrame)
    }

    func testDirectDisplayStreamMappingsAndFiltering() {
        for (status, expected) in [(CGDisplayStreamFrameStatus.frameComplete, TBCaptureHealth.State.active),
                                   (.frameIdle, .idle), (.frameBlank, .blank), (.stopped, .stopped)] {
            XCTAssertEqual(TBCaptureHealth.State(status), expected)
            XCTAssertEqual(expected.canContainFrame, expected == .active)
        }
    }

    func testRealSampleAttachmentParsing() throws {
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 8, 8,
            kCVPixelFormatType_32BGRA, nil, &pixel), kCVReturnSuccess)
        var format: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: try XCTUnwrap(pixel),
            formatDescriptionOut: &format), noErr)
        var timing = CMSampleTimingInfo(duration: .invalid,
            presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: try XCTUnwrap(pixel),
            formatDescription: try XCTUnwrap(format), sampleTiming: &timing,
            sampleBufferOut: &sample), noErr)
        let buffer = try XCTUnwrap(sample)
        XCTAssertEqual(TBCaptureHealth.State(sampleBuffer: buffer), .unknown)
        let array = try XCTUnwrap(CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true))
        let dict = unsafeBitCast(CFArrayGetValueAtIndex(array, 0), to: NSMutableDictionary.self)
        for status in [SCFrameStatus.complete, .idle, .blank, .started, .suspended, .stopped] {
            dict[SCStreamFrameInfo.status] = status.rawValue
            XCTAssertEqual(TBCaptureHealth.State(sampleBuffer: buffer), TBCaptureHealth.State(status))
        }
        dict[SCStreamFrameInfo.status] = 999
        XCTAssertEqual(TBCaptureHealth.State(sampleBuffer: buffer), .unknown)
    }
}
