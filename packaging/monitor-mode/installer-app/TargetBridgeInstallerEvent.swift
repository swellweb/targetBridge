import Foundation

enum InstallerCheckState: String, Equatable {
    case passed = "pass"
    case warning = "warn"
    case failed = "fail"
    case info
}

struct InstallerEvent: Equatable {
    var phase: String
    var code: String
    var state: InstallerCheckState
    var message: String

    static func parse(line: String) -> InstallerEvent? {
        guard line.hasPrefix("TB_EVENT|") else { return nil }
        let fields = line.split(separator: "|", maxSplits: 4, omittingEmptySubsequences: false)
        guard fields.count == 5,
              let state = InstallerCheckState(rawValue: String(fields[3])) else { return nil }
        return InstallerEvent(
            phase: String(fields[1]),
            code: String(fields[2]),
            state: state,
            message: String(fields[4])
        )
    }

    static func summary(
        from events: [InstallerEvent],
        priorityCodes: [String],
        limit: Int = 5
    ) -> [InstallerEvent] {
        guard limit > 0 else { return [] }
        var latestByCode: [String: InstallerEvent] = [:]
        events.forEach { latestByCode[$0.code] = $0 }

        var selected: [InstallerEvent] = []
        var includedCodes = Set<String>()
        func appendOnce(_ event: InstallerEvent) {
            guard includedCodes.insert(event.code).inserted else { return }
            selected.append(event)
        }

        // A failed or warning check must never be hidden by earlier successful
        // rows. Show the most recent actionable result first, then fill the
        // remaining space with the normal high-level summary.
        for state in [InstallerCheckState.failed, .warning] {
            for event in events.reversed()
                where event.state == state && latestByCode[event.code] == event {
                appendOnce(event)
            }
        }
        for code in priorityCodes {
            if let event = latestByCode[code] { appendOnce(event) }
        }
        for event in events.reversed() where latestByCode[event.code] == event {
            appendOnce(event)
        }
        return Array(selected.prefix(limit))
    }
}
