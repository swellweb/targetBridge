import AppKit
import ApplicationServices

struct TBBrightnessKeyEvent: Equatable {
    let isIncrease: Bool
    let isPressed: Bool

    /// Decodes a system-defined key event. Subtype 8 carries the media keys.
    static func decode(subtype: Int16, data1: Int) -> TBBrightnessKeyEvent? {
        guard subtype == 8 else { return nil }
        let keyCode = (data1 & 0xFFFF_0000) >> 16
        let keyState = (data1 & 0xFF00) >> 8
        let increaseKey = 2 // NX_KEYTYPE_BRIGHTNESS_UP
        let decreaseKey = 3 // NX_KEYTYPE_BRIGHTNESS_DOWN
        guard keyCode == increaseKey || keyCode == decreaseKey else { return nil }
        return TBBrightnessKeyEvent(isIncrease: keyCode == increaseKey, isPressed: keyState == 0xA)
    }
}

/// Catches the brightness keys. The handler returns true to keep a key from macOS.
@MainActor
final class TBBrightnessKeyController {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var requestedAccessibility = false
    var handler: ((TBBrightnessKeyEvent) -> Bool)?

    func start() {
        guard tap == nil else { return }
        let mask = CGEventMask(1) << NSEvent.EventType.systemDefined.rawValue
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                // The tap is serviced exclusively by the main run loop.
                let consumed = MainActor.assumeIsolated {
                    Unmanaged<TBBrightnessKeyController>.fromOpaque(context)
                        .takeUnretainedValue()
                        .handle(type: type, event: event)
                }
                return consumed ? nil : Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
                requestAccessibilityOnce()
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
    }

    func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CFMachPortInvalidate(tap)
        self.tap = nil
        source = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        guard let systemEvent = NSEvent(cgEvent: event),
              systemEvent.type == .systemDefined,
              let key = TBBrightnessKeyEvent.decode(
                  subtype: systemEvent.subtype.rawValue,
                  data1: systemEvent.data1
              ) else { return false }
        return handler?(key) ?? false
    }

    private func requestAccessibilityOnce() {
        guard !requestedAccessibility else { return }
        requestedAccessibility = true
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}
