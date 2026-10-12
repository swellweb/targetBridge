import XCTest
@testable import TargetBridge

final class TBOutputMuteRestorationTests: XCTestCase {
    func testMixedChannelsRetainTheirOriginalMuteStates() {
        var states: [UInt32: Bool] = [1: true, 2: false]
        let changed = TBOutputMuteRestoration.mute(
            elements: [1, 2], read: { states[$0] },
            write: { states[$0] = $1; return true }
        )
        XCTAssertEqual(states, [1: true, 2: true])
        XCTAssertEqual(changed, [2])
        TBOutputMuteRestoration.restore(
            changedElements: changed, read: { states[$0] },
            write: { states[$0] = $1; return true }
        )
        XCTAssertEqual(states, [1: true, 2: false])
    }

    func testAlreadyMutedDeviceIsNotChanged() {
        var writes = 0
        let changed = TBOutputMuteRestoration.mute(
            elements: [0], read: { _ in true },
            write: { _, _ in writes += 1; return true }
        )
        TBOutputMuteRestoration.restore(
            changedElements: changed, read: { _ in true },
            write: { _, _ in writes += 1; return true }
        )
        XCTAssertTrue(changed.isEmpty)
        XCTAssertEqual(writes, 0)
    }

    func testFailedReadsAndWritesNeverBecomeRestoreTargets() {
        var writes: [UInt32] = []
        let changed = TBOutputMuteRestoration.mute(
            elements: [1, 2, 3], read: { $0 == 1 ? nil : false },
            write: { element, _ in writes.append(element); return element == 3 }
        )
        XCTAssertEqual(changed, [3])
        XCTAssertEqual(writes, [2, 3])
        writes = []
        TBOutputMuteRestoration.restore(
            changedElements: changed, read: { _ in true },
            write: { element, muted in
                XCTAssertFalse(muted)
                writes.append(element)
                return true
            }
        )
        XCTAssertEqual(writes, [3])
    }

    func testRestoreDoesNotWriteToUnavailableOrAlreadyUnmutedChannels() {
        var writes = 0
        TBOutputMuteRestoration.restore(
            changedElements: [1, 2], read: { $0 == 1 ? nil : false },
            write: { _, _ in writes += 1; return true }
        )
        XCTAssertEqual(writes, 0)
    }
}
