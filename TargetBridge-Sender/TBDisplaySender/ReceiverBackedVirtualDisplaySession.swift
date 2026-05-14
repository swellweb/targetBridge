import CoreGraphics
import Foundation

extension CGVirtualDisplayDescriptor: @unchecked @retroactive Sendable {}
extension CGVirtualDisplay: @unchecked @retroactive Sendable {}
extension CGVirtualDisplaySettings: @unchecked @retroactive Sendable {}

@MainActor
final class ReceiverBackedVirtualDisplaySession {
    private var virtualDisplay: CGVirtualDisplay?
    private(set) var displayID: CGDirectDisplayID = kCGNullDirectDisplay
    private(set) var displayName: String = ""

    func create(from profile: TBMonitorDisplayProfile) -> Bool {
        destroy()

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.name = "TB Monitor - \(profile.receiverName)"
        descriptor.vendorID = 0xEEEE
        descriptor.productID = 0x5000
        descriptor.serialNum = 0x2026
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
        settings.modes = [
            CGVirtualDisplayMode(
                width: UInt(profile.modeWidth),
                height: UInt(profile.modeHeight),
                refreshRate: profile.refreshRate
            )
        ]

        guard display.apply(settings), display.displayID != kCGNullDirectDisplay else {
            return false
        }

        virtualDisplay = display
        displayID = display.displayID
        displayName = profile.receiverName
        return true
    }

    func destroy() {
        virtualDisplay = nil
        displayID = kCGNullDirectDisplay
        displayName = ""
    }
}
