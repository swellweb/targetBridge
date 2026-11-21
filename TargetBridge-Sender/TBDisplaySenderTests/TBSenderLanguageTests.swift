import XCTest
@testable import TargetBridge

final class TBSenderLanguageTests: XCTestCase {
    func testFirstSupportedSystemLanguageWins() {
        XCTAssertEqual(TBDisplaySenderLanguage.preferred(by: ["zh-Hans-AU", "en-AU"]), .chinese)
        XCTAssertEqual(TBDisplaySenderLanguage.preferred(by: ["de-CH"]), .german)
        XCTAssertEqual(TBDisplaySenderLanguage.preferred(by: ["fr-CA", "it-IT"]), .french)
        XCTAssertEqual(TBDisplaySenderLanguage.preferred(by: ["it"]), .italian)
    }

    func testUnsupportedLanguagesAreSkipped() {
        XCTAssertEqual(TBDisplaySenderLanguage.preferred(by: ["ja-JP", "it-IT"]), .italian)
    }

    func testEnglishWhenNothingIsSupported() {
        XCTAssertEqual(TBDisplaySenderLanguage.preferred(by: ["ja-JP", "ko-KR"]), .english)
        XCTAssertEqual(TBDisplaySenderLanguage.preferred(by: []), .english)
    }

    func testSavedLanguageTakesPrecedenceOverSystemLanguage() {
        let suite = "TargetBridge.LanguageTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for language in TBDisplaySenderLanguage.allCases {
            defaults.set(language.rawValue, forKey: TBDisplaySenderLanguage.defaultsKey)
            XCTAssertEqual(TBDisplaySenderLanguage.load(defaults: defaults), language)
        }
    }

    func testInvalidSavedLanguageFallsBackToSystemLanguage() {
        let suite = "TargetBridge.LanguageTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("unsupported", forKey: TBDisplaySenderLanguage.defaultsKey)
        XCTAssertEqual(TBDisplaySenderLanguage.load(defaults: defaults),
                       TBDisplaySenderLanguage.preferred(by: Locale.preferredLanguages))
    }
}
