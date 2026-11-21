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

    func testLegacyRAWSelectionRemainsStrictAfterChangingOnlyResolution() {
        let session = makeSession()
        session.capturePreset = .native4_5kRGB10Raw60
        XCTAssertEqual(session.capturePreset, .retina4_5k60)
        XCTAssertEqual(session.codecPreference, .rawRGB10)
        session.capturePreset = .standard1080p
        XCTAssertNil(TBVideoTransport.resolve(preference: session.codecPreference,
            preset: session.capturePreset, supportsRawNV12: true, supportsRawRGB10: nil))
        XCTAssertEqual(TBVideoTransport.resolve(preference: session.codecPreference,
            preset: session.capturePreset, supportsRawNV12: true, supportsRawRGB10: true), .rawRGB10Bit)
        session.codecPreference = .automatic
        session.capturePreset = .retina4_5k60
        XCTAssertEqual(TBVideoTransport.resolve(preference: session.codecPreference,
            preset: session.capturePreset, supportsRawNV12: true, supportsRawRGB10: true), .encoded)
    }

    func testLegacySelectionPreservesExplicitCompressionAndCanonicalGeometry() {
        let legacy = TBDisplayCapturePreset.native4_5kRGB10Raw60
        for preference in [TBDisplayCodecPreference.h264, .hevc, .rawRGB10] {
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

    func testSavedSessionsMigrateIndependentlyAndRoundTripWithoutReintroducingLegacyPresets() throws {
        let common: [String: Any] = [
            "transportKind": "thunderboltBridge", "localInterfaceIP": "", "receiverIP": "169.254.1.2",
            "selectedReceiverID": "TargetBridge Migration Test|169.254.1.2", "captureSource": "desktopMirror",
            "audioEnabled": false, "brightness": 0.5, "inputGestureMode": "direct",
            "capturePreset": "native4_5kRGB10Raw60"
        ]
        var raw: [[String: Any]] = []
        for preference: String? in [nil, "automatic", "h264", "hevc"] {
            var value = common
            if let preference { value["codecPreference"] = preference }
            raw.append(value)
        }
        var configs = try JSONDecoder().decode([TBDisplaySenderService.PersistedSession].self,
                                               from: JSONSerialization.data(withJSONObject: raw))
        for index in configs.indices { configs[index].normalizeCaptureSelection() }
        XCTAssertEqual(configs.map(\.capturePreset), Array(repeating: "retina4_5k60", count: 4))
        XCTAssertEqual(configs.map(\.codecPreference), ["rawRGB10", "rawRGB10", "h264", "hevc"])
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let saved = try encoder.encode(configs)
        var restored = try JSONDecoder().decode([TBDisplaySenderService.PersistedSession].self, from: saved)
        for index in restored.indices { restored[index].normalizeCaptureSelection() }
        XCTAssertEqual(try encoder.encode(restored), saved, "A second launch must not migrate again")
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
            let session = makeSession()
            session.selectedReceiverID = alias
            session.capturePreset = .native4_5kRGB10Raw60
            for _ in 0..<3 {
                XCTAssertFalse(session.updateDiscoveredReceiver(receiver, defaultCodecPreference: defaultCodec),
                               "Same-receiver refresh must not request display-profile restoration")
                XCTAssertEqual(session.capturePreset, .retina4_5k60)
                XCTAssertEqual(session.codecPreference, .rawRGB10)
                XCTAssertEqual(session.selectedReceiverID, receiver.stableIdentity)
                XCTAssertEqual(session.receiverIP, "169.254.2.3")
            }
            session.updateDiscoveredReceiver(receiver, defaultCodecPreference: .hevc)
            XCTAssertEqual(session.codecPreference, .rawRGB10)
        }
        let newSession = makeSession()
        XCTAssertTrue(newSession.updateDiscoveredReceiver(receiver, defaultCodecPreference: .hevc))
        XCTAssertEqual(newSession.codecPreference, .hevc)
        let other = self.receiver(id: "8D3FC604-AC90-4EB0-A090-2412B3CA9979")
        XCTAssertTrue(newSession.updateDiscoveredReceiver(other, defaultCodecPreference: .h264))
        XCTAssertEqual(newSession.codecPreference, .h264)
    }

    func testAddingSessionKeepsBothResolutionAndMigratedCompression() {
        let previous = makeSession()
        previous.capturePreset = .native4_5kRGB10Raw60
        let added = makeSession()
        added.inheritStreamSelection(from: previous)
        XCTAssertEqual(added.capturePreset, previous.capturePreset)
        XCTAssertEqual(added.codecPreference, .rawRGB10)
        added.capturePreset = .standard1080p
        XCTAssertEqual(added.codecPreference, .rawRGB10)
    }

    func testLegacyCLIProfileAliasesShareMigrationAndRespectExplicitCompression() throws {
        for alias in ["native4_5kRGB10Raw60", "4.5k-rgb10-raw", "imacm1-rgb10-raw"] {
            let preset = try XCTUnwrap(TBSenderAutomation.parsePreset(alias), alias)
            let session = makeSession()
            session.capturePreset = preset
            XCTAssertEqual(session.capturePreset, .retina4_5k60, alias)
            XCTAssertEqual(session.codecPreference, .rawRGB10, alias)
            session.codecPreference = .hevc
            session.capturePreset = preset
            XCTAssertEqual(session.codecPreference, .hevc, alias)
        }
    }

    func testResolutionMenuHasNoCompressionDuplicates() {
        let presets = TBDisplayCapturePreset.resolutionPresets
        XCTAssertFalse(presets.contains(.native4_5kRGB10Raw60))
        XCTAssertTrue(presets.contains(.retina4_5k60))
        XCTAssertEqual(Set(presets.map(\.resolutionTitle)).count, presets.count)
        XCTAssertEqual(TBDisplayCapturePreset.standard1080p.resolutionTitle, "1920 × 1080 · 30 FPS")
        for language in TBDisplaySenderLanguage.allCases {
            XCTAssertFalse(TBDisplaySenderL10n.streamProfileHint(language).contains("sender.stream"))
        }
    }
}

final class TBCompressionPreferenceTests: XCTestCase {
    func testExplicitRAWWorksForEveryPresetWithoutChangingGeometry() {
        for preset in TBDisplayCapturePreset.allCases {
            let transport = TBVideoTransport.resolve(preference: .rawRGB10, preset: preset,
                supportsRawNV12: false, supportsRawRGB10: true)
            XCTAssertEqual(transport, .rawRGB10Bit)
            XCTAssertEqual(transport?.captureQueueDepth(for: preset), preset.width >= 4480 ? 8 : preset.queueDepth)
            for unsupported: Bool? in [false, nil] {
                XCTAssertNil(TBVideoTransport.resolve(preference: .rawRGB10, preset: preset,
                    supportsRawNV12: true, supportsRawRGB10: unsupported, rawOverride: true))
            }
            for preference in [TBDisplayCodecPreference.h264, .hevc] {
                XCTAssertEqual(TBVideoTransport.resolve(preference: preference, preset: preset,
                    supportsRawNV12: true, supportsRawRGB10: true, rawOverride: true), .encoded)
            }
        }
    }
    func testAutomaticHonorsRAWCapabilityAndLegacyNV12Override() {
        for unsupported: Bool? in [false, nil] {
            XCTAssertNil(TBVideoTransport.resolve(preference: .automatic, preset: .native4_5kRGB10Raw60,
                supportsRawNV12: true, supportsRawRGB10: unsupported))
        }
        XCTAssertEqual(TBVideoTransport.resolve(preference: .automatic, preset: .native4_5kRGB10Raw60,
            supportsRawNV12: true, supportsRawRGB10: true), .rawRGB10Bit)
        XCTAssertEqual(TBVideoTransport.resolve(preference: .automatic, preset: .retina4_5k60,
            supportsRawNV12: true, supportsRawRGB10: true), .encoded)
        XCTAssertEqual(TBVideoTransport.resolve(preference: .automatic, preset: .retina4_5k60,
            supportsRawNV12: true, supportsRawRGB10: true, rawOverride: true), .rawNV12)
    }
    @MainActor
    func testCompressionChoicesRoundTripAndRAWBypassesHardwareEncoder() throws {
        for preference in TBDisplayCodecPreference.allCases {
            XCTAssertEqual(try JSONDecoder().decode(TBDisplayCodecPreference.self,
                from: JSONEncoder().encode(preference)), preference)
        }
        XCTAssertEqual(TBDisplayCodecPreference.allCases.map(\.rawValue), ["automatic", "h264", "hevc", "rawRGB10"])
        XCTAssertNil(TBDisplaySenderSession.chooseCodec(preference: .rawRGB10, preset: .retina4_5k60,
            receiverSupportsHEVC: true, senderSupportsH264: true, senderSupportsHEVC: true))
        XCTAssertEqual(TBDisplayCapturePreset.native4_5kRGB10Raw60.description, "4480 × 2520 @ 60")
    }
}


final class TBVideoSubmissionStatisticsTests: XCTestCase {
    private func frame(width: Int = 4480, height: Int = 2520,
                       seconds: Double = 0.012, usesGPU: Bool = true) -> TBVideoSubmissionStatistics.RGBFrame {
        .init(width: width, height: height, encodePacketSeconds: seconds, usesGPU: usesGPU)
    }

    func testDelayedTimerUsesOneElapsedWindowForFPSAndVideoTraffic() throws {
        var statistics = TBVideoSubmissionStatistics()
        let before = statistics.snapshot(at: 10)
        for _ in 0..<60 { statistics.record(packetBytes: 50_000_000, rgb: frame()) }
        let rate = TBVideoSubmissionStatistics.rate(from: before, to: statistics.snapshot(at: 12))
        XCTAssertEqual(rate.framesPerSecond, 30, accuracy: 0.0001)
        let rgb = try XCTUnwrap(rate.rgb)
        XCTAssertEqual(rgb.submittedGbps, 12, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(rgb.meanPacketMB), 50, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(rgb.compressionRatio), Double(4480 * 2520 * 4) / 50_000_000, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(rgb.meanEncodePacketMS), 12, accuracy: 0.0001)
    }

    func testNextWindowExcludesEarlierPacketsAndUsesActualCaptureSize() throws {
        var statistics = TBVideoSubmissionStatistics()
        statistics.record(packetBytes: 50_000_000, rgb: frame())
        let before = statistics.snapshot(at: 20)
        for _ in 0..<15 {
            statistics.record(packetBytes: 4_000_000, rgb: frame(width: 1920, height: 1080, seconds: 0.005))
        }
        let rate = TBVideoSubmissionStatistics.rate(from: before, to: statistics.snapshot(at: 20.5))
        XCTAssertEqual(rate.framesPerSecond, 30, accuracy: 0.0001)
        let rgb = try XCTUnwrap(rate.rgb)
        XCTAssertEqual(rgb.captureWidth, 1920)
        XCTAssertEqual(rgb.captureHeight, 1080)
        XCTAssertEqual(rgb.submittedGbps, 0.96, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(rgb.meanPacketMB), 4, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(rgb.compressionRatio), Double(1920 * 1080 * 4) / 4_000_000, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(rgb.meanEncodePacketMS), 5, accuracy: 0.0001)
    }

    func testIdleWindowReportsZeroTrafficWithoutStaleAverages() throws {
        var statistics = TBVideoSubmissionStatistics()
        statistics.record(packetBytes: 10_000_000, rgb: frame())
        let before = statistics.snapshot(at: 1)
        let rate = TBVideoSubmissionStatistics.rate(from: before, to: statistics.snapshot(at: 2))
        XCTAssertEqual(rate.framesPerSecond, 0)
        let rgb = try XCTUnwrap(rate.rgb)
        XCTAssertEqual(rgb.submittedGbps, 0)
        XCTAssertEqual(rgb.captureWidth, 4480)
        XCTAssertNil(rgb.meanPacketMB)
        XCTAssertNil(rgb.compressionRatio)
        XCTAssertNil(rgb.meanEncodePacketMS)
    }

    func testNewPipelineAndInvalidTimeDoNotReusePreviousRates() {
        var old = TBVideoSubmissionStatistics()
        old.record(packetBytes: 10_000_000, rgb: frame())
        let oldSnapshot = old.snapshot(at: 10)
        let fresh = TBVideoSubmissionStatistics()
        let restarted = TBVideoSubmissionStatistics.rate(from: oldSnapshot, to: fresh.snapshot(at: 11))
        XCTAssertEqual(restarted.framesPerSecond, 0)
        XCTAssertNil(restarted.rgb)
        for time in [10.0, 9.0] {
            let rate = TBVideoSubmissionStatistics.rate(from: oldSnapshot, to: old.snapshot(at: time))
            XCTAssertEqual(rate.framesPerSecond, 0)
            XCTAssertNil(rate.rgb)
        }
    }

    func testFallbackBackendTracksTheEncoderThatProducedTheLatestFrame() throws {
        var statistics = TBVideoSubmissionStatistics()
        let before = statistics.snapshot(at: 1)
        statistics.record(packetBytes: 10_000_000, rgb: frame(usesGPU: true))
        let gpu = statistics.snapshot(at: 2)
        XCTAssertTrue(try XCTUnwrap(TBVideoSubmissionStatistics.rate(from: before, to: gpu).rgb).usesGPU)
        statistics.record(packetBytes: 10_000_000, rgb: frame(usesGPU: false))
        let cpu = statistics.snapshot(at: 3)
        XCTAssertFalse(try XCTUnwrap(TBVideoSubmissionStatistics.rate(from: gpu, to: cpu).rgb).usesGPU)
    }

    func testEncodedVideoStillReportsFPSWithoutRGBDetails() {
        var statistics = TBVideoSubmissionStatistics()
        let before = statistics.snapshot(at: 5)
        for _ in 0..<24 { statistics.record(packetBytes: 100_000) }
        let rate = TBVideoSubmissionStatistics.rate(from: before, to: statistics.snapshot(at: 5.5))
        XCTAssertEqual(rate.framesPerSecond, 48, accuracy: 0.0001)
        XCTAssertNil(rate.rgb)
    }

    @MainActor
    func testStoppingLiveMetricsClearsRGBAndFPS() {
        let metrics = TBSessionLiveMetrics()
        var statistics = TBVideoSubmissionStatistics()
        let before = statistics.snapshot(at: 1)
        statistics.record(packetBytes: 10_000_000, rgb: frame())
        metrics.senderFPS = 30
        metrics.rgb = TBVideoSubmissionStatistics.rate(from: before, to: statistics.snapshot(at: 2)).rgb
        metrics.reset()
        XCTAssertEqual(metrics.senderFPS, 0)
        XCTAssertNil(metrics.rgb)
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
