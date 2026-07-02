import XCTest
@testable import TargetBridge

/// Tests for the pure parsing helpers behind the `targetbridge://` URL scheme
/// and `--connect` launch arguments (docs/Automation.md). These decide which
/// transport/mode/preset/session a scripted connect uses, so regressions here
/// silently reroute automation traffic.
@MainActor
final class TBSenderAutomationParsingTests: XCTestCase {

    // MARK: - parseTransport

    func testParseTransportNetworkAliases() {
        for alias in ["net", "network", "networklink", "link", "NET", "NetworkLink"] {
            XCTAssertEqual(TBSenderAutomation.parseTransport(alias), .networkLink, "alias \(alias)")
        }
    }

    /// Documents the current permissive behavior: anything that is not a
    /// network alias — including typos — selects Thunderbolt Bridge.
    func testParseTransportDefaultsToThunderbolt() {
        for value in ["tb", "thunderbolt", "", "bogus", "TB"] {
            XCTAssertEqual(TBSenderAutomation.parseTransport(value), .thunderboltBridge, "value \(value)")
        }
    }

    // MARK: - parseMode

    func testParseModeExtendedAliases() {
        for alias in ["extended", "extend", "extendeddesktop", "ext", "EXTENDED"] {
            XCTAssertEqual(TBSenderAutomation.parseMode(alias), .extendedDesktop, "alias \(alias)")
        }
    }

    func testParseModeMirrorAliases() {
        for alias in ["mirror", "mirrored", "desktopmirror", "Mirror"] {
            XCTAssertEqual(TBSenderAutomation.parseMode(alias), .desktopMirror, "alias \(alias)")
        }
    }

    func testParseModeAcceptsExactRawValues() {
        XCTAssertEqual(TBSenderAutomation.parseMode("extendedDesktop"), .extendedDesktop)
        XCTAssertEqual(TBSenderAutomation.parseMode("desktopMirror"), .desktopMirror)
    }

    func testParseModeRejectsUnknown() {
        XCTAssertNil(TBSenderAutomation.parseMode("bogus"))
        XCTAssertNil(TBSenderAutomation.parseMode(""))
    }

    // MARK: - parsePreset

    func testParsePresetAcceptsExactRawValues() {
        XCTAssertEqual(TBSenderAutomation.parsePreset("standard1440p"), .standard1440p)
        XCTAssertEqual(TBSenderAutomation.parsePreset("smooth1440p60"), .smooth1440p60)
        XCTAssertEqual(TBSenderAutomation.parsePreset("smooth1800p60"), .smooth1800p60)
        XCTAssertEqual(TBSenderAutomation.parsePreset("crisp2160p60"), .crisp2160p60)
        XCTAssertEqual(TBSenderAutomation.parsePreset("native5k"), .native5k)
    }

    func testParsePresetAliases() {
        XCTAssertEqual(TBSenderAutomation.parsePreset("1440p"), .standard1440p)
        XCTAssertEqual(TBSenderAutomation.parsePreset("standard"), .standard1440p)
        XCTAssertEqual(TBSenderAutomation.parsePreset("1440p60"), .smooth1440p60)
        XCTAssertEqual(TBSenderAutomation.parsePreset("smooth"), .smooth1440p60)
        XCTAssertEqual(TBSenderAutomation.parsePreset("1800p"), .smooth1800p60)
        XCTAssertEqual(TBSenderAutomation.parsePreset("4k"), .crisp2160p60)
        XCTAssertEqual(TBSenderAutomation.parsePreset("crisp"), .crisp2160p60)
        XCTAssertEqual(TBSenderAutomation.parsePreset("5k"), .native5k)
        XCTAssertEqual(TBSenderAutomation.parsePreset("5K"), .native5k, "aliases are case-insensitive")
        XCTAssertEqual(TBSenderAutomation.parsePreset("native"), .native5k)
        XCTAssertEqual(TBSenderAutomation.parsePreset("5120x2880"), .native5k)
    }

    func testParsePresetRejectsUnknown() {
        XCTAssertNil(TBSenderAutomation.parsePreset("bogus"))
        XCTAssertNil(TBSenderAutomation.parsePreset(""))
        // Raw values are case-sensitive and "native5k" has no capitalized alias.
        XCTAssertNil(TBSenderAutomation.parsePreset("NATIVE5K"))
    }

    // MARK: - matches (receiver selection for --receiver <value>)

    private func makeReceiver() -> TBDiscoveredReceiver {
        TBDiscoveredReceiver(
            serviceName: "TargetBridge Jonathans-iMac",
            receiverName: "Jonathans-iMac",
            preferredIP: "192.168.1.64",
            thunderboltIP: "169.254.89.80",
            networkIP: "192.168.1.64",
            panelSummary: "iMac 5K",
            version: "3.1.0",
            supportsHEVCDecode: true,
            hostName: "Jonathans-iMac.local."
        )
    }

    func testMatchesByName() {
        XCTAssertTrue(TBSenderAutomation.matches("Jonathans-iMac", makeReceiver()))
        XCTAssertTrue(TBSenderAutomation.matches("jonathans-imac", makeReceiver()), "name match is case-insensitive")
    }

    func testMatchesByShortHostName() {
        XCTAssertTrue(TBSenderAutomation.matches("jonathans-imac", makeReceiver()))
    }

    func testMatchesByAnyAdvertisedIP() {
        XCTAssertTrue(TBSenderAutomation.matches("192.168.1.64", makeReceiver()), "preferred/network IP")
        XCTAssertTrue(TBSenderAutomation.matches("169.254.89.80", makeReceiver()), "thunderbolt IP")
    }

    func testMatchesByID() {
        XCTAssertTrue(TBSenderAutomation.matches("targetbridge jonathans-imac|192.168.1.64", makeReceiver()))
    }

    func testDoesNotMatchUnrelatedValue() {
        XCTAssertFalse(TBSenderAutomation.matches("other-mac", makeReceiver()))
        XCTAssertFalse(TBSenderAutomation.matches("10.0.0.1", makeReceiver()))
    }

    // MARK: - resolveSessionIndex tri-state
    //
    // Returns `nil` = invalid input, `.some(nil)` = target all sessions,
    // `.some(index)` = zero-based session index.

    func testNoSessionParamTargetsAllSessionsWhenNotCreating() {
        let result: Int?? = TBSenderAutomation.resolveSessionIndex(nil, sessionCount: 3, createDefaultIfNeeded: false)
        XCTAssertEqual(result, Int??.some(.none), "absent session + no-create should mean 'all sessions'")
    }

    func testNoSessionParamDefaultsToFirstSessionWhenCreating() {
        XCTAssertEqual(
            TBSenderAutomation.resolveSessionIndex(nil, sessionCount: 0, createDefaultIfNeeded: true),
            Int??.some(0)
        )
        XCTAssertEqual(
            TBSenderAutomation.resolveSessionIndex(nil, sessionCount: 3, createDefaultIfNeeded: true),
            Int??.some(0)
        )
    }

    func testEmptySessionParamBehavesLikeAbsent() {
        XCTAssertEqual(
            TBSenderAutomation.resolveSessionIndex("", sessionCount: 2, createDefaultIfNeeded: false),
            Int??.some(.none)
        )
    }

    func testOneBasedIndexIsConvertedToZeroBased() {
        XCTAssertEqual(
            TBSenderAutomation.resolveSessionIndex("2", sessionCount: 3, createDefaultIfNeeded: false),
            Int??.some(1)
        )
    }

    func testOutOfRangeSessionIsInvalid() {
        XCTAssertNil(TBSenderAutomation.resolveSessionIndex("4", sessionCount: 3, createDefaultIfNeeded: false))
    }

    func testSessionOneOnEmptyListCreatesDefaultOnlyWhenAllowed() {
        XCTAssertEqual(
            TBSenderAutomation.resolveSessionIndex("1", sessionCount: 0, createDefaultIfNeeded: true),
            Int??.some(0)
        )
        XCTAssertNil(TBSenderAutomation.resolveSessionIndex("1", sessionCount: 0, createDefaultIfNeeded: false))
    }

    func testNonNumericAndNonPositiveSessionsAreInvalid() {
        XCTAssertNil(TBSenderAutomation.resolveSessionIndex("abc", sessionCount: 3, createDefaultIfNeeded: true))
        XCTAssertNil(TBSenderAutomation.resolveSessionIndex("0", sessionCount: 3, createDefaultIfNeeded: true))
        XCTAssertNil(TBSenderAutomation.resolveSessionIndex("-1", sessionCount: 3, createDefaultIfNeeded: true))
    }
}
