import CoreMedia
import XCTest
@testable import TargetBridge

@MainActor
final class TBHEVCSoftwareCapabilityTests: XCTestCase {
    func testSoftwareFallbackRequiresExplicitCapabilityForEveryPreference() {
        for preference in [TBDisplayCodecPreference.automatic, .h264, .hevc] {
            for software in [false, true] {
                let decision = TBDisplaySenderSession.chooseCodec(
                    preference: preference, preset: .native5k, receiverSupportsHEVC: false,
                    senderSupportsH264: false, senderSupportsHEVC: true,
                    receiverSupportsHEVCSoftware: software)
                XCTAssertEqual(decision?.codecType, software ? kCMVideoCodecType_HEVC : nil)
                XCTAssertEqual(decision?.usedFallback, software ? true : nil)
            }
            XCTAssertNil(TBDisplaySenderSession.chooseCodec(
                preference: preference, preset: .native5k, receiverSupportsHEVC: false,
                senderSupportsH264: false, senderSupportsHEVC: true))
            XCTAssertNil(TBDisplaySenderSession.chooseCodec(
                preference: preference, preset: .native5k, receiverSupportsHEVC: false,
                senderSupportsH264: false, senderSupportsHEVC: false,
                receiverSupportsHEVCSoftware: true))
        }
    }

    func testLegacyAndExplicitSoftwareProfilesRoundTrip() throws {
        let json = """
        {"receiverName":"Test","panelWidth":5120,"panelHeight":2880,
        "modeWidth":2560,"modeHeight":1440,"refreshRate":60,"hiDPI":true,
        "captureWidth":5120,"captureHeight":2880,"supportsHEVCDecode":false}
        """
        var profile = try JSONDecoder().decode(TBMonitorDisplayProfile.self, from: Data(json.utf8))
        XCTAssertNil(profile.supportsHEVCSoftwareDecode)
        for software in [false, true] {
            profile.supportsHEVCSoftwareDecode = software
            let decoded = try JSONDecoder().decode(TBMonitorDisplayProfile.self,
                from: JSONEncoder().encode(profile))
            XCTAssertEqual(decoded.supportsHEVCSoftwareDecode, software)
            XCTAssertEqual(decoded.supportsHEVCDecode, false)
        }
    }

    func testDiscoveryRequiresExplicitSoftwareTXTFlag() throws {
        let discovery = TBReceiverDiscovery()
        for (flag, expected) in [(nil, nil), ("", nil), ("unexpected", nil), ("0", false), ("1", true)] as [(String?, Bool?)] {
            let service = CapabilityService(flag: flag)
            discovery.netServiceDidResolveAddress(service)
            let receiver = try XCTUnwrap(discovery.receivers.first)
            XCTAssertEqual(receiver.supportsHEVCSoftwareDecode, expected)
            XCTAssertFalse(receiver.supportsHEVCDecode)
        }
    }

    func testChangingPeerClearsSoftwareHintEvenAtTheSameAddress() {
        let key = "fd.tbdisplaysender.receiverIP"
        let previousIP = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(previousIP, forKey: key) }
        let session = TBDisplaySenderSession(language: .english, largeCursor: false,
            preventDisplaySleep: false, autoRestartOnWake: false, audioEnabled: false)
        session.selectedReceiverID = "first"
        session.receiverSupportsHEVCSoftwareDecodeHint = true
        session.selectedReceiverID = "second"
        XCTAssertNil(session.receiverSupportsHEVCSoftwareDecodeHint)
        session.receiverSupportsHEVCSoftwareDecodeHint = true
        session.receiverIP = session.receiverIP == "127.0.0.1" ? "127.0.0.2" : "127.0.0.1"
        XCTAssertNil(session.receiverSupportsHEVCSoftwareDecodeHint)
    }
}

private final class CapabilityService: NetService {
    private let record: Data
    init(flag: String?) {
        var fields = ["ip": Data("127.0.0.1".utf8)]
        if let flag { fields["supportsHEVCSoftwareDecode"] = Data(flag.utf8) }
        record = NetService.data(fromTXTRecord: fields)
        super.init(domain: "local.", type: "_targetbridge._tcp.", name: "Capability fixture", port: 54321)
    }
    override func txtRecordData() -> Data? { record }
}
