import Combine
import Foundation

enum TBTransportKind: String, CaseIterable, Identifiable {
    case thunderboltBridge
    case networkLink

    var id: String { rawValue }

    func title(_ language: TBDisplaySenderLanguage) -> String {
        switch (self, language) {
        case (.thunderboltBridge, .italian): return "Thunderbolt Bridge"
        case (.thunderboltBridge, .english): return "Thunderbolt Bridge"
        case (.thunderboltBridge, .german): return "Thunderbolt Bridge"
        case (.networkLink, .italian): return "Network Link (sperimentale)"
        case (.networkLink, .english): return "Network Link (experimental)"
        case (.networkLink, .german): return "Network Link (experimentell)"
        }
    }
}

struct TBLocalLinkInterface: Identifiable, Hashable {
    let name: String
    let ip: String
    let transportKind: TBTransportKind

    var id: String { "\(transportKind.rawValue)|\(name)|\(ip)" }

    func displayText(_ language: TBDisplaySenderLanguage) -> String {
        "\(name) · \(ip) · \(transportKind.title(language))"
    }
}

@MainActor
final class TBDisplaySenderService: ObservableObject {
    static let shared = TBDisplaySenderService()

    @Published var sessions: [TBDisplaySenderSession] = []
    @Published private(set) var localInterfaces: [TBLocalLinkInterface] = []
    @Published private(set) var discoveredReceivers: [TBDiscoveredReceiver] = []
    @Published var language: TBDisplaySenderLanguage = .load() {
        didSet {
            language.persist()
            sessions.forEach { $0.language = language }
            objectWillChange.send()
        }
    }
    @Published var showsMenuBarIcon = true
    @Published var largeCursor: Bool = UserDefaults.standard.bool(forKey: "fd.tbdisplaysender.largeCursor") {
        didSet {
            UserDefaults.standard.set(largeCursor, forKey: "fd.tbdisplaysender.largeCursor")
            sessions.forEach { $0.largeCursor = largeCursor }
            objectWillChange.send()
        }
    }

    private var sessionCancellables: [UUID: AnyCancellable] = [:]
    private let receiverDiscovery = TBReceiverDiscovery()
    private var discoveryCancellable: AnyCancellable?

    private init() {
        discoveryCancellable = receiverDiscovery.$receivers.sink { [weak self] receivers in
            guard let self else { return }
            discoveredReceivers = receivers
            objectWillChange.send()
        }
        refreshLocalInterfaces()
        addSession()
    }

    var anyConnected: Bool {
        sessions.contains { $0.isConnected || $0.isStreaming }
    }

    var anyStreaming: Bool {
        sessions.contains { $0.isStreaming }
    }

    var connectedSessionCount: Int {
        sessions.reduce(into: 0) { count, session in
            if session.isConnected || session.isStreaming {
                count += 1
            }
        }
    }

    var localInterfaceSummaryText: String {
        guard !localInterfaces.isEmpty else {
            return TBDisplaySenderL10n.notDetected(language)
        }
        return localInterfaces
            .map { $0.displayText(language) }
            .joined(separator: "   ")
    }

    func addSession() {
        let session = TBDisplaySenderSession(language: language, largeCursor: largeCursor)
        if let previous = sessions.last {
            session.capturePreset = previous.capturePreset
            session.captureSource = previous.captureSource
            session.transportKind = previous.transportKind
        }
        if let suggestedInterface = suggestedInterfaceForNewSession(transportKind: session.transportKind) {
            session.localInterfaceIP = suggestedInterface.ip
        }
        attachSession(session)
        sessions.append(session)
        objectWillChange.send()
    }

    func removeSession(_ session: TBDisplaySenderSession) {
        guard sessions.count > 1 else { return }
        session.stop()
        sessions.removeAll { $0.id == session.id }
        sessionCancellables.removeValue(forKey: session.id)
        normalizeSessionInterfaces()
        objectWillChange.send()
    }

    func stopAll() {
        sessions.forEach { $0.persistExtendedDisplayArrangementSnapshot() }
        sessions.forEach { $0.stop(persistArrangement: false) }
    }

    func refreshLocalInterfaces() {
        localInterfaces = detectLocalInterfaces()
        receiverDiscovery.refresh()
        normalizeSessionInterfaces()
        objectWillChange.send()
    }

    func applyDiscoveredReceiver(_ receiver: TBDiscoveredReceiver, to session: TBDisplaySenderSession) {
        session.receiverIP = receiver.ip(for: session.transportKind)
        if session.localInterfaceIP.isEmpty {
            session.localInterfaceIP = suggestedInterfaceForNewSession(transportKind: session.transportKind)?.ip
                ?? availableInterfaces(for: session.transportKind).first?.ip
                ?? ""
        }
        objectWillChange.send()
    }

    func sessionTitle(for session: TBDisplaySenderSession) -> String {
        let index = sessions.firstIndex(where: { $0.id == session.id }).map { $0 + 1 } ?? 0
        return TBDisplaySenderL10n.sessionTitle(language, index: index)
    }

    func interfaceDisplayText(for ip: String) -> String {
        localInterfaces.first(where: { $0.ip == ip })?.displayText(language) ?? ip
    }

    func availableInterfaces(for transportKind: TBTransportKind) -> [TBLocalLinkInterface] {
        localInterfaces.filter { $0.transportKind == transportKind }
    }

    func defaultLocalInterfaceIP(for transportKind: TBTransportKind) -> String {
        suggestedInterfaceForNewSession(transportKind: transportKind)?.ip
            ?? availableInterfaces(for: transportKind).first?.ip
            ?? ""
    }

    func transportDidChange(for session: TBDisplaySenderSession) {
        session.localInterfaceIP = defaultLocalInterfaceIP(for: session.transportKind)
        if let receiver = discoveredReceivers.first(where: { $0.id == session.selectedReceiverID }) {
            session.receiverIP = receiver.ip(for: session.transportKind)
        }
        objectWillChange.send()
    }

    func summaryStatusText() -> String {
        if anyStreaming {
            return TBDisplaySenderL10n.multiSessionSummaryStreaming(language, active: connectedSessionCount, total: sessions.count)
        }
        if anyConnected {
            return TBDisplaySenderL10n.multiSessionSummaryConnected(language, active: connectedSessionCount, total: sessions.count)
        }
        return TBDisplaySenderStatusState.ready.text(language)
    }

    private func attachSession(_ session: TBDisplaySenderSession) {
        sessionCancellables[session.id] = session.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    private func suggestedInterfaceForNewSession(transportKind: TBTransportKind) -> TBLocalLinkInterface? {
        let candidates = availableInterfaces(for: transportKind)
        let usedIPs = Set(
            sessions
                .filter { $0.transportKind == transportKind }
                .map(\.localInterfaceIP)
                .filter { !$0.isEmpty }
        )
        return candidates.first(where: { !usedIPs.contains($0.ip) }) ?? candidates.first
    }

    private func normalizeSessionInterfaces() {
        for session in sessions {
            let available = availableInterfaces(for: session.transportKind)
            let validIPs = Set(available.map(\.ip))
            let fallbackIP = suggestedInterfaceForNewSession(transportKind: session.transportKind)?.ip
                ?? available.first?.ip
                ?? ""
            if session.localInterfaceIP.isEmpty || !validIPs.contains(session.localInterfaceIP) {
                session.localInterfaceIP = fallbackIP
            }
        }
    }

    private func detectLocalInterfaces() -> [TBLocalLinkInterface] {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return [] }
        defer { freeifaddrs(ifaddr) }

        var interfaces: [TBLocalLinkInterface] = []
        var pointer = ifaddr
        while let iface = pointer {
            defer { pointer = iface.pointee.ifa_next }
            guard let sa = iface.pointee.ifa_addr,
                  sa.pointee.sa_family == UInt8(AF_INET)
            else { continue }
            let name = String(cString: iface.pointee.ifa_name)
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
            let ip = String(cString: buffer)
            if name.hasPrefix("bridge"), ip.hasPrefix("169.254.") {
                interfaces.append(TBLocalLinkInterface(name: name, ip: ip, transportKind: .thunderboltBridge))
                continue
            }

            guard isLikelyLocalNetworkInterfaceName(name),
                  isLikelyLANIPv4(ip)
            else { continue }

            interfaces.append(TBLocalLinkInterface(name: name, ip: ip, transportKind: .networkLink))
        }

        return interfaces.sorted {
            if $0.transportKind == $1.transportKind, $0.name == $1.name {
                return $0.ip < $1.ip
            }
            if $0.transportKind == $1.transportKind {
                return $0.name < $1.name
            }
            return $0.transportKind.rawValue < $1.transportKind.rawValue
        }
    }

    private func isLikelyLocalNetworkInterfaceName(_ name: String) -> Bool {
        if name.hasPrefix("lo") || name.hasPrefix("utun") || name.hasPrefix("awdl") || name.hasPrefix("llw") {
            return false
        }
        return name.hasPrefix("en")
            || name.hasPrefix("eth")
            || name.hasPrefix("bridge")
    }

    private func isLikelyLANIPv4(_ ip: String) -> Bool {
        if ip.hasPrefix("169.254.") || ip.hasPrefix("127.") {
            return false
        }
        if ip.hasPrefix("10.") || ip.hasPrefix("192.168.") {
            return true
        }
        let components = ip.split(separator: ".")
        guard components.count == 4,
              let first = Int(components[0]),
              let second = Int(components[1])
        else {
            return false
        }
        return first == 172 && (16...31).contains(second)
    }
}
