import XCTest
@testable import TargetBridge

final class TBDisplayProfileTests: XCTestCase {
    func testWork5KUsesAnExtendedNative5KDisplay() {
        let settings = TBDisplayProfile.work5K.settings

        XCTAssertEqual(settings.captureSource, .extendedDesktop)
        XCTAssertEqual(settings.capturePreset, .native5k)
        XCTAssertTrue(settings.matchRenderToStream)
        XCTAssertFalse(settings.audioEnabled)
    }

    func testLowLatencyPrioritizesSmoothVideoWithoutAudio() {
        let settings = TBDisplayProfile.lowLatency.settings

        XCTAssertEqual(settings.captureSource, .desktopMirror)
        XCTAssertEqual(settings.capturePreset, .smooth1440p60)
        XCTAssertFalse(settings.matchRenderToStream)
        XCTAssertFalse(settings.audioEnabled)
    }

    func testPresentationUsesACompatibleMirrorProfileWithAudio() {
        let settings = TBDisplayProfile.presentation.settings

        XCTAssertEqual(settings.captureSource, .desktopMirror)
        XCTAssertEqual(settings.capturePreset, .standard1440p)
        XCTAssertTrue(settings.audioEnabled)
    }
}
