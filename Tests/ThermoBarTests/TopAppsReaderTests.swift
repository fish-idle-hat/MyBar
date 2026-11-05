import XCTest
@testable import ThermoBar

final class TopAppsReaderTests: XCTestCase {
    func testHelperNavigationUsesItsOwningAppAndDaemonRetainsExecutable() {
        let helperURL = URL(fileURLWithPath: "/Applications/Browser.app/Contents/Frameworks/Browser Helper.app/Contents/MacOS/Browser Helper")
        let helper = TopAppsReader.identity(forExecutableURL: helperURL)
        XCTAssertEqual(helper.applicationURL?.path, "/Applications/Browser.app")
        XCTAssertEqual(helper.executableURL, helperURL)
        XCTAssertEqual(helper.name, "Browser")
        let daemonURL = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/Test.framework/Support/spotlightknowledged")
        let daemon = TopAppsReader.identity(forExecutableURL: daemonURL)
        XCTAssertNil(daemon.applicationURL)
        XCTAssertEqual(daemon.executableURL, daemonURL)
    }

    func testProcessNamesCannotProduceBlankOrMultilineRows() {
        XCTAssertEqual(TopAppMetrics(name: " \n\t ", cpuPercent: 0, memoryBytes: 0).name, "Unknown process")
        XCTAssertEqual(TopAppMetrics(name: "Helper\n Service", cpuPercent: 0, memoryBytes: 0).name, "Helper Service")
    }

    func testBackgroundClassificationUsesFrontmostAppName() {
        XCTAssertFalse(TopAppsReader.isBackground(appName: "Google Chrome", frontmostName: "google chrome"))
        XCTAssertTrue(TopAppsReader.isBackground(appName: "Music", frontmostName: "Google Chrome"))
        XCTAssertTrue(TopAppsReader.isBackground(appName: "Music", frontmostName: nil))
    }

    func testResourceScoreIncludesAttributedEnergyUse() {
        let lowEnergy = TopAppMetrics(name: "Low", cpuPercent: 10, memoryBytes: 1_000_000_000, energyImpact: 2)
        let highEnergy = TopAppMetrics(name: "High", cpuPercent: 10, memoryBytes: 1_000_000_000, energyImpact: 40)

        XCTAssertGreaterThan(
            TopAppsReader.resourceScore(highEnergy, coreCount: 10, physicalMemory: 10_000_000_000),
            TopAppsReader.resourceScore(lowEnergy, coreCount: 10, physicalMemory: 10_000_000_000)
        )
    }
}
