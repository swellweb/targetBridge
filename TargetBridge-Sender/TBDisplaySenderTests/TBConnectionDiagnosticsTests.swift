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
}
