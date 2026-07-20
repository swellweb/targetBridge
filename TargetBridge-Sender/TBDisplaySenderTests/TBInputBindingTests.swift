import XCTest
@testable import TargetBridge

final class TBInputBindingTests: XCTestCase {
    func testMatchesOnlyTheExactTriggerCombination() {
        let binding = TBInputBinding(
            trigger: TBInputShortcut(keyCode: 123, modifiers: TBInputShortcut.control | TBInputShortcut.option),
            action: TBInputShortcut(keyCode: 123, modifiers: TBInputShortcut.control)
        )

        XCTAssertEqual(
            TBInputBindingEngine.match(keyCode: 123, modifiers: TBInputShortcut.control | TBInputShortcut.option, in: [binding]),
            binding
        )
        XCTAssertNil(TBInputBindingEngine.match(keyCode: 123, modifiers: TBInputShortcut.control, in: [binding]))
        XCTAssertNil(TBInputBindingEngine.match(keyCode: 124, modifiers: TBInputShortcut.control | TBInputShortcut.option, in: [binding]))
    }

    func testDisabledBindingDoesNotMatch() {
        let binding = TBInputBinding(
            trigger: TBInputShortcut(keyCode: 124, modifiers: TBInputShortcut.control | TBInputShortcut.option),
            action: TBInputShortcut(keyCode: 124, modifiers: TBInputShortcut.control),
            enabled: false
        )

        XCTAssertNil(TBInputBindingEngine.match(keyCode: 124, modifiers: TBInputShortcut.control | TBInputShortcut.option, in: [binding]))
    }

    func testModifierBitsTreatLeftAndRightKeysAsTheSameModifier() {
        XCTAssertEqual(TBInputBindingEngine.modifierBit(for: 59), TBInputShortcut.control)
        XCTAssertEqual(TBInputBindingEngine.modifierBit(for: 62), TBInputShortcut.control)
        XCTAssertEqual(TBInputBindingEngine.modifierBit(for: 58), TBInputShortcut.option)
        XCTAssertEqual(TBInputBindingEngine.modifierBit(for: 61), TBInputShortcut.option)
    }
}
