import XCTest
@testable import TargetBridge

final class TBDisplaySenderVersionTests: XCTestCase {
    func testFooterShowsTheBuiltVersionAndBuildNumber() {
        XCTAssertEqual(TBDisplaySenderBuildInfo.versionDisplay,
                       "\(TBDisplaySenderBuildInfo.marketingVersion) + build \(TBDisplaySenderBuildInfo.buildNumber)")
        XCTAssertFalse(TBDisplaySenderBuildInfo.versionDisplay.contains("\\("))
        XCTAssertEqual(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
                       TBDisplaySenderBuildInfo.marketingVersion)
        XCTAssertEqual(Bundle.main.infoDictionary?["CFBundleVersion"] as? String,
                       TBDisplaySenderBuildInfo.buildNumber)
    }
}
