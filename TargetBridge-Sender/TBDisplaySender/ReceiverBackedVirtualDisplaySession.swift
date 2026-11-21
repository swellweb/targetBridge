import CoreGraphics
import Foundation

extension CGVirtualDisplayDescriptor: @unchecked @retroactive Sendable {}
extension CGVirtualDisplay: @unchecked @retroactive Sendable {}
extension CGVirtualDisplaySettings: @unchecked @retroactive Sendable {}

/// Pixel size of the mode handed to CGVirtualDisplay. With `settings.hiDPI = true`
/// macOS synthesises a strictly 2x backing store, so a mode of (w, h) renders the
/// desktop into a (2w, 2h) framebuffer and reports "looks like w x h" in Displays.
///
/// `isHiDPI == false` asks for a 1x mode instead: the framebuffer equals the mode,
/// and the desktop reports its true size. That is the right choice when the stream
/// already matches a non-Retina receiver panel pixel for pixel, where a HiDPI mode
/// would render every control at 2x on a panel that has no extra pixels to show it.
struct TBVirtualDisplayModeSize: Equatable {
    let width: Int
    let height: Int
    let isHiDPI: Bool

    init(width: Int, height: Int, isHiDPI: Bool = true) {
        self.width = width
        self.height = height
        self.isHiDPI = isHiDPI
    }

    var backingWidth: Int { isHiDPI ? width * 2 : width }
    var backingHeight: Int { isHiDPI ? height * 2 : height }
}

/// The value part of mode selection can be checked without creating a display.
/// Keep point and backing dimensions together: equal point sizes do not imply
/// equal render resolutions.
enum TBVirtualDisplayModeSelection {
    struct Candidate: Codable, Equatable, Sendable {
        var pointWidth: Int
        var pointHeight: Int
        var pixelWidth: Int
        var pixelHeight: Int
        var refreshRate: Double

        static func snapshot(_ mode: CGDisplayMode) -> Self {
            Self(pointWidth: mode.width, pointHeight: mode.height,
                 pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight,
                 refreshRate: mode.refreshRate)
        }

        func hasSameDimensions(as other: Self) -> Bool {
            pointWidth == other.pointWidth && pointHeight == other.pointHeight &&
                pixelWidth == other.pixelWidth && pixelHeight == other.pixelHeight
        }
    }

    static func preferredIndex(in candidates: [Candidate], mode: TBVirtualDisplayModeSize,
                               refreshRate: Double) -> Int? {
        let matching = candidates.indices.filter {
            candidates[$0].pointWidth == mode.width && candidates[$0].pointHeight == mode.height
        }.sorted { candidates[$0].refreshRate > candidates[$1].refreshRate }
        let backingMatches = matching.filter {
            candidates[$0].pixelWidth == mode.backingWidth && candidates[$0].pixelHeight == mode.backingHeight
        }
        return backingMatches.first(where: { abs(candidates[$0].refreshRate - refreshRate) < 0.5 })
            ?? backingMatches.first
    }

    static func savedIndex(in candidates: [Candidate], choice: Candidate) -> Int? {
        let matching = candidates.indices.filter { candidates[$0].hasSameDimensions(as: choice) }
        return matching.first(where: { abs(candidates[$0].refreshRate - choice.refreshRate) < 0.5 })
            ?? matching.first
    }

    static func applyAndVerify(_ choice: Candidate, apply: () -> Bool,
                               readBack: () -> Candidate?) -> Bool {
        guard apply(), let current = readBack() else { return false }
        return current.hasSameDimensions(as: choice)
    }
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

        // The receiver reports its panel's logical and backing dimensions.
        // A render-matching override instead sizes the backing store to the
        // stream, avoiding capture-side resampling on both Retina and 1x panels.
        var resolvedMode = modeOverride ?? TBVirtualDisplayModeSize(
            width: profile.modeWidth,
            height: profile.modeHeight,
            isHiDPI: profile.hiDPI
        )

        // macOS refuses a HiDPI mode whose backing store exceeds the advertised panel.
        if resolvedMode.backingWidth > profile.panelWidth || resolvedMode.backingHeight > profile.panelHeight {
            NSLog(
                "TargetBridge: mode override %dx%d needs a %dx%d backing store, exceeds panel %dx%d; falling back to receiver profile",
                resolvedMode.width, resolvedMode.height,
                resolvedMode.backingWidth, resolvedMode.backingHeight,
                profile.panelWidth, profile.panelHeight
            )
            resolvedMode = TBVirtualDisplayModeSize(
                width: profile.modeWidth,
                height: profile.modeHeight,
                isHiDPI: profile.hiDPI
            )
        }

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.name = "\(identity.displayNamePrefix) - \(profile.receiverName)"
        descriptor.vendorID = 0xEEEE
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
        settings.hiDPI = resolvedMode.isHiDPI
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
        guard activatePreferredMode(for: display.displayID,
                                    mode: resolvedMode,
                                    refreshRate: preferredRefreshRate,
                                    savedChoice: savedChoice) else {
            // `apply(settings)` only publishes the modes. It does not promise
            // that WindowServer selected the requested 1x/HiDPI variant.
            return false
        }

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
                    success = TBVirtualDisplayModeSelection.applyAndVerify(.snapshot(chosenMode),
                        apply: { CGDisplaySetDisplayMode(displayID, chosenMode, nil) == .success },
                        readBack: { CGDisplayCopyDisplayMode(displayID).map(TBVirtualDisplayModeSelection.Candidate.snapshot) })
                }
            }
            if success {
                if let current = CGDisplayCopyDisplayMode(displayID) {
                    NSLog("TargetBridge: virtual display %u selected %dx%d points, %dx%d pixels at %.2f Hz",
                          displayID, current.width, current.height,
                          current.pixelWidth, current.pixelHeight, current.refreshRate)
                }
                return true
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        let current = CGDisplayCopyDisplayMode(displayID)
        NSLog("TargetBridge: virtual display %u could not activate %dx%d points, %dx%d pixels; current=%dx%d points, %dx%d pixels",
              displayID, mode.width, mode.height, mode.backingWidth, mode.backingHeight,
              current?.width ?? 0, current?.height ?? 0, current?.pixelWidth ?? 0, current?.pixelHeight ?? 0)
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

        let index = TBVirtualDisplayModeSelection.savedIndex(
            in: modes.map(TBVirtualDisplayModeSelection.Candidate.snapshot), choice: choice)
        return index.map { modes[$0] }
    }

    /// Select the mode by its backing pixels as well as its logical size. A
    /// virtual HiDPI display exposes both a Retina 2x and a low-resolution 1x
    /// variant that can report the same logical 2560x1440 size. Choosing only
    /// by points made Render Matching restore the blurry 1x variant.
    private func preferredMode(for displayID: CGDirectDisplayID,
                               mode: TBVirtualDisplayModeSize,
                               refreshRate: Double) -> CGDisplayMode? {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let modesCF = CGDisplayCopyAllDisplayModes(displayID, options) else {
            return nil
        }
        let modes = modesCF as? [CGDisplayMode] ?? []

        let index = TBVirtualDisplayModeSelection.preferredIndex(
            in: modes.map(TBVirtualDisplayModeSelection.Candidate.snapshot),
            mode: mode, refreshRate: refreshRate)
        return index.map { modes[$0] }
    }
}
