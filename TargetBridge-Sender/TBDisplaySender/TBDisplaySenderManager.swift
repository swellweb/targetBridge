import AppKit
import ApplicationServices
import Combine
import Foundation
import Network

enum TBTransportKind: String, CaseIterable, Identifiable {
    case thunderboltBridge
    case networkLink

    var id: String { rawValue }

    func title(_ language: TBDisplaySenderLanguage) -> String {
        switch (self, language) {
        case (.thunderboltBridge, .italian): return "Thunderbolt Bridge"
        case (.thunderboltBridge, .english): return "Thunderbolt Bridge"
        case (.thunderboltBridge, .german): return "Thunderbolt Bridge"
        case (.thunderboltBridge, .chinese): return "Thunderbolt Bridge"
        case (.networkLink, .italian): return "Network Link (sperimentale)"
        case (.networkLink, .english): return "Network Link (experimental)"
        case (.networkLink, .german): return "Network Link (experimentell)"
        case (.networkLink, .chinese): return "Network Link（实验性）"
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
    @Published private(set) var addons: [TBAddonRecord] = []
    @Published var language: TBDisplaySenderLanguage = .load() {
        didSet {
            language.persist()
            sessions.forEach { $0.language = language }
            pushLanguageUpdateToDiscoveredReceivers()
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
    @Published var preventDisplaySleep: Bool = {
        if UserDefaults.standard.object(forKey: "fd.tbdisplaysender.preventDisplaySleep") == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: "fd.tbdisplaysender.preventDisplaySleep")
    }() {
        didSet {
            UserDefaults.standard.set(preventDisplaySleep, forKey: "fd.tbdisplaysender.preventDisplaySleep")
            sessions.forEach { $0.preventDisplaySleep = preventDisplaySleep }
            objectWillChange.send()
        }
    }
    @Published var autoRestartOnWake: Bool = {
        if UserDefaults.standard.object(forKey: "fd.tbdisplaysender.autoRestartOnWake") == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: "fd.tbdisplaysender.autoRestartOnWake")
    }() {
        didSet {
            UserDefaults.standard.set(autoRestartOnWake, forKey: "fd.tbdisplaysender.autoRestartOnWake")
            sessions.forEach { $0.autoRestartOnWake = autoRestartOnWake }
            objectWillChange.send()
        }
    }
    @Published var verboseDisplayLogging: Bool = UserDefaults.standard.bool(forKey: "fd.tbdisplaysender.verboseDisplayLogging") {
        didSet {
            UserDefaults.standard.set(verboseDisplayLogging, forKey: "fd.tbdisplaysender.verboseDisplayLogging")
            sessions.forEach { $0.verboseDisplayLogging = verboseDisplayLogging }
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
    private let addonStore = TBAddonStore.shared
    private let inputRelayController = TBInputRelayController()
    private var discoveryCancellable: AnyCancellable?
    private var addonCancellable: AnyCancellable?
    private var clipboardTimer: Timer?
    private var lastClipboardChangeCount: Int = NSPasteboard.general.changeCount

    private init() {
        discoveryCancellable = receiverDiscovery.$receivers.sink { [weak self] receivers in
            guard let self else { return }
            discoveredReceivers = receivers
            pushLanguageUpdateToDiscoveredReceivers()
            objectWillChange.send()
        }
        addonCancellable = addonStore.$addons.sink { [weak self] addons in
            guard let self else { return }
            self.addons = addons
            normalizeAddonState()
            objectWillChange.send()
        }
        refreshLocalInterfaces()
        addonStore.refresh()
        restorePersistedSessions()
        startClipboardMonitoring()
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

    var availableTransportKinds: [TBTransportKind] {
        TBTransportKind.allCases.filter { transportKind in
            switch transportKind {
            case .thunderboltBridge:
                return true
            case .networkLink:
                return isAddonCapabilityEnabled(.networkLink)
            }
        }
    }

    var audioRelayAvailable: Bool {
        isAddonCapabilityEnabled(.audioRelay)
    }

    var inputDockstationAvailable: Bool {
        isAddonCapabilityEnabled(.inputDockstation)
    }

    var localInputInjectionTrusted: Bool {
        AXIsProcessTrusted()
    }

    var localInputMonitoringTrusted: Bool {
        CGPreflightListenEventAccess()
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func openInputMonitoringSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func addSession() {
        let session = TBDisplaySenderSession(
            language: language,
            largeCursor: largeCursor,
            preventDisplaySleep: preventDisplaySleep,
            autoRestartOnWake: autoRestartOnWake,
            audioEnabled: audioEnabled && audioRelayAvailable,
            verboseDisplayLogging: verboseDisplayLogging
        )
        if let previous = sessions.last {
            session.capturePreset = previous.capturePreset
            session.captureSource = previous.captureSource
            session.transportKind = previous.transportKind
            session.audioEnabled = audioRelayAvailable && previous.audioEnabled
            session.inputGestureMode = previous.inputGestureMode
        }
        session.audioAddonAvailable = audioRelayAvailable
        if let suggestedInterface = suggestedInterfaceForNewSession(transportKind: session.transportKind) {
            session.localInterfaceIP = suggestedInterface.ip
        }
        attachSession(session)
        sessions.append(session)
        schedulePersist()
        objectWillChange.send()
    }

    func removeSession(_ session: TBDisplaySenderSession) {
        guard sessions.count > 1 else { return }
        session.stop()
        sessions.removeAll { $0.id == session.id }
        sessionCancellables.removeValue(forKey: session.id)
        normalizeAddonState()
        normalizeSessionInterfaces()
        schedulePersist()
        objectWillChange.send()
    }

    func stopAll() {
        sessions.forEach { $0.persistExtendedDisplayArrangementSnapshot() }
        sessions.forEach { $0.stop(persistArrangement: false) }
    }

    // MARK: - Session persistence

    private static let persistedSessionsKey = "fd.tbdisplaysender.sessions.v1"

    /// Snapshot of the user-configurable settings for a single session. Runtime
    /// state (connection, input master role, FPS, …) is intentionally excluded —
    /// only the choices the user makes in the UI are remembered across launches.
    private struct PersistedSession: Codable {
        var transportKind: String
        var localInterfaceIP: String
        var receiverIP: String
        var selectedReceiverID: String
        var capturePreset: String
        var captureSource: String
        var audioEnabled: Bool
        var brightness: Double
        var inputGestureMode: String
        var volume: Double?
    }

    private var lastPersistedData: Data?
    private var persistScheduled = false

    /// Coalesces the many synchronous `objectWillChange` notifications a single
    /// user action produces into one write. Runs on the next main-loop tick, so
    /// it observes the post-change values rather than the pre-change ones that
    /// `objectWillChange` fires with.
    private func schedulePersist() {
        guard !persistScheduled else { return }
        persistScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.persistScheduled = false
            self.persistSessions()
        }
    }

    private func persistSessions() {
        let configs = sessions.map { session in
            PersistedSession(
                transportKind: session.transportKind.rawValue,
                localInterfaceIP: session.localInterfaceIP,
                receiverIP: session.receiverIP,
                selectedReceiverID: session.selectedReceiverID,
                capturePreset: session.capturePreset.rawValue,
                captureSource: session.captureSource.rawValue,
                audioEnabled: session.audioEnabled,
                brightness: session.brightness,
                inputGestureMode: session.inputGestureMode.rawValue,
                volume: session.volume
            )
        }
        guard let data = try? JSONEncoder().encode(configs) else { return }
        // Streaming churns `objectWillChange` constantly; skip redundant writes.
        guard data != lastPersistedData else { return }
        lastPersistedData = data
        UserDefaults.standard.set(data, forKey: Self.persistedSessionsKey)
    }

    private func restorePersistedSessions() {
        guard let data = UserDefaults.standard.data(forKey: Self.persistedSessionsKey),
              let configs = try? JSONDecoder().decode([PersistedSession].self, from: data),
              !configs.isEmpty
        else {
            addSession()
            return
        }

        lastPersistedData = data
        for config in configs {
            let session = TBDisplaySenderSession(
                language: language,
                largeCursor: largeCursor,
                preventDisplaySleep: preventDisplaySleep,
                autoRestartOnWake: autoRestartOnWake,
                audioEnabled: audioEnabled && audioRelayAvailable,
                verboseDisplayLogging: verboseDisplayLogging
            )
            apply(config, to: session)
            session.audioAddonAvailable = audioRelayAvailable
            attachSession(session)
            sessions.append(session)
        }
        // Drop transports/audio for addons that are no longer enabled and make
        // sure every restored interface still exists on this machine.
        normalizeAddonState()
        normalizeSessionInterfaces()
        objectWillChange.send()
    }

    private func apply(_ config: PersistedSession, to session: TBDisplaySenderSession) {
        if let transport = TBTransportKind(rawValue: config.transportKind) {
            session.transportKind = transport
        }
        if let preset = TBDisplayCapturePreset(rawValue: config.capturePreset) {
            session.capturePreset = preset
        }
        if let source = TBDisplayCaptureSource(rawValue: config.captureSource) {
            session.captureSource = source
        }
        if let gesture = TBInputGestureMode(rawValue: config.inputGestureMode) {
            session.inputGestureMode = gesture
        }
        session.receiverIP = config.receiverIP
        session.selectedReceiverID = config.selectedReceiverID
        session.localInterfaceIP = config.localInterfaceIP
        session.audioEnabled = config.audioEnabled && audioRelayAvailable
        session.brightness = config.brightness
        session.volume = config.volume ?? 0.5
    }

    func refreshLocalInterfaces() {
        localInterfaces = detectLocalInterfaces()
        receiverDiscovery.refresh()
        normalizeSessionInterfaces()
        objectWillChange.send()
    }

    func applyDiscoveredReceiver(_ receiver: TBDiscoveredReceiver, to session: TBDisplaySenderSession) {
        session.receiverIP = receiver.ip(for: session.transportKind)
        session.receiverSupportsHEVCDecodeHint = receiver.supportsHEVCDecode
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

    func refreshAddons() {
        addonStore.refresh()
    }

    func openAddonsFolder() {
        addonStore.openAddonsFolder()
    }

    func importAddonManifest(from url: URL) throws {
        _ = try addonStore.importManifest(from: url)
        normalizeAddonState()
    }

    func isAddonEnabled(_ addon: TBAddonRecord) -> Bool {
        addonStore.isEnabled(addon)
    }

    func setAddonEnabled(_ enabled: Bool, for addon: TBAddonRecord) {
        addonStore.setEnabled(enabled, for: addon)
        normalizeAddonState()
    }

    func isAddonCompatible(_ addon: TBAddonRecord) -> Bool {
        addonStore.isCompatible(addon)
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
        session.audioAddonAvailable = audioRelayAvailable
        session.onRemoteSwitchRequest = { [weak self, weak session] direction in
            guard let self, let session else { return }
            self.switchReceiverMasterTarget(from: session, direction: direction)
        }
        session.onRemoteDeactivateInputRequest = { [weak self, weak session] in
            guard let self, let session else { return }
            self.setInputControlRole(.off, for: session)
        }
        sessionCancellables[session.id] = session.objectWillChange.sink { [weak self] _ in
            self?.updateInputRelayController()
            self?.schedulePersist()
            self?.objectWillChange.send()
        }
    }

    func isInputRelayActive(for session: TBDisplaySenderSession) -> Bool {
        session.inputControlRole != .off
    }

    func setInputControlRole(_ role: TBInputControlRole, for session: TBDisplaySenderSession) {
        for candidate in sessions {
            if candidate.id == session.id {
                candidate.inputControlRole = role
            } else if role != .off {
                candidate.inputControlRole = .off
            }
        }
        updateInputRelayController()
        sessions.forEach { $0.updateInputControlMode() }
        objectWillChange.send()
    }

    func switchSenderMasterTarget(direction: Int) {
        let connected = sessions.filter { $0.isConnected || $0.isStreaming }
        guard connected.count > 1,
              let current = connected.first(where: { $0.inputControlRole == .senderMaster }),
              let currentIndex = connected.firstIndex(where: { $0.id == current.id })
        else {
            return
        }

        let nextIndex = (currentIndex + (direction >= 0 ? 1 : connected.count - 1)) % connected.count
        let next = connected[nextIndex]
        guard next.id != current.id else { return }

        for candidate in sessions {
            candidate.inputControlRole = (candidate.id == next.id) ? .senderMaster : .off
        }
        updateInputRelayController()
        sessions.forEach { $0.updateInputControlMode() }
        objectWillChange.send()
    }

    func switchReceiverMasterTarget(from session: TBDisplaySenderSession, direction: Int) {
        let connected = sessions.filter { $0.isConnected || $0.isStreaming }
        guard connected.count > 1,
              let currentIndex = connected.firstIndex(where: { $0.id == session.id })
        else {
            return
        }

        let nextIndex = (currentIndex + (direction >= 0 ? 1 : connected.count - 1)) % connected.count
        let next = connected[nextIndex]
        guard next.id != session.id else { return }

        for candidate in sessions {
            candidate.inputControlRole = (candidate.id == next.id) ? .receiverMaster : .off
        }
        updateInputRelayController()
        sessions.forEach { $0.updateInputControlMode() }
        objectWillChange.send()
    }

    private func isAddonCapabilityEnabled(_ capability: TBAddonCapability) -> Bool {
        addonStore.isCapabilityEnabled(capability)
    }

    private func normalizeAddonState() {
        let networkLinkEnabled = isAddonCapabilityEnabled(.networkLink)
        let audioEnabled = audioRelayAvailable
        let inputEnabled = inputDockstationAvailable

        for session in sessions {
            session.audioAddonAvailable = audioEnabled
            if !audioEnabled {
                session.audioEnabled = false
            }
            if !networkLinkEnabled, session.transportKind == .networkLink {
                session.transportKind = .thunderboltBridge
            }
            if !inputEnabled {
                session.inputControlRole = .off
                session.inputGestureMode = .native
            }
        }

        normalizeSessionInterfaces()
        updateInputRelayController()
        sessions.forEach { $0.updateInputControlMode() }
    }

    private func updateInputRelayController() {
        guard inputDockstationAvailable,
              let session = sessions.first(where: { $0.inputControlRole == .senderMaster })
        else {
            inputRelayController.stop()
            return
        }

        inputRelayController.start(
            gestureMode: session.inputGestureMode,
            handler: { [weak self] relayEvent in
                guard let self,
                      session.isConnected
                else { return }
                session.sendInputEvent(relayEvent)
            },
            switchHandler: { [weak self] direction in
                self?.switchSenderMasterTarget(direction: direction)
            },
            deactivateHandler: { [weak self, weak session] in
                guard let self, let session else { return }
                self.setInputControlRole(.off, for: session)
            }
        )
    }

    private func startClipboardMonitoring() {
        clipboardTimer?.invalidate()
        clipboardTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollClipboardIfNeeded()
            }
        }
    }

    private func pollClipboardIfNeeded() {
        guard let session = sessions.first(where: { $0.inputControlRole == .senderMaster && ($0.isConnected || $0.isStreaming) }) else {
            lastClipboardChangeCount = NSPasteboard.general.changeCount
            return
        }

        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastClipboardChangeCount else { return }
        lastClipboardChangeCount = pasteboard.changeCount

        guard let text = pasteboard.string(forType: .string) else { return }
        session.sendClipboardText(text)
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

    private func pushLanguageUpdateToDiscoveredReceivers() {
        let receivers = discoveredReceivers
        let languageCode = language.fileStem
        for receiver in receivers {
            let candidateIPs = [receiver.preferredIP, receiver.thunderboltIP, receiver.networkIP]
            var sentTo = Set<String>()
            for ip in candidateIPs where !ip.isEmpty && sentTo.insert(ip).inserted {
                sendLanguageUpdate(to: ip, languageCode: languageCode)
            }
        }
    }

    private func sendLanguageUpdate(to receiverIP: String, languageCode: String) {
        guard !receiverIP.isEmpty,
              let packet = TBMonitorProtocol.makeJSONPacket(
                type: .uiLanguage,
                value: TBMonitorUILanguageUpdate(uiLanguage: languageCode)
              )
        else { return }

        let connection = NWConnection(
            host: NWEndpoint.Host(receiverIP),
            port: NWEndpoint.Port(rawValue: TBMonitorProtocol.port)!,
            using: .tcp
        )

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: packet, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            case .failed, .cancelled:
                connection.cancel()
            default:
                break
            }
        }

        connection.start(queue: DispatchQueue.global(qos: .utility))
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
