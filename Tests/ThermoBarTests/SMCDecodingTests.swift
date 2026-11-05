import AppKit
import XCTest
@testable import ThermoBar

final class SMCDecodingTests: XCTestCase {
    @MainActor
    func testDarkDashboardRendersInactiveRPMCapsules() throws {
        let view = StatusDashboardView(frame: NSRect(x: 0, y: 0, width: 108, height: 22))
        view.appearance = NSAppearance(named: .darkAqua)
        view.update(
            cpuUsage: 0.06,
            gpuUsage: 0,
            memoryUsage: 0.62,
            temperature: 35,
            fanRPM: [0, 0],
            batteryTemperature: 27,
            wifiLatencyMilliseconds: 12,
            memoryLeakAssessment: nil
        )
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 1_000)
        if let path = ProcessInfo.processInfo.environment["THERMOBAR_DASHBOARD_PREVIEW_PATH"] {
            try png.write(to: URL(fileURLWithPath: path))
        }
    }

    func testFixedFirmwareThermalLimitsAreNotTreatedAsLiveSensors() {
        XCTAssertFalse(HardwareMonitor.isUsableTemperature(key: "Tf06", celsius: 89.375))
        XCTAssertFalse(HardwareMonitor.isUsableTemperature(key: "Tf06", celsius: 94.2))
        XCTAssertFalse(HardwareMonitor.isUsableTemperature(key: "Tf16", celsius: 95.359375))
        XCTAssertFalse(HardwareMonitor.isUsableTemperature(key: "Tf16", celsius: 72.4))
        XCTAssertTrue(HardwareMonitor.isUsableTemperature(key: "Tf18", celsius: 35.5))
    }

    func testAppleSiliconFloatRPM() throws {
        let value = try SMC.decode(bytes: [0x00, 0xe8, 0x9a, 0x45], type: "flt ")
        XCTAssertEqual(value, 4957, accuracy: 0.01)
    }

    func testFixedPointRPM() throws {
        let value = try SMC.decode(bytes: [0x23, 0xf0], type: "fpe2")
        XCTAssertEqual(value, 2300, accuracy: 0.01)
    }

    func testTemperatureFixedPoint() throws {
        let value = try SMC.decode(bytes: [0x2a, 0x80], type: "sp78")
        XCTAssertEqual(value, 42.5, accuracy: 0.01)
    }

    func testMalformedValueIsNotReportedAsZero() {
        XCTAssertThrowsError(try SMC.decode(bytes: [], type: "flt "))
    }

    func testGPUPerformanceStatisticsAreNormalized() throws {
        let metrics = try XCTUnwrap(SystemMetricsReader.gpuMetrics(from: [
            "Device Utilization %": 63,
            "Renderer Utilization %": 53,
            "Tiler Utilization %": 37,
        ]))
        XCTAssertEqual(metrics.usage, 0.63, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(metrics.rendererUsage), 0.53, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(metrics.tilerUsage), 0.37, accuracy: 0.001)
    }

    func testMemoryLeakDetectorRequiresSustainedRepeatedGrowth() throws {
        let detector = MemoryLeakDetector(totalPhysicalMemory: 16_000_000_000)
        let start = Date(timeIntervalSince1970: 1_000)
        var result: MemoryLeakAssessment?
        for index in 0...18 {
            result = detector.update(
                metrics: MemoryMetrics(
                    usage: 0.72 + Double(index) * 0.006,
                    appBytes: 6_000_000_000 + UInt64(index) * 70_000_000,
                    wiredBytes: 2_000_000_000,
                    compressedBytes: 1_000_000_000 + UInt64(index) * 20_000_000
                ),
                at: start.addingTimeInterval(Double(index) * 10)
            )
        }
        XCTAssertGreaterThan(try XCTUnwrap(result).growthBytes, 1_000_000_000)
    }

    func testMemoryLeakDetectorIgnoresOneLargeAllocation() {
        let detector = MemoryLeakDetector(totalPhysicalMemory: 16_000_000_000)
        let start = Date(timeIntervalSince1970: 1_000)
        var result: MemoryLeakAssessment?
        for index in 0...18 {
            result = detector.update(
                metrics: MemoryMetrics(
                    usage: index == 0 ? 0.72 : 0.84,
                    appBytes: index == 0 ? 6_000_000_000 : 7_500_000_000,
                    wiredBytes: 2_000_000_000,
                    compressedBytes: index == 0 ? 1_000_000_000 : 1_600_000_000
                ),
                at: start.addingTimeInterval(Double(index) * 10)
            )
        }
        XCTAssertNil(result)
    }

    func testFanRPMIsAveragedAcrossAvailableFans() throws {
        let average = try XCTUnwrap(StatusDashboardView.averageFanRPM([2_000, nil, 3_000]))
        XCTAssertEqual(average, 2_500, accuracy: 0.01)
    }

    func testTachometerStartsAtZeroAndShowsOneThousandRPM() {
        XCTAssertEqual(StatusDashboardView.tachometerProgress(for: nil), 0)
        XCTAssertEqual(StatusDashboardView.tachometerProgress(for: 0), 0)
        XCTAssertEqual(StatusDashboardView.tachometerProgress(for: 1_000), 0.125, accuracy: 0.001)
        XCTAssertEqual(StatusDashboardView.tachometerProgress(for: 4_000), 0.5, accuracy: 0.001)
        XCTAssertEqual(StatusDashboardView.tachometerProgress(for: 7_000), 0.875, accuracy: 0.001)
        XCTAssertEqual(StatusDashboardView.tachometerProgress(for: 8_000), 1)
    }

    func testSegmentTachometerUsesOneSegmentPerThousandRPM() {
        XCTAssertEqual(StatusDashboardView.activeSegmentCount(for: nil), 0)
        XCTAssertEqual(StatusDashboardView.activeSegmentCount(for: 0), 0)
        XCTAssertEqual(StatusDashboardView.activeSegmentCount(for: 1), 1)
        XCTAssertEqual(StatusDashboardView.activeSegmentCount(for: 1_000), 1)
        XCTAssertEqual(StatusDashboardView.activeSegmentCount(for: 3_400), 4)
        XCTAssertEqual(StatusDashboardView.activeSegmentCount(for: 8_000), 8)
        XCTAssertEqual(StatusDashboardView.activeSegmentCount(for: 9_000), 8)
    }

    func testTachometerPartiallyFillsTheCurrentThousandRPMCapsule() {
        let fills = StatusDashboardView.tachometerFills(
            currentRPM: 2_500,
            systemBaselineRPM: nil,
            isOverrideActive: false
        )

        XCTAssertEqual(fills[0], .init(system: 1, boost: 0))
        XCTAssertEqual(fills[1], .init(system: 1, boost: 0))
        XCTAssertEqual(fills[2], .init(system: 0.5, boost: 0))
        XCTAssertEqual(fills[3], .init(system: 0, boost: 0))
    }

    func testTachometerPreciselyStacksSystemAndBoostRPM() {
        let fills = StatusDashboardView.tachometerFills(
            currentRPM: 4_500,
            systemBaselineRPM: 2_250,
            isOverrideActive: true
        )

        XCTAssertEqual(fills[1], .init(system: 1, boost: 0))
        XCTAssertEqual(fills[2], .init(system: 0.25, boost: 0.75))
        XCTAssertEqual(fills[3], .init(system: 0, boost: 1))
        XCTAssertEqual(fills[4], .init(system: 0, boost: 0.5))
        XCTAssertEqual(fills[5], .init(system: 0, boost: 0))
    }

    func testThermalHeadroomOnlyAppearsWhenFansAreStopped() {
        XCTAssertFalse(StatusDashboardView.shouldShowThermalHeadroom(for: nil))
        XCTAssertTrue(StatusDashboardView.shouldShowThermalHeadroom(for: 0))
        XCTAssertFalse(StatusDashboardView.shouldShowThermalHeadroom(for: 1))
    }

    func testThermalHeadroomMapsFortyToEightyDegreesAcrossEightSegments() {
        XCTAssertEqual(StatusDashboardView.thermalHeadroomSegmentCount(for: nil), 0)
        XCTAssertEqual(StatusDashboardView.thermalHeadroomSegmentCount(for: 35), 1)
        XCTAssertEqual(StatusDashboardView.thermalHeadroomSegmentCount(for: 40), 1)
        XCTAssertEqual(StatusDashboardView.thermalHeadroomSegmentCount(for: 50), 2)
        XCTAssertEqual(StatusDashboardView.thermalHeadroomSegmentCount(for: 60), 4)
        XCTAssertEqual(StatusDashboardView.thermalHeadroomSegmentCount(for: 70), 6)
        XCTAssertEqual(StatusDashboardView.thermalHeadroomSegmentCount(for: 80), 8)
        XCTAssertEqual(StatusDashboardView.thermalHeadroomSegmentCount(for: 90), 8)
    }

    func testSegmentStackSeparatesSystemRPMFromFanControlBoost() {
        let segments = StatusDashboardView.tachometerSegments(
            currentRPM: 5_600,
            systemBaselineRPM: 2_800,
            isOverrideActive: true
        )
        XCTAssertEqual(segments, [
            .system, .system, .system,
            .boost, .boost, .boost,
            .inactive, .inactive,
        ])
    }

    func testSegmentStackStaysRedWithoutActiveOverride() {
        let segments = StatusDashboardView.tachometerSegments(
            currentRPM: 5_600,
            systemBaselineRPM: 2_800,
            isOverrideActive: false
        )
        XCTAssertEqual(segments, [
            .system, .system, .system, .system, .system, .system,
            .inactive, .inactive,
        ])
    }

    func testSegmentStackNeverDrawsPastCurrentRPM() {
        let segments = StatusDashboardView.tachometerSegments(
            currentRPM: 2_000,
            systemBaselineRPM: 3_000,
            isOverrideActive: true
        )
        XCTAssertEqual(segments, [
            .system, .system,
            .inactive, .inactive, .inactive, .inactive, .inactive, .inactive,
        ])
    }

    func testHighMetricThresholds() {
        XCTAssertFalse(StatusDashboardView.isTemperatureHigh(nil))
        XCTAssertFalse(StatusDashboardView.isTemperatureHigh(89.9))
        XCTAssertTrue(StatusDashboardView.isTemperatureHigh(90))

        XCTAssertFalse(StatusDashboardView.isTemperatureWarning(79.9))
        XCTAssertTrue(StatusDashboardView.isTemperatureWarning(80))
        XCTAssertTrue(StatusDashboardView.isTemperatureWarning(89.9))
        XCTAssertFalse(StatusDashboardView.isTemperatureWarning(90))

        XCTAssertFalse(StatusDashboardView.isLoadHigh(nil))
        XCTAssertFalse(StatusDashboardView.isLoadHigh(0.899))
        XCTAssertTrue(StatusDashboardView.isLoadHigh(0.90))

        XCTAssertFalse(StatusDashboardView.isCPULoadWarning(0.849))
        XCTAssertTrue(StatusDashboardView.isCPULoadWarning(0.85))
        XCTAssertTrue(StatusDashboardView.isCPULoadWarning(0.899))
        XCTAssertFalse(StatusDashboardView.isCPULoadWarning(0.90))

        XCTAssertFalse(StatusDashboardView.isBatteryOverheat(nil))
        XCTAssertFalse(StatusDashboardView.isBatteryOverheat(39.9))
        XCTAssertTrue(StatusDashboardView.isBatteryOverheat(40))
        XCTAssertTrue(StatusDashboardView.shouldKeepBatteryOverheat(38))
        XCTAssertFalse(StatusDashboardView.shouldKeepBatteryOverheat(37.9))

        XCTAssertFalse(StatusDashboardView.isLatencyHigh(nil))
        XCTAssertFalse(StatusDashboardView.isLatencyHigh(99.9))
        XCTAssertTrue(StatusDashboardView.isLatencyHigh(100))
        XCTAssertTrue(StatusDashboardView.shouldKeepHighLatency(80))
        XCTAssertFalse(StatusDashboardView.shouldKeepHighLatency(79.9))
    }

    func testBidirectionalStartupChaseMovesOutAndBack() {
        XCTAssertEqual(StatusDashboardView.startupChaseSegments(forFrame: 0), [])
        XCTAssertEqual(StatusDashboardView.startupChaseSegments(forFrame: 2), [0, 1])
        XCTAssertEqual(StatusDashboardView.startupChaseSegments(forFrame: 9), [7])
        XCTAssertEqual(StatusDashboardView.startupChaseSegments(forFrame: 13), [3, 4])
        XCTAssertEqual(StatusDashboardView.startupChaseSegments(forFrame: 16), [0, 1])
        XCTAssertEqual(StatusDashboardView.startupChaseSegments(forFrame: 17), [])
    }

    func testStartupCenterBurstExpandsFromTheMiddleAndCollapses() {
        XCTAssertEqual(StatusDashboardView.startupCenterBurstSegments(forFrame: 0), [])
        XCTAssertEqual(StatusDashboardView.startupCenterBurstSegments(forFrame: 2), [3, 4])
        XCTAssertEqual(StatusDashboardView.startupCenterBurstSegments(forFrame: 8), [0, 1, 2, 3, 4, 5, 6, 7])
        XCTAssertEqual(StatusDashboardView.startupCenterBurstSegments(forFrame: 13), [2, 3, 4, 5])
        XCTAssertEqual(StatusDashboardView.startupCenterBurstSegments(forFrame: 17), [])
    }

    func testCenterIgnitionExpandsAndCollapses() {
        XCTAssertEqual(StatusDashboardView.centerIgnitionSegments(forFrame: 0), [])
        XCTAssertEqual(StatusDashboardView.centerIgnitionSegments(forFrame: 2), [3, 4])
        XCTAssertEqual(StatusDashboardView.centerIgnitionSegments(forFrame: 5), [0, 1, 2, 3, 4, 5, 6, 7])
        XCTAssertEqual(StatusDashboardView.centerIgnitionSegments(forFrame: 8), [2, 3, 4, 5])
        XCTAssertEqual(StatusDashboardView.centerIgnitionSegments(forFrame: 10), [])
    }

    func testFanStartRequiresKnownStoppedToSpinningTransition() {
        XCTAssertFalse(StatusDashboardView.didFanStart(previousRPM: nil, currentRPM: 1_200))
        XCTAssertTrue(StatusDashboardView.didFanStart(previousRPM: 0, currentRPM: 1_200))
        XCTAssertFalse(StatusDashboardView.didFanStart(previousRPM: 1_000, currentRPM: 1_200))
        XCTAssertFalse(StatusDashboardView.didFanStart(previousRPM: 0, currentRPM: 0))
        XCTAssertFalse(StatusDashboardView.didFanStart(previousRPM: 0, currentRPM: nil))
    }

    func testSignificantMetricChangeThresholds() {
        XCTAssertFalse(StatusDashboardView.hasSignificantChange(
            previousFanRPM: nil, currentFanRPM: 2_000,
            previousChipTemperature: 45, currentChipTemperature: 54.9,
            previousBatteryTemperature: 30, currentBatteryTemperature: 34.9,
            previousCPUUsage: 0.20, currentCPUUsage: 0.499,
            previousMemoryUsage: 0.50, currentMemoryUsage: 0.649
        ))
        XCTAssertTrue(StatusDashboardView.hasSignificantChange(
            previousFanRPM: 1_000, currentFanRPM: 2_000,
            previousChipTemperature: 45, currentChipTemperature: 45,
            previousBatteryTemperature: 30, currentBatteryTemperature: 30,
            previousCPUUsage: 0.20, currentCPUUsage: 0.20,
            previousMemoryUsage: 0.50, currentMemoryUsage: 0.50
        ))
        XCTAssertTrue(StatusDashboardView.hasSignificantChange(
            previousFanRPM: 1_000, currentFanRPM: 1_000,
            previousChipTemperature: 45, currentChipTemperature: 55,
            previousBatteryTemperature: 30, currentBatteryTemperature: 30,
            previousCPUUsage: 0.20, currentCPUUsage: 0.20,
            previousMemoryUsage: 0.50, currentMemoryUsage: 0.50
        ))
        XCTAssertTrue(StatusDashboardView.hasSignificantChange(
            previousFanRPM: 1_000, currentFanRPM: 1_000,
            previousChipTemperature: 45, currentChipTemperature: 45,
            previousBatteryTemperature: 30, currentBatteryTemperature: 35,
            previousCPUUsage: 0.20, currentCPUUsage: 0.20,
            previousMemoryUsage: 0.50, currentMemoryUsage: 0.50
        ))
        XCTAssertTrue(StatusDashboardView.hasSignificantChange(
            previousFanRPM: 1_000, currentFanRPM: 1_000,
            previousChipTemperature: 45, currentChipTemperature: 45,
            previousBatteryTemperature: 30, currentBatteryTemperature: 30,
            previousCPUUsage: 0.20, currentCPUUsage: 0.50,
            previousMemoryUsage: 0.50, currentMemoryUsage: 0.50
        ))
        XCTAssertTrue(StatusDashboardView.hasSignificantChange(
            previousFanRPM: 1_000, currentFanRPM: 1_000,
            previousChipTemperature: 45, currentChipTemperature: 45,
            previousBatteryTemperature: 30, currentBatteryTemperature: 30,
            previousCPUUsage: 0.20, currentCPUUsage: 0.20,
            previousMemoryUsage: 0.50, currentMemoryUsage: 0.65
        ))
    }

    func testCoreDataFailureDetection() {
        XCTAssertFalse(StatusDashboardView.isCoreDataIncomplete(
            temperature: 42,
            cpuUsage: 0.18,
            gpuUsage: 0.27,
            memoryUsage: 0.63,
            fanRPM: [0, 0]
        ))
        XCTAssertTrue(StatusDashboardView.isCoreDataIncomplete(
            temperature: nil,
            cpuUsage: 0.18,
            gpuUsage: 0.27,
            memoryUsage: 0.63,
            fanRPM: [0, 0]
        ))
        XCTAssertTrue(StatusDashboardView.isCoreDataIncomplete(
            temperature: 42,
            cpuUsage: 0.18,
            gpuUsage: 0.27,
            memoryUsage: 0.63,
            fanRPM: [0, nil]
        ))
        XCTAssertTrue(StatusDashboardView.isCoreDataIncomplete(
            temperature: 42,
            cpuUsage: 0.18,
            gpuUsage: nil,
            memoryUsage: 0.63,
            fanRPM: [0, 0]
        ))
    }
}
