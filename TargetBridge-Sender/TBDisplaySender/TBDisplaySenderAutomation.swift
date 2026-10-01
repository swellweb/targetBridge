import AppKit
import Foundation

// Sender-side automation entry points.
//
// Lets the Sender be driven for scripting / SSH / login & wake automation WITHOUT a
// separate control daemon: it reuses the existing TBDisplaySenderService / session model.
//
// Two equivalent ways in:
//   • URL scheme:   open "targetbridge://connect?receiver=auto&mode=mirror&preset=native5k"
//                   open "targetbridge://disconnect"
//   • Launch args:  TargetBridge --connect --receiver auto --mode mirror --preset native5k
//                   (handy for a login item / LaunchAgent that should connect on launch)
//
// Both resolve to the same in-process actions on TBDisplaySenderService.shared, so there is
// no parallel connection logic — connect()/stop() are the same paths the GUI uses.
@MainActor
enum TBSenderAutomation {
    private static var didHandleLaunchArguments = false
    private static var continuousConnectTask: Task<Void, Never>?

    static func senderEnabledFlagURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support/TargetBridge/Sender", isDirectory: true)
            .appendingPathComponent("enabled", isDirectory: false)
    }

    static func suspendAutomaticReconnectAfterUserStop(
        enabledFlagURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        suspendAutomaticReconnect(
            enabledFlagURL: enabledFlagURL,
            fileManager: fileManager,
            logReason: "user stopped session"
        )
    }

    static func suspendAutomaticReconnectForRequiredPermission(
        enabledFlagURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        suspendAutomaticReconnect(
            enabledFlagURL: enabledFlagURL,
            fileManager: fileManager,
            logReason: "screen recording permission required"
        )
    }

    static func suspendAutomaticReconnectAfterCaptureFailure(
        enabledFlagURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        suspendAutomaticReconnect(
            enabledFlagURL: enabledFlagURL,
            fileManager: fileManager,
            logReason: "capture produced no frames"
        )
    }

    private static func suspendAutomaticReconnect(
        enabledFlagURL: URL?,
        fileManager: FileManager,
        logReason: String
    ) {
        continuousConnectTask?.cancel()
        continuousConnectTask = nil
        let marker = enabledFlagURL ?? senderEnabledFlagURL()
        do {
            if fileManager.fileExists(atPath: marker.path) {
                try fileManager.removeItem(at: marker)
            }
            NSLog("[automation] \(logReason); automatic reconnect suspended")
        } catch {
            NSLog("[automation] unable to clear automatic reconnect marker: \(error.localizedDescription)")
        }
    }

    /// Handle a `targetbridge://` URL (from `.onOpenURL`).
    static func handle(url: URL) {
        guard url.scheme?.lowercased() == "targetbridge" else { return }
        let action = (url.host ?? "").lowercased()
        var params: [String: String] = [:]
        if let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems {
            for item in items where item.value != nil {
                params[item.name.lowercased()] = item.value
            }
        }
        run(action: action, params: params)
    }

    /// Handle process launch arguments. No-op for a normal launch (no `--connect`/`--disconnect`).
    /// Runs at most once per process so a second window / state restoration can't re-trigger it.
    static func handleLaunchArguments(_ arguments: [String]) {
        guard !didHandleLaunchArguments else { return }
        didHandleLaunchArguments = true
        var action: String?
        var params: [String: String] = [:]
        var index = 1
        while index < arguments.count {
            let arg = arguments[index]
            if arg == "--connect" {
                action = "connect"
            } else if arg == "--disconnect" {
                action = "disconnect"
            } else if arg.hasPrefix("--") {
                let key = String(arg.dropFirst(2)).lowercased()
                if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
                    params[key] = arguments[index + 1]
                    index += 1
                } else {
                    params[key] = ""
                }
            }
            index += 1
        }
        guard let action else { return }
        run(action: action, params: params)
    }

    // MARK: - Dispatch

    private static func run(action: String, params: [String: String]) {
        switch action {
        case "connect":
            continuousConnectTask?.cancel()
            if flagEnabled(params["retry"] ?? params["autoreconnect"] ?? params["auto-reconnect"]) {
                continuousConnectTask = Task { await connectContinuously(params) }
            } else {
                continuousConnectTask = nil
                Task { _ = await connect(params) }
            }
        case "disconnect":
            continuousConnectTask?.cancel()
            continuousConnectTask = nil
            disconnect(params)
        default:
            NSLog("[automation] unknown action '\(action)' (expected connect|disconnect)")
        }
    }

    private static func connectContinuously(_ params: [String: String]) async {
        var attempt = 0
        while !Task.isCancelled {
            attempt += 1
            NSLog("[automation] automatic connection attempt \(attempt)")

            if let session = await connect(params) {
                if await waitForConnection(session) {
                    NSLog("[automation] automatic connection active; monitoring link")
                    while !Task.isCancelled && (session.isConnected || session.isStreaming) {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                    }
                    guard !Task.isCancelled else { return }
                    NSLog("[automation] connection lost; retrying")
                } else {
                    NSLog("[automation] connection attempt did not become active; retrying")
                }

                if !session.isConnected && !session.isStreaming {
                    session.stopForAutomaticReconnect()
                }
            }

            guard !Task.isCancelled else { return }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    @discardableResult
    private static func connect(_ params: [String: String]) async -> TBDisplaySenderSession? {
        let service = TBDisplaySenderService.shared
        guard let session = resolveSession(service, params["session"]) else { return nil }

        service.refreshLocalInterfaces()

        if let transport = params["transport"] {
            session.transportKind = parseTransport(transport)
        }

        let rawPath = params["path"] ?? params["connection-path"] ?? params["connection"]
        let pathPreference: TBConnectionPathPreference?
        if let rawPath {
            guard let parsed = TBConnectionPathPreference.parse(rawPath) else {
                NSLog("[automation] unknown connection path '\(rawPath)'; aborting connect")
                return nil
            }
            pathPreference = parsed
        } else {
            pathPreference = nil
        }

        let receiver = params["receiver"].flatMap { $0.isEmpty ? nil : $0 } ?? "auto"
        let discoveredReceivers = await waitForReceivers(
            service,
            preferredIdentity: receiver.lowercased() == "auto"
                ? session.selectedReceiverID
                : receiver
        )
        if receiver.lowercased() == "auto" {
            guard let discovered = automaticReceiver(
                in: discoveredReceivers,
                preferredIdentity: session.selectedReceiverID
            ) else {
                if !session.selectedReceiverID.isEmpty {
                    NSLog("[automation] preferred monitor unavailable or ambiguous; waiting for that monitor")
                } else if discoveredReceivers.count > 1 {
                    NSLog("[automation] multiple receivers discovered and no preferred monitor is selected; waiting for user choice")
                } else {
                    NSLog("[automation] no receivers discovered; aborting connect")
                }
                return nil
            }
            if let pathPreference {
                guard let selected = await selectConnectionPath(
                    receiver: discovered,
                    preference: pathPreference,
                    requestedLocalIP: params["localip"] ?? params["local-ip"]
                ) else {
                    NSLog("[automation] no working \(pathPreference.rawValue) path; aborting connect")
                    return nil
                }
                apply(selected, receiver: discovered, to: session)
            } else {
                service.applyDiscoveredReceiver(discovered, to: session)
            }
        } else if let discovered = discoveredReceivers.first(where: { matches(receiver, $0) }) {
            if let pathPreference {
                guard let selected = await selectConnectionPath(
                    receiver: discovered,
                    preference: pathPreference,
                    requestedLocalIP: params["localip"] ?? params["local-ip"]
                ) else {
                    NSLog("[automation] no working \(pathPreference.rawValue) path to \(receiver); aborting connect")
                    return nil
                }
                apply(selected, receiver: discovered, to: session)
            } else {
                service.applyDiscoveredReceiver(discovered, to: session)
            }
        } else {
            guard !isPersistedReceiverReference(receiver) else {
                NSLog("[automation] requested monitor identity is not available; aborting connect")
                return nil
            }
            // Treat as a raw IP / hostname (bypasses Bonjour).
            session.receiverIP = receiver
            session.selectedReceiverID = ""
        }

        if pathPreference == nil,
           let localIP = (params["localip"] ?? params["local-ip"]),
           !localIP.isEmpty {
            session.localInterfaceIP = localIP
        }
        if session.localInterfaceIP.isEmpty {
            session.localInterfaceIP = service.defaultLocalInterfaceIP(for: session.transportKind)
        }

        if let mode = params["mode"] {
            if let source = parseMode(mode) { session.captureSource = source }
            else { NSLog("[automation] unknown mode '\(mode)' (ignored)") }
        }
        if let presetName = params["preset"] {
            if let preset = parsePreset(presetName) { session.capturePreset = preset }
            else { NSLog("[automation] unknown preset '\(presetName)' (ignored)") }
        }

        guard !session.receiverIP.isEmpty else {
            NSLog("[automation] no receiver IP resolved; aborting connect")
            return nil
        }
        guard !session.localInterfaceIP.isEmpty else {
            NSLog("[automation] no local interface for transport \(session.transportKind.rawValue); aborting connect")
            return nil
        }
        NSLog("[automation] connecting to \(session.receiverIP) from \(session.localInterfaceIP) via \(session.transportKind.rawValue) — \(session.captureSource.rawValue)/\(session.capturePreset.rawValue)")
        session.connect()
        return session
    }

    private static func disconnect(_ params: [String: String]) {
        let service = TBDisplaySenderService.shared
        guard let target = resolveSessionIndex(params["session"], sessionCount: service.sessions.count, createDefaultIfNeeded: false) else {
            if params["session"] != nil {
                NSLog("[automation] invalid session '\(params["session"] ?? "")'; refusing to disconnect")
            } else {
                NSLog("[automation] no sessions available to disconnect")
            }
            return
        }

        if let target {
            service.sessions[target].stop(persistArrangement: true)
        } else {
            service.stopAll()
        }
    }

    // MARK: - Helpers

    private static func resolveSession(_ service: TBDisplaySenderService, _ raw: String?) -> TBDisplaySenderSession? {
        guard let index = resolveSessionIndex(raw, sessionCount: service.sessions.count, createDefaultIfNeeded: true) else {
            NSLog("[automation] invalid session '\(raw ?? "")'; aborting connect")
            return nil
        }

        if service.sessions.isEmpty {
            service.addSession()
        }
        guard !service.sessions.isEmpty, let safeIndex = index, safeIndex < service.sessions.count else { return nil }
        return service.sessions[safeIndex]
    }

    /// Resolves a 1-based session number from automation input.
    /// - Returns:
    ///   - `nil` when the explicit session is invalid.
    ///   - `.some(nil)` when no session was requested and the caller should target all sessions.
    ///   - `.some(index)` with a zero-based index for a specific session.
    /// - Note: `internal` (not `private`) so the unit-test bundle can exercise the tri-state logic.
    static func resolveSessionIndex(
        _ raw: String?,
        sessionCount: Int,
        createDefaultIfNeeded: Bool
    ) -> Int?? {
        guard let raw, !raw.isEmpty else {
            if createDefaultIfNeeded && sessionCount == 0 {
                return .some(0)
            }
            return createDefaultIfNeeded ? .some(0) : .some(nil)
        }

        guard let number = Int(raw), number >= 1 else {
            return nil
        }

        let index = number - 1
        if index < sessionCount {
            return .some(index)
        }
        if createDefaultIfNeeded && sessionCount == 0 && index == 0 {
            return .some(0)
        }
        return nil
    }

    /// Bonjour results arrive incrementally. Waiting for a short settled window
    /// prevents `auto` from connecting to whichever of several displays happens
    /// to advertise first. A previously selected stable identity may return
    /// immediately because it is unambiguous.
    private static func waitForReceivers(
        _ service: TBDisplaySenderService,
        preferredIdentity: String
    ) async -> [TBDiscoveredReceiver] {
        var lastSignature: [String] = []
        var unchangedIterations = 0
        var firstNonEmptyIteration: Int?

        for iteration in 0..<24 {
            let receivers = service.discoveredReceivers
            if !preferredIdentity.isEmpty,
               receivers.contains(where: { $0.matchesPersistedIdentity(preferredIdentity) }) {
                return receivers
            }

            if !receivers.isEmpty {
                if firstNonEmptyIteration == nil { firstNonEmptyIteration = iteration }
                let signature = receivers
                    .map { "\($0.stableIdentity)|\($0.preferredIP)" }
                    .sorted()
                if signature == lastSignature {
                    unchangedIterations += 1
                } else {
                    lastSignature = signature
                    unchangedIterations = 0
                }

                if let firstNonEmptyIteration,
                   iteration - firstNonEmptyIteration >= 6,
                   unchangedIterations >= 3 {
                    return receivers
                }
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return service.discoveredReceivers
    }

    /// Automatic startup is safe only when the preferred display is present or
    /// exactly one Receiver exists and no preference was saved. With multiple unpaired displays, returning
    /// nil is intentional: silently choosing the first one would send the user's
    /// desktop to the wrong Mac.
    static func automaticReceiver(
        in receivers: [TBDiscoveredReceiver],
        preferredIdentity: String
    ) -> TBDiscoveredReceiver? {
        if !preferredIdentity.isEmpty {
            let preferred = receivers.filter {
               $0.matchesPersistedIdentity(preferredIdentity)
            }
            return preferred.count == 1 ? preferred[0] : nil
        }
        return receivers.count == 1 ? receivers[0] : nil
    }

    static func isPersistedReceiverReference(_ value: String) -> Bool {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value.hasPrefix("receiver:") || value.hasPrefix("service:") ||
            value.contains("|") || UUID(uuidString: value) != nil
    }

    private static func selectConnectionPath(
        receiver: TBDiscoveredReceiver,
        preference: TBConnectionPathPreference,
        requestedLocalIP: String?
    ) async -> TBConnectionMeasurement? {
        let allInterfaces = TBConnectionDiagnostics.currentIPv4Interfaces()
        let eligibleInterfaces: [TBConnectionDiagnostics.LocalInterface]
        if let requestedLocalIP, !requestedLocalIP.isEmpty {
            eligibleInterfaces = allInterfaces.filter { $0.ip == requestedLocalIP }
        } else {
            eligibleInterfaces = allInterfaces
        }

        let allCandidates = TBConnectionDiagnostics.connectionCandidates(
            receiver: receiver,
            interfaces: eligibleInterfaces,
            hardwareKinds: TBConnectionDiagnostics.hardwarePathKinds()
        )
        let candidates = allCandidates.filter { preference.allows($0.kind) }
        guard !candidates.isEmpty else {
            NSLog("[automation] no candidate interfaces/endpoints for path \(preference.rawValue)")
            return nil
        }

        let measurements = await Task.detached(priority: .userInitiated) {
            var values: [TBConnectionMeasurement] = []
            for candidate in candidates {
                guard !Task.isCancelled else { break }
                NSLog("[automation] probing \(candidate.kind.rawValue): \(candidate.localIP) (\(candidate.localInterfaceName)) -> \(candidate.receiverIP)")
                do {
                    let measurement = try TBConnectionDiagnostics.probe(candidate)
                    NSLog(
                        "[automation] path \(candidate.kind.rawValue) measured \(String(format: "%.3f", measurement.throughputGbps)) Gbit/s, \(String(format: "%.2f", measurement.connectLatencyMilliseconds)) ms"
                    )
                    values.append(measurement)
                } catch {
                    NSLog("[automation] path \(candidate.kind.rawValue) unavailable: \(error.localizedDescription)")
                }
                usleep(100_000)
            }
            return values
        }.value

        guard let selected = TBConnectionDiagnostics.selectBestMeasurement(
            measurements,
            preference: preference
        ) else { return nil }
        NSLog(
            "[automation] selected \(selected.candidate.kind.rawValue) on \(selected.candidate.localInterfaceName) at \(String(format: "%.3f", selected.throughputGbps)) Gbit/s"
        )
        return selected
    }

    private static func apply(
        _ measurement: TBConnectionMeasurement,
        receiver: TBDiscoveredReceiver,
        to session: TBDisplaySenderSession
    ) {
        session.transportKind = measurement.candidate.transportKind
        session.localInterfaceIP = measurement.candidate.localIP
        session.receiverIP = measurement.candidate.receiverIP
        session.receiverSupportsHEVCDecodeHint = receiver.supportsHEVCDecode
    }

    private static func waitForConnection(_ session: TBDisplaySenderSession) async -> Bool {
        for _ in 0..<40 {
            if session.isConnected || session.isStreaming { return true }
            guard !Task.isCancelled else { return false }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return session.isConnected || session.isStreaming
    }

    static func flagEnabled(_ value: String?) -> Bool {
        guard let value else { return false }
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "0", "false", "no", "off":
            return false
        default:
            return true
        }
    }

    // The pure parsing helpers below are `internal` (not `private`) so the
    // unit-test bundle can exercise them directly.
    static func matches(_ value: String, _ receiver: TBDiscoveredReceiver) -> Bool {
        let needle = value.lowercased()
        if receiver.matchesPersistedIdentity(needle) { return true }
        if receiver.receiverName.lowercased() == needle { return true }
        if let host = receiver.shortHostName?.lowercased(), host == needle { return true }
        return receiver.preferredIP.lowercased() == needle
            || receiver.thunderboltIP.lowercased() == needle
            || receiver.usbIP.lowercased() == needle
            || receiver.ethernetIP.lowercased() == needle
            || receiver.wifiIP.lowercased() == needle
            || receiver.networkIP.lowercased() == needle
            || receiver.resolvedIPv4Addresses.contains(where: { $0.lowercased() == needle })
    }

    static func parseTransport(_ value: String) -> TBTransportKind {
        switch value.lowercased() {
        case "net", "network", "networklink", "link":
            return .networkLink
        default:
            return .thunderboltBridge
        }
    }

    static func parseMode(_ value: String) -> TBDisplayCaptureSource? {
        switch value.lowercased() {
        case "extended", "extend", "extendeddesktop", "ext":
            return .extendedDesktop
        case "mirror", "mirrored", "desktopmirror":
            return .desktopMirror
        default:
            return TBDisplayCaptureSource(rawValue: value)
        }
    }

    static func parsePreset(_ value: String) -> TBDisplayCapturePreset? {
        if let preset = TBDisplayCapturePreset(rawValue: value) { return preset }
        switch value.lowercased() {
        case "1440p", "1440", "standard": return .standard1440p
        case "1440p60", "smooth", "smooth1440": return .smooth1440p60
        case "1800p", "1800p60", "smooth1800": return .smooth1800p60
        case "2160p", "2160p60", "4k", "crisp": return .crisp2160p60
        case "retina4k", "retina4k60", "4096x2304", "imac4k": return .retina4k60
        case "5k60", "native5k60": return .native5k60Experimental
        case "5k", "native", "5120x2880": return .native5k
        default: return nil
        }
    }
}
