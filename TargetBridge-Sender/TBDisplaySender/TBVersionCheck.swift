import Foundation

/// Sender and Receiver should run the same version: newer performance
/// features need both apps. Compares "4.0", "3.7.0-rc1" and the like.
enum TBVersionCheck {
    /// Where the "Download update" button points.
    static let downloadURL = URL(string: "https://github.com/mjfrank/targetBridge/releases/latest")!

    enum Mismatch: Equatable {
        /// The Receiver is older; nil when it doesn't report a version (before 4.0).
        case receiverOlder(String?)
        case senderOlder(String)
    }

    /// Numeric parts of a version; stops at the first non-numeric part ("-rc1").
    static func components(_ version: String) -> [Int] {
        var parts: [Int] = []
        for piece in version.split(separator: ".", omittingEmptySubsequences: false) {
            let digits = piece.prefix { $0.isNumber }
            guard let value = Int(digits) else { break }
            parts.append(value)
            if digits.count != piece.count { break }
        }
        return parts
    }

    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let a = components(lhs)
        let b = components(rhs)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    static func mismatch(sender: String, receiver: String?) -> Mismatch? {
        guard let receiver, !receiver.isEmpty else { return .receiverOlder(nil) }
        switch compare(sender, receiver) {
        case .orderedSame: return nil
        case .orderedDescending: return .receiverOlder(receiver)
        case .orderedAscending: return .senderOlder(receiver)
        }
    }
}
