import AppKit
import CoreGraphics
import Foundation

/// Consuming event tap for the hardware volume keys (sound up / sound down / mute).
///
/// While a session streams audio the sender Mac is typically muted — ScreenCaptureKit
/// captures system audio upstream of the output device, so the local mute only
/// silences the speakers. The physical volume keys would then just flash the local
/// bezel over a muted device. This tap lets the service redirect them to the
/// receiver's volume instead: the handler decides per event whether it was consumed;
/// unclaimed events fall through to macOS untouched.
@MainActor
final class TBVolumeKeyRelayController {
    enum Key {
        case up
        case down
        case mute
    }

    /// Called for every volume-key press and release. Return true to consume the
    /// event (macOS never sees it), false to let it through. Volume is only
    /// adjusted on `isKeyDown`; releases are reported so the matching key-up can
    /// be swallowed alongside its press.
    typealias Handler = (_ key: Key, _ isKeyDown: Bool, _ fineStep: Bool) -> Bool

    // NX_SYSDEFINED media-key event constants (IOKit/hidsystem/ev_keymap.h).
    // CGEventType has no case for 14, so the raw value is compared directly.
    private static let systemDefinedEventType: UInt32 = 14
    private static let mediaKeySubtype: Int16 = 8
    private static let soundUpKey = 0 // NX_KEYTYPE_SOUND_UP
    private static let soundDownKey = 1 // NX_KEYTYPE_SOUND_DOWN
    private static let muteKey = 7 // NX_KEYTYPE_MUTE

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var handler: Handler?

    var isActive: Bool { eventTap != nil }

    /// Installs the tap on the main run loop. Returns false when the tap cannot
    /// be created, which in practice means Accessibility trust is missing — a
    /// consuming session tap is refused without it.
    @discardableResult
    func start(handler: @escaping Handler) -> Bool {
        stop()

        let mask = CGEventMask(1) << CGEventMask(Self.systemDefinedEventType)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, cgEvent, refcon in
                guard let refcon else { return Unmanaged.passUnretained(cgEvent) }
                let controller = Unmanaged<TBVolumeKeyRelayController>.fromOpaque(refcon).takeUnretainedValue()
                return controller.handle(type: type, cgEvent: cgEvent)
            },
            userInfo: refcon
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source
        self.handler = handler
        return true
    }

    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        handler = nil
    }

    private func handle(type: CGEventType, cgEvent: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables taps that stall or when secure input kicks in;
        // re-enable and stay out of the way.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(cgEvent)
        }

        guard type.rawValue == Self.systemDefinedEventType,
              let handler,
              let event = NSEvent(cgEvent: cgEvent),
              event.subtype.rawValue == Self.mediaKeySubtype
        else {
            return Unmanaged.passUnretained(cgEvent)
        }

        let data1 = event.data1
        let key: Key
        switch (data1 & 0xFFFF_0000) >> 16 {
        case Self.soundUpKey: key = .up
        case Self.soundDownKey: key = .down
        case Self.muteKey: key = .mute
        default:
            return Unmanaged.passUnretained(cgEvent)
        }

        let isKeyDown = ((data1 & 0x0000_FF00) >> 8) == 0x0A
        let fineStep = event.modifierFlags.contains(.shift) && event.modifierFlags.contains(.option)
        return handler(key, isKeyDown, fineStep) ? nil : Unmanaged.passUnretained(cgEvent)
    }
}
