import AppKit
import Foundation

// Sender-side automation entry points.
//
// Lets the Sender be driven for scripting / SSH / login & wake automation WITHOUT a
// separate control daemon: it reuses the existing TBDisplaySenderService / session model.
//
// Two equivalent ways in:
//   • URL scheme:   open "targetbridge://connect?receiver=auto&mode=mirror&preset=native5k&input=receiver"
//                   open "targetbridge://disconnect"
//   • Launch args:  TargetBridge --connect --receiver auto --mode mirror --preset native5k
//                                --input receiver --retry --path auto
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

    /// A GUI Stop is an operator decision, not a transient link failure. Cancel
    /// the in-process retry loop and clear launchd's PathState marker. The
    /// Receiver's Start button recreates the marker and kickstarts a fresh
    /// Sender process, so this remains completely reversible from the iMac.
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

    /// A missing capture permission cannot recover through network retries.
    /// Stop both the in-process loop and launchd's PathState restart until the
    /// operator grants the permission and presses Start again on the Receiver.
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

    /// A capture pipeline that starts but never receives a frame cannot recover
    /// by repeatedly rebuilding the same display. Stop the retry loop and let
    /// the Receiver's Start action perform the next explicit attempt.
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
        if action == "connect" {
            let persistedPath = loadPersistentPathOverride()
            params = applyingPersistentPathOverride(params, rawValue: persistedPath)
            if let persistedPath,
               let parsed = TBConnectionPathPreference.parse(persistedPath) {
                NSLog("[automation] persistent connection path override: \(parsed.rawValue)")
            }
            let persistedInput = loadPersistentInputOverride()
            params = applyingPersistentInputOverride(params, rawValue: persistedInput)
            if let persistedInput,
               let parsed = parseInputControlRole(persistedInput) {
                NSLog("[automation] persistent input control override: \(parsed.rawValue)")
            }
        }
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
        var nextAllowedPathReevaluation = Date.distantPast
        while !Task.isCancelled {
            attempt += 1
            NSLog("[automation] automatic connection attempt \(attempt)")

            if let session = await connect(params) {
                let connected = await waitForConnection(session)
                if connected {
                    NSLog("[automation] automatic connection active; monitoring link")
                    var nextPathAvailabilityCheck = Date().addingTimeInterval(30)
                    var pathReevaluationRequested = false
                    while !Task.isCancelled && (session.isConnected || session.isStreaming) {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        let now = Date()
                        if now >= nextPathAvailabilityCheck {
                            nextPathAvailabilityCheck = now.addingTimeInterval(30)
                            if now >= nextAllowedPathReevaluation,
                               livePathShouldBeReevaluated(session: session, params: params) {
                                // A higher-class physical path appeared after the initial
                                // fallback. Disconnect once so the normal measured probe
                                // can compare every candidate while the Receiver is idle.
                                nextAllowedPathReevaluation = now.addingTimeInterval(600)
                                pathReevaluationRequested = true
                                NSLog("[automation] higher-priority path available; re-measuring connection paths")
                                session.stopForAutomaticReconnect()
                                break
                            }
                        }
                    }
                    guard !Task.isCancelled else { return }
                    if pathReevaluationRequested {
                        NSLog("[automation] restarting connection for path re-measurement")
                    } else {
                        NSLog("[automation] connection lost; retrying")
                    }
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

        let legacyDirectUSB = flagEnabled(params["direct-usb"] ?? params["directusb"])
        let pathValue = params["path"] ?? params["connection-path"] ?? params["connection"]
        let pathPreference: TBConnectionPathPreference?
        if let pathValue {
            guard let parsed = TBConnectionPathPreference.parse(pathValue) else {
                NSLog("[automation] unknown connection path '\(pathValue)'; waiting")
                return nil
            }
            pathPreference = parsed
        } else if legacyDirectUSB {
            pathPreference = .usb
        } else {
            pathPreference = nil
        }
        let receiver = params["receiver"].flatMap { $0.isEmpty ? nil : $0 } ?? "auto"
        if receiver.lowercased() == "auto" {
            guard let discovered = await waitForReceiver(service) else {
                NSLog("[automation] no receivers discovered; aborting connect")
                return nil
            }
            if let pathPreference {
                guard let selected = await selectConnectionPath(
                    receiver: discovered,
                    preference: pathPreference,
                    requestedLocalIP: params["localip"] ?? params["local-ip"]
                ) else {
                    NSLog("[automation] no working \(pathPreference.rawValue) path; waiting")
                    return nil
                }
                apply(selected, receiver: discovered, to: session)
            } else {
                service.applyDiscoveredReceiver(discovered, to: session)
            }
            session.selectedReceiverID = discovered.id
        } else if let discovered = service.discoveredReceivers.first(where: { matches(receiver, $0) }) {
            if let pathPreference {
                guard let selected = await selectConnectionPath(
                    receiver: discovered,
                    preference: pathPreference,
                    requestedLocalIP: params["localip"] ?? params["local-ip"]
                ) else {
                    NSLog("[automation] no working \(pathPreference.rawValue) path to \(receiver); waiting")
                    return nil
                }
                apply(selected, receiver: discovered, to: session)
            } else {
                service.applyDiscoveredReceiver(discovered, to: session)
            }
            session.selectedReceiverID = discovered.id
        } else {
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
        if let inputRole = params["input"] ?? params["input-role"] ?? params["inputcontrol"] {
            if let role = parseInputControlRole(inputRole) {
                session.inputControlRole = role
            } else {
                NSLog("[automation] unknown input role '\(inputRole)' (ignored)")
            }
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

    /// Discovery is async (Bonjour); briefly wait for the first receiver to appear.
    private static func waitForReceiver(_ service: TBDisplaySenderService) async -> TBDiscoveredReceiver? {
        for _ in 0..<20 {
            if let first = service.discoveredReceivers.first { return first }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return service.discoveredReceivers.first
    }

    private static func waitForConnection(_ session: TBDisplaySenderSession) async -> Bool {
        for _ in 0..<40 {
            if session.isConnected || session.isStreaming { return true }
            guard !Task.isCancelled else { return false }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return session.isConnected || session.isStreaming
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
        let hardwareKinds = TBConnectionDiagnostics.hardwarePathKinds()
        let allCandidates = TBConnectionDiagnostics.connectionCandidates(
            receiver: receiver,
            interfaces: eligibleInterfaces,
            hardwareKinds: hardwareKinds
        )
        let candidates: [TBConnectionCandidate]
        candidates = allCandidates.filter { preference.allows($0.kind) }
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

    // The pure parsing helpers below are `internal` (not `private`) so the
    // unit-test bundle can exercise them directly.
    static func applyingPersistentPathOverride(
        _ params: [String: String],
        rawValue: String?
    ) -> [String: String] {
        guard let parsed = TBConnectionPathPreference.parse(rawValue) else {
            return params
        }
        var updated = params
        updated["path"] = parsed.rawValue
        return updated
    }

    static func applyingPersistentInputOverride(
        _ params: [String: String],
        rawValue: String?
    ) -> [String: String] {
        guard let rawValue,
              let parsed = parseInputControlRole(rawValue)
        else { return params }
        var updated = params
        updated["input"] = parsed.rawValue
        return updated
    }

    /// Decides whether a healthy fallback connection deserves one fresh,
    /// measured comparison. Manual path choices are never second-guessed.
    static func shouldReevaluateAutomaticPath(
        preference: TBConnectionPathPreference?,
        current: TBConnectionPathKind?,
        available: Set<TBConnectionPathKind>
    ) -> Bool {
        guard let preference,
              preference == .automatic || preference == .wired,
              let current,
              preference.allows(current)
        else { return false }

        func priority(_ kind: TBConnectionPathKind) -> Int {
            switch kind {
            case .thunderbolt: return 4
            case .usb: return 3
            case .ethernet: return 2
            case .wifi: return 1
            }
        }

        return available
            .filter { preference.allows($0) }
            .contains { priority($0) > priority(current) }
    }

    private static func livePathShouldBeReevaluated(
        session: TBDisplaySenderSession,
        params: [String: String]
    ) -> Bool {
        let rawPreference = params["path"] ?? params["connection-path"] ?? params["connection"]
        let preference = TBConnectionPathPreference.parse(rawPreference)
        guard preference == .automatic || preference == .wired else { return false }

        let service = TBDisplaySenderService.shared
        service.refreshLocalInterfaces()
        guard let receiver = service.discoveredReceivers.first(where: {
            $0.id == session.selectedReceiverID || matches(session.receiverIP, $0)
        }) else { return false }

        let interfaces = TBConnectionDiagnostics.currentIPv4Interfaces()
        let hardwareKinds = TBConnectionDiagnostics.hardwarePathKinds()
        let currentInterface = interfaces.first(where: { $0.ip == session.localInterfaceIP })
        let currentKind = currentInterface.flatMap {
            TBConnectionDiagnostics.pathKind(for: $0, hardwareKinds: hardwareKinds)
        }
        let candidates = TBConnectionDiagnostics.connectionCandidates(
            receiver: receiver,
            interfaces: interfaces,
            hardwareKinds: hardwareKinds
        )
        return shouldReevaluateAutomaticPath(
            preference: preference,
            current: currentKind,
            available: Set(candidates.map(\.kind))
        )
    }

    private static func loadPersistentPathOverride() -> String? {
        let environment = ProcessInfo.processInfo.environment
        let stateDirectory: URL
        if let override = environment["TARGETBRIDGE_CONTROL_STATE_DIR"], !override.isEmpty {
            stateDirectory = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            stateDirectory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/TargetBridge/Sender", isDirectory: true)
        }
        let pathFile = stateDirectory.appendingPathComponent("requested-path", isDirectory: false)
        return try? String(contentsOf: pathFile, encoding: .utf8)
    }

    private static func loadPersistentInputOverride() -> String? {
        let environment = ProcessInfo.processInfo.environment
        let stateDirectory: URL
        if let override = environment["TARGETBRIDGE_CONTROL_STATE_DIR"], !override.isEmpty {
            stateDirectory = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            stateDirectory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/TargetBridge/Sender", isDirectory: true)
        }
        let inputFile = stateDirectory.appendingPathComponent("requested-input", isDirectory: false)
        return try? String(contentsOf: inputFile, encoding: .utf8)
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

    static func matches(_ value: String, _ receiver: TBDiscoveredReceiver) -> Bool {
        let needle = value.lowercased()
        if receiver.id.lowercased() == needle { return true }
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
        case "2160p", "2160p60", "crisp": return .crisp2160p60
        case "4k", "retina4k", "retina4k60", "4096x2304", "imac4k": return .retina4k60
        case "5k60", "native5k60": return .native5k60Experimental
        case "5k", "native", "5120x2880": return .native5k
        default: return nil
        }
    }

    static func parseInputControlRole(_ value: String) -> TBInputControlRole? {
        switch value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "") {
        case "off", "none", "disabled", "disable", "0":
            return .off
        case "receiver", "receivermaster", "imac", "monitor":
            return .receiverMaster
        case "sender", "sendermaster", "macmini", "mini":
            return .senderMaster
        default:
            return nil
        }
    }
}
