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

    func testVirtualDisplayReuseRequiresExactTargetBridgeIdentity() {
        let identity = TBVirtualDisplayIdentity.desktopMirror

        XCTAssertTrue(TBVirtualDisplayReuse.matches(
            vendorID: 0xEEEE,
            productID: identity.productID,
            serialNumber: identity.serialNumber,
            identity: identity
        ))
        XCTAssertFalse(TBVirtualDisplayReuse.matches(
            vendorID: 0x1234,
            productID: identity.productID,
            serialNumber: identity.serialNumber,
            identity: identity
        ))
        XCTAssertFalse(TBVirtualDisplayReuse.matches(
            vendorID: 0xEEEE,
            productID: identity.productID + 1,
            serialNumber: identity.serialNumber,
            identity: identity
        ))
        XCTAssertFalse(TBVirtualDisplayReuse.matches(
            vendorID: 0xEEEE,
            productID: identity.productID,
            serialNumber: identity.serialNumber + 1,
            identity: identity
        ))
    }

    func testExtendedIdentityCannotReuseMirrorDisplay() {
        let mirror = TBVirtualDisplayIdentity.desktopMirror
        let extended = TBVirtualDisplayIdentity.extendedDesktop(receiverKey: "iMac-4K")

        XCTAssertFalse(TBVirtualDisplayReuse.matches(
            vendorID: 0xEEEE,
            productID: mirror.productID,
            serialNumber: mirror.serialNumber,
            identity: extended
        ))
    }
}
