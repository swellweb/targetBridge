import CoreGraphics
import Foundation

/// Tracks the click count macOS expects on injected mouse-down events.
/// Receiver input packets carry button transitions, not click metadata.
struct TBInjectedClickStateTracker {
    private(set) var currentClickState = 0
    private var lastClickTime: TimeInterval?
    private var lastClickLocation: CGPoint?

    mutating func registerClick(
        at location: CGPoint,
        timestamp: TimeInterval,
        doubleClickInterval: TimeInterval,
        maximumDistance: CGFloat = 4
    ) -> Int {
        let isConsecutiveClick: Bool
        if let lastClickTime, let lastClickLocation {
            let elapsed = timestamp - lastClickTime
            let distance = hypot(location.x - lastClickLocation.x, location.y - lastClickLocation.y)
            isConsecutiveClick = elapsed >= 0 && elapsed <= doubleClickInterval && distance <= maximumDistance
        } else {
            isConsecutiveClick = false
        }

        currentClickState = isConsecutiveClick ? currentClickState + 1 : 1
        lastClickTime = timestamp
        lastClickLocation = location
        return currentClickState
    }

    mutating func reset() {
        currentClickState = 0
        lastClickTime = nil
        lastClickLocation = nil
    }
}
