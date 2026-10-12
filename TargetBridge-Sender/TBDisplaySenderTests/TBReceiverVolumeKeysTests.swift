import XCTest
@testable import TargetBridge

final class TBReceiverVolumeKeysTests: XCTestCase {
    /// Packs `data1` the way IOHIDSystem does for an aux-control-button event:
    /// key code in the high 16 bits, key state in bits 8–15, repeat in bit 0.
    private func data1(keyCode: Int, down: Bool, repeating: Bool = false) -> Int {
        (keyCode << 16) | ((down ? 0x0A : 0x0B) << 8) | (repeating ? 1 : 0)
    }

    // MARK: - Decoding

    func testDecodesVolumeKeysWithStateAndRepeat() {
        let up = TBVolumeKeyEvent.decode(subtype: 8, data1: data1(keyCode: 0, down: true))
        XCTAssertEqual(up, TBVolumeKeyEvent(key: .up, isDown: true, isRepeat: false))

        let downRepeat = TBVolumeKeyEvent.decode(subtype: 8, data1: data1(keyCode: 1, down: true, repeating: true))
        XCTAssertEqual(downRepeat, TBVolumeKeyEvent(key: .down, isDown: true, isRepeat: true))

        let muteRelease = TBVolumeKeyEvent.decode(subtype: 8, data1: data1(keyCode: 7, down: false))
        XCTAssertEqual(muteRelease, TBVolumeKeyEvent(key: .mute, isDown: false, isRepeat: false))
    }

    func testIgnoresOtherMediaKeysAndSubtypes() {
        // Play/pause (16), brightness (2/3) and keyboard backlight (21/22) are
        // not ours; the system must keep handling them.
        for keyCode in [2, 3, 16, 17, 18, 19, 20, 21, 22] {
            XCTAssertNil(TBVolumeKeyEvent.decode(subtype: 8, data1: data1(keyCode: keyCode, down: true)),
                         "key code \(keyCode) should pass through")
        }
        // A volume key code under a different subtype is not a key press.
        XCTAssertNil(TBVolumeKeyEvent.decode(subtype: 7, data1: data1(keyCode: 0, down: true)))
        XCTAssertNil(TBVolumeKeyEvent.decode(subtype: 0, data1: data1(keyCode: 0, down: true)))
    }

    func testIgnoresUnknownKeyState() {
        let data = (0 << 16) | (0x0C << 8)
        XCTAssertNil(TBVolumeKeyEvent.decode(subtype: 8, data1: data))
    }

    // MARK: - Stepping

    func testCoarseStepsFollowSixteenthGrid() {
        XCTAssertEqual(TBReceiverVolumeKeys.step(0.5, .up), 0.5625, accuracy: 1e-9)
        XCTAssertEqual(TBReceiverVolumeKeys.step(0.5, .down), 0.4375, accuracy: 1e-9)
        XCTAssertEqual(TBReceiverVolumeKeys.step(0.0, .up), 0.0625, accuracy: 1e-9)
    }

    func testFineStepsFollowSixtyFourthGrid() {
        XCTAssertEqual(TBReceiverVolumeKeys.step(0.5, .up, fine: true), 0.515625, accuracy: 1e-9)
        XCTAssertEqual(TBReceiverVolumeKeys.step(0.5, .down, fine: true), 0.484375, accuracy: 1e-9)
    }

    func testStepsClampToRange() {
        XCTAssertEqual(TBReceiverVolumeKeys.step(1.0, .up), 1.0)
        XCTAssertEqual(TBReceiverVolumeKeys.step(0.99, .up), 1.0)
        XCTAssertEqual(TBReceiverVolumeKeys.step(0.0, .down), 0.0)
        XCTAssertEqual(TBReceiverVolumeKeys.step(0.01, .down), 0.0)
    }

    func testOffGridLevelsSnapToNeighbouringGridPoint() {
        // A slider can leave the level anywhere; one press lands on the next
        // grid point in the pressed direction without skipping one.
        XCTAssertEqual(TBReceiverVolumeKeys.step(0.53, .up), 0.5625, accuracy: 1e-9)
        XCTAssertEqual(TBReceiverVolumeKeys.step(0.53, .down), 0.5, accuracy: 1e-9)
    }

    func testRepeatedStepsNeverStallOnFloatingPointDrift() {
        var level = 0.0
        for _ in 0..<16 {
            let next = TBReceiverVolumeKeys.step(level, .up)
            XCTAssertGreaterThan(next, level)
            level = next
        }
        XCTAssertEqual(level, 1.0, accuracy: 1e-9)
        for _ in 0..<16 {
            let next = TBReceiverVolumeKeys.step(level, .down)
            XCTAssertLessThan(next, level)
            level = next
        }
        XCTAssertEqual(level, 0.0, accuracy: 1e-9)
    }

    // MARK: - Mute

    func testMuteRemembersAndRestoresLevel() {
        let muted = TBReceiverVolumeKeys.toggleMute(level: 0.75, remembered: nil)
        XCTAssertEqual(muted.level, 0)
        XCTAssertEqual(muted.remembered, 0.75)

        let restored = TBReceiverVolumeKeys.toggleMute(level: muted.level, remembered: muted.remembered)
        XCTAssertEqual(restored.level, 0.75)
        XCTAssertNil(restored.remembered)
    }

    func testUnmuteWithoutRememberedLevelUsesSessionDefault() {
        let result = TBReceiverVolumeKeys.toggleMute(level: 0, remembered: nil)
        XCTAssertEqual(result.level, TBReceiverVolumeKeys.unmuteFallbackLevel)
        XCTAssertNil(result.remembered)
    }
}
