import CoreMedia
import XCTest
@testable import TargetBridge

/// Tests for the pure parsing helpers behind the `targetbridge://` URL scheme
/// and `--connect` launch arguments (docs/Automation.md). These decide which
/// transport/mode/preset/session a scripted connect uses, so regressions here
/// silently reroute automation traffic.
@MainActor
final class TBSenderAutomationParsingTests: XCTestCase {
    func testReceiverControlKeepsNativeCursorWithoutLargeCursor() {
        XCTAssertFalse(
            TBInputControlRole.receiverMaster.usesLowLatencyCursorOverlay(
                largeCursorEnabled: false
            )
        )
        XCTAssertFalse(
            TBInputControlRole.senderMaster.usesLowLatencyCursorOverlay(
                largeCursorEnabled: false
            )
        )
        XCTAssertFalse(
            TBInputControlRole.off.usesLowLatencyCursorOverlay(
                largeCursorEnabled: false
            )
        )
        XCTAssertTrue(
            TBInputControlRole.off.usesLowLatencyCursorOverlay(
                largeCursorEnabled: true
            )
        )

        XCTAssertFalse(
            TBInputControlRole.receiverMaster.changesCursorCaptureMode(
                from: .off,
                largeCursorEnabled: false
            )
        )
        XCTAssertFalse(
            TBInputControlRole.off.changesCursorCaptureMode(
                from: .receiverMaster,
                largeCursorEnabled: false
            )
        )
        XCTAssertFalse(
            TBInputControlRole.senderMaster.changesCursorCaptureMode(
                from: .off,
                largeCursorEnabled: false
            )
        )
        XCTAssertFalse(
            TBInputControlRole.receiverMaster.changesCursorCaptureMode(
                from: .off,
                largeCursorEnabled: true
            )
        )
    }

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

    func testSenderEnabledFlagUsesSelectedHomeDirectory() {
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
        XCTAssertEqual(TBSenderAutomation.parsePreset("4k"), .crisp2160p60)
        XCTAssertEqual(TBSenderAutomation.parsePreset("crisp"), .crisp2160p60)
        XCTAssertEqual(TBSenderAutomation.parsePreset("retina4k"), .retina4k60)
        XCTAssertEqual(TBSenderAutomation.parsePreset("RETINA4K60"), .retina4k60)
        XCTAssertEqual(TBSenderAutomation.parsePreset("4096x2304"), .retina4k60)
        XCTAssertEqual(TBSenderAutomation.parsePreset("imac4k"), .retina4k60)
        XCTAssertEqual(TBSenderAutomation.parsePreset("5k60"), .native5k60Experimental)
        XCTAssertEqual(TBSenderAutomation.parsePreset("native5k60"), .native5k60Experimental)
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

    func testExperimental5K60UsesIndependent60FPSHEVCSettings() {
        let preset = TBDisplayCapturePreset.native5k60Experimental

        XCTAssertEqual(preset.width, 5120)
        XCTAssertEqual(preset.height, 2880)
        XCTAssertEqual(preset.expectedFrameRate, 60)
        XCTAssertEqual(preset.virtualDisplayRefreshRate, 60)
        XCTAssertEqual(preset.codecName, "HEVC")
        XCTAssertEqual(preset.averageBitRate, 150_000_000)
    }

    func testRetina4KPresetMatches215InchIMacPanel() {
        let preset = TBDisplayCapturePreset.retina4k60

        XCTAssertEqual(preset.width, 4096)
        XCTAssertEqual(preset.height, 2304)
        XCTAssertEqual(preset.expectedFrameRate, 60)
        XCTAssertEqual(preset.virtualDisplayRefreshRate, 60)
        XCTAssertEqual(preset.averageBitRate, 120_000_000)
        XCTAssertEqual(preset.codecName, "HEVC")
        XCTAssertEqual(preset.renderMatchedDesktopDescription, "2048 × 1152")
    }

    // MARK: - matches (receiver selection for --receiver <value>)

    private func makeReceiver() -> TBDiscoveredReceiver {
        TBDiscoveredReceiver(
            serviceName: "TargetBridge Jonathans-iMac",
            receiverName: "Jonathans-iMac",
            receiverID: "A4E28721-22A7-42A9-89D7-70F3DBB0E906",
            preferredIP: "192.168.1.64",
            thunderboltIP: "169.254.89.80",
            usbIP: "169.254.189.3",
            networkIP: "192.168.1.64",
            ethernetIP: "10.77.77.2",
            wifiIP: "192.168.1.64",
            resolvedIPv4Addresses: ["172.20.10.2"],
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
        XCTAssertTrue(TBSenderAutomation.matches("169.254.189.3", makeReceiver()), "direct USB IP")
        XCTAssertTrue(TBSenderAutomation.matches("10.77.77.2", makeReceiver()), "Ethernet IP")
        XCTAssertTrue(TBSenderAutomation.matches("172.20.10.2", makeReceiver()), "resolved Bonjour IP")
    }

    func testMatchesByID() {
        XCTAssertTrue(TBSenderAutomation.matches("receiver:A4E28721-22A7-42A9-89D7-70F3DBB0E906", makeReceiver()))
        XCTAssertTrue(TBSenderAutomation.matches("A4E28721-22A7-42A9-89D7-70F3DBB0E906", makeReceiver()))
        XCTAssertTrue(TBSenderAutomation.matches("targetbridge jonathans-imac|192.168.1.64", makeReceiver()))
    }

    func testDoesNotMatchUnrelatedValue() {
        XCTAssertFalse(TBSenderAutomation.matches("other-mac", makeReceiver()))
        XCTAssertFalse(TBSenderAutomation.matches("10.0.0.1", makeReceiver()))
    }

    func testAutomaticReceiverUsesPreferredStableIdentityAmongSeveral() {
        let preferred = makeReceiver()
        let other = TBDiscoveredReceiver(
            serviceName: "TargetBridge Other-iMac",
            receiverName: "Other-iMac",
            receiverID: "other-receiver",
            preferredIP: "192.168.1.70",
            thunderboltIP: "",
            networkIP: "192.168.1.70",
            panelSummary: "iMac 4K",
            version: "3.5.2",
            supportsHEVCDecode: true,
            hostName: "Other-iMac.local."
        )

        XCTAssertEqual(
            TBSenderAutomation.automaticReceiver(
                in: [other, preferred],
                preferredIdentity: preferred.stableIdentity
            ),
            preferred
        )
    }

    func testAutomaticReceiverUsesOnlyReceiverWithoutPreference() {
        let receiver = makeReceiver()
        XCTAssertEqual(
            TBSenderAutomation.automaticReceiver(in: [receiver], preferredIdentity: ""),
            receiver
        )
    }

    func testAutomaticReceiverRefusesAmbiguousFirstChoice() {
        let first = makeReceiver()
        let second = TBDiscoveredReceiver(
            serviceName: "TargetBridge Other-iMac",
            receiverName: "Other-iMac",
            receiverID: "other-receiver",
            preferredIP: "192.168.1.70",
            thunderboltIP: "",
            networkIP: "192.168.1.70",
            panelSummary: "iMac 4K",
            version: "3.5.2",
            supportsHEVCDecode: true,
            hostName: "Other-iMac.local."
        )

        XCTAssertNil(
            TBSenderAutomation.automaticReceiver(in: [first, second], preferredIdentity: "")
        )
    }

    // MARK: - resolveSessionIndex tri-state

    func testAutomaticReceiverDoesNotReplaceMissingPreferredMonitor() {
        XCTAssertNil(TBSenderAutomation.automaticReceiver(
            in: [makeReceiver()], preferredIdentity: "receiver:B4E28721-22A7-42A9-89D7-70F3DBB0E906"))
    }

    func testAutomaticReceiverRejectsAmbiguousLegacyPreference() {
        let first = makeReceiver()
        XCTAssertNil(TBSenderAutomation.automaticReceiver(
            in: [first, first], preferredIdentity: "service:\(first.serviceName)"))
    }

    func testMissingIdentityDoesNotBecomeRawHostname() {
        for value in ["receiver:unknown", "service:TargetBridge iMac", "iMac|169.254.1.2",
                      "A4E28721-22A7-42A9-89D7-70F3DBB0E906"] {
            XCTAssertTrue(TBSenderAutomation.isPersistedReceiverReference(value))
        }
        for value in ["iMac.local", "192.168.1.64", "fe80::1234"] {
            XCTAssertFalse(TBSenderAutomation.isPersistedReceiverReference(value))
        }
    }
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
