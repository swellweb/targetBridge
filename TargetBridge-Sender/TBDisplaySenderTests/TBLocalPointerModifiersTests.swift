import CoreGraphics
import XCTest
@testable import TargetBridge

final class TBLocalPointerModifiersTests: XCTestCase {
    private func pointer(_ type: CGEventType = .leftMouseDown,
                         flags: CGEventFlags = []) throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: type,
            mouseCursorPosition: CGPoint(x: 120, y: 240), mouseButton: .left))
        event.flags = flags
        return event
    }

    func testRemoteShiftAndCommandReachLocalClicksAndDrags() throws {
        for flags: CGEventFlags in [.maskShift, .maskCommand, [.maskShift, .maskCommand]] {
            let state = TBLocalPointerModifiers(remoteFlags: flags)
            for type in TBLocalPointerModifiers.eventTypes {
                let event = try pointer(type)
                XCTAssertTrue(state.apply(to: event))
                XCTAssertEqual(event.flags, flags)
                XCTAssertEqual(event.type, type)
            }
        }
    }

    func testHeldModifierPersistsAcrossClicksThenReleaseClearsIt() throws {
        var state = TBLocalPointerModifiers(remoteFlags: [.maskShift, .maskCommand])
        for _ in 0..<3 {
            XCTAssertTrue(state.apply(to: try pointer()))
        }
        state.remoteFlags = .maskShift
        let stillShift = try pointer()
        state.apply(to: stillShift)
        XCTAssertEqual(stillShift.flags, .maskShift)
        state.remoteFlags = []
        let released = try pointer()
        XCTAssertFalse(state.apply(to: released))
        XCTAssertEqual(released.flags, [])
    }

    func testPreservesPhysicalModifiersPositionAndClickCount() throws {
        let event = try pointer(flags: [.maskAlternate, .maskAlphaShift])
        event.setIntegerValueField(.mouseEventClickState, value: 2)
        TBLocalPointerModifiers(remoteFlags: .maskShift).apply(to: event)
        XCTAssertEqual(event.flags, [.maskAlternate, .maskAlphaShift, .maskShift])
        XCTAssertEqual(event.location, CGPoint(x: 120, y: 240))
        XCTAssertEqual(event.getIntegerValueField(.mouseEventClickState), 2)
    }

    func testRemoteFnAndUnsupportedFlagsNeverLeakIntoLocalClicks() throws {
        let event = try pointer()
        TBLocalPointerModifiers(remoteFlags: [.maskShift, .maskSecondaryFn, .maskAlphaShift,
                                              .maskNumericPad]).apply(to: event)
        XCTAssertEqual(event.flags, .maskShift)
    }

    func testKeyboardMotionAndScrollAreNotRewritten() throws {
        let state = TBLocalPointerModifiers(remoteFlags: [.maskShift, .maskCommand])
        for type: CGEventType in [.keyDown, .keyUp, .flagsChanged, .mouseMoved, .scrollWheel] {
            let event = try pointer()
            event.type = type
            XCTAssertFalse(state.apply(to: event))
            XCTAssertEqual(event.flags, [])
        }
    }

    func testQueuedRelayedClickKeepsOriginalModifierSnapshot() throws {
        let event = try XCTUnwrap(TBInjectedPointerEvent.mouse(source: nil, type: .leftMouseDown,
            position: .zero, button: .left, modifiers: .maskShift))
        XCTAssertFalse(TBLocalPointerModifiers(remoteFlags: .maskCommand).apply(to: event))
        XCTAssertEqual(event.flags, .maskShift)
    }
}
