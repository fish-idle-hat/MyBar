import FanControlProtocol
import XCTest

final class SmartFanCurveTests: XCTestCase {
    func testBalancedCurveLeavesCoolSystemAutomatic() {
        XCTAssertEqual(SmartFanCurve.demand(temperature: 50, profile: .balanced), 0)
        XCTAssertEqual(SmartFanCurve.demand(temperature: 92, profile: .balanced), 1)
    }

    func testBalancedCurveInterpolates() {
        XCTAssertEqual(SmartFanCurve.demand(temperature: 62.5, profile: .balanced), 0.475, accuracy: 0.001)
    }

    func testCoolProfileEngagesEarlierThanQuiet() {
        let cool = SmartFanCurve.demand(temperature: 55, profile: .cool)
        let quiet = SmartFanCurve.demand(temperature: 55, profile: .quiet)
        XCTAssertGreaterThan(cool, quiet)
    }

    func testSynchronizedDemandRespectsEachFansRange() {
        let fans = [
            FanCapability(index: 0, minimumRPM: 2_000, maximumRPM: 8_000, modeKey: "F0md"),
            FanCapability(index: 1, minimumRPM: 2_400, maximumRPM: 7_600, modeKey: "F1md"),
        ]
        let targets = SmartFanCurve.targets(capabilities: fans, demand: 0.5)
        XCTAssertEqual(targets, [FanTarget(index: 0, rpm: 5_000), FanTarget(index: 1, rpm: 5_000)])
    }

    func testTargetDemandIsClamped() {
        let fan = FanCapability(index: 0, minimumRPM: 2_000, maximumRPM: 8_000, modeKey: "F0md")
        XCTAssertEqual(SmartFanCurve.targets(capabilities: [fan], demand: -1)[0].rpm, 2_000)
        XCTAssertEqual(SmartFanCurve.targets(capabilities: [fan], demand: 2)[0].rpm, 8_000)
    }
}
