import Foundation

@main
struct InstallerEventTests {
    private static var checks = 0
    private static var failures = 0

    private static func check(_ label: String, _ condition: @autoclosure () -> Bool) {
        checks += 1
        if !condition() {
            failures += 1
            fputs("FAIL: \(label)\n", stderr)
        }
    }

    static func main() {
        let parsed = InstallerEvent.parse(line: "TB_EVENT|preflight|hardware|pass|iMac18,2")
        check("event phase parsed", parsed?.phase == "preflight")
        check("event code parsed", parsed?.code == "hardware")
        check("event state parsed", parsed?.state == .passed)
        check("event message parsed", parsed?.message == "iMac18,2")
        check(
            "event message preserves separators",
            InstallerEvent.parse(line: "TB_EVENT|phase|code|info|one|two")?.message == "one|two"
        )
        check("ordinary output ignored", InstallerEvent.parse(line: "ordinary output") == nil)
        check("malformed event ignored", InstallerEvent.parse(line: "TB_EVENT|short") == nil)
        check("unknown state ignored", InstallerEvent.parse(line: "TB_EVENT|phase|code|maybe|message") == nil)

        let events = [
            InstallerEvent(phase: "preflight", code: "hardware", state: .passed, message: "hardware ok"),
            InstallerEvent(phase: "preflight", code: "package", state: .warning, message: "old warning"),
            InstallerEvent(phase: "preflight", code: "package", state: .passed, message: "package ok"),
            InstallerEvent(phase: "preflight", code: "architecture", state: .failed, message: "wrong architecture"),
            InstallerEvent(phase: "readiness", code: "link", state: .warning, message: "using Wi-Fi")
        ]
        let summary = InstallerEvent.summary(
            from: events,
            priorityCodes: ["hardware", "package", "link"]
        )
        check("failure appears first", summary.first?.code == "architecture")
        check("warning remains visible", summary.dropFirst().first?.code == "link")
        check("resolved warning is not prioritized", summary.dropFirst(2).first?.code == "hardware")
        check("summary has no duplicate codes", Set(summary.map(\.code)).count == summary.count)
        check(
            "summary limit is enforced",
            InstallerEvent.summary(from: events, priorityCodes: ["hardware"], limit: 2).count == 2
        )
        check("zero limit returns no rows", InstallerEvent.summary(from: events, priorityCodes: [], limit: 0).isEmpty)

        print("installer event tests: \(checks) checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
