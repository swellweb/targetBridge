import CoreGraphics
import Foundation

@MainActor
final class TBLocalPointerModifierBridge {
    private var modifiers = TBLocalPointerModifiers()
    // Mutated on the main actor; deinit only invalidates/removes the CF resources.
    nonisolated(unsafe) private var tap: CFMachPort?
    nonisolated(unsafe) private var source: CFRunLoopSource?

    func update(_ flags: CGEventFlags) {
        modifiers.remoteFlags = flags.intersection(TBLocalPointerModifiers.supported)
        guard !modifiers.remoteFlags.isEmpty else { stop(); return }
        guard tap == nil else { return }
        let mask = TBLocalPointerModifiers.eventTypes.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                // The tap is serviced exclusively by the main run loop.
                MainActor.assumeIsolated {
                    let bridge = Unmanaged<TBLocalPointerModifierBridge>.fromOpaque(context).takeUnretainedValue()
                    bridge.handle(type: type, event: event)
                }
                return Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
                TBInputDebugLog.log("sender local-pointer modifier bridge unavailable; check Accessibility")
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
        TBInputDebugLog.log("sender local-pointer modifier bridge active")
    }

    func stop() {
        modifiers.remoteFlags = []
        if let tap { CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        } else if modifiers.apply(to: event), type == .leftMouseDown {
            let flags = modifiers.remoteFlags.rawValue
            Task { @MainActor in
                TBInputDebugLog.log("sender local click with remote modifiers=\(flags)")
            }
        }
    }

    deinit {
        if let tap { CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    }
}
