import XCTest
import CoreVideo
import CoreGraphics
import ScreenCaptureKit
import Dispatch
@testable import TargetBridge

final class TBDisplayProfileTests: XCTestCase {
    func testWork5KUsesAnExtendedNative5KDisplay() {
        let settings = TBDisplayProfile.work5K.settings

        XCTAssertEqual(settings.captureSource, .extendedDesktop)
        XCTAssertEqual(settings.capturePreset, .native5k)
        XCTAssertTrue(settings.matchRenderToStream)
        XCTAssertNil(settings.audioEnabled)
    }

    func testLowLatencyPrioritizesSmoothVideoWithoutAudio() {
        let settings = TBDisplayProfile.lowLatency.settings

        XCTAssertEqual(settings.captureSource, .desktopMirror)
        XCTAssertEqual(settings.capturePreset, .smooth1440p60)
        XCTAssertFalse(settings.matchRenderToStream)
        XCTAssertNil(settings.audioEnabled)
    }

    func testPresentationUsesACompatibleMirrorProfileWithAudio() {
        let settings = TBDisplayProfile.presentation.settings

        XCTAssertEqual(settings.captureSource, .desktopMirror)
        XCTAssertEqual(settings.capturePreset, .standard1440p)
        XCTAssertEqual(settings.audioEnabled, true)
    }

    func testAudioPreferenceRepairRestoresOnlyTheAmbiguousDisabledState() {
        XCTAssertTrue(TBDisplaySenderService.restoredAudioEnabled(from: false, repairPending: true))
        XCTAssertFalse(TBDisplaySenderService.restoredAudioEnabled(from: false, repairPending: false))
        XCTAssertTrue(TBDisplaySenderService.restoredAudioEnabled(from: true, repairPending: false))
    }
}

@MainActor
final class TBStreamSelectionMigrationTests: XCTestCase {
    private func makeSession() -> TBDisplaySenderSession {
        TBDisplaySenderSession(language: .english, largeCursor: false,
                               preventDisplaySleep: false, autoRestartOnWake: false,
                               audioEnabled: false)
    }

    func testLegacyDPCMAutomaticSelectionSurvivesChangingOnlyResolution() {
        let session = makeSession()
        session.capturePreset = .native5kRaw60
        XCTAssertEqual(session.capturePreset, .native5k60Experimental)
        XCTAssertEqual(session.codecPreference.rawValue, "automaticDPCM")
        session.capturePreset = .standard1080p
        XCTAssertEqual(TBVideoTransport.resolve(
            preference: session.codecPreference, preset: session.capturePreset,
            supportsDPCM: true, supportsRawNV12: true
        ), .dpcm10Bit)
        XCTAssertEqual(TBVideoTransport.resolve(
            preference: session.codecPreference, preset: session.capturePreset,
            supportsDPCM: false, supportsRawNV12: true
        ), .rawNV12)
        session.codecPreference = .automatic
        session.capturePreset = .native5k60Experimental
        XCTAssertEqual(TBVideoTransport.resolve(
            preference: session.codecPreference, preset: session.capturePreset,
            supportsDPCM: true, supportsRawNV12: true
        ), .encoded)
    }

    func testLegacySelectionsPreserveExplicitCompressionAndCanonicalGeometry() {
        for legacy in [TBDisplayCapturePreset.native4_5kRaw60, .native5kRaw60] {
            for preference in [TBDisplayCodecPreference.h264, .hevc, .dpcm] {
                let session = makeSession()
                session.codecPreference = preference
                session.capturePreset = legacy
                XCTAssertEqual(session.codecPreference, preference)
                XCTAssertEqual(session.capturePreset.width, legacy.width)
                XCTAssertEqual(session.capturePreset.height, legacy.height)
                XCTAssertEqual(session.capturePreset.expectedFrameRate, legacy.expectedFrameRate)
                XCTAssertTrue(TBDisplayCapturePreset.resolutionPresets.contains(session.capturePreset))
            }
        }
    }

    func testSavedSessionsMigrateIndependentlyAndRoundTripWithoutReintroducingLegacyPresets() throws {
        let common: [String: Any] = [
            "transportKind": "thunderboltBridge", "localInterfaceIP": "", "receiverIP": "169.254.1.2",
            "selectedReceiverID": "TargetBridge Migration Test|169.254.1.2", "captureSource": "desktopMirror",
            "audioEnabled": false, "brightness": 0.5, "inputGestureMode": "direct"
        ]
        var raw: [[String: Any]] = []
        for (preset, preference) in [("native4_5kRaw60", nil), ("native5kRaw60", "automatic"),
                                     ("native5kRaw60", "h264")] {
            var value = common
            value["capturePreset"] = preset
            if let preference { value["codecPreference"] = preference }
            raw.append(value)
        }
        var configs = try JSONDecoder().decode([TBDisplaySenderService.PersistedSession].self,
                                               from: JSONSerialization.data(withJSONObject: raw))
        for index in configs.indices { configs[index].normalizeCaptureSelection() }
        XCTAssertEqual(configs.map(\.capturePreset), ["retina4_5k60", "native5k60Experimental", "native5k60Experimental"])
        XCTAssertEqual(configs.map(\.codecPreference), ["automaticDPCM", "automaticDPCM", "h264"])
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let saved = try encoder.encode(configs)
        var restored = try JSONDecoder().decode([TBDisplaySenderService.PersistedSession].self, from: saved)
        for index in restored.indices { restored[index].normalizeCaptureSelection() }
        XCTAssertEqual(try encoder.encode(restored), saved, "A second launch must not migrate again")
        // Explicitly choosing ordinary Auto after migration must stick on restart.
        restored[0].codecPreference = "automatic"
        restored[0].normalizeCaptureSelection()
        XCTAssertEqual(restored[0].codecPreference, "automatic")
        XCTAssertEqual(restored[0].capturePreset, "retina4_5k60")
    }

    private func receiver(id: String = "A4E28721-22A7-42A9-89D7-70F3DBB0E906") -> TBDiscoveredReceiver {
        TBDiscoveredReceiver(serviceName: "TargetBridge Migration Test", receiverName: "Migration Test",
                             receiverID: id, preferredIP: "169.254.2.3", thunderboltIP: "169.254.2.3",
                             networkIP: "", panelSummary: "", version: "3.6.0",
                             supportsHEVCDecode: true, hostName: nil)
    }

    func testBonjourAndIdentityMigrationDoNotOverrideEachSessionsSavedCompression() {
        let receiver = receiver()
        for alias in [receiver.stableIdentity, receiver.receiverID, "service:\(receiver.serviceName)",
                      "\(receiver.serviceName)|169.254.1.2"] {
            var receiverDefaults = ["service:\(receiver.serviceName)": "automatic"]
            TBReceiverPreferenceMigration.migrateCodecs(
                &receiverDefaults, identity: receiver.stableIdentity, serviceName: receiver.serviceName,
                matchesIdentity: receiver.matchesPersistedIdentity)
            let defaultCodec = receiverDefaults[receiver.stableIdentity].flatMap(TBDisplayCodecPreference.init(rawValue:))
            for legacy in [TBDisplayCapturePreset.native4_5kRaw60] {
                let session = makeSession()
                session.selectedReceiverID = alias
                session.capturePreset = legacy
                let expected = session.codecPreference
                for _ in 0..<3 {
                    XCTAssertFalse(session.updateDiscoveredReceiver(receiver, defaultCodecPreference: defaultCodec),
                                   "Same-receiver refresh must not request display-profile restoration")
                    XCTAssertEqual(session.capturePreset, legacy.canonical)
                    XCTAssertEqual(session.codecPreference, expected)
                    XCTAssertEqual(session.selectedReceiverID, receiver.stableIdentity)
                    XCTAssertEqual(session.receiverIP, "169.254.2.3")
                }
                // A saved session remains authoritative even if another session
                // has more recently changed the receiver's default to HEVC.
                session.updateDiscoveredReceiver(receiver, defaultCodecPreference: .hevc)
                XCTAssertEqual(session.codecPreference, expected)
            }
        }
        let newSession = makeSession()
        XCTAssertTrue(newSession.updateDiscoveredReceiver(receiver, defaultCodecPreference: .hevc))
        XCTAssertEqual(newSession.codecPreference, .hevc)
        let other = self.receiver(id: "8D3FC604-AC90-4EB0-A090-2412B3CA9979")
        XCTAssertTrue(newSession.updateDiscoveredReceiver(other, defaultCodecPreference: .h264))
        XCTAssertEqual(newSession.codecPreference, .h264)
    }

    func testAddingSessionKeepsBothResolutionAndMigratedCompression() {
        for legacy in [TBDisplayCapturePreset.native5kRaw60] {
            let previous = makeSession()
            previous.capturePreset = legacy
            let added = makeSession()
            added.inheritStreamSelection(from: previous)
            XCTAssertEqual(added.capturePreset, previous.capturePreset)
            XCTAssertEqual(added.codecPreference, previous.codecPreference)
            added.capturePreset = .standard1080p
            XCTAssertEqual(added.codecPreference, previous.codecPreference)
        }
    }

    func testLegacyCLIProfileAliasesShareMigrationAndRespectExplicitCompression() throws {
        for alias in ["4.5k-dpcm", "imacm1-dpcm", "NATIVE4_5KRAW60", "native5kRaw60"] {
            let preset = try XCTUnwrap(TBSenderAutomation.parsePreset(alias), alias)
            let session = makeSession()
            session.capturePreset = preset
            XCTAssertEqual(session.capturePreset, preset.canonical, alias)
            XCTAssertEqual(session.codecPreference, .automaticDPCM, alias)
            session.codecPreference = .hevc
            session.capturePreset = preset
            XCTAssertEqual(session.codecPreference, .hevc, alias)
        }
    }

    func testResolutionMenuHasNoCompressionDuplicatesAndCompatibilityChoiceOnlyAppearsWhenActive() {
        let presets = TBDisplayCapturePreset.resolutionPresets
        XCTAssertFalse(presets.contains(.native4_5kRaw60))
        XCTAssertFalse(presets.contains(.native5kRaw60))
        XCTAssertTrue(presets.contains(.retina4_5k60))
        XCTAssertTrue(presets.contains(.native5k60Experimental))
        XCTAssertEqual(Set(presets.map(\.resolutionTitle)).count, presets.count)
        XCTAssertEqual(TBDisplayCapturePreset.standard1080p.resolutionTitle, "1920 × 1080 · 30 FPS")
        for selection in TBDisplayCodecPreference.allCases {
            let choices = TBDisplayCodecPreference.menuChoices(current: selection)
            XCTAssertTrue(choices.contains(selection))
            XCTAssertEqual(choices.contains(.automaticDPCM), selection == .automaticDPCM)
        }
        for language in TBDisplaySenderLanguage.allCases {
            let title = TBDisplaySenderL10n.codecPreferenceTitle(.automaticDPCM, language: language)
            let hint = TBDisplaySenderL10n.codecPreferenceHint(.automaticDPCM, language: language)
            XCTAssertTrue(title.contains("DPCM"))
            XCTAssertTrue(hint.contains("NV12"))
            XCTAssertFalse(title.contains("sender.codec"))
            XCTAssertFalse(TBDisplaySenderL10n.streamProfileHint(language).contains("sender.stream"))
        }
    }

    func testMigratedDPCMUsesOldFallbackSettingsAndReportsActualRequestedTransport() throws {
        for legacy in [TBDisplayCapturePreset.native4_5kRaw60, .native5kRaw60] {
            let session = makeSession()
            session.capturePreset = legacy
            let settings = session.codecPreference.captureSettings(for: session.capturePreset)
            XCTAssertEqual(settings.averageBitRate, 120_000_000)
            XCTAssertEqual(TBVideoTransport.encoded.captureQueueDepth(for: settings), legacy.queueDepth)
            XCTAssertEqual(TBVideoTransport.rawNV12.captureQueueDepth(for: settings), legacy.queueDepth)
            XCTAssertEqual(TBVideoTransport.dpcm10Bit.captureQueueDepth(for: settings), legacy.queueDepth)
            XCTAssertTrue(session.streamResolutionText.contains("DPCM RGB 10-bit"))
            for (dpcm, nv12, expected): (Bool?, Bool?, TBVideoTransport) in [
                (true, true, .dpcm10Bit), (false, true, .rawNV12), (nil, nil, .encoded)
            ] {
                XCTAssertEqual(TBVideoTransport.resolve(preference: session.codecPreference,
                    preset: session.capturePreset, supportsDPCM: dpcm, supportsRawNV12: nv12), expected)
            }
        }
        let choice = try XCTUnwrap(TBDisplaySenderSession.chooseCodec(
            preference: .automaticDPCM, preset: .native5k60Experimental,
            receiverSupportsHEVC: false, senderSupportsH264: true, senderSupportsHEVC: true))
        XCTAssertEqual(choice.codecType, kCMVideoCodecType_H264)
        let saved = try JSONEncoder().encode(TBDisplayCodecPreference.automaticDPCM)
        XCTAssertEqual(try JSONDecoder().decode(TBDisplayCodecPreference.self, from: saved), .automaticDPCM)
    }
}

@MainActor
final class TBCompressionPreferenceTests: XCTestCase {
    func testDPCMCanBeSelectedForEveryPresetWithoutChangingSizeOrFrameRate() throws {
        for preset in TBDisplayCapturePreset.allCases {
            let transport = try XCTUnwrap(TBVideoTransport.resolve(
                preference: .dpcm, preset: preset, supportsDPCM: true,
                supportsRawNV12: true, rawOverride: true))
            XCTAssertEqual(transport, .dpcm10Bit)
            let configuration = SCStreamConfiguration()
            configuration.width = preset.width
            configuration.height = preset.height
            let interval = CMTime(value: 1, timescale: CMTimeScale(preset.expectedFrameRate))
            configuration.minimumFrameInterval = interval
            transport.configureCapture(configuration)
            XCTAssertEqual(configuration.width, preset.width)
            XCTAssertEqual(configuration.height, preset.height)
            XCTAssertEqual(configuration.minimumFrameInterval, interval)
            XCTAssertEqual(configuration.pixelFormat, kCVPixelFormatType_ARGB2101010LEPacked)
        }
    }

    func testExplicitDPCMRejectsMissingCapabilityWithoutFallingBackToNV12() {
        for preset in TBDisplayCapturePreset.allCases {
            for unsupported: Bool? in [nil, false] {
                XCTAssertNil(TBVideoTransport.resolve(
                    preference: .dpcm, preset: preset, supportsDPCM: unsupported,
                    supportsRawNV12: true, rawOverride: true))
            }
        }
    }

    func testExplicitHardwareCodecOverridesDPCMPresetsAndRawOverride() {
        for preset in TBDisplayCapturePreset.allCases {
            for preference in [TBDisplayCodecPreference.h264, .hevc] {
                for rawOverride in [false, true] {
                    for support: Bool? in [nil, false, true] {
                        XCTAssertEqual(TBVideoTransport.resolve(
                            preference: preference, preset: preset, supportsDPCM: support,
                            supportsRawNV12: support, rawOverride: rawOverride), .encoded)
                    }
                }
            }
        }
    }

    func testAutomaticKeepsLegacyDPCMFallbackOrderForOldReceivers() {
        let peers: [(Bool?, Bool?, TBVideoTransport)] = [
            (true, true, .dpcm10Bit), (true, nil, .dpcm10Bit),
            (false, true, .rawNV12), (nil, true, .rawNV12),
            (false, false, .encoded), (nil, nil, .encoded)
        ]
        for preset in [TBDisplayCapturePreset.native4_5kRaw60, .native5kRaw60] {
            for (supportsDPCM, supportsRawNV12, expected) in peers {
                for rawOverride in [false, true] {
                    XCTAssertEqual(TBVideoTransport.resolve(
                        preference: .automatic, preset: preset, supportsDPCM: supportsDPCM,
                        supportsRawNV12: supportsRawNV12, rawOverride: rawOverride), expected)
                }
            }
        }
    }

    func testAutomaticOrdinaryPresetsUseHardwareCodecUnlessLegacyNV12OverrideIsSupported() {
        for preset in [TBDisplayCapturePreset.standard1080p, .retina4_5k60, .native5k] {
            XCTAssertEqual(TBVideoTransport.resolve(
                preference: .automatic, preset: preset, supportsDPCM: true,
                supportsRawNV12: true), .encoded)
            XCTAssertEqual(TBVideoTransport.resolve(
                preference: .automatic, preset: preset, supportsDPCM: true,
                supportsRawNV12: true, rawOverride: true), .rawNV12)
            for unsupported: Bool? in [nil, false] {
                XCTAssertEqual(TBVideoTransport.resolve(
                    preference: .automatic, preset: preset, supportsDPCM: true,
                    supportsRawNV12: unsupported, rawOverride: true), .encoded)
            }
        }
    }

    func testDPCMDoesNotSelectAHardwareEncoder() {
        for preset in [TBDisplayCapturePreset.standard1080p, .native5kRaw60] {
            for hardwareAvailable in [false, true] {
                XCTAssertNil(TBDisplaySenderSession.chooseCodec(
                    preference: .dpcm, preset: preset, receiverSupportsHEVC: hardwareAvailable,
                    senderSupportsH264: hardwareAvailable, senderSupportsHEVC: hardwareAvailable))
            }
        }
    }

    func testLargeDPCMSelectionRetainsEightCaptureSurfaces() {
        let override = ProcessInfo.processInfo.environment["QD"].flatMap(Int.init)
        for preset in [TBDisplayCapturePreset.retina4_5k60, .native5k, .native5k60Experimental] {
            XCTAssertEqual(TBVideoTransport.dpcm10Bit.captureQueueDepth(for: preset), override ?? 8)
            XCTAssertEqual(TBVideoTransport.encoded.captureQueueDepth(for: preset), preset.queueDepth)
        }
        XCTAssertEqual(TBVideoTransport.dpcm10Bit.captureQueueDepth(for: .standard1080p),
                       TBDisplayCapturePreset.standard1080p.queueDepth)
    }

    func testSavedCodecPreferencesRoundTripWithoutChangingExistingValues() throws {
        let preferences: [(String, TBDisplayCodecPreference)] = [
            ("automatic", .automatic), ("automaticDPCM", .automaticDPCM),
            ("h264", .h264), ("hevc", .hevc), ("dpcm", .dpcm)
        ]
        XCTAssertEqual(TBDisplayCodecPreference.allCases, preferences.map(\.1))
        for (value, preference) in preferences {
            XCTAssertEqual(TBDisplayCodecPreference(rawValue: value), preference)
            let encoded = try JSONEncoder().encode(preference)
            XCTAssertEqual(String(decoding: encoded, as: UTF8.self), "\"\(value)\"")
            XCTAssertEqual(try JSONDecoder().decode(TBDisplayCodecPreference.self, from: encoded), preference)
        }
    }

    @MainActor
    func testIdlePreviewFollowsCompressionAcrossPresetSourceAndLanguageChanges() {
        let session = TBDisplaySenderSession(language: .english, largeCursor: false,
                                            preventDisplaySleep: false, autoRestartOnWake: false,
                                            audioEnabled: false)
        session.codecPreference = .dpcm
        XCTAssertTrue(session.streamResolutionText.contains("DPCM RGB 10-bit"))
        session.capturePreset = .retina4_5k60
        session.captureSource = .extendedDesktop
        session.language = .chinese
        XCTAssertTrue(session.streamResolutionText.contains("DPCM RGB 10-bit"))
        session.capturePreset = .native5kRaw60
        session.codecPreference = .h264
        XCTAssertTrue(session.streamResolutionText.contains("H.264"))
        XCTAssertEqual(TBDisplayCodecPreference.dpcm.requestedTransport(for: .retina4_5k60), .dpcm10Bit)
        XCTAssertEqual(TBDisplayCodecPreference.h264.requestedTransport(for: .native5kRaw60), .encoded)
    }

    func testDPCMMenuHintsAndErrorsAreLocalizedAndFourPointFiveKNamesAreGeneric() {
        for language in TBDisplaySenderLanguage.allCases {
            for key in ["sender.codec.dpcm", "sender.codec.hint.dpcm", "sender.error.dpcm_unavailable"] {
                let value = TBDisplaySenderL10n.text(key, language)
                XCTAssertFalse(value.isEmpty)
                XCTAssertNotEqual(value, key)
            }
            XCTAssertEqual(TBDisplaySenderL10n.codecPreferenceHint(
                .automatic, language: language, preset: .native5kRaw60),
                TBDisplaySenderL10n.text("sender.codec.hint.automatic.dpcm", language))
            XCTAssertFalse(TBDisplayCapturePreset.retina4_5k60.title(language).contains("iMac"))
            XCTAssertFalse(TBDisplayCapturePreset.native4_5kRaw60.title(language).contains("iMac"))
        }
    }
}

final class TBDPCMTransportTests: XCTestCase {
    func testNegotiationDoesNotSendNewPacketsToOldReceivers() {
        XCTAssertEqual(TBVideoTransport.resolve(wantsDPCM: true, supportsDPCM: true,
                                               supportsRawNV12: true, rawOverride: true), .dpcm10Bit)
        for support: Bool? in [nil, false] {
            XCTAssertEqual(TBVideoTransport.resolve(wantsDPCM: true, supportsDPCM: support,
                                                   supportsRawNV12: true, rawOverride: false), .rawNV12)
            XCTAssertEqual(TBVideoTransport.resolve(wantsDPCM: true, supportsDPCM: support,
                                                   supportsRawNV12: support, rawOverride: true), .encoded)
        }
        XCTAssertEqual(TBVideoTransport.resolve(wantsDPCM: false, supportsDPCM: true,
                                               supportsRawNV12: true, rawOverride: false), .encoded)
        XCTAssertEqual(TBVideoTransport.resolve(wantsDPCM: false, supportsDPCM: true,
                                               supportsRawNV12: true, rawOverride: true), .rawNV12)
    }

    func testCodecLabelsDescribeTheNegotiatedTransport() {
        XCTAssertEqual(TBVideoTransport.dpcm10Bit.codecName(encoded: "HEVC"), "DPCM RGB 10-bit")
        XCTAssertEqual(TBVideoTransport.rawNV12.codecName(encoded: "HEVC"), "NV12 RAW 8-bit")
        XCTAssertEqual(TBVideoTransport.encoded.codecName(encoded: "H.264"), "H.264")
    }

    func testNegotiatedTransportConfiguresActualCaptureDepthAndColorSpace() {
        let configuration = SCStreamConfiguration()
        TBVideoTransport.dpcm10Bit.configureCapture(configuration)
        XCTAssertEqual(configuration.pixelFormat, kCVPixelFormatType_ARGB2101010LEPacked)
        XCTAssertEqual(configuration.colorSpaceName, CGColorSpace.displayP3)
        for transport in [TBVideoTransport.rawNV12, .encoded] {
            let legacy = SCStreamConfiguration()
            transport.configureCapture(legacy)
            XCTAssertEqual(legacy.pixelFormat, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        }
    }

    private func buffer(format: OSType, width: Int = 1024, height: Int = 3) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, nil, &buffer), kCVReturnSuccess)
        return try XCTUnwrap(buffer)
    }

    func testCPUFallbackPreservesAllTenBitsFromCapturedBuffer() throws {
        let pixelBuffer = try buffer(format: kCVPixelFormatType_ARGB2101010LEPacked)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(pixelBuffer, []), kCVReturnSuccess)
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixelBuffer))
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        for channel in 0..<3 {
            let row = base.advanced(by: channel * stride).assumingMemoryBound(to: UInt32.self)
            for level in 0..<1024 { row[level] = (3 << 30) | (UInt32(level) << (channel * 10)) }
        }
        let original = Data(bytes: base, count: stride * 3)
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        let encoder = TBDPCMFrameEncoder(useGPU: false)
        let payload = try XCTUnwrap(encoder.encode(pixelBuffer))
        var info = tb_dpcm_info()
        var decoded = Data(count: stride * 3)
        payload.withUnsafeBytes { raw in
            let input = raw.bindMemory(to: UInt8.self).baseAddress
            XCTAssertEqual(tb_dpcm_parse(input, payload.count, &info), 0)
            XCTAssertEqual(info.ten_bit, 1)
            XCTAssertEqual(info.width, 1024)
            XCTAssertEqual(info.height, 3)
            decoded.withUnsafeMutableBytes { output in
                XCTAssertEqual(tb_dpcm_decode(input, payload.count,
                    output.bindMemory(to: UInt8.self).baseAddress, Int32(stride)), 0)
            }
        }
        for channel in 0..<3 {
            let row = channel * stride..<(channel * stride + 4096)
            XCTAssertEqual(decoded.subdata(in: row), original.subdata(in: row))
        }
    }

    func testDPCMRejectsNV12AndEightBitRGBInsteadOfReinterpretingMemory() throws {
        let encoder = TBDPCMFrameEncoder(useGPU: false)
        let invalidBuffers = [
            try buffer(format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, width: 64, height: 64),
            try buffer(format: kCVPixelFormatType_32BGRA),
            try buffer(format: kCVPixelFormatType_ARGB2101010LEPacked, width: 5121)
        ]
        for pixelBuffer in invalidBuffers {
            XCTAssertNil(encoder.encode(pixelBuffer))
            XCTAssertNil(encoder.encodePacket(pixelBuffer))
            XCTAssertNil(encoder.encodeDispatchPacket(pixelBuffer))
        }
    }

    func testCPUOwnedPacketsRetainTenBitPixelsAcrossEncoderReuseAndDestruction() throws {
        try assertOwnedPacketsSurviveReuse(useGPU: false)
        try assertOwnedPacketsSurviveReuse(useGPU: false, adaptiveColor: true)
    }

    func testGPUOwnedPacketsRetainTenBitPixelsAcrossEncoderReuseAndDestruction() throws {
        guard let probe = tb_dpcm_gpu_create() else {
            throw XCTSkip("Metal DPCM encoder unavailable")
        }
        tb_dpcm_gpu_destroy(probe)
        try assertOwnedPacketsSurviveReuse(useGPU: true)
        try assertOwnedPacketsSurviveReuse(useGPU: true, adaptiveColor: true)
    }

    func testAdaptiveDPCMReducesCorrelatedRGBWithoutDroppingAnyTenBitLevel() throws {
        let width = 1024, height = 8
        let pixelBuffer = try buffer(format: kCVPixelFormatType_ARGB2101010LEPacked,
                                     width: width, height: height)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(pixelBuffer, []), kCVReturnSuccess)
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixelBuffer))
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        var pixels = Data()
        for y in 0..<height {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt32.self)
            for x in 0..<width {
                let level = UInt32((x * 137 + y) & 1023)
                row[x] = (3 << 30) | (level << 20) | (level << 10) | level
            }
            pixels.append(base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self), count: width * 4)
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        for useGPU in [false, true] {
            let legacy = try XCTUnwrap(TBDPCMFrameEncoder(useGPU: useGPU).encodePacket(pixelBuffer))
            let adaptive = try XCTUnwrap(TBDPCMFrameEncoder(useGPU: useGPU, adaptiveColor: true).encodePacket(pixelBuffer))
            XCTAssertEqual(legacy[5 + 14] & UInt8(TB_DPCM_FLAG_ADAPTIVE_COLOR), 0)
            XCTAssertNotEqual(adaptive[5 + 14] & UInt8(TB_DPCM_FLAG_ADAPTIVE_COLOR), 0)
            XCTAssertLessThan(adaptive.count * 2, legacy.count)
            try assertPacket(adaptive, decodesTo: pixels, width: width, height: height)
        }
    }

    private func assertOwnedPacketsSurviveReuse(useGPU: Bool, adaptiveColor: Bool = false) throws {
        let width = 1024, height = 3
        let pixelBuffer = try buffer(format: kCVPixelFormatType_ARGB2101010LEPacked,
                                     width: width, height: height)
        var encoder: TBDPCMFrameEncoder? = TBDPCMFrameEncoder(useGPU: useGPU, adaptiveColor: adaptiveColor)
        var retained: [(packet: Data, dispatchPacket: DispatchData, pixels: Data)] = []
        for frame in 0..<8 {
            XCTAssertEqual(CVPixelBufferLockBaseAddress(pixelBuffer, []), kCVReturnSuccess)
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixelBuffer))
            let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
            var pixels = Data(capacity: width * height * 4)
            for y in 0..<height {
                let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt32.self)
                for x in 0..<width {
                    let blue = UInt32((x + frame) & 1023)
                    let green = UInt32((1023 - x + frame + y) & 1023)
                    let red = UInt32((x * 5 + frame + y) & 1023)
                    row[x] = (3 << 30) | (red << 20) | (green << 10) | blue
                }
                pixels.append(base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self), count: width * 4)
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            retained.append((try XCTUnwrap(encoder?.encodePacket(pixelBuffer)),
                             try XCTUnwrap(encoder?.encodeDispatchPacket(pixelBuffer)), pixels))
            for snapshot in retained {
                try assertPacket(snapshot.packet, decodesTo: snapshot.pixels, width: width, height: height)
                XCTAssertEqual(Data(snapshot.dispatchPacket), snapshot.packet)
                try assertPacket(Data(snapshot.dispatchPacket), decodesTo: snapshot.pixels, width: width, height: height)
            }
        }
        encoder = nil
        for snapshot in retained {
            try assertPacket(snapshot.packet, decodesTo: snapshot.pixels, width: width, height: height)
            XCTAssertEqual(Data(snapshot.dispatchPacket), snapshot.packet)
            try assertPacket(Data(snapshot.dispatchPacket), decodesTo: snapshot.pixels, width: width, height: height)
        }
    }

    private func assertPacket(_ packet: Data, decodesTo pixels: Data, width: Int, height: Int) throws {
        XCTAssertEqual(Int(TBMonitorProtocol.readBE32(packet, offset: 0)), packet.count - 4)
        var wire = packet
        let (type, payload) = try XCTUnwrap(try TBMonitorProtocol.drainPacket(from: &wire))
        XCTAssertEqual(type, .rawDPCM)
        XCTAssertTrue(wire.isEmpty)
        XCTAssertEqual(packet, TBMonitorProtocol.makePacket(type: .rawDPCM, payload: payload))
        var info = tb_dpcm_info()
        var decoded = Data(count: width * height * 4)
        payload.withUnsafeBytes { input in
            let base = input.bindMemory(to: UInt8.self).baseAddress
            XCTAssertEqual(tb_dpcm_parse(base, payload.count, &info), 0)
            XCTAssertEqual(info.ten_bit, 1)
            XCTAssertEqual(info.width, Int32(width))
            XCTAssertEqual(info.height, Int32(height))
            decoded.withUnsafeMutableBytes { output in
                XCTAssertEqual(tb_dpcm_decode(base, payload.count,
                    output.bindMemory(to: UInt8.self).baseAddress, Int32(width * 4)), 0)
            }
        }
        XCTAssertEqual(decoded, pixels)
    }
}

final class TBVideoSubmissionStatisticsTests: XCTestCase {
    private func frame(width: Int = 4480, height: Int = 2520,
                       seconds: Double = 0.012, usesGPU: Bool = true) -> TBVideoSubmissionStatistics.DPCMFrame {
        .init(width: width, height: height, encodePacketSeconds: seconds, usesGPU: usesGPU)
    }

    func testDelayedTimerUsesOneElapsedWindowForFPSAndVideoTraffic() throws {
        var statistics = TBVideoSubmissionStatistics()
        let before = statistics.snapshot(at: 10)
        for _ in 0..<60 { statistics.record(packetBytes: 50_000_000, dpcm: frame()) }
        let rate = TBVideoSubmissionStatistics.rate(from: before, to: statistics.snapshot(at: 12))
        XCTAssertEqual(rate.framesPerSecond, 30, accuracy: 0.0001)
        let dpcm = try XCTUnwrap(rate.dpcm)
        XCTAssertEqual(dpcm.submittedGbps, 12, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(dpcm.meanPacketMB), 50, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(dpcm.compressionRatio), Double(4480 * 2520 * 4) / 50_000_000, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(dpcm.meanEncodePacketMS), 12, accuracy: 0.0001)
    }

    func testNextWindowExcludesEarlierPacketsAndUsesActualCaptureSize() throws {
        var statistics = TBVideoSubmissionStatistics()
        statistics.record(packetBytes: 50_000_000, dpcm: frame())
        let before = statistics.snapshot(at: 20)
        for _ in 0..<15 {
            statistics.record(packetBytes: 4_000_000, dpcm: frame(width: 1920, height: 1080, seconds: 0.005))
        }
        let rate = TBVideoSubmissionStatistics.rate(from: before, to: statistics.snapshot(at: 20.5))
        XCTAssertEqual(rate.framesPerSecond, 30, accuracy: 0.0001)
        let dpcm = try XCTUnwrap(rate.dpcm)
        XCTAssertEqual(dpcm.captureWidth, 1920)
        XCTAssertEqual(dpcm.captureHeight, 1080)
        XCTAssertEqual(dpcm.submittedGbps, 0.96, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(dpcm.meanPacketMB), 4, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(dpcm.compressionRatio), Double(1920 * 1080 * 4) / 4_000_000, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(dpcm.meanEncodePacketMS), 5, accuracy: 0.0001)
    }

    func testIdleWindowReportsZeroTrafficWithoutStaleAverages() throws {
        var statistics = TBVideoSubmissionStatistics()
        statistics.record(packetBytes: 10_000_000, dpcm: frame())
        let before = statistics.snapshot(at: 1)
        let rate = TBVideoSubmissionStatistics.rate(from: before, to: statistics.snapshot(at: 2))
        XCTAssertEqual(rate.framesPerSecond, 0)
        let dpcm = try XCTUnwrap(rate.dpcm)
        XCTAssertEqual(dpcm.submittedGbps, 0)
        XCTAssertEqual(dpcm.captureWidth, 4480)
        XCTAssertNil(dpcm.meanPacketMB)
        XCTAssertNil(dpcm.compressionRatio)
        XCTAssertNil(dpcm.meanEncodePacketMS)
    }

    func testNewPipelineAndInvalidTimeDoNotReusePreviousRates() {
        var old = TBVideoSubmissionStatistics()
        old.record(packetBytes: 10_000_000, dpcm: frame())
        let oldSnapshot = old.snapshot(at: 10)
        let fresh = TBVideoSubmissionStatistics()
        let restarted = TBVideoSubmissionStatistics.rate(from: oldSnapshot, to: fresh.snapshot(at: 11))
        XCTAssertEqual(restarted.framesPerSecond, 0)
        XCTAssertNil(restarted.dpcm)
        for time in [10.0, 9.0] {
            let rate = TBVideoSubmissionStatistics.rate(from: oldSnapshot, to: old.snapshot(at: time))
            XCTAssertEqual(rate.framesPerSecond, 0)
            XCTAssertNil(rate.dpcm)
        }
    }

    func testFallbackBackendTracksTheEncoderThatProducedTheLatestFrame() throws {
        var statistics = TBVideoSubmissionStatistics()
        let before = statistics.snapshot(at: 1)
        statistics.record(packetBytes: 10_000_000, dpcm: frame(usesGPU: true))
        let gpu = statistics.snapshot(at: 2)
        XCTAssertTrue(try XCTUnwrap(TBVideoSubmissionStatistics.rate(from: before, to: gpu).dpcm).usesGPU)
        statistics.record(packetBytes: 10_000_000, dpcm: frame(usesGPU: false))
        let cpu = statistics.snapshot(at: 3)
        XCTAssertFalse(try XCTUnwrap(TBVideoSubmissionStatistics.rate(from: gpu, to: cpu).dpcm).usesGPU)
    }

    func testEncodedVideoStillReportsFPSWithoutDPCMDetails() {
        var statistics = TBVideoSubmissionStatistics()
        let before = statistics.snapshot(at: 5)
        for _ in 0..<24 { statistics.record(packetBytes: 100_000) }
        let rate = TBVideoSubmissionStatistics.rate(from: before, to: statistics.snapshot(at: 5.5))
        XCTAssertEqual(rate.framesPerSecond, 48, accuracy: 0.0001)
        XCTAssertNil(rate.dpcm)
    }

    @MainActor
    func testStoppingLiveMetricsClearsDPCMAndFPS() {
        let metrics = TBSessionLiveMetrics()
        var statistics = TBVideoSubmissionStatistics()
        let before = statistics.snapshot(at: 1)
        statistics.record(packetBytes: 10_000_000, dpcm: frame())
        metrics.senderFPS = 30
        metrics.dpcm = TBVideoSubmissionStatistics.rate(from: before, to: statistics.snapshot(at: 2)).dpcm
        metrics.reset()
        XCTAssertEqual(metrics.senderFPS, 0)
        XCTAssertNil(metrics.dpcm)
    }
}

final class TBVirtualDisplayModeSelectionTests: XCTestCase {
    private typealias Candidate = TBVirtualDisplayModeSelection.Candidate
    private let standard = Candidate(pointWidth: 2240, pointHeight: 1260,
                                     pixelWidth: 2240, pixelHeight: 1260, refreshRate: 60)
    private let retina = Candidate(pointWidth: 2240, pointHeight: 1260,
                                   pixelWidth: 4480, pixelHeight: 2520, refreshRate: 60)
    private let requested = TBVirtualDisplayModeSize(width: 2240, height: 1260)

    func testSameLogicalSizeSelectsHiDPIRegardlessOfEnumerationOrder() {
        XCTAssertEqual(TBVirtualDisplayModeSelection.preferredIndex(
            in: [standard, retina], mode: requested, refreshRate: 60), 1)
        XCTAssertEqual(TBVirtualDisplayModeSelection.preferredIndex(
            in: [retina, standard], mode: requested, refreshRate: 60), 0)
    }

    func testHiDPIModeMustBeAvailableBeforeStartupCanSelectIt() {
        // The standard variant can appear before WindowServer publishes HiDPI.
        // It must not end the startup retry loop with the wrong backing size.
        XCTAssertNil(TBVirtualDisplayModeSelection.preferredIndex(
            in: [standard], mode: requested, refreshRate: 60))
        XCTAssertEqual(TBVirtualDisplayModeSelection.preferredIndex(
            in: [standard, retina], mode: requested, refreshRate: 60), 1)
    }

    func testNative1080pStillSelectsOneToOnePixels() {
        let native = Candidate(pointWidth: 1920, pointHeight: 1080,
                               pixelWidth: 1920, pixelHeight: 1080, refreshRate: 60)
        let doubled = Candidate(pointWidth: 1920, pointHeight: 1080,
                                pixelWidth: 3840, pixelHeight: 2160, refreshRate: 60)
        let mode = TBVirtualDisplayModeSize(width: 1920, height: 1080, isHiDPI: false)
        XCTAssertEqual(TBVirtualDisplayModeSelection.preferredIndex(
            in: [doubled, native], mode: mode, refreshRate: 60), 1)
        XCTAssertNil(TBVirtualDisplayModeSelection.preferredIndex(
            in: [doubled], mode: mode, refreshRate: 60))
    }

    func testSavedChoicePreservesBothHiDPIAndExplicitStandardModes() throws {
        for (index, choice) in [standard, retina].enumerated() {
            let restored = try JSONDecoder().decode(Candidate.self, from: JSONEncoder().encode(choice))
            XCTAssertEqual(TBVirtualDisplayModeSelection.savedIndex(
                in: [standard, retina], choice: restored), index)
        }
        XCTAssertNil(TBVirtualDisplayModeSelection.savedIndex(in: [standard], choice: retina))
    }

    func testModeSwitchSuccessRequiresMatchingBackingReadback() {
        XCTAssertFalse(TBVirtualDisplayModeSelection.applyAndVerify(retina,
            apply: { true }, readBack: { self.standard }))
        XCTAssertFalse(TBVirtualDisplayModeSelection.applyAndVerify(retina,
            apply: { true }, readBack: { nil }))
        XCTAssertTrue(TBVirtualDisplayModeSelection.applyAndVerify(retina,
            apply: { true }, readBack: { self.retina }))
        XCTAssertFalse(TBVirtualDisplayModeSelection.applyAndVerify(retina,
            apply: { false }, readBack: { XCTFail("failed switch must not be published"); return self.retina }))
    }
}

/// The production startup wrapper is exercised with a suspended asynchronous
/// start. No SCStream, display, network, or system permissions are involved.
final class TBCaptureStartupTests: XCTestCase {
    @MainActor
    private final class DeferredStart {
        var beginCount = 0
        private var continuation: CheckedContinuation<Void, Error>?
        private var started: CheckedContinuation<Void, Never>?

        func begin() async throws {
            beginCount += 1
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                started?.resume()
                started = nil
            }
        }

        func waitUntilStarted() async {
            if continuation != nil { return }
            await withCheckedContinuation { started = $0 }
        }

        func finish(_ error: Error? = nil) {
            guard let continuation else { return }
            self.continuation = nil
            if let error { continuation.resume(throwing: error) }
            else { continuation.resume() }
        }
    }

    @MainActor
    func testCurrentStartupCanPublishWithoutDiscarding() async throws {
        let gate = DeferredStart()
        var discarded = 0
        let task = Task {
            try await TBCaptureStartup.start(isCurrent: { true },
                                            begin: { try await gate.begin() },
                                            discard: { discarded += 1 })
        }
        await gate.waitUntilStarted()
        gate.finish()
        let canPublish = try await task.value
        XCTAssertTrue(canPublish)
        XCTAssertEqual(gate.beginCount, 1)
        XCTAssertEqual(discarded, 0)
    }

    @MainActor
    func testStopDuringStartupDiscardsLateStreamBeforePublication() async throws {
        let gate = DeferredStart()
        var current = true
        var discarded = 0
        let task = Task {
            try await TBCaptureStartup.start(isCurrent: { current },
                                            begin: { try await gate.begin() },
                                            discard: { discarded += 1 })
        }
        await gate.waitUntilStarted()
        current = false // stop/reconnect while the original SCStream is starting
        gate.finish()
        let canPublish = try await task.value
        XCTAssertFalse(canPublish)
        XCTAssertEqual(discarded, 1)
    }

    @MainActor
    func testSupersededAttemptDoesNotEvenStart() async throws {
        let gate = DeferredStart()
        var discarded = 0
        let canPublish = try await TBCaptureStartup.start(isCurrent: { false },
                                                         begin: { try await gate.begin() },
                                                         discard: { discarded += 1 })
        XCTAssertFalse(canPublish)
        XCTAssertEqual(gate.beginCount, 0)
        XCTAssertEqual(discarded, 1)
    }

    @MainActor
    func testStartupFailureDiscardsOnlyItsOwnResources() async {
        enum Failure: Error { case capture }
        let gate = DeferredStart()
        var oldDiscarded = 0
        var replacementIsActive = false
        let task = Task {
            try await TBCaptureStartup.start(isCurrent: { !replacementIsActive },
                                            begin: { try await gate.begin() },
                                            discard: { oldDiscarded += 1 })
        }
        await gate.waitUntilStarted()
        replacementIsActive = true
        gate.finish(Failure.capture)
        do {
            _ = try await task.value
            XCTFail("capture failure must be propagated")
        } catch Failure.capture {
            // The session caller checks its generation before reporting/stopping.
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(oldDiscarded, 1)
        XCTAssertTrue(replacementIsActive)
    }
}
