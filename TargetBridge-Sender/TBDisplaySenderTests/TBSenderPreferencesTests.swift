import CoreMedia
import XCTest
@testable import TargetBridge

@MainActor
final class TBSenderPreferencesTests: XCTestCase {
    func testLanguageFollowsSystemRegionVariants() {
        XCTAssertEqual(TBDisplaySenderLanguage.systemDefault(preferredLanguages: ["de-DE"]), .german)
        XCTAssertEqual(TBDisplaySenderLanguage.systemDefault(preferredLanguages: ["zh-Hans-CN"]), .chinese)
        XCTAssertEqual(TBDisplaySenderLanguage.systemDefault(preferredLanguages: ["it"]), .italian)
    }

    func testUnavailableOrMissingLanguageFallsBackToEnglish() {
        XCTAssertEqual(TBDisplaySenderLanguage.systemDefault(preferredLanguages: ["es-ES", "de-DE"]), .english)
        XCTAssertEqual(TBDisplaySenderLanguage.systemDefault(preferredLanguages: []), .english)
    }

    func testBrightnessKeysAreDecoded() {
        XCTAssertEqual(
            TBBrightnessKeyEvent.decode(subtype: 8, data1: (2 << 16) | (0xA << 8)),
            TBBrightnessKeyEvent(isIncrease: true, isPressed: true)
        )
        XCTAssertEqual(
            TBBrightnessKeyEvent.decode(subtype: 8, data1: (3 << 16) | (0xB << 8)),
            TBBrightnessKeyEvent(isIncrease: false, isPressed: false)
        )
    }

    func testOtherSystemEventsAreNotBrightnessKeys() {
        XCTAssertNil(TBBrightnessKeyEvent.decode(subtype: 8, data1: (0 << 16) | (0xA << 8)))
        XCTAssertNil(TBBrightnessKeyEvent.decode(subtype: 7, data1: (2 << 16) | (0xA << 8)))
    }

    func testBrightnessStepsStayInRange() {
        XCTAssertEqual(TBDisplaySenderSession.steppedBrightness(from: 0.5, increase: true), 0.5625)
        XCTAssertEqual(TBDisplaySenderSession.steppedBrightness(from: 1, increase: true), 1)
        XCTAssertEqual(TBDisplaySenderSession.steppedBrightness(from: 0, increase: false), 0)
    }

    func testUncompressedFallsBackLikeAutomaticWhenRawIsUnavailable() {
        let decision = TBDisplaySenderSession.chooseCodec(
            preference: .uncompressed,
            preset: .standard1440p,
            receiverSupportsHEVC: false,
            senderSupportsH264: true,
            senderSupportsHEVC: false
        )
        XCTAssertEqual(decision?.codecType, kCMVideoCodecType_H264)
    }
}
