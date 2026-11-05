import AppKit
import FanControlProtocol
import XCTest
@testable import ThermoBar

final class FanControlViewTests: XCTestCase {
    @MainActor
    func testFanGlyphRotatesAroundItsOwnCenter() throws {
        let view = SpinningFanView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        let center = NSPoint(x: view.bounds.midX, y: view.bounds.midY)
        let transform = SpinningFanView.rotationTransform(in: view.bounds, degrees: 137)
        let transformedCenter = transform.transform(center)

        XCTAssertEqual(transformedCenter.x, center.x, accuracy: 0.001)
        XCTAssertEqual(transformedCenter.y, center.y, accuracy: 0.001)
    }

    @MainActor
    func testControlRendersWhenHelperIsUnavailable() throws {
        let view = FanControlView(frame: NSRect(origin: .zero, size: FanControlView.preferredSize))
        view.appearance = NSAppearance(named: .aqua)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        view.update(FanControlViewState(
            selectedMode: .smart,
            activeMode: .system,
            profile: .balanced,
            helperReady: false,
            helperRegistration: "Not enabled",
            status: "Monitoring remains independent",
            capabilities: [],
            targets: [],
            actualRPM: [2_300, 2_420]
        ))
        view.layoutSubtreeIfNeeded()

        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let helperButton = try XCTUnwrap(view.subviews.compactMap { $0 as? NSButton }.first { $0.title == "Enable Helper…" })
        let modeControl = try XCTUnwrap(view.subviews.compactMap { $0 as? NSSegmentedControl }.first)
        XCTAssertGreaterThan(png.count, 5_000)
        XCTAssertFalse(helperButton.isHidden)
        XCTAssertFalse(modeControl.isEnabled(forSegment: FanControlMode.manual.rawValue))
        XCTAssertFalse(modeControl.isEnabled(forSegment: FanControlMode.smart.rawValue))
    }

    @MainActor
    func testConfirmedHelperShowsCompactManualFanControls() throws {
        let view = FanControlView(frame: NSRect(origin: .zero, size: FanControlView.preferredSize))
        view.update(FanControlViewState(
            selectedMode: .manual,
            activeMode: .manual,
            profile: .balanced,
            helperReady: true,
            helperRegistration: "Installed",
            helperFeedback: .confirmed,
            applyFeedback: .confirmed,
            status: "✓ Manual confirmed and active",
            systemBaselineRPM: 2_000,
            capabilities: [
                FanCapability(index: 0, minimumRPM: 1_350, maximumRPM: 5_777, modeKey: "F0md"),
                FanCapability(index: 1, minimumRPM: 1_350, maximumRPM: 5_777, modeKey: "F1md"),
            ],
            targets: [FanTarget(index: 0, rpm: 4_000), FanTarget(index: 1, rpm: 4_000)],
            manualTargets: [FanTarget(index: 0, rpm: 4_000), FanTarget(index: 1, rpm: 4_000)],
            actualRPM: [3_950, 4_020]
        ))
        view.layoutSubtreeIfNeeded()

        let modeControl = try XCTUnwrap(view.subviews.compactMap { $0 as? NSSegmentedControl }.first)
        let buttons = view.subviews.compactMap { $0 as? NSButton }
        let helperButton = try XCTUnwrap(buttons.first { $0.title == "Helper Ready" })
        let rows = view.subviews.compactMap { $0 as? FanRPMRowView }
        XCTAssertEqual(modeControl.label(forSegment: 0), "System")
        XCTAssertEqual(modeControl.label(forSegment: 1), "Manual")
        XCTAssertEqual(modeControl.label(forSegment: 2), "Auto Boost")
        XCTAssertEqual(modeControl.selectedSegment, FanControlMode.manual.rawValue)
        XCTAssertTrue(helperButton.isHidden)
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { $0.slider.isEditable })
    }

    func testLinkedManualTargetsPreserveEquivalentFanDemand() throws {
        let capabilities = [
            FanCapability(index: 0, minimumRPM: 1_000, maximumRPM: 7_000, modeKey: "F0md"),
            FanCapability(index: 1, minimumRPM: 2_000, maximumRPM: 8_000, modeKey: "F1md"),
        ]
        let targets = FanControlView.synchronizedTargets(sourceIndex: 0, rpm: 4_000, capabilities: capabilities)

        XCTAssertEqual(targets, [FanTarget(index: 0, rpm: 4_000), FanTarget(index: 1, rpm: 5_000)])
    }

    func testTemperatureSensorsAreGroupedAndNamedForDisplay() {
        let sensors = FanControlView.temperatureDisplaySensors([
            TemperatureReading(key: "Tg02", celsius: 64, group: .gpu),
            TemperatureReading(key: "Tp02", celsius: 72, group: .cpu),
            TemperatureReading(key: "Tp01", celsius: 71, group: .cpu),
        ])

        XCTAssertEqual(sensors.map(\.group), [.cpu, .cpu, .gpu])
        XCTAssertEqual(sensors.map(\.name), ["CPU Sensor 1", "CPU Sensor 2", "GPU Region 1"])
        XCTAssertEqual(sensors.map(\.key), ["Tp01", "Tp02", "Tg02"])
    }

    func testTemperatureInsightPinsCriticalCPUOutlierWithWorkloadContext() throws {
        let sensors = FanControlView.temperatureDisplaySensors([
            TemperatureReading(key: "Tp01", celsius: 61, group: .cpu),
            TemperatureReading(key: "Tp02", celsius: 63, group: .cpu),
            TemperatureReading(key: "Tp03", celsius: 64, group: .cpu),
            TemperatureReading(key: "Tp04", celsius: 94, group: .cpu),
        ])

        let insight = try XCTUnwrap(FanControlView.detectTemperatureInsights(
            sensors,
            cpuUsage: 0.86,
            gpuUsage: 0.10,
            topApps: [TopAppMetrics(name: "Google Chrome", cpuPercent: 72, memoryBytes: 2_000_000_000)]
        ).first)

        XCTAssertEqual(insight.sensor.key, "Tp04")
        XCTAssertEqual(insight.severity, .critical)
        XCTAssertTrue(insight.reason.contains("86%"))
        XCTAssertTrue(insight.reason.contains("Google Chrome"))
        XCTAssertTrue(insight.assessment.contains("plausible briefly"))
        XCTAssertTrue(insight.location.contains("CPU region"))
        XCTAssertTrue(insight.location.contains("not exposed"))
        XCTAssertTrue(insight.solution.contains("Pause"))
    }

    func testTemperatureInsightMarksLowLoadCriticalHeatAsUnusual() throws {
        let sensors = FanControlView.temperatureDisplaySensors([
            TemperatureReading(key: "Tg01", celsius: 62, group: .gpu),
            TemperatureReading(key: "Tg02", celsius: 63, group: .gpu),
            TemperatureReading(key: "Tg03", celsius: 92, group: .gpu),
        ])

        let insight = try XCTUnwrap(FanControlView.detectTemperatureInsights(
            sensors,
            cpuUsage: 0.12,
            gpuUsage: 0.08,
            topApps: [],
            thermalState: .nominal
        ).first)

        XCTAssertTrue(insight.assessment.contains("not normal if sustained"))
        XCTAssertTrue(insight.location.contains("GPU region"))
    }

    func testTemperatureInsightIgnoresNormalSensorSpread() {
        let sensors = FanControlView.temperatureDisplaySensors([
            TemperatureReading(key: "Tp01", celsius: 58, group: .cpu),
            TemperatureReading(key: "Tp02", celsius: 63, group: .cpu),
            TemperatureReading(key: "Tp03", celsius: 66, group: .cpu),
        ])

        XCTAssertTrue(FanControlView.detectTemperatureInsights(
            sensors,
            cpuUsage: 0.20,
            gpuUsage: 0.10,
            topApps: []
        ).isEmpty)
    }
}
