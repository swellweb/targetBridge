import Combine
import Foundation

struct TBLocalBridgeInterface: Identifiable, Hashable {
    let name: String
    let ip: String

    var id: String { "\(name)|\(ip)" }
    var displayText: String { "\(name) · \(ip)" }
}

@MainActor
final class TBDisplaySenderService: ObservableObject {
    static let shared = TBDisplaySenderService()

    @Published var sessions: [TBDisplaySenderSession] = []
    @Published private(set) var bridgeInterfaces: [TBLocalBridgeInterface] = []
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
    @Published var audioEnabled: Bool = UserDefaults.standard.object(forKey: "fd.tbdisplaysender.audioEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(audioEnabled, forKey: "fd.tbdisplaysender.audioEnabled")
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
        refreshBridgeInterfaces()
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

    var bridgeSummaryText: String {
        guard !bridgeInterfaces.isEmpty else {
            return TBDisplaySenderL10n.notDetected(language)
        }
        return bridgeInterfaces.map(\.displayText).joined(separator: "   ")
    }

    func addSession() {
        let session = TBDisplaySenderSession(language: language, largeCursor: largeCursor, audioEnabled: audioEnabled)
        if let previous = sessions.last {
            session.capturePreset = previous.capturePreset
            session.captureSource = previous.captureSource
        }
        if let suggestedInterface = suggestedInterfaceForNewSession() {
            session.localTBIP = suggestedInterface.ip
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

    func refreshBridgeInterfaces() {
        bridgeInterfaces = detectBridgeInterfaces()
        receiverDiscovery.refresh()
        normalizeSessionInterfaces()
        objectWillChange.send()
    }

    func applyDiscoveredReceiver(_ receiver: TBDiscoveredReceiver, to session: TBDisplaySenderSession) {
        session.receiverIP = receiver.receiverIP
        if session.localTBIP.isEmpty {
            session.localTBIP = suggestedInterfaceForNewSession()?.ip ?? bridgeInterfaces.first?.ip ?? ""
        }
        objectWillChange.send()
    }

    func sessionTitle(for session: TBDisplaySenderSession) -> String {
        let index = sessions.firstIndex(where: { $0.id == session.id }).map { $0 + 1 } ?? 0
        return TBDisplaySenderL10n.sessionTitle(language, index: index)
    }

    func interfaceDisplayText(for ip: String) -> String {
        bridgeInterfaces.first(where: { $0.ip == ip })?.displayText ?? ip
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

    private func suggestedInterfaceForNewSession() -> TBLocalBridgeInterface? {
        let usedIPs = Set(sessions.map(\.localTBIP).filter { !$0.isEmpty })
        return bridgeInterfaces.first(where: { !usedIPs.contains($0.ip) }) ?? bridgeInterfaces.first
    }

    private func normalizeSessionInterfaces() {
        let validIPs = Set(bridgeInterfaces.map(\.ip))
        let fallbackIP = bridgeInterfaces.first?.ip ?? ""
        for session in sessions {
            if session.localTBIP.isEmpty || !validIPs.contains(session.localTBIP) {
                session.localTBIP = fallbackIP
            }
        }
    }

    private func detectBridgeInterfaces() -> [TBLocalBridgeInterface] {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return [] }
        defer { freeifaddrs(ifaddr) }

        var interfaces: [TBLocalBridgeInterface] = []
        var pointer = ifaddr
        while let iface = pointer {
            defer { pointer = iface.pointee.ifa_next }
            guard let sa = iface.pointee.ifa_addr,
                  sa.pointee.sa_family == UInt8(AF_INET)
            else { continue }
            let name = String(cString: iface.pointee.ifa_name)
            guard name.hasPrefix("bridge") else { continue }
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
            guard ip.hasPrefix("169.254.") else { continue }
            interfaces.append(TBLocalBridgeInterface(name: name, ip: ip))
        }

        return interfaces.sorted {
            if $0.name == $1.name {
                return $0.ip < $1.ip
            }
            return $0.name < $1.name
        }
    }
}
