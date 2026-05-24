import AppKit
import Foundation

@MainActor
final class TBAddonStore: ObservableObject {
    static let shared = TBAddonStore()
    private static let overridesDefaultsKey = "fd.tbdisplaysender.addonEnabledOverrides"

    @Published private(set) var addons: [TBAddonRecord] = []

    private let fileManager = FileManager.default

    private init() {
        ensureAddonsDirectoryExists()
        refresh()
    }

    var addonsDirectoryURL: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("TargetBridge", isDirectory: true)
            .appendingPathComponent("Addons", isDirectory: true)
    }

    func refresh() {
        ensureAddonsDirectoryExists()

        var merged: [String: TBAddonRecord] = [:]
        for record in loadBundledAddons() {
            merged[record.id] = record
        }
        for record in loadUserAddons() {
            merged[record.id] = record
        }

        addons = merged.values.sorted {
            if $0.origin == $1.origin {
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            return $0.origin == .bundled
        }
    }

    func isEnabled(_ addon: TBAddonRecord) -> Bool {
        enabledOverrides()[addon.id] ?? addon.manifest.defaultEnabled
    }

    func setEnabled(_ enabled: Bool, for addon: TBAddonRecord) {
        var overrides = enabledOverrides()
        overrides[addon.id] = enabled
        UserDefaults.standard.set(overrides, forKey: Self.overridesDefaultsKey)
        objectWillChange.send()
    }

    func isCapabilityEnabled(_ capability: TBAddonCapability) -> Bool {
        addons.contains { addon in
            isEnabled(addon) && addon.manifest.capabilities.contains(capability) && isCompatible(addon)
        }
    }

    func isCompatible(_ addon: TBAddonRecord) -> Bool {
        guard let minimum = addon.manifest.minimumSenderVersion, !minimum.isEmpty else {
            return true
        }
        return compareVersion(TBDisplaySenderBuildInfo.marketingVersion, to: minimum) != .orderedAscending
    }

    func openAddonsFolder() {
        ensureAddonsDirectoryExists()
        NSWorkspace.shared.open(addonsDirectoryURL)
    }

    @discardableResult
    func importManifest(from url: URL) throws -> TBAddonRecord {
        ensureAddonsDirectoryExists()
        let manifest = try decodeManifest(at: url)
        let destination = addonsDirectoryURL.appendingPathComponent("\(manifest.id).json")
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: url, to: destination)
        refresh()
        guard let imported = addons.first(where: { $0.id == manifest.id }) else {
            throw NSError(domain: "TargetBridge.Addons", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Imported addon could not be reloaded."
            ])
        }
        return imported
    }

    private func enabledOverrides() -> [String: Bool] {
        UserDefaults.standard.dictionary(forKey: Self.overridesDefaultsKey) as? [String: Bool] ?? [:]
    }

    private func loadBundledAddons() -> [TBAddonRecord] {
        var urls = Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: "Addons") ?? []
        if let resources = Bundle.main.resourceURL,
           let enumerator = fileManager.enumerator(
            at: resources,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
           ) {
            for case let url as URL in enumerator where url.pathExtension.lowercased() == "json" {
                urls.append(url)
            }
        }
        let uniqueURLs = Array(Set(urls))
        return uniqueURLs.compactMap { url in
            try? loadRecord(at: url, origin: .bundled)
        }
    }

    private func loadUserAddons() -> [TBAddonRecord] {
        guard let enumerator = fileManager.enumerator(
            at: addonsDirectoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var records: [TBAddonRecord] = []
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "json" else { continue }
            if let record = try? loadRecord(at: url, origin: .user) {
                records.append(record)
            }
        }
        return records
    }

    private func loadRecord(at url: URL, origin: TBAddonOrigin) throws -> TBAddonRecord {
        let manifest = try decodeManifest(at: url)
        return TBAddonRecord(manifest: manifest, origin: origin, sourceURL: url)
    }

    private func decodeManifest(at url: URL) throws -> TBAddonManifest {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(TBAddonManifest.self, from: data)
    }

    private func ensureAddonsDirectoryExists() {
        if !fileManager.fileExists(atPath: addonsDirectoryURL.path) {
            try? fileManager.createDirectory(at: addonsDirectoryURL, withIntermediateDirectories: true)
        }
    }

    private func compareVersion(_ lhs: String, to rhs: String) -> ComparisonResult {
        let left = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0) ?? 0 }
        let count = max(left.count, right.count)
        for index in 0..<count {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l < r { return .orderedAscending }
            if l > r { return .orderedDescending }
        }
        return .orderedSame
    }
}
