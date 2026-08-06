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
        // models can report the same SDL display name and panel size, so two of
        // them would derive the same identity and macOS would
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

/// Identifies displays created by this Sender. On recent macOS releases a
/// virtual-display proxy can remain online after its owning Swift object is
/// released. While that proxy exists, `CGVirtualDisplay(descriptor:)` refuses
/// a replacement with `KERN_FAILURE`. Reusing only our exact deterministic
/// identity lets a headless automatic session recover without restarting
/// WindowServer.
enum TBVirtualDisplayReuse {
    static let vendorID: UInt32 = 0xEEEE

    static func matches(
        vendorID: UInt32,
        productID: UInt32,
        serialNumber: UInt32,
        identity: TBVirtualDisplayIdentity
    ) -> Bool {
        vendorID == Self.vendorID &&
            productID == identity.productID &&
            serialNumber == identity.serialNumber
    }
}

@MainActor
final class ReceiverBackedVirtualDisplaySession {
    private var virtualDisplay: CGVirtualDisplay?
    private(set) var displayID: CGDirectDisplayID = kCGNullDirectDisplay
    private(set) var displayName: String = ""
    private(set) var identityDescription: String = ""
    private(set) var reusedExistingDisplay = false

    func create(
        from profile: TBMonitorDisplayProfile,
        refreshRate: Double? = nil,
        modeOverride: TBVirtualDisplayModeSize? = nil,
        identity: TBVirtualDisplayIdentity,
        receiverKey: String
    ) -> Bool {
        destroy()
        let preferredRefreshRate = refreshRate ?? profile.refreshRate

        // The receiver advertises its native HiDPI mode. A lower-resolution
        // capture preset would otherwise make ScreenCaptureKit resample the
        // backing store down to the stream and the receiver scale it back to
        // the panel. `modeOverride` keeps capture 1:1 when the requested mode
        // fits within the advertised panel.
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

        let preferenceKey = TBVirtualDisplayModeMemory.preferenceKey(
            for: identity,
            receiverKey: receiverKey
        )

        // A previous proxy can survive CGVirtualDisplay destruction. Adopt only
        // our exact vendor/product/serial identity; never borrow an arbitrary
        // third-party virtual or physical display.
        if let existingDisplayID = reusableDisplayID(matching: identity) {
            // Do not reapply its mode here. The proxy already has the retained
            // mode, while CGDisplaySetDisplayMode can block on a stale proxy.
            virtualDisplay = nil
            displayID = existingDisplayID
            displayName = profile.receiverName
            reusedExistingDisplay = true
            identityDescription = "vendor=0x\(String(TBVirtualDisplayReuse.vendorID, radix: 16)) product=0x\(String(identity.productID, radix: 16)) serial=0x\(String(identity.serialNumber, radix: 16)) reused=yes"
            TBVirtualDisplayModeMemory.shared.track(displayID: existingDisplayID, key: preferenceKey)
            NSLog(
                "TargetBridge: reusing existing virtual display %u after stale-proxy recovery (%@)",
                existingDisplayID,
                identityDescription
            )
            return true
        }

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.name = "\(identity.displayNamePrefix) - \(profile.receiverName)"
        descriptor.vendorID = TBVirtualDisplayReuse.vendorID
        descriptor.productID = identity.productID
        descriptor.serialNum = identity.serialNumber
        descriptor.serialNumber = identity.serialNumber
        descriptor.maxPixelsWide = UInt32(profile.panelWidth)
        descriptor.maxPixelsHigh = UInt32(profile.panelHeight)

        // A virtual display without chromaticity metadata can receive a generic
        // ColorSync profile. In mirror mode that makes macOS render the same
        // desktop differently from the built-in Display P3 panel. Advertise the
        // iMac's wide-gamut SDR space explicitly so capture is colour-managed
        // before it enters the 8-bit NV12 video pipeline.
        descriptor.whitePoint = CGPoint(x: 0.3125, y: 0.3291) // D65
        descriptor.redPrimary = CGPoint(x: 0.6797, y: 0.3203)
        descriptor.greenPrimary = CGPoint(x: 0.2559, y: 0.6983)
        descriptor.bluePrimary = CGPoint(x: 0.1494, y: 0.0557)

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

    private func reusableDisplayID(matching identity: TBVirtualDisplayIdentity) -> CGDirectDisplayID? {
        var displayCount: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &displayCount) == .success,
              displayCount > 0
        else { return nil }

        var displayIDs = Array(repeating: kCGNullDirectDisplay, count: Int(displayCount))
        guard CGGetOnlineDisplayList(displayCount, &displayIDs, &displayCount) == .success else {
            return nil
        }

        return displayIDs.prefix(Int(displayCount)).first { candidateID in
            candidateID != kCGNullDirectDisplay &&
                TBVirtualDisplayReuse.matches(
                    vendorID: CGDisplayVendorNumber(candidateID),
                    productID: CGDisplayModelNumber(candidateID),
                    serialNumber: CGDisplaySerialNumber(candidateID),
                    identity: identity
                )
        }
    }

    func destroy() {
        if displayID != kCGNullDirectDisplay {
            TBVirtualDisplayModeMemory.shared.untrack(displayID: displayID)
        }
        virtualDisplay = nil
        displayID = kCGNullDirectDisplay
        displayName = ""
        identityDescription = ""
        reusedExistingDisplay = false
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
