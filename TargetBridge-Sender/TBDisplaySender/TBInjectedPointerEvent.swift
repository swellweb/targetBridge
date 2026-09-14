import CoreGraphics

/// Pointer events must carry the relayed keyboard state, not the sender's HID flags.
enum TBInjectedPointerEvent {
    static let marker: Int64 = 0x5442504F494E5445

    static func mouse(source: CGEventSource?, type: CGEventType, position: CGPoint,
                      button: CGMouseButton, modifiers: CGEventFlags) -> CGEvent? {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: position, mouseButton: button) else { return nil }
        event.flags = modifiers
        event.setIntegerValueField(.eventSourceUserData, value: marker)
        return event
    }

    static func scroll(source: CGEventSource?, x: Int32, y: Int32,
                       modifiers: CGEventFlags) -> CGEvent? {
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .line,
                                  wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0) else { return nil }
        event.flags = modifiers
        event.setIntegerValueField(.eventSourceUserData, value: marker)
        return event
    }
}
