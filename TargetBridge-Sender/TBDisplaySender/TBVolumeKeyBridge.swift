import AppKit
import CoreGraphics
import Foundation

/// Routes the keyboard's volume keys to a receiver instead of this Mac.
///
/// Relayed audio is captured before this Mac's output volume is applied
/// (see docs/audio.md), so the system volume keys have no effect on what the
/// receiver plays. While active, this intercepts the volume up / down / mute
/// keys with an event tap, hands them to `handler`, and swallows them so the
/// sender's own output level is left alone. Every other key — play/pause,
/// brightness, keyboard backlight — passes through untouched.
///
/// Filtering (rather than observing) events needs the app to be trusted under
/// Privacy & Security › Accessibility. Without it `start` fails quietly and
/// `isActive` stays false; the settings UI reads that to show a hint.
@MainActor
final class TBVolumeKeyBridge {
    typealias Handler = (_ key: TBVolumeKeyEvent.Key, _ fine: Bool) -> Void

    /// `NX_SYSDEFINED` — CoreGraphics has no named case for it.
    private static let systemDefinedEventType = CGEventType(rawValue: 14)!

    private var handler: Handler?
    // Mutated on the main actor; deinit only invalidates/removes the CF resources.
    nonisolated(unsafe) private var tap: CFMachPort?
    nonisolated(unsafe) private var source: CFRunLoopSource?

    var isActive: Bool { tap != nil }

    /// Installs the tap if it is not already running. Safe to call repeatedly,
    /// which lets the owner retry after the user grants Accessibility access.
    func start(handler: @escaping Handler) {
        self.handler = handler
        guard tap == nil else { return }

        let mask = CGEventMask(1) << CGEventMask(Self.systemDefinedEventType.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                // The tap is serviced exclusively by the main run loop. Only a
                // Bool crosses the isolation boundary: CGEvent is not Sendable.
                let swallow = MainActor.assumeIsolated { () -> Bool in
                    let bridge = Unmanaged<TBVolumeKeyBridge>.fromOpaque(context).takeUnretainedValue()
                    return bridge.handle(type: type, event: event)
                }
                return swallow ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            TBLog.audio.warning("volume key bridge unavailable; check Accessibility permission")
            TBInputDebugLog.log("sender volume key bridge unavailable; check Accessibility")
            return
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return
        }
        self.tap = tap
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        TBLog.audio.info("volume key bridge active")
    }

    func stop() {
        handler = nil
        guard tap != nil else { return }
        if let tap { CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        TBLog.audio.info("volume key bridge stopped")
    }

    /// Returns true when the event is a volume key press that was handled and
    /// must not reach the system.
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        guard type == Self.systemDefinedEventType,
              let nsEvent = NSEvent(cgEvent: event),
              let keyEvent = TBVolumeKeyEvent.decode(subtype: nsEvent.subtype.rawValue, data1: nsEvent.data1)
        else {
            return false
        }

        if keyEvent.isDown {
            // Shift+Option is the system's quarter-step modifier.
            let fine = nsEvent.modifierFlags.contains([.shift, .option])
            handler?(keyEvent.key, fine)
        }
        // Swallow the key-up as well, so the system never sees half a press.
        return true
    }

    deinit {
        if let tap { CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    }
}
