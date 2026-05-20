import CoreGraphics
import Foundation

extension CGVirtualDisplayDescriptor: @unchecked @retroactive Sendable {}
extension CGVirtualDisplay: @unchecked @retroactive Sendable {}
extension CGVirtualDisplaySettings: @unchecked @retroactive Sendable {}

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

    static func extendedDesktop() -> TBVirtualDisplayIdentity {
        let random = UInt32.random(in: 0x0100...0xFFFE)
        return TBVirtualDisplayIdentity(
            productID: 0x6000 | (random & 0x00FF),
            serialNumber: 0x2027_0000 | random,
            displayNamePrefix: "TB Extend",
            usesDedicatedArrangementIdentity: true
        )
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
        identity: TBVirtualDisplayIdentity
    ) -> Bool {
        destroy()
        let preferredRefreshRate = refreshRate ?? profile.refreshRate

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
            width: UInt(profile.modeWidth),
            height: UInt(profile.modeHeight),
            refreshRate: preferredRefreshRate
        ) else {
            return false
        }
        settings.modes = [mode]

        guard display.apply(settings), display.displayID != kCGNullDirectDisplay else {
            return false
        }

        activatePreferredMode(for: display.displayID, profile: profile, refreshRate: preferredRefreshRate)

        virtualDisplay = display
        displayID = display.displayID
        displayName = profile.receiverName
        identityDescription = "vendor=0x\(String(descriptor.vendorID, radix: 16)) product=0x\(String(identity.productID, radix: 16)) serial=0x\(String(identity.serialNumber, radix: 16))"
        return true
    }

    func destroy() {
        virtualDisplay = nil
        displayID = kCGNullDirectDisplay
        displayName = ""
        identityDescription = ""
    }

    @discardableResult
    private func activatePreferredMode(for displayID: CGDirectDisplayID, profile: TBMonitorDisplayProfile, refreshRate: Double) -> Bool {
        let timeout = Date().addingTimeInterval(2.0)
        while Date() < timeout {
            var success = false
            autoreleasepool {
                if let preferredMode = preferredMode(for: displayID, profile: profile, refreshRate: refreshRate) {
                    success = CGDisplaySetDisplayMode(displayID, preferredMode, nil) == .success
                }
            }
            if success {
                return true
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return false
    }

    private func preferredMode(for displayID: CGDirectDisplayID, profile: TBMonitorDisplayProfile, refreshRate: Double) -> CGDisplayMode? {
        guard let modesCF = CGDisplayCopyAllDisplayModes(displayID, nil) else {
            return nil
        }
        let modes = modesCF as? [CGDisplayMode] ?? []

        let matchingModes = modes.filter { mode in
            mode.width == profile.modeWidth && mode.height == profile.modeHeight
        }.sorted { $0.refreshRate > $1.refreshRate }

        if let exactMatch = matchingModes.first(where: { abs($0.refreshRate - refreshRate) < 0.5 }) {
            return exactMatch
        }

        return matchingModes.first
    }
}
