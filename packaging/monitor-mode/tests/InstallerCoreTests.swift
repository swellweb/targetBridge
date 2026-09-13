import Foundation

@main
struct InstallerCoreTests {
    private static var checks = 0
    private static var failures = 0

    private static func check(_ label: String, _ condition: @autoclosure () -> Bool) {
        checks += 1
        if condition() {
            print("OK: \(label)")
        } else {
            failures += 1
            fputs("FAIL: \(label)\n", stderr)
        }
    }

    static func main() {
        let imac = HardwareProfile(modelIdentifier: "iMac18,2", architecture: "x86_64", operatingSystemVersion: "13.7.8")
        let mini = HardwareProfile(modelIdentifier: "Mac16,10", architecture: "arm64", operatingSystemVersion: "26.6")
        let rosettaMini = HardwareProfile(modelIdentifier: "Mac16,10", architecture: "x86_64", operatingSystemVersion: "26.6")
        let unknownArm = HardwareProfile(
            modelIdentifier: "Mac15,6",
            architecture: "arm64",
            operatingSystemVersion: "15.0",
            displays: [display(inches: 24, builtIn: false, width: 3840, height: 2160)]
        )
        let otherIMac = HardwareProfile(modelIdentifier: "iMac18,3", architecture: "x86_64", operatingSystemVersion: "13.7")
        let legacyMini = HardwareProfile(modelIdentifier: "Macmini8,1", architecture: "x86_64", operatingSystemVersion: "14.7")
        let headlessMini = HardwareProfile(modelIdentifier: "Macmini9,1", architecture: "arm64", operatingSystemVersion: "14.7")
        let macBook13 = HardwareProfile(
            modelIdentifier: "MacBookPro17,1",
            modelName: "MacBook Pro",
            architecture: "arm64",
            operatingSystemVersion: "15.0",
            displays: [display(inches: 13.3, builtIn: true, width: 2560, height: 1600)]
        )
        let largeUnknown = HardwareProfile(
            modelIdentifier: "Mac99,1",
            modelName: "Mac",
            architecture: "arm64",
            operatingSystemVersion: "15.0",
            displays: [display(inches: 23.6, builtIn: true, width: 4480, height: 2520)]
        )

        check("reference iMac selects Receiver", TargetBridgeHardwarePolicy.decide(for: imac).role == .receiver)
        check("reference iMac is exact", TargetBridgeHardwarePolicy.decide(for: imac).confidence == .exact)
        check("reference mini selects Sender", TargetBridgeHardwarePolicy.decide(for: mini).role == .sender)
        check("Rosetta cannot change mini role", TargetBridgeHardwarePolicy.decide(for: rosettaMini).role == .sender)
        check("unknown desktop Mac is not guessed", TargetBridgeHardwarePolicy.decide(for: unknownArm).role == nil)
        check("other Intel iMac is a warned Receiver", TargetBridgeHardwarePolicy.decide(for: otherIMac).confidence == .compatibleFamily)
        check("legacy Mac mini is a warned Sender", TargetBridgeHardwarePolicy.decide(for: legacyMini).role == .sender)
        check("headless Mac mini is the Mac to use", TargetBridgeHardwarePolicy.decide(for: headlessMini).role == .sender)
        check("13-inch MacBook is the Mac to use", TargetBridgeHardwarePolicy.decide(for: macBook13).role == .sender)
        check("large built-in panel becomes the display", TargetBridgeHardwarePolicy.decide(for: largeUnknown).role == .receiver)
        check("large built-in panel is inferred", TargetBridgeHardwarePolicy.decide(for: largeUnknown).confidence == .inferred)

        let miniAndIMac = TargetBridgeHardwarePolicy.decide(first: headlessMini, second: otherIMac)
        check("headless mini paired with iMac stays the Mac to use", miniAndIMac.firstRole == .sender)
        check("iMac paired with headless mini becomes the display", miniAndIMac.secondRole == .receiver)

        let macBookAndIMac = TargetBridgeHardwarePolicy.decide(first: macBook13, second: otherIMac)
        check("MacBook paired with iMac stays the Mac to use", macBookAndIMac.firstRole == .sender)
        check("iMac paired with MacBook becomes the display", macBookAndIMac.secondRole == .receiver)

        let secondNotebook = HardwareProfile(
            modelIdentifier: "MacBookAir10,1",
            modelName: "MacBook Air",
            architecture: "arm64",
            operatingSystemVersion: "15.0",
            displays: [display(inches: 13.6, builtIn: true, width: 2560, height: 1664)]
        )
        let twoNotebooks = TargetBridgeHardwarePolicy.decide(first: macBook13, second: secondNotebook)
        check("two notebooks require a user choice", twoNotebooks.firstRole == nil && twoNotebooks.secondRole == nil)

        let virtualOnlyMini = HardwareProfile(
            modelIdentifier: "Macmini9,1",
            architecture: "arm64",
            operatingSystemVersion: "15.0",
            displays: [DisplayProfile(
                widthPixels: 5120,
                heightPixels: 2880,
                physicalWidthMillimetres: 600,
                physicalHeightMillimetres: 340,
                isBuiltIn: false,
                isVirtual: true
            )]
        )
        check("TargetBridge virtual display is ignored", !virtualOnlyMini.hasUsableDisplay)

        let visibleRoleCopy = InstallRole.allCases
            .flatMap { [$0.deviceTitle, $0.detail] }
            .joined(separator: " ")
            .lowercased()
        check("visible role copy avoids sender", !visibleRoleCopy.contains("sender"))
        check("visible role copy avoids receiver", !visibleRoleCopy.contains("receiver"))
        check("visible role copy avoids trasmettitore", !visibleRoleCopy.contains("trasmettitore"))
        check("visible role copy avoids ricevitore", !visibleRoleCopy.contains("ricevitore"))
        check("Receiver accepts macOS 13", TargetBridgeHardwarePolicy.supportsOS("13.0", role: .receiver))
        check("Receiver rejects macOS 12", !TargetBridgeHardwarePolicy.supportsOS("12.6.9", role: .receiver))
        check("Sender accepts macOS 14", TargetBridgeHardwarePolicy.supportsOS("14.0", role: .sender))
        check("Sender rejects malformed version", !TargetBridgeHardwarePolicy.supportsOS("unknown", role: .sender))
        let normalized = TargetBridgeHardwareProbe.currentProfile(environment: [
            "TB_TEST_MODEL": "Mac16,10",
            "TB_TEST_ARCH": "arm64",
            "TB_TEST_OS_VERSION": "Version 26.6 (Build 25G72)"
        ])
        check("runtime OS description is normalized", normalized.operatingSystemVersion == "26.6")

        print("installer core tests: \(checks) checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }

    private static func display(
        inches: Double,
        builtIn: Bool,
        width: Int,
        height: Int
    ) -> DisplayProfile {
        let aspectWidth = 16.0
        let aspectHeight = 9.0
        let scale = inches * 25.4 / hypot(aspectWidth, aspectHeight)
        return DisplayProfile(
            widthPixels: width,
            heightPixels: height,
            physicalWidthMillimetres: aspectWidth * scale,
            physicalHeightMillimetres: aspectHeight * scale,
            isBuiltIn: builtIn
        )
    }
}
