import XCTest
@testable import TargetBridge

final class TBSenderLocalizationTests: XCTestCase {
    func testEveryCaptureProfileHasATitleInEveryLanguage() {
        for language in TBDisplaySenderLanguage.allCases {
            for preset in TBDisplayCapturePreset.allCases {
                let title = preset.title(language)
                XCTAssertFalse(title.isEmpty, "\(language): \(preset)")
                XCTAssertFalse(title.contains("[["), "\(language): \(preset)")
            }
            XCTAssertEqual(TBDisplayCapturePreset.standard1080p.title(language), "Full HD")
            XCTAssertEqual(TBDisplayCapturePreset.smooth1080p60.title(language), "Full HD 60")
        }
    }

    func testBundledAddonSummariesFollowSelectedLanguage() throws {
        let expected = [
            "audio-relay": "Trasmetti l'audio dal Sender al Receiver per ogni sessione di TargetBridge.",
            "network-link": "Abilita il collegamento sperimentale tramite LAN e Wi-Fi, oltre a Thunderbolt Bridge.",
            "input-dockstation": "Inoltra tastiera e mouse dal Sender a una sessione Receiver collegata."
        ]
        for (name, italian) in expected {
            let record = addon("targetbridge.\(name)", origin: .bundled)
            XCTAssertEqual(TBDisplaySenderL10n.addonSummary(record, .italian), italian)
            for language in TBDisplaySenderLanguage.allCases {
                let summary = TBDisplaySenderL10n.addonSummary(record, language)
                XCTAssertFalse(summary.isEmpty)
                XCTAssertFalse(summary.contains("[["))
                XCTAssertNotEqual(summary, record.summary)
            }
        }
    }

    func testCustomAndUnknownAddonSummariesArePreserved() {
        for language in TBDisplaySenderLanguage.allCases {
            for id in ["targetbridge.audio-relay", "targetbridge.network-link", "targetbridge.input-dockstation", "custom.addon"] {
                let record = addon(id, origin: .user)
                XCTAssertEqual(TBDisplaySenderL10n.addonSummary(record, language), record.summary)
            }
            let unknown = addon("future.bundled-addon", origin: .bundled)
            XCTAssertEqual(TBDisplaySenderL10n.addonSummary(unknown, language), unknown.summary)
        }
    }

    func testItalianPermissionDescriptionsArePackaged() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "InfoPlist", withExtension: "strings", subdirectory: nil, localization: "it"))
        let strings = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
        for key in ["NSScreenCaptureUsageDescription", "NSAppleEventsUsageDescription", "NSLocalNetworkUsageDescription"] {
            let text = try XCTUnwrap(strings[key], key)
            XCTAssertTrue(text.hasPrefix("TargetBridge "))
            XCTAssertFalse(text.contains("requires"))
        }
    }

    private func addon(_ id: String, origin: TBAddonOrigin) -> TBAddonRecord {
        TBAddonRecord(manifest: TBAddonManifest(id: id, name: id, version: "1", summary: "Manifest-owned wording"),
                      origin: origin, sourceURL: URL(fileURLWithPath: "/unused-manifest.json"))
    }
}
