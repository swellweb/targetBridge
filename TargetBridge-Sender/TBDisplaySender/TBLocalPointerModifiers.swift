import CoreGraphics

/// Combines a remote keyboard with a local mouse, without rewriting key events.
struct TBLocalPointerModifiers {
    static let supported: CGEventFlags = [.maskShift, .maskCommand, .maskAlternate, .maskControl]
    static let eventTypes: [CGEventType] = [
        .leftMouseDown, .leftMouseUp, .leftMouseDragged,
        .rightMouseDown, .rightMouseUp, .rightMouseDragged,
        .otherMouseDown, .otherMouseUp, .otherMouseDragged
    ]
    var remoteFlags: CGEventFlags = []

    @discardableResult
    func apply(to event: CGEvent) -> Bool {
        guard Self.eventTypes.contains(event.type),
              event.getIntegerValueField(.eventSourceUserData) != TBInjectedPointerEvent.marker else { return false }
        let combined = event.flags.union(remoteFlags.intersection(Self.supported))
        guard combined != event.flags else { return false }
        event.flags = combined
        return true
    }
}
