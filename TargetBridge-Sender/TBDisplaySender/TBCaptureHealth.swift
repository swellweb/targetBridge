import Foundation
import CoreGraphics
import CoreMedia
import ScreenCaptureKit

/// Capture health is not FPS: event-driven capture may remain idle indefinitely.
/// Owned by the pipeline under its snapshot lock. Times use monotonic uptime.
struct TBCaptureHealth {
    enum State: String {
        case starting, active, idle, blank, suspended, stopped, unknown

        init(_ status: SCFrameStatus) {
            switch status {
            case .complete, .started: self = .active
            case .idle: self = .idle
            case .blank: self = .blank
            case .suspended: self = .suspended
            case .stopped: self = .stopped
            @unknown default: self = .unknown
            }
        }

        init(_ status: CGDisplayStreamFrameStatus) {
            switch status {
            case .frameComplete: self = .active
            case .frameIdle: self = .idle
            case .frameBlank: self = .blank
            case .stopped: self = .stopped
            @unknown default: self = .unknown
            }
        }

        init(sampleBuffer: CMSampleBuffer) {
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[SCStreamFrameInfo.status] as? Int,
                  let status = SCFrameStatus(rawValue: raw) else {
                self = .unknown
                return
            }
            self.init(status)
        }

        var canContainFrame: Bool { self == .active || self == .unknown }
        var isQuiescent: Bool { self == .idle || self == .blank || self == .suspended }
    }

    private(set) var state: State = .starting
    private(set) var frameCount: UInt64 = 0
    private(set) var idleCount: UInt64 = 0
    private(set) var lastFrameAt: TimeInterval?
    private var progressAt: TimeInterval

    init(now: TimeInterval) { progressAt = now }

    mutating func observe(_ next: State, now: TimeInterval) {
        // A resumed stream gets a fresh grace period, but repeated callbacks
        // without usable frames must not hide a genuine capture failure.
        if state.isQuiescent && !next.isQuiescent && next != .stopped {
            progressAt = now
        }
        state = next
        if next == .idle { idleCount &+= 1 }
    }

    mutating func recordFrame(now: TimeInterval) {
        state = .active
        lastFrameAt = now
        progressAt = now
        frameCount &+= 1
    }

    func shouldRestart(now: TimeInterval, timeout: TimeInterval = 8) -> Bool {
        if state == .stopped { return true }
        // Blank/suspended are deliberate states, not failures; don't wake a
        // sleeping display in a restart loop. System-wake recovery is separate.
        if state == .blank || state == .suspended { return false }
        // An idle event is a state transition, NOT a periodic heartbeat promise.
        // Require a real first frame so initial idle cannot mask a failed start.
        if state == .idle && lastFrameAt != nil { return false }
        return now - progressAt >= timeout
    }
}
