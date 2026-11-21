import XCTest
@testable import TargetBridge

final class TBMenuBarIconPreferenceTests: XCTestCase {
    private func withDefaults(_ body: (UserDefaults, String) throws -> Void) rethrows {
        let suite = "org.targetbridge.tests.menu-bar.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults, suite)
    }

    func testMissingPreferenceDefaultsToVisibleWithoutWriting() {
        withDefaults { defaults, suite in
            XCTAssertTrue(TBMenuBarIconPreference.load(defaults: defaults))
            XCTAssertTrue(defaults.persistentDomain(forName: suite)?.isEmpty ?? true)
        }
    }

    func testHiddenPreferenceSurvivesReload() {
        withDefaults { defaults, suite in
            TBMenuBarIconPreference.save(false, defaults: defaults)
            let reloaded = UserDefaults(suiteName: suite)!
            XCTAssertFalse(TBMenuBarIconPreference.load(defaults: reloaded))
        }
    }

    func testRepeatedChangesPersistTheLatestSelection() {
        withDefaults { defaults, _ in
            for requested in [false, true, false, true, false] {
                TBMenuBarIconPreference.save(requested, defaults: defaults)
                XCTAssertEqual(TBMenuBarIconPreference.load(defaults: defaults), requested)
            }
        }
    }

    func testPreferencesAreIsolatedBetweenStores() {
        withDefaults { first, _ in
            withDefaults { second, _ in
                TBMenuBarIconPreference.save(false, defaults: first)
                XCTAssertTrue(TBMenuBarIconPreference.load(defaults: second))
                XCTAssertFalse(TBMenuBarIconPreference.load(defaults: first))
            }
        }
    }
}
