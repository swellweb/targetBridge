import CoreGraphics
import Foundation

/// Remembers the user's chosen display mode per virtual-display identity and
/// restores it on reconnect.
///
/// macOS does not reliably persist the resolution of these hot-plugged virtual
/// displays, and the session otherwise re-imposes the receiver-advertised
/// default (e.g. 2560×1440 HiDPI) on every connect. We capture the user's manual
/// resolution change via a CoreGraphics display-reconfiguration callback and
/// re-apply it the next time the same receiver connects.
///
/// All access happens on the main thread: the session (which is `@MainActor`)
/// drives `track`/`untrack`/`load`, and the reconfiguration callback is invoked
/// on the run loop of the registering (main) thread. Hence `@unchecked Sendable`.
final class TBVirtualDisplayModeMemory: @unchecked Sendable {
    /// A persisted mode choice. `pixelWidth`/`pixelHeight` capture the backing
    /// resolution, which is what distinguishes a HiDPI mode from its 1× ("Standard")
    /// counterpart at the same point size.
    struct Choice: Codable {
        var pointWidth: Int
        var pointHeight: Int
        var pixelWidth: Int
        var pixelHeight: Int
        var refreshRate: Double
    }

    static let shared = TBVirtualDisplayModeMemory()
    private init() {}

    private let defaultsPrefix = "tb.displayMode."
    private var tracked: [CGDirectDisplayID: String] = [:]
    private var registered = false

    private func defaultsKey(_ key: String) -> String { defaultsPrefix + key }

    /// The stable preference key for a virtual-display identity.
    static func preferenceKey(for identity: TBVirtualDisplayIdentity) -> String {
        "\(identity.productID)-\(identity.serialNumber)"
    }

    func load(forKey key: String) -> Choice? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey(key)) else { return nil }
        return try? JSONDecoder().decode(Choice.self, from: data)
    }

    /// Begin remembering mode changes for `displayID` under `key`, so the user's
    /// subsequent manual resolution changes are persisted.
    func track(displayID: CGDirectDisplayID, key: String) {
        ensureRegistered()
        tracked[displayID] = key
    }

    func untrack(displayID: CGDirectDisplayID) {
        tracked.removeValue(forKey: displayID)
    }

    private func ensureRegistered() {
        guard !registered else { return }
        registered = true
        CGDisplayRegisterReconfigurationCallback(tbVirtualDisplayReconfigurationCallback, nil)
    }

    fileprivate func handleReconfiguration(_ displayID: CGDirectDisplayID,
                                           _ flags: CGDisplayChangeSummaryFlags) {
        guard flags.contains(.setModeFlag) else { return }
        guard let key = tracked[displayID] else { return }
        guard let mode = CGDisplayCopyDisplayMode(displayID) else { return }
        let choice = Choice(
            pointWidth: mode.width,
            pointHeight: mode.height,
            pixelWidth: mode.pixelWidth,
            pixelHeight: mode.pixelHeight,
            refreshRate: mode.refreshRate
        )
        if let data = try? JSONEncoder().encode(choice) {
            UserDefaults.standard.set(data, forKey: defaultsKey(key))
        }
    }
}

private func tbVirtualDisplayReconfigurationCallback(
    _ displayID: CGDirectDisplayID,
    _ flags: CGDisplayChangeSummaryFlags,
    _ userInfo: UnsafeMutableRawPointer?
) {
    TBVirtualDisplayModeMemory.shared.handleReconfiguration(displayID, flags)
}
