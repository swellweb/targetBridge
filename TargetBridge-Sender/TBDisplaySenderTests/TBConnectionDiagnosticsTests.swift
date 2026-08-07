import XCTest
@testable import TargetBridge

/// Tests for the connect-path helpers: link-local interface scoping (the fix
/// for Thunderbolt Bridge dials leaving via the wrong interface) and the
/// failure-detail composer that keeps diagnostics attached to errors.
final class TBConnectionDiagnosticsTests: XCTestCase {

    private typealias Interface = TBConnectionDiagnostics.LocalInterface

    private let interfaces: [Interface] = [
        Interface(name: "en0", ip: "192.168.1.225"),
        Interface(name: "bridge0", ip: "169.254.109.86"),
        Interface(name: "en8", ip: "169.254.190.84"),
    ]

    // MARK: - interfaceName(forLocalIP:)

    func testInterfaceNameFindsOwningInterface() {
        XCTAssertEqual(
            TBConnectionDiagnostics.interfaceName(forLocalIP: "169.254.109.86", in: interfaces),
            "bridge0"
        )
        XCTAssertEqual(
            TBConnectionDiagnostics.interfaceName(forLocalIP: "192.168.1.225", in: interfaces),
            "en0"
        )
    }

    func testInterfaceNameNilForUnknownOrEmptyIP() {
        XCTAssertNil(TBConnectionDiagnostics.interfaceName(forLocalIP: "10.0.0.1", in: interfaces))
        XCTAssertNil(TBConnectionDiagnostics.interfaceName(forLocalIP: "", in: interfaces))
        XCTAssertNil(TBConnectionDiagnostics.interfaceName(forLocalIP: "169.254.109.86", in: []))
    }

    // MARK: - Direct USB-NCM interface classification

    func testDirectLinkInterfaceAcceptsUSBNCMLinkLocalAddress() {
        XCTAssertTrue(TBConnectionDiagnostics.isDirectLinkInterface(name: "en8", ip: "169.254.190.84"))
        XCTAssertTrue(TBConnectionDiagnostics.isDirectLinkInterface(name: "eth2", ip: "169.254.1.2"))
    }

    func testDirectLinkInterfaceRejectsThunderboltLANAndMalformedAddresses() {
        XCTAssertFalse(TBConnectionDiagnostics.isDirectLinkInterface(name: "bridge0", ip: "169.254.109.86"))
        XCTAssertFalse(TBConnectionDiagnostics.isDirectLinkInterface(name: "en8", ip: "192.168.178.93"))
        XCTAssertFalse(TBConnectionDiagnostics.isDirectLinkInterface(name: "en8", ip: "169.254.300.1"))
        XCTAssertFalse(TBConnectionDiagnostics.isDirectLinkInterface(name: "en8", ip: "169.254.1"))
    }

    // MARK: - scopedReceiverHost

    /// The Thunderbolt Bridge case: both ends self-assign 169.254.x, the
    /// routing table pins 169.254/16 to the primary interface, and only a
    /// scoped dial reaches the peer.
    func testLinkLocalReceiverIsScopedToOwningInterface() {
        XCTAssertEqual(
            TBConnectionDiagnostics.scopedReceiverHost(
                receiverIP: "169.254.89.80",
                localIP: "169.254.109.86",
                interfaces: interfaces
            ),
            "169.254.89.80%bridge0"
        )
    }

    func testNonLinkLocalReceiverIsNotScoped() {
        XCTAssertEqual(
            TBConnectionDiagnostics.scopedReceiverHost(
                receiverIP: "192.168.1.64",
                localIP: "192.168.1.225",
                interfaces: interfaces
            ),
            "192.168.1.64"
        )
    }

    func testLinkLocalReceiverWithoutMatchingLocalInterfaceIsUnchanged() {
        XCTAssertEqual(
            TBConnectionDiagnostics.scopedReceiverHost(
                receiverIP: "169.254.89.80",
                localIP: "10.9.9.9",
                interfaces: interfaces
            ),
            "169.254.89.80"
        )
    }

    func testUSBNCMLinkLocalReceiverIsNotGivenAnIPv4ZoneSuffix() {
        XCTAssertEqual(
            TBConnectionDiagnostics.scopedReceiverHost(
                receiverIP: "169.254.189.3",
                localIP: "169.254.190.84",
                interfaces: interfaces
            ),
            "169.254.189.3"
        )
    }

    func testAlreadyScopedReceiverIsUnchanged() {
        XCTAssertEqual(
            TBConnectionDiagnostics.scopedReceiverHost(
                receiverIP: "169.254.89.80%bridge0",
                localIP: "169.254.109.86",
                interfaces: interfaces
            ),
            "169.254.89.80%bridge0"
        )
    }

    // MARK: - failureDetail

    func testFailureDetailIncludesFullContext() {
        let detail = TBConnectionDiagnostics.failureDetail(
            receiverHost: "169.254.89.80",
            port: 54321,
            localIP: "169.254.109.86",
            interfaceName: "bridge0",
            transport: "thunderboltBridge",
            lastNetworkState: "waiting(No route to host)"
        )
        XCTAssertEqual(
            detail,
            "dialed 169.254.89.80:54321 from 169.254.109.86 (bridge0) [thunderboltBridge] — last network state: waiting(No route to host)"
        )
    }

    func testFailureDetailOmitsMissingInterfaceAndState() {
        let detail = TBConnectionDiagnostics.failureDetail(
            receiverHost: "192.168.1.64",
            port: 54321,
            localIP: "192.168.1.225",
            interfaceName: nil,
            transport: "networkLink",
            lastNetworkState: nil
        )
        XCTAssertEqual(detail, "dialed 192.168.1.64:54321 from 192.168.1.225 [networkLink]")
    }

    // MARK: - currentIPv4Interfaces (live snapshot; environment-tolerant)

    func testCurrentIPv4InterfacesExcludesLoopbackAndHasNames() {
        let interfaces = TBConnectionDiagnostics.currentIPv4Interfaces()
        for iface in interfaces {
            XCTAssertFalse(iface.name.isEmpty)
            XCTAssertFalse(iface.ip.hasPrefix("127."), "loopback must be excluded, found \(iface.ip) on \(iface.name)")
        }
    }

    // MARK: - Automatic path candidates and ranking

    func testPathPreferenceAcceptsUSB4AndUserFacingAliases() {
        XCTAssertEqual(TBConnectionPathPreference.parse("auto"), .automatic)
        XCTAssertEqual(TBConnectionPathPreference.parse("wired"), .wired)
        XCTAssertEqual(TBConnectionPathPreference.parse("Thunderbolt Bridge"), .thunderbolt)
        XCTAssertEqual(TBConnectionPathPreference.parse("USB4"), .usb)
        XCTAssertEqual(TBConnectionPathPreference.parse("USB-C"), .usb)
        XCTAssertEqual(TBConnectionPathPreference.parse("LAN"), .ethernet)
        XCTAssertEqual(TBConnectionPathPreference.parse("wireless"), .wifi)
        XCTAssertNil(TBConnectionPathPreference.parse("fibre-channel"))
    }

    private func candidate(
        _ kind: TBConnectionPathKind,
        localIP: String,
        receiverIP: String
    ) -> TBConnectionCandidate {
        TBConnectionCandidate(
            kind: kind,
            localInterfaceName: kind == .thunderbolt ? "bridge0" : "en8",
            localIP: localIP,
            receiverIP: receiverIP
        )
    }

    func testCandidateDiscoverySeparatesThunderboltUSBEthernetAndWiFi() {
        let receiver = TBDiscoveredReceiver(
            serviceName: "TargetBridge iMac",
            receiverName: "iMac",
            preferredIP: "192.168.178.101",
            thunderboltIP: "169.254.50.32",
            usbIP: "169.254.190.85",
            networkIP: "192.168.178.101",
            ethernetIP: "10.77.77.2",
            wifiIP: "192.168.178.101",
            resolvedIPv4Addresses: ["169.254.50.32", "169.254.190.85", "10.77.77.2", "192.168.178.101"],
            panelSummary: "iMac 4K",
            version: "3.2.1",
            supportsHEVCDecode: true,
            hostName: "iMac.local."
        )
        let local = [
            Interface(name: "bridge0", ip: "169.254.50.31"),
            Interface(name: "en8", ip: "169.254.190.84"),
            Interface(name: "en0", ip: "10.77.77.1"),
            Interface(name: "en1", ip: "192.168.178.93"),
        ]
        let candidates = TBConnectionDiagnostics.connectionCandidates(
            receiver: receiver,
            interfaces: local,
            hardwareKinds: ["en0": .ethernet, "en1": .wifi]
        )

        XCTAssertTrue(candidates.contains(candidate(.thunderbolt, localIP: "169.254.50.31", receiverIP: "169.254.50.32")))
        XCTAssertTrue(candidates.contains(candidate(.usb, localIP: "169.254.190.84", receiverIP: "169.254.190.85")))
        XCTAssertTrue(candidates.contains {
            $0.kind == .ethernet && $0.localIP == "10.77.77.1" && $0.receiverIP == "10.77.77.2"
        })
        XCTAssertTrue(candidates.contains {
            $0.kind == .wifi && $0.localIP == "192.168.178.93" && $0.receiverIP == "192.168.178.101"
        })
    }

    func testAutoSelectionLetsGigabitEthernetBeatSlowerUSB() {
        let usb = TBConnectionMeasurement(
            candidate: candidate(.usb, localIP: "169.254.1.1", receiverIP: "169.254.1.2"),
            throughputGbps: 0.48,
            connectLatencyMilliseconds: 0.20
        )
        let ethernet = TBConnectionMeasurement(
            candidate: candidate(.ethernet, localIP: "10.77.77.1", receiverIP: "10.77.77.2"),
            throughputGbps: 0.94,
            connectLatencyMilliseconds: 0.35
        )
        XCTAssertEqual(
            TBConnectionDiagnostics.selectBestMeasurement([usb, ethernet], preference: .automatic),
            ethernet
        )
    }

    func testAutoSelectionChoosesMeasuredFastestPhysicalPath() {
        let thunderbolt = TBConnectionMeasurement(
            candidate: candidate(.thunderbolt, localIP: "169.254.50.31", receiverIP: "169.254.50.32"),
            throughputGbps: 4.2,
            connectLatencyMilliseconds: 0.16
        )
        let ethernet = TBConnectionMeasurement(
            candidate: candidate(.ethernet, localIP: "10.77.77.1", receiverIP: "10.77.77.2"),
            throughputGbps: 0.94,
            connectLatencyMilliseconds: 0.22
        )
        XCTAssertEqual(
            TBConnectionDiagnostics.selectBestMeasurement([ethernet, thunderbolt], preference: .automatic),
            thunderbolt
        )
    }

    func testManualSelectionFiltersOutFasterOtherPaths() {
        let usb = TBConnectionMeasurement(
            candidate: candidate(.usb, localIP: "169.254.1.1", receiverIP: "169.254.1.2"),
            throughputGbps: 0.42,
            connectLatencyMilliseconds: 0.20
        )
        let thunderbolt = TBConnectionMeasurement(
            candidate: candidate(.thunderbolt, localIP: "169.254.2.1", receiverIP: "169.254.2.2"),
            throughputGbps: 7.0,
            connectLatencyMilliseconds: 0.10
        )
        XCTAssertEqual(
            TBConnectionDiagnostics.selectBestMeasurement([thunderbolt, usb], preference: .usb),
            usb
        )
        XCTAssertNil(TBConnectionDiagnostics.selectBestMeasurement([thunderbolt], preference: .wifi))
    }

    func testWiredModeNeverFallsBackToFasterWiFi() {
        let ethernet = TBConnectionMeasurement(
            candidate: candidate(.ethernet, localIP: "10.77.77.1", receiverIP: "10.77.77.2"),
            throughputGbps: 0.94,
            connectLatencyMilliseconds: 0.22
        )
        let wifi = TBConnectionMeasurement(
            candidate: candidate(.wifi, localIP: "192.168.178.93", receiverIP: "192.168.178.101"),
            throughputGbps: 1.20,
            connectLatencyMilliseconds: 0.15
        )
        XCTAssertEqual(
            TBConnectionDiagnostics.selectBestMeasurement([wifi, ethernet], preference: .wired),
            ethernet
        )
        XCTAssertNil(TBConnectionDiagnostics.selectBestMeasurement([wifi], preference: .wired))
    }
}
