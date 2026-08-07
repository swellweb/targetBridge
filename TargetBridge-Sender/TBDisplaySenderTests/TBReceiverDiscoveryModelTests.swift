import XCTest
@testable import TargetBridge

/// Tests for the discovered-receiver value model: per-transport address
/// selection and the human-readable summary. These pin down which IP the
/// sender dials for Thunderbolt vs Network Link — the exact decision that
/// determines whether traffic goes over the bridge or the LAN.
final class TBReceiverDiscoveryModelTests: XCTestCase {

    private func makeReceiver(
        serviceName: String = "TargetBridge Test-iMac",
        receiverName: String = "Test-iMac",
        preferredIP: String = "192.168.1.64",
        thunderboltIP: String = "",
        usbIP: String = "",
        networkIP: String = "",
        panelSummary: String = "",
        version: String = "3.1.0",
        supportsHEVCDecode: Bool = true,
        hostName: String? = nil
    ) -> TBDiscoveredReceiver {
        TBDiscoveredReceiver(
            serviceName: serviceName,
            receiverName: receiverName,
            preferredIP: preferredIP,
            thunderboltIP: thunderboltIP,
            usbIP: usbIP,
            networkIP: networkIP,
            panelSummary: panelSummary,
            version: version,
            supportsHEVCDecode: supportsHEVCDecode,
            hostName: hostName
        )
    }

    // MARK: - ip(for:) transport selection

    func testThunderboltTransportPrefersThunderboltIP() {
        let receiver = makeReceiver(preferredIP: "192.168.1.64", thunderboltIP: "169.254.89.80", networkIP: "192.168.1.64")
        XCTAssertEqual(receiver.ip(for: .thunderboltBridge), "169.254.89.80")
    }

    func testThunderboltTransportFallsBackToPreferredIP() {
        let receiver = makeReceiver(preferredIP: "192.168.1.64", thunderboltIP: "", networkIP: "192.168.1.64")
        XCTAssertEqual(receiver.ip(for: .thunderboltBridge), "192.168.1.64")
    }

    func testNetworkTransportPrefersNetworkIP() {
        let receiver = makeReceiver(preferredIP: "169.254.89.80", thunderboltIP: "169.254.89.80", networkIP: "192.168.1.64")
        XCTAssertEqual(receiver.ip(for: .networkLink), "192.168.1.64")
    }

    func testNetworkTransportFallsBackToPreferredIP() {
        let receiver = makeReceiver(preferredIP: "169.254.89.80", thunderboltIP: "169.254.89.80", networkIP: "")
        XCTAssertEqual(receiver.ip(for: .networkLink), "169.254.89.80")
    }

    func testNetworkTransportUsesUSBIPForLinkLocalLocalInterface() {
        let receiver = makeReceiver(
            preferredIP: "169.254.189.3",
            usbIP: "169.254.189.3",
            networkIP: "192.168.178.101"
        )
        XCTAssertEqual(
            receiver.ip(for: .networkLink, localInterfaceIP: "169.254.190.84"),
            "169.254.189.3"
        )
    }

    func testNetworkTransportKeepsLANIPForLANLocalInterface() {
        let receiver = makeReceiver(
            preferredIP: "169.254.189.3",
            usbIP: "169.254.189.3",
            networkIP: "192.168.178.101"
        )
        XCTAssertEqual(
            receiver.ip(for: .networkLink, localInterfaceIP: "192.168.178.93"),
            "192.168.178.101"
        )
    }

    // MARK: - Identity

    func testIDCombinesServiceNameAndPreferredIP() {
        let receiver = makeReceiver(serviceName: "TargetBridge Jonathans-iMac", preferredIP: "192.168.1.64")
        XCTAssertEqual(receiver.id, "TargetBridge Jonathans-iMac|192.168.1.64")
    }

    func testStableIdentityDoesNotChangeWhenTheReceiverIPChanges() {
        let beforeWake = makeReceiver(serviceName: "TargetBridge Jonathans-iMac", preferredIP: "169.254.89.80")
        let afterWake = makeReceiver(serviceName: "TargetBridge Jonathans-iMac", preferredIP: "169.254.12.44")

        XCTAssertNotEqual(beforeWake.id, afterWake.id)
        XCTAssertEqual(beforeWake.stableIdentity, afterWake.stableIdentity)
    }

    // MARK: - shortHostName

    func testShortHostNameStripsTrailingDotAndDomain() {
        let receiver = makeReceiver(hostName: "Jonathans-iMac.local.")
        XCTAssertEqual(receiver.shortHostName, "Jonathans-iMac")
    }

    func testShortHostNameNilWhenHostMissingOrEmpty() {
        XCTAssertNil(makeReceiver(hostName: nil).shortHostName)
        XCTAssertNil(makeReceiver(hostName: "").shortHostName)
    }

    // MARK: - displayText

    func testDisplayTextShowsBothTransportsWhenAvailable() {
        let receiver = makeReceiver(
            thunderboltIP: "169.254.89.80",
            usbIP: "169.254.189.3",
            networkIP: "192.168.1.64",
            hostName: "Jonathans-iMac.local."
        )
        XCTAssertEqual(receiver.displayText, "Jonathans-iMac (TB 169.254.89.80 · USB 169.254.189.3 · NET 192.168.1.64)")
    }

    func testDisplayTextSingleTransportOnly() {
        XCTAssertEqual(makeReceiver(thunderboltIP: "169.254.89.80").displayText, "169.254.89.80")
        XCTAssertEqual(makeReceiver(networkIP: "192.168.1.64").displayText, "192.168.1.64")
    }

    func testDisplayTextFallsBackToPreferredIPWithoutTransportIPs() {
        let receiver = makeReceiver(preferredIP: "192.168.1.64")
        XCTAssertEqual(receiver.displayText, "192.168.1.64")
    }

    func testDisplayTextAppendsPanelSummary() {
        let receiver = makeReceiver(networkIP: "192.168.1.64", panelSummary: "iMac 5K (5120x2880)")
        XCTAssertEqual(receiver.displayText, "192.168.1.64 · iMac 5K (5120x2880)")
    }

    func testDisplayTextDistinguishesEthernetAndWiFiWhenAdvertised() {
        let receiver = TBDiscoveredReceiver(
            serviceName: "TargetBridge iMac",
            receiverName: "iMac",
            preferredIP: "192.168.178.101",
            thunderboltIP: "",
            usbIP: "",
            networkIP: "192.168.178.101",
            ethernetIP: "10.77.77.2",
            wifiIP: "192.168.178.101",
            resolvedIPv4Addresses: ["10.77.77.2", "192.168.178.101"],
            panelSummary: "",
            version: "3.2.1",
            supportsHEVCDecode: true,
            hostName: "iMac.local."
        )
        XCTAssertEqual(receiver.displayText, "iMac (ETH 10.77.77.2 · Wi-Fi 192.168.178.101)")
    }
}
