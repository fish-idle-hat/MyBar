import XCTest
@testable import ThermoBar

final class BatteryLifeEstimatorTests: XCTestCase {
    func testEstimateUsesEnergyAndObservedDrain() throws {
        let suite = "ThermoBarTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let estimator = BatteryLifeEstimator(defaults: defaults)

        let estimate = estimator.update(
            level: 0.5,
            remainingEnergyWh: 50,
            dischargeWatts: 10,
            isCharging: false,
            systemMinutesRemaining: 300,
            topApps: [TopAppMetrics(name: "Browser", cpuPercent: 30, memoryBytes: 1_000_000_000)],
            at: Date()
        )

        XCTAssertEqual(estimate.minutesRemaining ?? 0, 300, accuracy: 1)
        XCTAssertEqual(estimate.confidence, .learning)
        XCTAssertFalse(estimate.history.isEmpty)
    }

    func testChargingSuppressesTimeToEmpty() throws {
        let suite = "ThermoBarTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let estimator = BatteryLifeEstimator(defaults: defaults)

        let estimate = estimator.update(
            level: 0.8,
            remainingEnergyWh: 70,
            dischargeWatts: 20,
            isCharging: true,
            systemMinutesRemaining: 210,
            topApps: [],
            at: Date()
        )

        XCTAssertNil(estimate.minutesRemaining)
    }
}
