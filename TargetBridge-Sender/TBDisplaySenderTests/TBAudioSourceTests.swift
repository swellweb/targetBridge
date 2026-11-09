import XCTest
@testable import TargetBridge

final class TBAudioSourceTests: XCTestCase {
    func testPersistedValuesStayStable() {
        XCTAssertEqual(TBAudioSource(rawValue: "system"), .systemCapture)
        XCTAssertEqual(TBAudioSource(rawValue: "device"), .outputDevice)
        XCTAssertNil(TBAudioSource(rawValue: "unknown"))
    }

    func testShellQuotingKeepsApostrophesInsidePath() {
        XCTAssertEqual(
            TBAudioDriverInstaller.shellQuoted("/Users/o'neil/App"),
            "'/Users/o'\\''neil/App'"
        )
    }

    func testAppleScriptQuotingEscapesQuotesAndBackslashes() {
        XCTAssertEqual(
            TBAudioDriverInstaller.appleScriptQuoted(#"a"b\c"#),
            #""a\"b\\c""#
        )
    }

    func testInstallCommandQuotesSourceAndRestartsCoreAudio() {
        let source = URL(fileURLWithPath: "/Applications/My Apps/TargetBridgeAudio.driver")
        let command = TBAudioDriverInstaller.installCommand(from: source)
        XCTAssertTrue(command.contains("'/Applications/My Apps/TargetBridgeAudio.driver'"))
        XCTAssertTrue(command.hasSuffix("/usr/bin/killall coreaudiod"))
    }
}
