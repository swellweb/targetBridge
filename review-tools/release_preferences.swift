import Foundation

let domain = "com.targetbridge.sender"
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
        defaults.setPersistentDomain(original, forName: domain)
    case "verify":
        guard NSDictionary(dictionary: original).isEqual(to: defaults.persistentDomain(forName: domain) ?? [:]) else {
            fatalError("Sender preferences differ from this run's backup")
        }
        print("Sender preferences exactly restored")
    default: fatalError("Unknown operation")
    }
}
defaults.synchronize()
