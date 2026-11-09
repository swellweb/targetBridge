import Foundation

enum TBMenuBarIconPreference {
    private static let key = "fd.tbdisplaysender.showsMenuBarIcon"

    static func load(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }

    static func save(_ isVisible: Bool, defaults: UserDefaults = .standard) {
        defaults.set(isVisible, forKey: key)
    }
}
