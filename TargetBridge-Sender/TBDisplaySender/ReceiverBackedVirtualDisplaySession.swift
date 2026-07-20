import CoreGraphics
import Foundation

extension CGVirtualDisplayDescriptor: @unchecked @retroactive Sendable {}
extension CGVirtualDisplay: @unchecked @retroactive Sendable {}
extension CGVirtualDisplaySettings: @unchecked @retroactive Sendable {}

/// Pixel size of the mode handed to CGVirtualDisplay. With `settings.hiDPI = true`
/// macOS synthesises a strictly 2x backing store, so a mode of (w, h) renders the
/// desktop into a (2w, 2h) framebuffer and reports "looks like w x h" in Displays.
struct TBVirtualDisplayModeSize: Equatable {
    let width: Int
    let height: Int

    var backingWidth: Int { width * 2 }
    var backingHeight: Int { height * 2 }
}

struct TBVirtualDisplayIdentity {
    let productID: UInt32
    let serialNumber: UInt32
    let displayNamePrefix: String
    let usesDedicatedArrangementIdentity: Bool

    static let desktopMirror = TBVirtualDisplayIdentity(
        productID: 0x5000,
        serialNumber: 0x2026,
        displayNamePrefix: "TB Mirror",
        usesDedicatedArrangementIdentity: false
    )

    static func extendedDesktop(receiverKey: String) -> TBVirtualDisplayIdentity {
        // Deterministic identity per receiver so macOS retains window placement
        // and the saved extended-desktop arrangement across reconnects.
        //
        // `receiverKey` must uniquely identify the receiver (the caller derives it
        // from the connection address, matching the saved-arrangement key). Keying
        // on the receiver-reported display name alone is not enough: identical iMac
        // models report the same SDL display name and the same hard-coded panel
        // size, so two of them would derive the same identity and macOS would
        // refuse to create the second virtual display.
        let hash = djb2(receiverKey)
        let productLow = (hash & 0x00FF) | 0x01
        let serialLow = (hash & 0xFFFE) | 0x0100
        return TBVirtualDisplayIdentity(
            productID: 0x6000 | productLow,
            serialNumber: 0x2027_0000 | UInt32(serialLow),
            displayNamePrefix: "TB Extend",
            usesDedicatedArrangementIdentity: true
        )
    }

    private static func djb2(_ input: String) -> UInt32 {
        var hash: UInt32 = 5381
        for byte in input.utf8 {
            hash = hash &* 33 &+ UInt32(byte)
        }
        return hash
    }
}

@MainActor
final class ReceiverBackedVirtualDisplaySession {
    private var virtualDisplay: CGVirtualDisplay?
    private(set) var displayID: CGDirectDisplayID = kCGNullDirectDisplay
    private(set) var displayName: String = ""
    private(set) var identityDescription: String = ""

    func create(
        from profile: TBMonitorDisplayProfile,
        refreshRate: Double? = nil,
        modeOverride: TBVirtualDisplayModeSize? = nil,
        identity: TBVirtualDisplayIdentity,
        receiverKey: String
    ) -> Bool {
        destroy()
        let preferredRefreshRate = refreshRate ?? profile.refreshRate

        // The receiver hard-codes mode 2560x1440 + hiDPI, i.e. a 5120x2880 backing
        // store, regardless of which capture preset the sender is running. Any preset
        // below 5K therefore makes ScreenCaptureKit resample 5120x2880 down to the
        // stream size, and the receiver resample back up to the panel: two non-integer
        // passes. `modeOverride` lets the sender size the backing store to match the
        // stream exactly, so capture is 1:1 and only the panel-side scale remains.
        var resolvedMode = modeOverride ?? TBVirtualDisplayModeSize(
            width: profile.modeWidth,
            height: profile.modeHeight
        )

        // macOS refuses a HiDPI mode whose backing store exceeds the advertised panel.
        if resolvedMode.backingWidth > profile.panelWidth || resolvedMode.backingHeight > profile.panelHeight {
            NSLog(
                "TargetBridge: mode override %dx%d needs a %dx%d backing store, exceeds panel %dx%d; falling back to receiver profile",
                resolvedMode.width, resolvedMode.height,
                resolvedMode.backingWidth, resolvedMode.backingHeight,
                profile.panelWidth, profile.panelHeight
            )
            resolvedMode = TBVirtualDisplayModeSize(width: profile.modeWidth, height: profile.modeHeight)
        }

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.name = "\(identity.displayNamePrefix) - \(profile.receiverName)"
        descriptor.vendorID = 0xEEEE
        descriptor.productID = identity.productID
        descriptor.serialNum = identity.serialNumber
        descriptor.serialNumber = identity.serialNumber
        descriptor.maxPixelsWide = UInt32(profile.panelWidth)
        descriptor.maxPixelsHigh = UInt32(profile.panelHeight)

        let ppi = 218.0
        descriptor.sizeInMillimeters = CGSize(
            width: Double(profile.panelWidth) / ppi * 25.4,
            height: Double(profile.panelHeight) / ppi * 25.4
        )

        guard let display = CGVirtualDisplay(descriptor: descriptor) else {
            return false
        }

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = profile.hiDPI
        guard let mode = CGVirtualDisplayMode(
            width: UInt(resolvedMode.width),
            height: UInt(resolvedMode.height),
            refreshRate: preferredRefreshRate
        ) else {
            return false
        }
        settings.modes = [mode]

        guard display.apply(settings), display.displayID != kCGNullDirectDisplay else {
            return false
        }

        // Restore the user's previously chosen mode for this receiver if we have
        // one; otherwise fall back to the receiver-advertised profile default.
        // An explicit render-matching override outranks the remembered choice: a
        // stale manual pick would silently break the 1:1 capture the user asked for.
        let preferenceKey = TBVirtualDisplayModeMemory.preferenceKey(
            for: identity,
            receiverKey: receiverKey
        )
        let savedChoice = modeOverride == nil
            ? TBVirtualDisplayModeMemory.shared.load(forKey: preferenceKey)
            : nil
        activatePreferredMode(for: display.displayID,
                              mode: resolvedMode,
                              refreshRate: preferredRefreshRate,
                              savedChoice: savedChoice)

        virtualDisplay = display
        displayID = display.displayID
        displayName = profile.receiverName
        identityDescription = "vendor=0x\(String(descriptor.vendorID, radix: 16)) product=0x\(String(identity.productID, radix: 16)) serial=0x\(String(identity.serialNumber, radix: 16))"

        // Remember any manual resolution change the user makes from now on, so it
        // sticks across reconnects for this receiver.
        TBVirtualDisplayModeMemory.shared.track(displayID: display.displayID, key: preferenceKey)
        return true
    }

    func destroy() {
        if displayID != kCGNullDirectDisplay {
            TBVirtualDisplayModeMemory.shared.untrack(displayID: displayID)
        }
        virtualDisplay = nil
        displayID = kCGNullDirectDisplay
        displayName = ""
        identityDescription = ""
    }

    @discardableResult
    private func activatePreferredMode(for displayID: CGDirectDisplayID,
                                       mode: TBVirtualDisplayModeSize,
                                       refreshRate: Double,
                                       savedChoice: TBVirtualDisplayModeMemory.Choice?) -> Bool {
        let timeout = Date().addingTimeInterval(2.0)
        while Date() < timeout {
            var success = false
            autoreleasepool {
                let chosenMode = savedChoice.flatMap { savedMode(for: displayID, choice: $0) }
                    ?? preferredMode(for: displayID, mode: mode, refreshRate: refreshRate)
                if let chosenMode {
                    success = CGDisplaySetDisplayMode(displayID, chosenMode, nil) == .success
                }
            }
            if success {
                return true
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return false
    }

    /// Find the display mode matching a saved choice. Matches on pixel size as
    /// well as point size so a HiDPI mode is not confused with its 1× ("Standard")
    /// counterpart. The low-resolution-duplicates option ensures both variants are
    /// enumerated.
    private func savedMode(for displayID: CGDirectDisplayID, choice: TBVirtualDisplayModeMemory.Choice) -> CGDisplayMode? {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let modesCF = CGDisplayCopyAllDisplayModes(displayID, options) else {
            return nil
        }
        let modes = modesCF as? [CGDisplayMode] ?? []

        let candidates = modes.filter { mode in
            mode.width == choice.pointWidth && mode.height == choice.pointHeight &&
            mode.pixelWidth == choice.pixelWidth && mode.pixelHeight == choice.pixelHeight
        }
        if let exact = candidates.first(where: { abs($0.refreshRate - choice.refreshRate) < 0.5 }) {
            return exact
        }
        return candidates.first
    }

    private func preferredMode(for displayID: CGDirectDisplayID, mode: TBVirtualDisplayModeSize, refreshRate: Double) -> CGDisplayMode? {
        guard let modesCF = CGDisplayCopyAllDisplayModes(displayID, nil) else {
            return nil
        }
        let modes = modesCF as? [CGDisplayMode] ?? []

        let matchingModes = modes.filter { candidate in
            candidate.width == mode.width && candidate.height == mode.height
        }.sorted { $0.refreshRate > $1.refreshRate }

        if let exactMatch = matchingModes.first(where: { abs($0.refreshRate - refreshRate) < 0.5 }) {
            return exactMatch
        }

        return matchingModes.first
    }
}
