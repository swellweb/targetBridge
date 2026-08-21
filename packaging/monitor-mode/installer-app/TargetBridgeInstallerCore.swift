import CoreGraphics
import Foundation

enum InstallRole: String, CaseIterable {
    case sender
    case receiver

    var deviceTitle: String {
        switch self {
        case .receiver: return "Questo Mac diventa lo schermo"
        case .sender: return "Questo è il Mac che userai"
        }
    }

    var detail: String {
        switch self {
        case .receiver:
            return "Mostrerà l’immagine dell’altro Mac."
        case .sender:
            return "Qui aprirai app, documenti e finestre."
        }
    }
}
enum RoleConfidence: Equatable {
    case exact
    case inferred
    case compatibleFamily
    case unsupported
}

struct DisplayProfile: Equatable {
    var widthPixels: Int
    var heightPixels: Int
    var physicalWidthMillimetres: Double?
    var physicalHeightMillimetres: Double?
    var isBuiltIn: Bool
    var isActive: Bool
    var isVirtual: Bool

    init(
        widthPixels: Int,
        heightPixels: Int,
        physicalWidthMillimetres: Double? = nil,
        physicalHeightMillimetres: Double? = nil,
        isBuiltIn: Bool,
        isActive: Bool = true,
        isVirtual: Bool = false
    ) {
        self.widthPixels = widthPixels
        self.heightPixels = heightPixels
        self.physicalWidthMillimetres = physicalWidthMillimetres
        self.physicalHeightMillimetres = physicalHeightMillimetres
        self.isBuiltIn = isBuiltIn
        self.isActive = isActive
        self.isVirtual = isVirtual
    }

    var pixelArea: Int64 {
        Int64(max(widthPixels, 0)) * Int64(max(heightPixels, 0))
    }

    var diagonalInches: Double? {
        guard let width = physicalWidthMillimetres,
              let height = physicalHeightMillimetres,
              width >= 100,
              height >= 60 else { return nil }
        return hypot(width, height) / 25.4
    }

    var isUsablePhysicalDisplay: Bool {
        isActive && !isVirtual && widthPixels > 0 && heightPixels > 0
    }
}

struct HardwareProfile: Equatable {
    var modelIdentifier: String
    var modelName: String
    var architecture: String
    var operatingSystemVersion: String
    var displays: [DisplayProfile]

    init(
        modelIdentifier: String,
        modelName: String = "",
        architecture: String,
        operatingSystemVersion: String,
        displays: [DisplayProfile] = []
    ) {
        self.modelIdentifier = modelIdentifier
        self.modelName = modelName
        self.architecture = architecture
        self.operatingSystemVersion = operatingSystemVersion
        self.displays = displays
    }

    var usableDisplays: [DisplayProfile] {
        displays.filter(\.isUsablePhysicalDisplay)
    }

    var hasUsableDisplay: Bool { !usableDisplays.isEmpty }

    var largestDisplay: DisplayProfile? {
        usableDisplays.max(by: TargetBridgeHardwarePolicy.displayIsSmaller)
    }

    var largestBuiltInDisplay: DisplayProfile? {
        usableDisplays.filter(\.isBuiltIn).max(by: TargetBridgeHardwarePolicy.displayIsSmaller)
    }
}

struct RoleDecision: Equatable {
    var role: InstallRole?
    var confidence: RoleConfidence
    var explanation: String
}

struct PairRoleDecision: Equatable {
    var firstRole: InstallRole?
    var secondRole: InstallRole?
    var confidence: RoleConfidence
    var explanation: String
}

enum TargetBridgeHardwarePolicy {
    static let referenceReceiver = "iMac18,2"
    static let referenceSender = "Mac16,10"

    static func decide(for hardware: HardwareProfile) -> RoleDecision {
        switch hardware.modelIdentifier {
        case referenceReceiver:
            return RoleDecision(
                role: .receiver,
                confidence: .exact,
                explanation: "iMac Retina 4K 21,5-inch 2017 riconosciuto"
            )
        case referenceSender:
            return RoleDecision(
                role: .sender,
                confidence: .exact,
                explanation: "Mac mini M4 riconosciuto"
            )
        default:
            if isIMac(hardware) {
                return RoleDecision(
                    role: .receiver,
                    confidence: .compatibleFamily,
                    explanation: "Il pannello integrato dell’iMac è adatto a diventare lo schermo."
                )
            }
            if isMacBook(hardware) {
                return RoleDecision(
                    role: .sender,
                    confidence: .compatibleFamily,
                    explanation: "Un portatile è normalmente il Mac più comodo da usare direttamente."
                )
            }
            if isMacMini(hardware) {
                return RoleDecision(
                    role: .sender,
                    confidence: .compatibleFamily,
                    explanation: hardware.hasUsableDisplay
                        ? "Questo Mac è normalmente quello su cui lavorerai."
                        : "Non risulta collegato uno schermo: questo è il Mac su cui lavorerai."
                )
            }
            if let diagonal = hardware.largestBuiltInDisplay?.diagonalInches {
                if diagonal >= 18 {
                    return RoleDecision(
                        role: .receiver,
                        confidence: .inferred,
                        explanation: "Il grande pannello integrato è adatto a diventare lo schermo."
                    )
                }
                if diagonal <= 17.5 {
                    return RoleDecision(
                        role: .sender,
                        confidence: .inferred,
                        explanation: "Il pannello compatto indica che probabilmente userai direttamente questo Mac."
                    )
                }
            }
            if !hardware.hasUsableDisplay {
                return RoleDecision(
                    role: .sender,
                    confidence: .inferred,
                    explanation: "Non risulta collegato uno schermo: questo è il Mac su cui lavorerai."
                )
            }
            return RoleDecision(
                role: nil,
                confidence: .unsupported,
                explanation: "Non c’è una scelta evidente. Seleziona come vuoi usare questo Mac."
            )
        }
    }

    static func decide(first: HardwareProfile, second: HardwareProfile) -> PairRoleDecision {
        if isIMac(first) != isIMac(second) {
            return complementaryDecision(
                firstIsDisplay: isIMac(first),
                confidence: .exact,
                explanation: "L’iMac ha il pannello più adatto a diventare lo schermo."
            )
        }

        if first.hasUsableDisplay != second.hasUsableDisplay {
            return complementaryDecision(
                firstIsDisplay: first.hasUsableDisplay,
                confidence: .exact,
                explanation: "Il Mac senza schermo rimane quello su cui lavorerai."
            )
        }

        if isMacBook(first) != isMacBook(second) {
            return complementaryDecision(
                firstIsDisplay: !isMacBook(first),
                confidence: .exact,
                explanation: "Il portatile rimane il Mac che userai direttamente."
            )
        }

        // Due portatili sono entrambi plausibili come Mac principale: la sola
        // dimensione non basta per imporre all'utente una scelta sorprendente.
        if isMacBook(first) && isMacBook(second) {
            return PairRoleDecision(
                firstRole: nil,
                secondRole: nil,
                confidence: .unsupported,
                explanation: "I due Mac sono simili. Scegli quale deve diventare lo schermo."
            )
        }

        if let firstDisplay = first.largestDisplay,
           let secondDisplay = second.largestDisplay {
            if let firstDiagonal = firstDisplay.diagonalInches,
               let secondDiagonal = secondDisplay.diagonalInches,
               abs(firstDiagonal - secondDiagonal) >= 1.5 {
                return complementaryDecision(
                    firstIsDisplay: firstDiagonal > secondDiagonal,
                    confidence: .inferred,
                    explanation: "Il Mac con lo schermo fisicamente più grande è la scelta consigliata."
                )
            }

            let smallerArea = max(1, min(firstDisplay.pixelArea, secondDisplay.pixelArea))
            let largerArea = max(firstDisplay.pixelArea, secondDisplay.pixelArea)
            if Double(largerArea) / Double(smallerArea) >= 1.35 {
                return complementaryDecision(
                    firstIsDisplay: firstDisplay.pixelArea > secondDisplay.pixelArea,
                    confidence: .inferred,
                    explanation: "Il Mac con lo schermo più definito è la scelta consigliata."
                )
            }
        }

        return PairRoleDecision(
            firstRole: nil,
            secondRole: nil,
            confidence: .unsupported,
            explanation: "Non c’è una scelta evidente. Seleziona quale Mac deve diventare lo schermo."
        )
    }

    static func displayIsSmaller(_ lhs: DisplayProfile, _ rhs: DisplayProfile) -> Bool {
        switch (lhs.diagonalInches, rhs.diagonalInches) {
        case let (left?, right?) where abs(left - right) >= 0.1:
            return left < right
        default:
            return lhs.pixelArea < rhs.pixelArea
        }
    }

    private static func isIMac(_ hardware: HardwareProfile) -> Bool {
        let value = "\(hardware.modelName) \(hardware.modelIdentifier)".lowercased()
        return value.contains("imac")
    }

    private static func isMacBook(_ hardware: HardwareProfile) -> Bool {
        let value = "\(hardware.modelName) \(hardware.modelIdentifier)".lowercased()
        return value.contains("macbook")
    }

    private static func isMacMini(_ hardware: HardwareProfile) -> Bool {
        let value = "\(hardware.modelName) \(hardware.modelIdentifier)".lowercased()
        return value.contains("mac mini") || value.contains("macmini")
    }

    private static func complementaryDecision(
        firstIsDisplay: Bool,
        confidence: RoleConfidence,
        explanation: String
    ) -> PairRoleDecision {
        PairRoleDecision(
            firstRole: firstIsDisplay ? .receiver : .sender,
            secondRole: firstIsDisplay ? .sender : .receiver,
            confidence: confidence,
            explanation: explanation
        )
    }

    static func minimumMajorVersion(for role: InstallRole) -> Int {
        role == .receiver ? 13 : 14
    }

    static func supportsOS(_ version: String, role: InstallRole) -> Bool {
        guard let first = version.split(separator: ".").first,
              let major = Int(first) else { return false }
        return major >= minimumMajorVersion(for: role)
    }
}

enum TargetBridgeHardwareProbe {
    static func currentProfile(environment: [String: String] = ProcessInfo.processInfo.environment) -> HardwareProfile {
        let model = environment["TB_TEST_MODEL"] ?? sysctlValue("hw.model") ?? "unknown"
        let modelName = environment["TB_TEST_MODEL_NAME"]
            ?? (environment["TB_TEST_MODEL"] == nil ? systemProfilerModelName() : nil)
            ?? ""
        let architecture = environment["TB_TEST_ARCH"] ?? sysctlValue("hw.optional.arm64").flatMap {
            $0 == "1" ? "arm64" : nil
        } ?? machineArchitecture()
        let version = environment["TB_TEST_OS_VERSION"] ?? ProcessInfo.processInfo.operatingSystemVersionString
        return HardwareProfile(
            modelIdentifier: model,
            modelName: modelName,
            architecture: architecture,
            operatingSystemVersion: normalizedVersion(version),
            displays: environment["TB_TEST_MODEL"] == nil ? activeDisplays() : []
        )
    }

    private static func activeDisplays() -> [DisplayProfile] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = Array(repeating: CGDirectDisplayID(), count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { id in
            let size = CGDisplayScreenSize(id)
            return DisplayProfile(
                widthPixels: CGDisplayPixelsWide(id),
                heightPixels: CGDisplayPixelsHigh(id),
                physicalWidthMillimetres: size.width > 0 ? size.width : nil,
                physicalHeightMillimetres: size.height > 0 ? size.height : nil,
                isBuiltIn: CGDisplayIsBuiltin(id) != 0,
                isActive: CGDisplayIsActive(id) != 0,
                isVirtual: CGDisplayVendorNumber(id) == 0xEEEE
            )
        }
    }

    private static func systemProfilerModelName() -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPHardwareDataType", "-json"]
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = root["SPHardwareDataType"] as? [[String: Any]],
                  let modelName = items.first?["machine_name"] as? String,
                  !modelName.isEmpty else { return nil }
            return modelName
        } catch {
            return nil
        }
    }

    private static func machineArchitecture() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }

    private static func sysctlValue(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    private static func normalizedVersion(_ value: String) -> String {
        if let match = value.range(of: #"\d+(?:\.\d+){0,2}"#, options: .regularExpression) {
            return String(value[match])
        }
        return value
    }
}
