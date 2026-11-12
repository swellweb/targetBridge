import Foundation

let domain = ProcessInfo.processInfo.environment["TB_RELEASE_PREFS_DOMAIN"] ?? "com.targetbridge.sender"
let args = CommandLine.arguments
guard args.count == 3 else { fatalError("Expected snapshot|prepare|restore|verify backup.plist") }
let url = URL(fileURLWithPath: args[2])
let defaults = UserDefaults.standard
if args[1] == "snapshot" {
    let original = defaults.persistentDomain(forName: domain) ?? [:]
    let data = try PropertyListSerialization.data(fromPropertyList: original, format: .binary, options: 0)
    try data.write(to: url, options: .withoutOverwriting)
} else {
    let original = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as! [String: Any]
    switch args[1] {
    case "prepare":
        var copy = original
        if let data = original["fd.tbdisplaysender.sessions.v1"] as? Data {
            var sessions = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
            for index in sessions.indices {
                sessions[index]["inputControlRole"] = "off"
                sessions[index]["volume"] = 0.0
                sessions[index]["audioEnabled"] = true
            }
            copy["fd.tbdisplaysender.sessions.v1"] = try JSONSerialization.data(withJSONObject: sessions)
        }
        defaults.setPersistentDomain(copy, forName: domain)
    case "restore":
        let current = defaults.persistentDomain(forName: domain) ?? [:]
        let removed = Array(Set(current.keys).subtracting(original.keys))
        CFPreferencesSetMultiple(original as CFDictionary, removed as CFArray,
                                 domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard CFPreferencesSynchronize(domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            fatalError("Could not synchronize restored preferences")
        }
    case "verify":
        var expected = original
        var actual = defaults.persistentDomain(forName: domain) ?? [:]
        // The running app may serialize identical session dictionaries in a different key order.
        let sessionKey = "fd.tbdisplaysender.sessions.v1"
        if let data = expected[sessionKey] as? Data { expected[sessionKey] = try JSONSerialization.jsonObject(with: data) }
        if let data = actual[sessionKey] as? Data { actual[sessionKey] = try JSONSerialization.jsonObject(with: data) }
        guard NSDictionary(dictionary: expected).isEqual(NSDictionary(dictionary: actual)) else {
            fputs("Sender preferences differ from this run's backup\n", stderr)
            exit(1)
        }
        print("\(domain) preferences restored; session JSON compared structurally")
    default: fatalError("Unknown operation")
    }
}
defaults.synchronize()
