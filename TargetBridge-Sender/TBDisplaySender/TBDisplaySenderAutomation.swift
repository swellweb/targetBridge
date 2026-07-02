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
            Task { await connect(params) }
        case "disconnect":
            disconnect(params)
        default:
            NSLog("[automation] unknown action '\(action)' (expected connect|disconnect)")
        }
    }

    private static func connect(_ params: [String: String]) async {
        let service = TBDisplaySenderService.shared
        guard let session = resolveSession(service, params["session"]) else { return }

        service.refreshLocalInterfaces()

        if let transport = params["transport"] {
            session.transportKind = parseTransport(transport)
        }

        let receiver = params["receiver"].flatMap { $0.isEmpty ? nil : $0 } ?? "auto"
        if receiver.lowercased() == "auto" {
            guard let discovered = await waitForReceiver(service) else {
                NSLog("[automation] no receivers discovered; aborting connect")
                return
            }
            service.applyDiscoveredReceiver(discovered, to: session)
            session.selectedReceiverID = discovered.id
        } else if let discovered = service.discoveredReceivers.first(where: { matches(receiver, $0) }) {
            service.applyDiscoveredReceiver(discovered, to: session)
            session.selectedReceiverID = discovered.id
        } else {
            // Treat as a raw IP / hostname (bypasses Bonjour).
            session.receiverIP = receiver
            session.selectedReceiverID = ""
        }

        if let localIP = (params["localip"] ?? params["local-ip"]), !localIP.isEmpty {
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
            return
        }
        guard !session.localInterfaceIP.isEmpty else {
            NSLog("[automation] no local interface for transport \(session.transportKind.rawValue); aborting connect")
            return
        }
        NSLog("[automation] connecting to \(session.receiverIP) via \(session.transportKind.rawValue) — \(session.captureSource.rawValue)/\(session.capturePreset.rawValue)")
        session.connect()
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

    // The pure parsing helpers below are `internal` (not `private`) so the
    // unit-test bundle can exercise them directly.
    static func matches(_ value: String, _ receiver: TBDiscoveredReceiver) -> Bool {
        let needle = value.lowercased()
        if receiver.id.lowercased() == needle { return true }
        if receiver.receiverName.lowercased() == needle { return true }
        if let host = receiver.shortHostName?.lowercased(), host == needle { return true }
        return receiver.preferredIP.lowercased() == needle
            || receiver.thunderboltIP.lowercased() == needle
            || receiver.networkIP.lowercased() == needle
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
        case "5k", "native", "5120x2880": return .native5k
        default: return nil
        }
    }
}
