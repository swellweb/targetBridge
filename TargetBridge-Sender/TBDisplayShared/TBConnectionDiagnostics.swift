import Foundation
import Network
import os

/// Unified-logging entry points for the sender. `log stream --predicate
/// 'subsystem == "com.targetbridge.sender"'` (or Console.app) shows the
/// connection lifecycle without attaching a debugger.
enum TBLog {
    static let connection = Logger(subsystem: "com.targetbridge.sender", category: "connection")
}

/// Pure helpers for deciding how to dial a receiver and for composing
/// actionable connection-failure details. Kept free of session state so the
/// unit-test bundle can exercise them without hardware.
enum TBConnectionDiagnostics {

    /// A local IPv4 interface as (name, ip) — the test-injectable slice of
    /// what `getifaddrs` reports.
    struct LocalInterface: Equatable {
        let name: String
        let ip: String

        init(name: String, ip: String) {
            self.name = name
            self.ip = ip
        }
    }

    /// Returns the name of the local interface that owns `localIP`, if any.
    static func interfaceName(forLocalIP localIP: String, in interfaces: [LocalInterface]) -> String? {
        guard !localIP.isEmpty else { return nil }
        return interfaces.first(where: { $0.ip == localIP })?.name
    }

    /// For a link-local (`169.254.x`) receiver address, returns
    /// `"<ip>%<interface>"` so the dial is scoped to the interface that owns
    /// `localIP`. Everything else is returned unchanged.
    ///
    /// Why: macOS keeps a single routing-table entry for all of
    /// 169.254.0.0/16, pointing at the primary interface (usually Wi-Fi). A
    /// Thunderbolt Bridge peer is only reachable on the bridge interface, so
    /// an unscoped dial to its self-assigned link-local address leaves via the
    /// wrong interface and times out — with both Macs configured correctly.
    /// A scoped address routes on the named interface regardless of the table.
    static func scopedReceiverHost(
        receiverIP: String,
        localIP: String,
        interfaces: [LocalInterface]
    ) -> String {
        guard receiverIP.hasPrefix("169.254."), !receiverIP.contains("%") else { return receiverIP }
        guard let name = interfaceName(forLocalIP: localIP, in: interfaces) else { return receiverIP }
        return "\(receiverIP)%\(name)"
    }

    /// Human-readable context for a failed or timed-out connect attempt:
    /// where we dialed, from which address/interface, over which transport,
    /// and the last state reported by the network stack.
    static func failureDetail(
        receiverHost: String,
        port: UInt16,
        localIP: String,
        interfaceName: String?,
        transport: String,
        lastNetworkState: String?
    ) -> String {
        var detail = "dialed \(receiverHost):\(port) from \(localIP)"
        if let interfaceName, !interfaceName.isEmpty {
            detail += " (\(interfaceName))"
        }
        detail += " [\(transport)]"
        if let lastNetworkState, !lastNetworkState.isEmpty {
            detail += " — last network state: \(lastNetworkState)"
        }
        return detail
    }

    /// Snapshot of the machine's up, non-loopback IPv4 interfaces.
    static func currentIPv4Interfaces() -> [LocalInterface] {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return [] }
        defer { freeifaddrs(ifaddr) }

        var interfaces: [LocalInterface] = []
        var pointer = ifaddr
        while let iface = pointer {
            defer { pointer = iface.pointee.ifa_next }
            guard let sa = iface.pointee.ifa_addr,
                  sa.pointee.sa_family == UInt8(AF_INET)
            else { continue }
            let flags = Int32(iface.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                sa,
                socklen_t(sa.pointee.sa_len),
                &buffer,
                socklen_t(buffer.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 else { continue }
            interfaces.append(LocalInterface(name: String(cString: iface.pointee.ifa_name), ip: String(cString: buffer)))
        }
        return interfaces
    }
}
