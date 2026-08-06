import CoreMedia
import XCTest
@testable import TargetBridge

/// Tests for the pure parsing helpers behind the `targetbridge://` URL scheme
/// and `--connect` launch arguments (docs/Automation.md). These decide which
/// transport/mode/preset/session a scripted connect uses, so regressions here
/// silently reroute automation traffic.
@MainActor
final class TBSenderAutomationParsingTests: XCTestCase {
    func testHighFrameRatePresetsUseFiveCaptureSurfaces() {
        XCTAssertEqual(TBDisplayCapturePreset.standard1440p.queueDepth, 3)
        XCTAssertEqual(TBDisplayCapturePreset.smooth1440p60.queueDepth, 5)
        XCTAssertEqual(TBDisplayCapturePreset.retina4k60.queueDepth, 5)
        XCTAssertEqual(TBDisplayCapturePreset.native5k60Experimental.queueDepth, 5)
    }

    func testHighFrameRatePresetsRequestCaptureHeadroom() {
        XCTAssertEqual(TBDisplayCapturePreset.standard1440p.captureRequestFrameRate, 30)
        XCTAssertEqual(TBDisplayCapturePreset.smooth1440p60.captureRequestFrameRate, 120)
        XCTAssertEqual(TBDisplayCapturePreset.retina4k60.captureRequestFrameRate, 120)
        XCTAssertEqual(TBDisplayCapturePreset.native5k.captureRequestFrameRate, 96)
    }

    func testFrameRatePacerSamples75HzInputAt60Hz() {
        var pacer = TBFrameRatePacer(maximumFrameRate: 60)
        let emitted = (0..<750).filter { frame in
            pacer.shouldEmit(presentationTime: CMTime(seconds: Double(frame) / 75.0, preferredTimescale: 60_000))
        }
        XCTAssertEqual(emitted.count, 600)
    }

    func testFrameRatePacerPreservesInputsAtOrBelowCeiling() {
        for inputRate in [30, 60] {
            var pacer = TBFrameRatePacer(maximumFrameRate: 60)
            let emitted = (0..<(inputRate * 10)).filter { frame in
                pacer.shouldEmit(presentationTime: CMTime(seconds: Double(frame) / Double(inputRate), preferredTimescale: 60_000))
            }
            XCTAssertEqual(emitted.count, inputRate * 10)
        }
    }

    func testFrameRatePacerDoesNotAccumulateBurstCreditAfterIdleGap() {
        var pacer = TBFrameRatePacer(maximumFrameRate: 60)
        XCTAssertTrue(pacer.shouldEmit(presentationTime: CMTime(seconds: 0, preferredTimescale: 60_000)))
        XCTAssertTrue(pacer.shouldEmit(presentationTime: CMTime(seconds: 1, preferredTimescale: 60_000)))
        XCTAssertFalse(pacer.shouldEmit(presentationTime: CMTime(seconds: 1 + 1.0 / 75.0, preferredTimescale: 60_000)))
    }

    func testReceiverMasterUsesLowLatencyCursorOverlay() {
        XCTAssertFalse(TBInputControlRole.off.prefersLowLatencyCursorOverlay)
        XCTAssertFalse(TBInputControlRole.senderMaster.prefersLowLatencyCursorOverlay)
        XCTAssertTrue(TBInputControlRole.receiverMaster.prefersLowLatencyCursorOverlay)
    }


    func testSenderEnabledFlagUsesSelectedHomeDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("targetbridge-automation-path-test", isDirectory: true)
        XCTAssertEqual(
            TBSenderAutomation.senderEnabledFlagURL(homeDirectory: root).path,
            root.appendingPathComponent(
                "Library/Application Support/TargetBridge/Sender/enabled",
                isDirectory: false
            ).path
        )
    }

    func testUserStopRemovesAutomaticReconnectMarker() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("targetbridge-user-stop-\(UUID().uuidString)", isDirectory: true)
        let marker = root.appendingPathComponent("enabled")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: marker.path, contents: Data()))

        TBSenderAutomation.suspendAutomaticReconnectAfterUserStop(enabledFlagURL: marker)

        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        try? FileManager.default.removeItem(at: root)
    }

    func testRequiredPermissionRemovesAutomaticReconnectMarker() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("targetbridge-permission-stop-\(UUID().uuidString)", isDirectory: true)
        let marker = root.appendingPathComponent("enabled")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: marker.path, contents: Data()))

        TBSenderAutomation.suspendAutomaticReconnectForRequiredPermission(enabledFlagURL: marker)

        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        try? FileManager.default.removeItem(at: root)
    }

    func testCaptureFailureRemovesAutomaticReconnectMarker() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("targetbridge-capture-stop-\(UUID().uuidString)", isDirectory: true)
        let marker = root.appendingPathComponent("enabled")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: marker.path, contents: Data()))

        TBSenderAutomation.suspendAutomaticReconnectAfterCaptureFailure(enabledFlagURL: marker)

        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - flagEnabled

    func testAutomationFlagsEnableOnPresenceOrTruthyValues() {
        for value in ["", "1", "true", "yes", "on", "unexpected"] {
            XCTAssertTrue(TBSenderAutomation.flagEnabled(value), "value \(value)")
        }
    }

    func testAutomationFlagsDisableOnMissingOrExplicitFalseValues() {
        XCTAssertFalse(TBSenderAutomation.flagEnabled(nil))
        for value in ["0", "false", "FALSE", "no", "off", " Off "] {
            XCTAssertFalse(TBSenderAutomation.flagEnabled(value), "value \(value)")
        }
    }

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

    // MARK: - parse connection path

    func testParseConnectionPathSupportsNoviceFriendlyAliases() {
        for value in ["auto", "automatic", "automatico", "best"] {
            XCTAssertEqual(TBConnectionPathPreference.parse(value), .automatic, "value \(value)")
        }
        for value in ["wired", "cable", "cable only", "solo cavo"] {
            XCTAssertEqual(TBConnectionPathPreference.parse(value), .wired, "value \(value)")
        }
        XCTAssertEqual(TBConnectionPathPreference.parse("Thunderbolt Bridge"), .thunderbolt)
        XCTAssertEqual(TBConnectionPathPreference.parse("USB4"), .usb)
        XCTAssertEqual(TBConnectionPathPreference.parse("LAN"), .ethernet)
        XCTAssertEqual(TBConnectionPathPreference.parse("Wi-Fi"), .wifi)
    }

    func testParseConnectionPathRejectsUnknownValues() {
        XCTAssertNil(TBConnectionPathPreference.parse(nil))
        XCTAssertNil(TBConnectionPathPreference.parse("satellite"))
    }

    func testPersistentPathOverrideReplacesLaunchAgentDefault() {
        let params = ["path": "auto", "preset": "retina4k60"]
        let updated = TBSenderAutomation.applyingPersistentPathOverride(
            params,
            rawValue: "Thunderbolt Bridge\n"
        )
        XCTAssertEqual(updated["path"], TBConnectionPathPreference.thunderbolt.rawValue)
        XCTAssertEqual(updated["preset"], "retina4k60")
    }

    func testPersistentAutomaticPathOverrideIsCanonical() {
        let updated = TBSenderAutomation.applyingPersistentPathOverride(
            ["path": "wifi"],
            rawValue: "automatico"
        )
        XCTAssertEqual(updated["path"], TBConnectionPathPreference.automatic.rawValue)
    }

    func testInvalidPersistentPathDoesNotOverrideLaunchArguments() {
        let params = ["path": "ethernet"]
        XCTAssertEqual(
            TBSenderAutomation.applyingPersistentPathOverride(params, rawValue: "satellite"),
            params
        )
        XCTAssertEqual(
            TBSenderAutomation.applyingPersistentPathOverride(params, rawValue: nil),
            params
        )
    }

    func testPersistentInputOverrideEnablesIMacControls() {
        let updated = TBSenderAutomation.applyingPersistentInputOverride(
            ["input": "off", "preset": "retina4k60"],
            rawValue: "receiver\n"
        )
        XCTAssertEqual(updated["input"], TBInputControlRole.receiverMaster.rawValue)
        XCTAssertEqual(updated["preset"], "retina4k60")
    }

    func testPersistentInputOverrideCanDisableControls() {
        let updated = TBSenderAutomation.applyingPersistentInputOverride(
            ["input": "receiver"],
            rawValue: "off"
        )
        XCTAssertEqual(updated["input"], TBInputControlRole.off.rawValue)
    }

    func testInvalidPersistentInputDoesNotOverrideLaunchArguments() {
        let params = ["input": "receiver"]
        XCTAssertEqual(
            TBSenderAutomation.applyingPersistentInputOverride(params, rawValue: "unknown"),
            params
        )
    }

    func testAutomaticPathReevaluatesWhenThunderboltAppearsAboveEthernet() {
        XCTAssertTrue(TBSenderAutomation.shouldReevaluateAutomaticPath(
            preference: .automatic,
            current: .ethernet,
            available: [.ethernet, .thunderbolt]
        ))
    }

    func testAutomaticPathKeepsHighestAvailableTransport() {
        XCTAssertFalse(TBSenderAutomation.shouldReevaluateAutomaticPath(
            preference: .automatic,
            current: .thunderbolt,
            available: [.wifi, .ethernet, .thunderbolt]
        ))
    }

    func testWiredPathIgnoresWiFiButReevaluatesForUSB() {
        XCTAssertFalse(TBSenderAutomation.shouldReevaluateAutomaticPath(
            preference: .wired,
            current: .ethernet,
            available: [.ethernet, .wifi]
        ))
        XCTAssertTrue(TBSenderAutomation.shouldReevaluateAutomaticPath(
            preference: .wired,
            current: .ethernet,
            available: [.ethernet, .usb, .wifi]
        ))
    }

    func testManualPathIsNeverReevaluated() {
        XCTAssertFalse(TBSenderAutomation.shouldReevaluateAutomaticPath(
            preference: .ethernet,
            current: .ethernet,
            available: [.ethernet, .thunderbolt]
        ))
        XCTAssertFalse(TBSenderAutomation.shouldReevaluateAutomaticPath(
            preference: .automatic,
            current: nil,
            available: [.thunderbolt]
        ))
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
        XCTAssertEqual(TBSenderAutomation.parsePreset("retina4k60"), .retina4k60)
        XCTAssertEqual(TBSenderAutomation.parsePreset("native5k"), .native5k)
        XCTAssertEqual(TBSenderAutomation.parsePreset("native5k60Experimental"), .native5k60Experimental)
    }

    func testParsePresetAliases() {
        XCTAssertEqual(TBSenderAutomation.parsePreset("1440p"), .standard1440p)
        XCTAssertEqual(TBSenderAutomation.parsePreset("standard"), .standard1440p)
        XCTAssertEqual(TBSenderAutomation.parsePreset("1440p60"), .smooth1440p60)
        XCTAssertEqual(TBSenderAutomation.parsePreset("smooth"), .smooth1440p60)
        XCTAssertEqual(TBSenderAutomation.parsePreset("1800p"), .smooth1800p60)
        XCTAssertEqual(TBSenderAutomation.parsePreset("4k"), .retina4k60)
        XCTAssertEqual(TBSenderAutomation.parsePreset("crisp"), .crisp2160p60)
        XCTAssertEqual(TBSenderAutomation.parsePreset("retina4k"), .retina4k60)
        XCTAssertEqual(TBSenderAutomation.parsePreset("RETINA4K60"), .retina4k60)
        XCTAssertEqual(TBSenderAutomation.parsePreset("4096x2304"), .retina4k60)
        XCTAssertEqual(TBSenderAutomation.parsePreset("imac4k"), .retina4k60)
        XCTAssertEqual(TBSenderAutomation.parsePreset("5k"), .native5k)
        XCTAssertEqual(TBSenderAutomation.parsePreset("5k60"), .native5k60Experimental)
        XCTAssertEqual(TBSenderAutomation.parsePreset("native5k60"), .native5k60Experimental)
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

    func testRetina4KPresetMatches2017IMacPanel() {
        let preset = TBDisplayCapturePreset.retina4k60
        XCTAssertEqual(preset.width, 4096)
        XCTAssertEqual(preset.height, 2304)
        XCTAssertEqual(preset.expectedFrameRate, 60)
        XCTAssertEqual(preset.averageBitRate, 120_000_000)
        XCTAssertEqual(preset.codecName, "HEVC")
        XCTAssertEqual(preset.queueDepth, 5)
        XCTAssertEqual(preset.renderMatchedDesktopDescription, "2048 × 1152")
    }

    // MARK: - parseInputControlRole

    func testParseInputControlRoleSelectsReceiverMasterForIMacAliases() {
        for alias in ["receiver", "receiverMaster", "receiver-master", "imac", "monitor", " RECEIVER "] {
            XCTAssertEqual(TBSenderAutomation.parseInputControlRole(alias), .receiverMaster, "alias \(alias)")
        }
    }

    func testParseInputControlRoleSelectsSenderMasterForMacMiniAliases() {
        for alias in ["sender", "senderMaster", "sender_master", "macmini", "mini", " SENDER "] {
            XCTAssertEqual(TBSenderAutomation.parseInputControlRole(alias), .senderMaster, "alias \(alias)")
        }
    }

    func testParseInputControlRoleSupportsOffAndRejectsUnknownValues() {
        for alias in ["off", "none", "disabled", "disable", "0"] {
            XCTAssertEqual(TBSenderAutomation.parseInputControlRole(alias), .off, "alias \(alias)")
        }
        XCTAssertNil(TBSenderAutomation.parseInputControlRole(""))
        XCTAssertNil(TBSenderAutomation.parseInputControlRole("bogus"))
    }

    // MARK: - matches (receiver selection for --receiver <value>)

    private func makeReceiver() -> TBDiscoveredReceiver {
        TBDiscoveredReceiver(
            serviceName: "TargetBridge Jonathans-iMac",
            receiverName: "Jonathans-iMac",
            preferredIP: "192.168.1.64",
            thunderboltIP: "169.254.89.80",
            usbIP: "169.254.189.3",
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
