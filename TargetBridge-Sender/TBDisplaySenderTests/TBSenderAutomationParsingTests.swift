import CoreMedia
import XCTest
@testable import TargetBridge

/// Tests for the pure parsing helpers behind the `targetbridge://` URL scheme
/// and `--connect` launch arguments (docs/Automation.md). These decide which
/// transport/mode/preset/session a scripted connect uses, so regressions here
/// silently reroute automation traffic.
@MainActor
final class TBSenderAutomationParsingTests: XCTestCase {
    func testHeadlessMirrorUsesOnlyOnlineVirtualDisplayDirectly() {
        XCTAssertTrue(
            TBDisplaySenderSession.shouldUseHeadlessVirtualDisplay(
                virtualDisplayID: 120,
                mainDisplayID: 120,
                onlineDisplayIDs: [120]
            )
        )
    }

    func testHeadlessMirrorDoesNotBypassMirroringWithPhysicalDisplayOnline() {
        XCTAssertFalse(
            TBDisplaySenderSession.shouldUseHeadlessVirtualDisplay(
                virtualDisplayID: 120,
                mainDisplayID: 120,
                onlineDisplayIDs: [120, 1]
            )
        )
        XCTAssertFalse(
            TBDisplaySenderSession.shouldUseHeadlessVirtualDisplay(
                virtualDisplayID: 120,
                mainDisplayID: 1,
                onlineDisplayIDs: [1, 120]
            )
        )
    }

    func testHeadlessMirrorRequiresVirtualDisplayToBeOnline() {
        XCTAssertFalse(
            TBDisplaySenderSession.shouldUseHeadlessVirtualDisplay(
                virtualDisplayID: 120,
                mainDisplayID: 120,
                onlineDisplayIDs: []
            )
        )
    }

    func testDirectHeadlessVideoStartsAuxiliaryAudioOnlyWhenEnabled() {
        XCTAssertTrue(
            TBDisplaySenderSession.needsAuxiliaryAudioCapture(
                usingDirectDisplayStream: true,
                shouldRelayAudio: true
            )
        )
        XCTAssertFalse(
            TBDisplaySenderSession.needsAuxiliaryAudioCapture(
                usingDirectDisplayStream: true,
                shouldRelayAudio: false
            )
        )
        XCTAssertFalse(
            TBDisplaySenderSession.needsAuxiliaryAudioCapture(
                usingDirectDisplayStream: false,
                shouldRelayAudio: true
            )
        )
    }

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

    func testNativeScaleAppliesOnlyToPanelMatchedProfiles() {
        XCTAssertTrue(TBDisplayCapturePreset.standard1080p.rendersAtNativeScale)
        XCTAssertTrue(TBDisplayCapturePreset.smooth1080p60.rendersAtNativeScale)
        for preset in TBDisplayCapturePreset.allCases where preset.width > 1920 {
            XCTAssertFalse(
                preset.rendersAtNativeScale,
                "\(preset.rawValue) targets a Retina panel and must keep its HiDPI mode"
            )
        }
    }

    /// A 1x mode must hand CGVirtualDisplay the full stream size with a framebuffer
    /// to match, not the halved HiDPI point size. Getting this backwards renders the
    /// desktop at 960x540 and draws every control at 2x on a 1080p panel.
    func testNativeScaleModeRendersFullSizeWithoutHiDPIBacking() {
        let mode = TBDisplayCapturePreset.standard1080p.nativeScaleDisplayMode
        XCTAssertEqual(mode.width, 1920)
        XCTAssertEqual(mode.height, 1080)
        XCTAssertFalse(mode.isHiDPI)
        XCTAssertEqual(mode.backingWidth, 1920)
        XCTAssertEqual(mode.backingHeight, 1080)
    }

    /// Render matching keeps its 2x contract for every non-native-scale profile.
    func testRenderMatchedModeKeepsHiDPIBacking() {
        let mode = TBDisplayCapturePreset.standard1440p.renderMatchedDisplayMode
        XCTAssertEqual(mode.width, 1280)
        XCTAssertEqual(mode.height, 720)
        XCTAssertTrue(mode.isHiDPI)
        XCTAssertEqual(mode.backingWidth, 2560)
        XCTAssertEqual(mode.backingHeight, 1440)
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

    func testAutomaticCodecUsesH264WhenHEVCIsUnavailable() {
        let decision = TBDisplaySenderSession.chooseCodec(
            preference: .automatic,
            preset: .standard1440p,
            receiverSupportsHEVC: false,
            senderSupportsH264: true,
            senderSupportsHEVC: true
        )
        XCTAssertEqual(decision?.codecType, kCMVideoCodecType_H264)
        XCTAssertEqual(decision?.usedFallback, false)
    }

    func testAutomaticCodecUsesHEVCWhenBothMacsSupportIt() {
        for preset in [TBDisplayCapturePreset.standard1440p, .retina4k60] {
            let decision = TBDisplaySenderSession.chooseCodec(
                preference: .automatic,
                preset: preset,
                receiverSupportsHEVC: true,
                senderSupportsH264: true,
                senderSupportsHEVC: true
            )
            XCTAssertEqual(decision?.codecType, kCMVideoCodecType_HEVC)
            XCTAssertEqual(decision?.usedFallback, false)
        }
    }

    func testAutomaticHighResolutionFallsBackToH264WithoutHEVC() {
        let decision = TBDisplaySenderSession.chooseCodec(
            preference: .automatic,
            preset: .retina4k60,
            receiverSupportsHEVC: false,
            senderSupportsH264: true,
            senderSupportsHEVC: true
        )
        XCTAssertEqual(decision?.codecType, kCMVideoCodecType_H264)
        XCTAssertEqual(decision?.usedFallback, true)
    }

    func testManualCodecChoicesAreHonouredWhenAvailable() {
        let h264 = TBDisplaySenderSession.chooseCodec(
            preference: .h264,
            preset: .retina4k60,
            receiverSupportsHEVC: true,
            senderSupportsH264: true,
            senderSupportsHEVC: true
        )
        XCTAssertEqual(h264?.codecType, kCMVideoCodecType_H264)
        XCTAssertEqual(h264?.usedFallback, false)

        let hevc = TBDisplaySenderSession.chooseCodec(
            preference: .hevc,
            preset: .standard1440p,
            receiverSupportsHEVC: true,
            senderSupportsH264: true,
            senderSupportsHEVC: true
        )
        XCTAssertEqual(hevc?.codecType, kCMVideoCodecType_HEVC)
        XCTAssertEqual(hevc?.usedFallback, false)
    }

    func testManualCodecFallsBackOnlyToACompatibleAlternative() {
        let hevcToH264 = TBDisplaySenderSession.chooseCodec(
            preference: .hevc,
            preset: .standard1440p,
            receiverSupportsHEVC: false,
            senderSupportsH264: true,
            senderSupportsHEVC: true
        )
        XCTAssertEqual(hevcToH264?.codecType, kCMVideoCodecType_H264)
        XCTAssertEqual(hevcToH264?.usedFallback, true)

        let h264ToHEVC = TBDisplaySenderSession.chooseCodec(
            preference: .h264,
            preset: .native5k,
            receiverSupportsHEVC: true,
            senderSupportsH264: false,
            senderSupportsHEVC: true
        )
        XCTAssertEqual(h264ToHEVC?.codecType, kCMVideoCodecType_HEVC)
        XCTAssertEqual(h264ToHEVC?.usedFallback, true)
    }

    func testCodecSelectionUsesSoftwareDecodedHEVCWhenH264CannotEncodeTheSize() {
        // e.g. a Haswell iMac receiver (no HEVC decode block) at 5K: H.264 has no hardware
        // encoder at 5120x2880, so HEVC (software-decoded on the receiver) is the only path.
        let decision = TBDisplaySenderSession.chooseCodec(
            preference: .automatic,
            preset: .native5k,
            receiverSupportsHEVC: false,
            senderSupportsH264: false,
            senderSupportsHEVC: true,
            receiverSupportsHEVCSoftware: true
        )
        XCTAssertEqual(decision?.codecType, kCMVideoCodecType_HEVC)
        XCTAssertEqual(decision?.usedFallback, true)

        // Where H.264 can be hardware-encoded, it is still preferred over software HEVC.
        let at4k = TBDisplaySenderSession.chooseCodec(
            preference: .automatic,
            preset: .retina4k60,
            receiverSupportsHEVC: false,
            senderSupportsH264: true,
            senderSupportsHEVC: true,
            receiverSupportsHEVCSoftware: true
        )
        XCTAssertEqual(at4k?.codecType, kCMVideoCodecType_H264)
    }

    func testCodecSelectionFailsCleanlyWhenNoHardwarePathExists() {
        XCTAssertNil(TBDisplaySenderSession.chooseCodec(
            preference: .automatic,
            preset: .native5k,
            receiverSupportsHEVC: false,
            senderSupportsH264: false,
            senderSupportsHEVC: false
        ))
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

    func test5K60SpacesKeyframesAndCapsPeakRate() {
        let preset = TBDisplayCapturePreset.native5k60Experimental

        XCTAssertEqual(preset.maxKeyFrameIntervalDuration, 4)
        XCTAssertEqual(preset.maxKeyFrameInterval, 240)
        XCTAssertEqual(preset.peakBitRate, 225_000_000)
    }

    func testStableProfilesKeepPreviousEncoderTuning() {
        XCTAssertEqual(TBDisplayCapturePreset.native5k.maxKeyFrameIntervalDuration, 1)
        XCTAssertEqual(TBDisplayCapturePreset.native5k.maxKeyFrameInterval, 48)
        XCTAssertNil(TBDisplayCapturePreset.native5k.peakBitRate)
        XCTAssertNil(TBDisplayCapturePreset.retina4k60.peakBitRate)
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

// These tests exercise the same profiles and geometry used by session creation.
// They do not create a display, start capture, or connect to a Receiver.
extension TBSenderAutomationParsingTests {
    private func retinaProfile(width: Int = 3072, height: Int = 1920) -> TBMonitorDisplayProfile {
        TBMonitorDisplayProfile(
            receiverName: "16:10 test fixture", panelWidth: width, panelHeight: height,
            modeWidth: width / 2, modeHeight: height / 2, refreshRate: 60,
            hiDPI: true, captureWidth: width, captureHeight: height
        )
    }

    func test16x10ProfilesAreSelectable() throws {
        for raw in ["retina16x10", "retina16x10MoreSpace"] {
            let preset = try XCTUnwrap(TBDisplayCapturePreset(rawValue: raw))
            XCTAssertTrue(TBDisplayCapturePreset.allCases.contains(preset))
            XCTAssertEqual(preset.width * 5, preset.height * 8)
            XCTAssertEqual(preset.width % 2, 0)
            XCTAssertEqual(preset.height % 2, 0)
            XCTAssertFalse(preset.rendersAtNativeScale)
        }
    }

    func test16x10NativeRetinaHasExactPanelBacking() {
        let preset = TBDisplayCapturePreset.retina16x10
        let mode = preset.renderMatchedDisplayMode
        XCTAssertEqual(mode, TBVirtualDisplayModeSize(width: 1536, height: 960))
        XCTAssertEqual(mode.backingWidth, 3072)
        XCTAssertEqual(mode.backingHeight, 1920)
        XCTAssertEqual(preset.renderMatchedDesktopDescription, "1536 × 960")
        let geometry = TBVirtualDisplayGeometry(profile: retinaProfile(), modeOverride: mode,
                                               allow16x10Supersampling: preset.permits16x10Supersampling)
        XCTAssertEqual(geometry.mode, mode)
        XCTAssertEqual(geometry.maxPixelsWide, 3072)
        XCTAssertEqual(geometry.maxPixelsHigh, 1920)
    }

    func test16x10MoreSpaceKeeps1792HiDPIAndAdvertisesLargerBacking() {
        let preset = TBDisplayCapturePreset.retina16x10MoreSpace
        let profile = retinaProfile()
        let mode = preset.renderMatchedDisplayMode
        XCTAssertEqual(mode, TBVirtualDisplayModeSize(width: 1792, height: 1120))
        XCTAssertEqual(preset.renderMatchedDesktopDescription, "1792 × 1120")
        let geometry = TBVirtualDisplayGeometry(profile: profile, modeOverride: mode,
                                               allow16x10Supersampling: preset.permits16x10Supersampling)
        XCTAssertEqual(geometry.mode, mode)
        XCTAssertEqual(geometry.maxPixelsWide, 3584)
        XCTAssertEqual(geometry.maxPixelsHigh, 2240)
        // The receiver's physical panel and its physical-size metadata stay intact.
        XCTAssertEqual(profile.panelWidth, 3072)
        XCTAssertEqual(profile.panelHeight, 1920)
    }

    func test16x10SupersamplingRequiresExplicitOptIn() {
        let geometry = TBVirtualDisplayGeometry(profile: retinaProfile(),
            modeOverride: TBDisplayCapturePreset.retina16x10MoreSpace.renderMatchedDisplayMode)
        XCTAssertEqual(geometry.mode, TBVirtualDisplayModeSize(width: 1536, height: 960))
        XCTAssertEqual(geometry.maxPixelsWide, 3072)
        XCTAssertEqual(geometry.maxPixelsHigh, 1920)
    }

    func test16x10WithoutRenderOverrideKeepsReceiverDefault() {
        var profile = retinaProfile()
        profile.modeWidth = 1344
        profile.modeHeight = 840
        let geometry = TBVirtualDisplayGeometry(profile: profile, modeOverride: nil,
                                               allow16x10Supersampling: true)
        XCTAssertEqual(geometry.mode, TBVirtualDisplayModeSize(width: 1344, height: 840))
        XCTAssertEqual(geometry.maxPixelsWide, 3072)
        XCTAssertEqual(geometry.maxPixelsHigh, 1920)
    }

    func test16x10LargerBackingIsNotGrantedToOtherPanelShapes() {
        for (width, height) in [(1920, 1080), (2560, 1440), (1600, 1200), (1920, 3072)] {
            let profile = retinaProfile(width: width, height: height)
            let geometry = TBVirtualDisplayGeometry(profile: profile,
                modeOverride: TBDisplayCapturePreset.retina16x10MoreSpace.renderMatchedDisplayMode,
                allow16x10Supersampling: true)
            XCTAssertEqual(geometry.mode, TBVirtualDisplayModeSize(width: width / 2, height: height / 2))
            XCTAssertEqual(geometry.maxPixelsWide, width)
            XCTAssertEqual(geometry.maxPixelsHigh, height)
        }
    }

    func test16x10SupersamplingIsBoundedAndRequiresMatchingModeAspect() {
        for mode in [TBVirtualDisplayModeSize(width: 1800, height: 1125),
                     TBVirtualDisplayModeSize(width: 1792, height: 1119),
                     TBVirtualDisplayModeSize(width: 3584, height: 2240, isHiDPI: false)] {
            let geometry = TBVirtualDisplayGeometry(profile: retinaProfile(), modeOverride: mode,
                                                   allow16x10Supersampling: true)
            XCTAssertEqual(geometry.mode, TBVirtualDisplayModeSize(width: 1536, height: 960))
            XCTAssertEqual(geometry.maxPixelsWide, 3072)
            XCTAssertEqual(geometry.maxPixelsHigh, 1920)
        }
    }

    func test16x10ProfilesAlsoFitSmallerAndLarger16x10Panels() {
        for preset in [TBDisplayCapturePreset.retina16x10, .retina16x10MoreSpace] {
            for (width, height) in [(2560, 1600), (2880, 1800), (3840, 2400)] {
                let mode = preset.renderMatchedDisplayMode
                let geometry = TBVirtualDisplayGeometry(profile: retinaProfile(width: width, height: height),
                    modeOverride: mode, allow16x10Supersampling: preset.permits16x10Supersampling)
                XCTAssertEqual(geometry.mode, mode)
                XCTAssertEqual(geometry.maxPixelsWide, max(width, mode.backingWidth))
                XCTAssertEqual(geometry.maxPixelsHigh, max(height, mode.backingHeight))
            }
        }
    }

    func test16x9PresetsKeepAllExistingPanelLimits() {
        for preset in TBDisplayCapturePreset.allCases where !preset.permits16x10Supersampling {
            for (width, height) in [(1920, 1080), (3072, 1920), (4096, 2304), (5120, 2880)] {
                let profile = retinaProfile(width: width, height: height)
                let requested = preset.rendersAtNativeScale ? preset.nativeScaleDisplayMode : preset.renderMatchedDisplayMode
                let expected = requested.backingWidth > width || requested.backingHeight > height
                    ? TBVirtualDisplayModeSize(width: width / 2, height: height / 2) : requested
                let geometry = TBVirtualDisplayGeometry(profile: profile, modeOverride: requested,
                    allow16x10Supersampling: preset.permits16x10Supersampling)
                XCTAssertEqual(geometry.mode, expected, preset.rawValue)
                XCTAssertEqual(geometry.maxPixelsWide, width)
                XCTAssertEqual(geometry.maxPixelsHigh, height)
            }
        }
    }

    func test16x9PresetDimensionsRatesAndBitratesRemainUnchanged() throws {
        let expected: [(String, Int, Int, Int, Int)] = [
            ("standard1080p", 1920, 1080, 30, 20_000_000),
            ("smooth1080p60", 1920, 1080, 60, 30_000_000),
            ("standard1440p", 2560, 1440, 30, 36_000_000),
            ("smooth1440p60", 2560, 1440, 60, 52_000_000),
            ("smooth1800p60", 3200, 1800, 60, 78_000_000),
            ("crisp2160p60", 3840, 2160, 60, 105_000_000),
            ("retina4k60", 4096, 2304, 60, 120_000_000),
            ("native5k", 5120, 2880, 48, 120_000_000),
            ("native5k60Experimental", 5120, 2880, 60, 150_000_000)
        ]
        for (raw, width, height, fps, bitrate) in expected {
            let preset = try XCTUnwrap(TBDisplayCapturePreset(rawValue: raw))
            XCTAssertEqual(preset.width, width)
            XCTAssertEqual(preset.height, height)
            XCTAssertEqual(preset.expectedFrameRate, fps)
            XCTAssertEqual(preset.averageBitRate, bitrate)
            XCTAssertFalse(preset.permits16x10Supersampling)
        }
    }

    func test16x10KeepsHEVCAndH264FallbackPolicies() {
        for preset in [TBDisplayCapturePreset.retina16x10, .retina16x10MoreSpace] {
            XCTAssertEqual(preset.expectedFrameRate, 60)
            XCTAssertEqual(preset.virtualDisplayRefreshRate, 60)
            XCTAssertEqual(preset.codecType, kCMVideoCodecType_HEVC)
            XCTAssertEqual(preset.queueDepth, TBDisplayCapturePreset.retina4k60.queueDepth)
            XCTAssertEqual(preset.maxPendingVideoPackets, TBDisplayCapturePreset.retina4k60.maxPendingVideoPackets)
            XCTAssertEqual(preset.maxInFlightEncodeFrames, TBDisplayCapturePreset.retina4k60.maxInFlightEncodeFrames)
            for supportsHEVC in [false, true] {
                let decision = TBDisplaySenderSession.chooseCodec(preference: .automatic, preset: preset,
                    receiverSupportsHEVC: supportsHEVC, senderSupportsH264: true, senderSupportsHEVC: true)
                XCTAssertEqual(decision?.codecType, supportsHEVC ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264)
                XCTAssertEqual(decision?.usedFallback, !supportsHEVC)
            }
        }
    }

    func test16x10AutomationAliasesAndPersistenceNames() {
        for name in ["16x10", "retina16x10", "3072x1920", "RETINA16X10"] {
            XCTAssertEqual(TBSenderAutomation.parsePreset(name), .retina16x10)
        }
        for name in ["16x10-more-space", "retina16x10MoreSpace", "3584x2240", "RETINA16X10MORESPACE"] {
            XCTAssertEqual(TBSenderAutomation.parsePreset(name), .retina16x10MoreSpace)
        }
        XCTAssertNil(TBSenderAutomation.parsePreset("16x10-unknown"))
        XCTAssertEqual(TBSenderAutomation.parsePreset("imac4k"), .retina4k60)
        XCTAssertEqual(TBSenderAutomation.parsePreset("5k"), .native5k)
    }

    func test16x10LabelsExistInEveryLanguage() {
        for language in TBDisplaySenderLanguage.allCases {
            for preset in [TBDisplayCapturePreset.retina16x10, .retina16x10MoreSpace] {
                let title = preset.title(language)
                XCTAssertTrue(title.contains("16:10"))
                XCTAssertFalse(title.contains("[["))
            }
        }
        XCTAssertEqual(TBDisplayCapturePreset.retina16x10MoreSpace.title(.italian), "Retina 16:10 più spazio")
    }
}
