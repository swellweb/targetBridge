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
