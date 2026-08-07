import Foundation
import Darwin
import Network
import os
import SystemConfiguration

enum TBConnectionPathPreference: String, CaseIterable {
    case automatic
    case wired
    case thunderbolt
    case usb
    case ethernet
    case wifi

    static func parse(_ value: String?) -> TBConnectionPathPreference? {
        guard let value else { return nil }
        switch value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "") {
        case "auto", "automatic", "automatico", "best", "alwaysavailable", "sempredisponibile": return .automatic
        case "wired", "cable", "cabled", "cableonly", "solocavo", "onlycable": return .wired
        case "tb", "thunderbolt", "thunderboltbridge", "bridge": return .thunderbolt
        case "usb", "usb4", "usbc", "directusb": return .usb
        case "ethernet", "eth", "lan": return .ethernet
        case "wifi", "wireless", "wlan": return .wifi
        default: return nil
        }
    }

    func allows(_ kind: TBConnectionPathKind) -> Bool {
        switch self {
        case .automatic:
            return true
        case .wired:
            return kind != .wifi
        case .thunderbolt, .usb, .ethernet, .wifi:
            return kind.rawValue == rawValue
        }
    }
}

enum TBConnectionPathKind: String, CaseIterable {
    case thunderbolt
    case usb
    case ethernet
    case wifi

    var transportKind: TBTransportKind {
        self == .thunderbolt ? .thunderboltBridge : .networkLink
    }

    fileprivate var tieBreakPriority: Int {
        switch self {
        case .thunderbolt: return 4
        case .usb: return 3
        case .ethernet: return 2
        case .wifi: return 1
        }
    }
}

struct TBConnectionCandidate: Hashable {
    let kind: TBConnectionPathKind
    let localInterfaceName: String
    let localIP: String
    let receiverIP: String

    var transportKind: TBTransportKind { kind.transportKind }
    var id: String { "\(kind.rawValue)|\(localInterfaceName)|\(localIP)|\(receiverIP)" }
}

struct TBConnectionMeasurement: Equatable {
    let candidate: TBConnectionCandidate
    let throughputGbps: Double
    let connectLatencyMilliseconds: Double
}

enum TBConnectionProbeError: LocalizedError {
    case invalidAddress(String)
    case interfaceUnavailable(String)
    case socketFailure(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .invalidAddress(let value): return "Invalid IPv4 address: \(value)"
        case .interfaceUnavailable(let value): return "Interface unavailable: \(value)"
        case .socketFailure(let value): return value
        case .timeout: return "Connection-path probe timed out"
        }
    }
}

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

    /// Direct Mac-to-Mac USB connections are exposed by macOS as USB-NCM
    /// Ethernet interfaces (normally enX) with an IPv4 link-local address.
    /// Keep bridgeX reserved for the Thunderbolt Bridge transport.
    static func isDirectLinkInterface(name: String, ip: String) -> Bool {
        guard name.hasPrefix("en") || name.hasPrefix("eth") else { return false }
        let octets = ip.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4,
              let first = Int(octets[0]),
              let second = Int(octets[1]),
              octets.dropFirst(2).allSatisfy({ component in
                  guard let value = Int(component) else { return false }
                  return (0...255).contains(value)
              })
        else {
            return false
        }
        return first == 169 && second == 254
    }

    static func isIPv4LinkLocal(_ ip: String) -> Bool {
        let octets = ipv4Octets(ip)
        return octets?.count == 4 && octets?[0] == 169 && octets?[1] == 254
    }

    static func isPrivateIPv4(_ ip: String) -> Bool {
        guard let octets = ipv4Octets(ip) else { return false }
        return octets[0] == 10
            || (octets[0] == 172 && (16...31).contains(octets[1]))
            || (octets[0] == 192 && octets[1] == 168)
    }

    private static func ipv4Octets(_ ip: String) -> [Int]? {
        let components = ip.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4 else { return nil }
        let octets = components.compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return nil }
        return octets
    }

    /// Maps BSD interface names to their physical role using SystemConfiguration.
    /// This avoids assuming that Wi-Fi is always en0/en1, which changes between Macs.
    static func hardwarePathKinds() -> [String: TBConnectionPathKind] {
        guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return [:] }
        var result: [String: TBConnectionPathKind] = [:]
        for interface in all {
            guard let bsdNameValue = SCNetworkInterfaceGetBSDName(interface),
                  let type = SCNetworkInterfaceGetInterfaceType(interface)
            else { continue }
            let bsdName = bsdNameValue as String
            if CFEqual(type, kSCNetworkInterfaceTypeIEEE80211) {
                result[bsdName] = .wifi
            } else if CFEqual(type, kSCNetworkInterfaceTypeEthernet) {
                result[bsdName] = .ethernet
            }
        }
        return result
    }

    static func pathKind(
        for interface: LocalInterface,
        hardwareKinds: [String: TBConnectionPathKind]
    ) -> TBConnectionPathKind? {
        if interface.name.hasPrefix("bridge"), isIPv4LinkLocal(interface.ip) {
            return .thunderbolt
        }
        if isDirectLinkInterface(name: interface.name, ip: interface.ip) {
            return .usb
        }
        if hardwareKinds[interface.name] == .wifi, isPrivateIPv4(interface.ip) {
            return .wifi
        }
        if hardwareKinds[interface.name] == .ethernet, isPrivateIPv4(interface.ip) {
            return .ethernet
        }
        // Some third-party USB Ethernet adapters are absent from the SC inventory.
        if (interface.name.hasPrefix("en") || interface.name.hasPrefix("eth")), isPrivateIPv4(interface.ip) {
            return .ethernet
        }
        return nil
    }

    /// Builds every plausible local/remote pair. Real probing decides which pair
    /// is alive; a cable type is never presumed to be faster merely from its name.
    static func connectionCandidates(
        receiver: TBDiscoveredReceiver,
        interfaces: [LocalInterface],
        hardwareKinds: [String: TBConnectionPathKind]
    ) -> [TBConnectionCandidate] {
        let allReceiverIPs = uniqueIPv4Addresses([
            receiver.thunderboltIP,
            receiver.usbIP,
            receiver.ethernetIP,
            receiver.wifiIP,
            receiver.networkIP,
            receiver.preferredIP,
        ] + receiver.resolvedIPv4Addresses)

        var candidates: [TBConnectionCandidate] = []
        var seen = Set<String>()
        for interface in interfaces {
            guard let kind = pathKind(for: interface, hardwareKinds: hardwareKinds) else { continue }
            let explicitIP: String
            switch kind {
            case .thunderbolt: explicitIP = receiver.thunderboltIP
            case .usb: explicitIP = receiver.usbIP
            case .ethernet: explicitIP = receiver.ethernetIP
            case .wifi: explicitIP = receiver.wifiIP
            }

            let addressPool: [String]
            if kind == .thunderbolt || kind == .usb {
                addressPool = uniqueIPv4Addresses([explicitIP] + allReceiverIPs.filter(isIPv4LinkLocal))
            } else {
                let privateAddresses = allReceiverIPs.filter(isPrivateIPv4)
                let sameSubnet = privateAddresses.filter { likelySameIPv4Subnet(interface.ip, $0) }
                // Prefer a same-/24 endpoint. If Bonjour only exposes a different
                // subnet, retain it as a probe candidate so routed LANs still work.
                addressPool = uniqueIPv4Addresses(
                    [explicitIP] + (sameSubnet.isEmpty ? privateAddresses : sameSubnet)
                )
            }

            for receiverIP in addressPool where receiverIP != interface.ip {
                let candidate = TBConnectionCandidate(
                    kind: kind,
                    localInterfaceName: interface.name,
                    localIP: interface.ip,
                    receiverIP: receiverIP
                )
                if seen.insert(candidate.id).inserted {
                    candidates.append(candidate)
                }
            }
        }

        return candidates.sorted {
            if $0.kind.tieBreakPriority != $1.kind.tieBreakPriority {
                return $0.kind.tieBreakPriority > $1.kind.tieBreakPriority
            }
            if $0.localInterfaceName != $1.localInterfaceName {
                return $0.localInterfaceName < $1.localInterfaceName
            }
            return $0.receiverIP < $1.receiverIP
        }
    }

    static func selectBestMeasurement(
        _ measurements: [TBConnectionMeasurement],
        preference: TBConnectionPathPreference
    ) -> TBConnectionMeasurement? {
        let eligible: [TBConnectionMeasurement]
        eligible = measurements.filter { preference.allows($0.candidate.kind) }
        guard let fastest = eligible.max(by: { $0.throughputGbps < $1.throughputGbps }) else { return nil }

        // Results within 10% are effectively tied for a short startup probe.
        // In that narrow band prefer lower latency, then the more direct medium.
        let competitive = eligible.filter {
            $0.throughputGbps >= fastest.throughputGbps * 0.90
        }
        return competitive.sorted {
            let latencyDifference = abs($0.connectLatencyMilliseconds - $1.connectLatencyMilliseconds)
            if latencyDifference > 0.25 {
                return $0.connectLatencyMilliseconds < $1.connectLatencyMilliseconds
            }
            if $0.candidate.kind.tieBreakPriority != $1.candidate.kind.tieBreakPriority {
                return $0.candidate.kind.tieBreakPriority > $1.candidate.kind.tieBreakPriority
            }
            return $0.throughputGbps > $1.throughputGbps
        }.first
    }

    /// Sends a bounded stream of protocol-valid TEST_DATA packets through one
    /// explicitly bound interface. The receiver already discards this packet
    /// type, so the probe measures the real path without starting video capture.
    static func probe(
        _ candidate: TBConnectionCandidate,
        port: UInt16 = TBMonitorProtocol.port,
        payloadBytes: Int = 16 * 1024 * 1024,
        timeout: TimeInterval = 3.0
    ) throws -> TBConnectionMeasurement {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw socketError("socket") }
        defer { Darwin.close(fd) }

        var noSignal: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal))) == 0 else {
            throw socketError("setsockopt(SO_NOSIGPIPE)")
        }

        let interfaceIndex = if_nametoindex(candidate.localInterfaceName)
        guard interfaceIndex != 0 else { throw TBConnectionProbeError.interfaceUnavailable(candidate.localInterfaceName) }
        var boundIndex = interfaceIndex
        guard setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &boundIndex, socklen_t(MemoryLayout.size(ofValue: boundIndex))) == 0 else {
            throw socketError("setsockopt(IP_BOUND_IF)")
        }

        var localAddress = try socketAddress(ip: candidate.localIP, port: 0)
        let bindResult = withUnsafePointer(to: &localAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw socketError("bind") }

        let originalFlags = fcntl(fd, F_GETFL, 0)
        guard originalFlags >= 0, fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK) == 0 else {
            throw socketError("fcntl")
        }

        var remoteAddress = try socketAddress(ip: candidate.receiverIP, port: port)
        let connectStarted = DispatchTime.now().uptimeNanoseconds
        let connectResult = withUnsafePointer(to: &remoteAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connectResult != 0 {
            guard errno == EINPROGRESS else { throw socketError("connect") }
            try waitForSocket(fd, events: Int16(POLLOUT), timeout: timeout)
            var socketStatus: Int32 = 0
            var socketStatusLength = socklen_t(MemoryLayout.size(ofValue: socketStatus))
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketStatus, &socketStatusLength) == 0 else {
                throw socketError("getsockopt(SO_ERROR)")
            }
            guard socketStatus == 0 else {
                throw TBConnectionProbeError.socketFailure("connect: \(String(cString: strerror(socketStatus)))")
            }
        }
        let connectedAt = DispatchTime.now().uptimeNanoseconds

        let chunkBytes = min(256 * 1024, max(1, payloadBytes))
        let payload = Data(repeating: 0xA5, count: chunkBytes)
        let fullPacket = TBMonitorProtocol.makePacket(type: .testData, payload: payload)
        let sendStarted = DispatchTime.now().uptimeNanoseconds
        let deadline = sendStarted + UInt64(timeout * 1_000_000_000)
        var sentPayloadBytes = 0

        while sentPayloadBytes < payloadBytes {
            let remaining = payloadBytes - sentPayloadBytes
            let packet = remaining >= chunkBytes
                ? fullPacket
                : TBMonitorProtocol.makePacket(type: .testData, payload: Data(repeating: 0xA5, count: remaining))
            try sendAll(packet, socket: fd, deadline: deadline)
            sentPayloadBytes += min(chunkBytes, remaining)
        }
        let finishedAt = DispatchTime.now().uptimeNanoseconds
        let sendSeconds = max(Double(finishedAt - sendStarted) / 1_000_000_000.0, 0.000_001)
        let throughput = (Double(sentPayloadBytes) * 8.0) / 1_000_000_000.0 / sendSeconds
        let latency = Double(connectedAt - connectStarted) / 1_000_000.0
        return TBConnectionMeasurement(
            candidate: candidate,
            throughputGbps: throughput,
            connectLatencyMilliseconds: latency
        )
    }

    private static func uniqueIPv4Addresses(_ values: [String]) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for value in values where ipv4Octets(value) != nil && seen.insert(value).inserted {
            result.append(value)
        }
        return result
    }

    private static func likelySameIPv4Subnet(_ lhs: String, _ rhs: String) -> Bool {
        guard let left = ipv4Octets(lhs), let right = ipv4Octets(rhs) else { return false }
        return left[0] == right[0] && left[1] == right[1] && left[2] == right[2]
    }

    private static func socketAddress(ip: String, port: UInt16) throws -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard ip.withCString({ inet_pton(AF_INET, $0, &address.sin_addr) }) == 1 else {
            throw TBConnectionProbeError.invalidAddress(ip)
        }
        return address
    }

    private static func waitForSocket(_ fd: Int32, events: Int16, timeout: TimeInterval) throws {
        var descriptor = pollfd(fd: fd, events: events, revents: 0)
        let milliseconds = Int32(max(1, min(timeout * 1000.0, Double(Int32.max))))
        while true {
            let result = Darwin.poll(&descriptor, 1, milliseconds)
            if result > 0 {
                guard (descriptor.revents & (Int16(POLLERR) | Int16(POLLHUP) | Int16(POLLNVAL))) == 0 else {
                    throw TBConnectionProbeError.socketFailure("socket became unavailable")
                }
                return
            }
            if result == 0 { throw TBConnectionProbeError.timeout }
            if errno != EINTR { throw socketError("poll") }
        }
    }

    private static func sendAll(_ data: Data, socket fd: Int32, deadline: UInt64) throws {
        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let now = DispatchTime.now().uptimeNanoseconds
                if now >= deadline {
                    throw TBConnectionProbeError.timeout
                }
                let sent = Darwin.send(fd, baseAddress.advanced(by: offset), buffer.count - offset, 0)
                if sent > 0 {
                    offset += sent
                } else if sent < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    let waitStarted = DispatchTime.now().uptimeNanoseconds
                    guard waitStarted < deadline else { throw TBConnectionProbeError.timeout }
                    let remainingSeconds = Double(deadline - waitStarted) / 1_000_000_000.0
                    try waitForSocket(fd, events: Int16(POLLOUT), timeout: max(0.001, remainingSeconds))
                } else if sent < 0 && errno == EINTR {
                    continue
                } else {
                    throw socketError("send")
                }
            }
        }
    }

    private static func socketError(_ operation: String) -> TBConnectionProbeError {
        TBConnectionProbeError.socketFailure("\(operation): \(String(cString: strerror(errno)))")
    }

    /// For a link-local (`169.254.x`) receiver reached through bridgeX,
    /// returns `"<ip>%<interface>"` so the Thunderbolt dial is scoped to the
    /// interface that owns `localIP`. Direct USB-NCM enX links remain
    /// unscoped: macOS installs a host route for the USB peer and Network.framework
    /// does not reliably accept an IPv4 `%enX` zone suffix.
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
        guard name.hasPrefix("bridge") else { return receiverIP }
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
