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
        }
    }
    @Published var showsMenuBarIcon = true
    @Published var largeCursor: Bool = UserDefaults.standard.bool(forKey: "fd.tbdisplaysender.largeCursor") {
        didSet {
            UserDefaults.standard.set(largeCursor, forKey: "fd.tbdisplaysender.largeCursor")
            sessions.forEach { $0.largeCursor = largeCursor }
        }
    }
    @Published var preventDisplaySleep: Bool = UserDefaults.standard.bool(forKey: "fd.tbdisplaysender.preventDisplaySleep") {
        didSet {
            UserDefaults.standard.set(preventDisplaySleep, forKey: "fd.tbdisplaysender.preventDisplaySleep")
            sessions.forEach { $0.preventDisplaySleep = preventDisplaySleep }
        }
    }
    @Published var autoRestartOnWake: Bool = UserDefaults.standard.bool(forKey: "fd.tbdisplaysender.autoRestartOnWake") {
        didSet {
            UserDefaults.standard.set(autoRestartOnWake, forKey: "fd.tbdisplaysender.autoRestartOnWake")
            sessions.forEach { $0.autoRestartOnWake = autoRestartOnWake }
        }
    }
    @Published var verboseDisplayLogging: Bool = UserDefaults.standard.bool(forKey: "fd.tbdisplaysender.verboseDisplayLogging") {
        didSet {
            UserDefaults.standard.set(verboseDisplayLogging, forKey: "fd.tbdisplaysender.verboseDisplayLogging")
            sessions.forEach { $0.verboseDisplayLogging = verboseDisplayLogging }
        }
    }

    /// Software-KVM: when on, the sender's keyboard/mouse drive the receiver's
    /// native desktop. Transient (never persisted — must be re-armed each launch).
    @Published var controlIMacKVM: Bool = false {
        didSet {
            guard controlIMacKVM != oldValue else { return }
            if controlIMacKVM { enableKVM() } else { disableKVM() }
        }
    }

    /// KVM can only be engaged while a session is connected.
    var canControlIMac: Bool { sessions.contains { $0.isConnected } }

    private func enableKVM() {
        guard let session = sessions.first(where: { $0.isConnected }) else {
            controlIMacKVM = false   // nothing to control
            return
        }
        let started = session.beginKVM(onForceDeactivate: { [weak self] in
            // Escape hotkey or a failsafe fired on the tap — reflect it in the UI,
            // which routes back through disableKVM().
            self?.controlIMacKVM = false
        })
        if !started {
            controlIMacKVM = false   // not connected, or Accessibility denied
        }
    }

    private func disableKVM() {
        sessions.forEach { $0.endKVM() }
    }

    private var sessionCancellables: [UUID: AnyCancellable] = [:]
    private let receiverDiscovery = TBReceiverDiscovery()
    private var discoveryCancellable: AnyCancellable?

    private init() {
        discoveryCancellable = receiverDiscovery.$receivers.sink { [weak self] receivers in
            guard let self else { return }
            discoveredReceivers = receivers
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
        let session = TBDisplaySenderSession(
            language: language,
            largeCursor: largeCursor,
            preventDisplaySleep: preventDisplaySleep,
            autoRestartOnWake: autoRestartOnWake,
            verboseDisplayLogging: verboseDisplayLogging
        )
        if let previous = sessions.last {
            session.capturePreset = previous.capturePreset
            session.captureSource = previous.captureSource
        }
        if let suggestedInterface = suggestedInterfaceForNewSession() {
            session.localTBIP = suggestedInterface.ip
        }
        attachSession(session)
        sessions.append(session)
    }

    func removeSession(_ session: TBDisplaySenderSession) {
        guard sessions.count > 1 else { return }
        session.stop()
        sessions.removeAll { $0.id == session.id }
        sessionCancellables.removeValue(forKey: session.id)
        normalizeSessionInterfaces()
    }

    func stopAll() {
        sessions.forEach { $0.persistExtendedDisplayArrangementSnapshot() }
        sessions.forEach { $0.stop(persistArrangement: false) }
    }

    func refreshBridgeInterfaces() {
        bridgeInterfaces = detectBridgeInterfaces()
        receiverDiscovery.refresh()
        normalizeSessionInterfaces()
    }

    func applyDiscoveredReceiver(_ receiver: TBDiscoveredReceiver, to session: TBDisplaySenderSession) {
        session.receiverIP = receiver.receiverIP
        if session.localTBIP.isEmpty {
            session.localTBIP = suggestedInterfaceForNewSession()?.ip ?? bridgeInterfaces.first?.ip ?? ""
        }
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
