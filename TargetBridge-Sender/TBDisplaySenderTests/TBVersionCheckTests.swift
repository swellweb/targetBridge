import XCTest
@testable import TargetBridge

@MainActor
final class TBVersionCheckTests: XCTestCase {
    func testVersionsCompareNumerically() {
        XCTAssertEqual(TBVersionCheck.compare("4.0", "4.0.0"), .orderedSame)
        XCTAssertEqual(TBVersionCheck.compare("3.7.0-rc1", "4.0"), .orderedAscending)
        XCTAssertEqual(TBVersionCheck.compare("4.10", "4.9"), .orderedDescending)
        XCTAssertEqual(TBVersionCheck.components("3.7.0-rc1"), [3, 7, 0])
    }

    func testMismatchNamesTheOlderApp() {
        XCTAssertNil(TBVersionCheck.mismatch(sender: "4.0", receiver: "4.0"))
        XCTAssertEqual(TBVersionCheck.mismatch(sender: "4.0", receiver: nil), .receiverOlder(nil))
        XCTAssertEqual(TBVersionCheck.mismatch(sender: "4.0", receiver: "3.6.0"), .receiverOlder("3.6.0"))
        XCTAssertEqual(TBVersionCheck.mismatch(sender: "4.0", receiver: "4.1"), .senderOlder("4.1"))
    }

    func testUncompressedProfilesChooseTheirCompression() {
        XCTAssertEqual(TBDisplayCapturePreset.native5k60Uncompressed.forcedCodecPreference, .uncompressed)
        XCTAssertEqual(TBDisplayCapturePreset.native5k60UncompressedLZ4.forcedCodecPreference, .uncompressedLZ4)
        XCTAssertEqual(TBDisplayCapturePreset.native5k60Enhanced10Bit.forcedCodecPreference, .uncompressedEnhanced)
        XCTAssertEqual(TBDisplayCapturePreset.native5k60Full10Bit.forcedCodecPreference, .uncompressedFull10Bit)
        XCTAssertNil(TBDisplayCapturePreset.native5k60Experimental.forcedCodecPreference)
        for preset in [TBDisplayCapturePreset.native5k60Uncompressed, .native5k60Full10Bit] {
            XCTAssertEqual(preset.width, 5120)
            XCTAssertEqual(preset.height, 2880)
            XCTAssertEqual(preset.expectedFrameRate, 60)
        }
    }

    func testAutomationAcceptsTheNewProfiles() {
        XCTAssertEqual(TBSenderAutomation.parsePreset("5k60lz4"), .native5k60UncompressedLZ4)
        XCTAssertEqual(TBSenderAutomation.parsePreset("5k60full10"), .native5k60Full10Bit)
        XCTAssertEqual(TBSenderAutomation.parsePreset("native5k60Enhanced10Bit"), .native5k60Enhanced10Bit)
    }
}
