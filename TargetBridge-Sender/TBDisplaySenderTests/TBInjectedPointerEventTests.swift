import CoreGraphics
import XCTest
@testable import TargetBridge

final class TBInjectedPointerEventTests: XCTestCase {
    private func mouse(_ type: CGEventType, _ flags: CGEventFlags,
                       button: CGMouseButton = .left) throws -> CGEvent {
        try XCTUnwrap(TBInjectedPointerEvent.mouse(source: CGEventSource(stateID: .hidSystemState),
            type: type, position: CGPoint(x: 120, y: 240), button: button, modifiers: flags))
    }

    func testShiftAndCommandReachBothHalvesOfClick() throws {
        for flags: CGEventFlags in [.maskShift, .maskCommand, [.maskShift, .maskCommand]] {
            for type: CGEventType in [.leftMouseDown, .leftMouseUp] {
                let event = try mouse(type, flags)
                XCTAssertEqual(event.flags, flags)
                XCTAssertEqual(event.type, type)
            }
        }
    }

    func testRepeatedSelectionClicksAndModifierRelease() throws {
        // The remote key state stays held across clicks, then becomes empty on key-up.
        for flags: CGEventFlags in [.maskCommand, .maskCommand, .maskShift, []] {
            XCTAssertEqual(try mouse(.leftMouseDown, flags).flags, flags)
            XCTAssertEqual(try mouse(.leftMouseUp, flags).flags, flags)
        }
    }

    func testAllDragButtonsPreserveModifiers() throws {
        let flags: CGEventFlags = [.maskCommand, .maskShift]
        for (type, button) in [(CGEventType.leftMouseDragged, CGMouseButton.left),
                               (.rightMouseDragged, .right), (.otherMouseDragged, .center)] {
            let event = try mouse(type, flags, button: button)
            XCTAssertEqual(event.flags, flags)
            XCTAssertEqual(event.type, type)
            XCTAssertEqual(event.location, CGPoint(x: 120, y: 240))
        }
    }

    func testPointerMotionIncludingEdgeMovesPreservesModifiers() throws {
        let flags: CGEventFlags = [.maskShift, .maskAlternate]
        let event = try mouse(.mouseMoved, flags)
        event.setIntegerValueField(.mouseEventDeltaX, value: -3)
        event.setIntegerValueField(.mouseEventDeltaY, value: 7)
        XCTAssertEqual(event.flags, flags)
        XCTAssertEqual(event.getIntegerValueField(.mouseEventDeltaX), -3)
        XCTAssertEqual(event.getIntegerValueField(.mouseEventDeltaY), 7)
    }

    func testRightAndMiddleClicksAndDoubleClickStateStayIntact() throws {
        for (type, button) in [(CGEventType.rightMouseDown, CGMouseButton.right),
                               (.rightMouseUp, .right), (.otherMouseDown, .center),
                               (.otherMouseUp, .center), (.leftMouseDown, .left)] {
            let event = try mouse(type, .maskControl, button: button)
            event.setIntegerValueField(.mouseEventClickState, value: 2)
            XCTAssertEqual(event.flags, .maskControl)
            XCTAssertEqual(event.getIntegerValueField(.mouseEventClickState), 2)
            XCTAssertEqual(event.getIntegerValueField(.mouseEventButtonNumber), Int64(button.rawValue))
        }
    }

    func testScrollPreservesOnlyRemoteFlagsAndClearsThemAfterRelease() throws {
        for flags: CGEventFlags in [.maskAlternate, .maskShift, [.maskShift, .maskCommand], []] {
            let event = try XCTUnwrap(TBInjectedPointerEvent.scroll(
                source: CGEventSource(stateID: .hidSystemState), x: 2, y: -3, modifiers: flags))
            XCTAssertEqual(event.flags, flags)
            XCTAssertFalse(event.flags.contains(.maskSecondaryFn))
            XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventDeltaAxis1), -3)
            XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventDeltaAxis2), 2)
        }
    }
}
