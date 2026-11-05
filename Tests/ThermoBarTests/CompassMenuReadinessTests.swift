import AppKit
import XCTest
@testable import ThermoBar

final class CompassMenuReadinessTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func ready() -> CompassMenuReadiness {
        var value = CompassMenuReadiness()
        value.enabled = true; value.sampledAt = now; value.estimate = 67
        value.quality = 0.8; value.baselineSamples = 20
        return value
    }

    func testReadinessRequiresConsentWarmupFreshnessAndValidData() {
        var value = ready()
        XCTAssertEqual(value.percentage(at: now), 65)
        XCTAssertNil(value.percentage(at: now.addingTimeInterval(181)))
        XCTAssertNil(value.percentage(at: now.addingTimeInterval(-1)))
        value.baselineSamples = 19
        XCTAssertNil(value.percentage(at: now))
        XCTAssertTrue(value.explanation(at: now).contains("19/20"))
        value = ready(); value.enabled = false
        XCTAssertNil(value.percentage(at: now))
        value = ready(); value.quality = 0.39
        XCTAssertNil(value.percentage(at: now))
        value.quality = .nan
        XCTAssertNil(value.percentage(at: now))
        for invalid in [Double.nan, .infinity, -1, 101] {
            value = ready(); value.estimate = invalid
            XCTAssertNil(value.percentage(at: now))
        }
    }

    func testPresentationNeverCountsUnapprovedSourcesOrTimeAsCoverage() {
        var p = CompassPresentation()
        p.settings.enabled = true
        p.state.latestDate = now; p.state.latestQuality = 1
        p.state.latestEstimate = ["readiness": 75]
        for name in ["activity", "switching", "streak", "breaks", "typing", "hourSin", "contextHome"] {
            p.state.latestRaw[name] = 0.5
            p.state.baseline[name] = CompassBaseline(mean: 0.5, count: 20)
        }
        XCTAssertEqual(CompassMenuReadiness(p).percentage(at: now), 75)
        p.settings.activity = false
        XCTAssertNil(CompassMenuReadiness(p).percentage(at: now))
        p.settings.typing = true // One available optional signal is insufficient.
        XCTAssertNil(CompassMenuReadiness(p).percentage(at: now))
        p.state.latestRaw["rhythm"] = 0.5
        p.state.baseline["rhythm"] = CompassBaseline(mean: 0.5, count: 20)
        XCTAssertEqual(CompassMenuReadiness(p).percentage(at: now), 75)
    }

    func testFanStopMustBeConfirmedForEveryFan() {
        XCTAssertTrue(StatusDashboardView.areFansConfirmedStopped([0, 0]))
        for values: [Double?] in [[], [nil], [0, nil], [0, 1], [0, -1], [.nan, 0], [.infinity, 0]] {
            XCTAssertFalse(StatusDashboardView.areFansConfirmedStopped(values))
        }
    }

    @MainActor
    func testMenuSwitchesWithoutNewTimersAndPreservesThermalWarnings() {
        let view = StatusDashboardView(frame: NSRect(x: 0, y: 0, width: 108, height: 22))
        view.setReadiness(ready())
        func update(_ fans: [Double?], temperature: Double = 42) {
            view.update(cpuUsage: 0.2, gpuUsage: 0.1, memoryUsage: 0.5,
                        temperature: temperature, fanRPM: fans, batteryTemperature: 30,
                        wifiLatencyMilliseconds: 10, memoryLeakAssessment: nil)
        }
        update([0, 0])
        XCTAssertEqual(view.primaryMetric(at: now).label, "RDY")
        XCTAssertEqual(view.primaryMetric(at: now).value, "65%")
        XCTAssertTrue(view.primaryMetricExplanation(at: now).contains("Blue bar"))
        XCTAssertEqual(view.primaryMetric(at: now.addingTimeInterval(181)).value, "—%")
        update([0, 1_000])
        XCTAssertEqual(view.primaryMetric(at: now).label, "TEMP")
        XCTAssertEqual(view.primaryMetric(at: now).value, "42°")
        update([0, nil])
        XCTAssertEqual(view.primaryMetric(at: now).label, "TEMP")
        update([0, 0], temperature: 80)
        XCTAssertTrue(view.primaryMetric(at: now).warning)
        XCTAssertEqual(view.primaryMetric(at: now).label, "TEMP")
        update([0, 0], temperature: 90)
        XCTAssertTrue(view.primaryMetric(at: now).high)
        update([0, 0])
        view.setReadiness(CompassMenuReadiness())
        XCTAssertEqual(view.primaryMetric(at: now).value, "—%")
        view.showLoading()
        XCTAssertEqual(view.primaryMetric(at: now).label, "TEMP")
    }

    @MainActor
    func testMenuReadinessRendersInBothAppearances() throws {
        let view = StatusDashboardView(frame: NSRect(x: 0, y: 0, width: 108, height: 22))
        var readiness = ready(); readiness.sampledAt = Date(); readiness.estimate = 100
        view.setReadiness(readiness)
        view.update(cpuUsage: 0.23, gpuUsage: 0.05, memoryUsage: 0.5,
                    temperature: 42, fanRPM: [0, 0], batteryTemperature: 30,
                    wifiLatencyMilliseconds: 10, memoryLeakAssessment: nil)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            view.appearance = NSAppearance(named: appearance)
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(data.count, 500)
            if ProcessInfo.processInfo.environment["MOOD_COMPASS_PREVIEW"] == "1" {
                try data.write(to: URL(fileURLWithPath: "/private/tmp/readiness-\(appearance.rawValue).png"))
            }
        }
    }

    func testBoundedWorkloadBenchmark() throws {
        guard ProcessInfo.processInfo.environment["MOOD_COMPASS_BENCHMARK"] == "1" else {
            throw XCTSkip("Opt-in release-mode performance probe")
        }
        let features = Dictionary(uniqueKeysWithValues: CompassSignal.allCases.map { ($0.rawValue, 0.5) })
        var state = CompassState()
        let end = now.addingTimeInterval(8 * 86_400)
        state.points = (0..<2_017).map { CompassPoint(timestamp: end.addingTimeInterval(Double($0 - 2_016) * 300), values: state.model.predict(features)) }
        state.days = (0..<180).map { CompassPoint(timestamp: end.addingTimeInterval(Double($0 - 179) * 86_400), values: state.model.predict(features)) }
        state.labels = (0..<512).map { index in
            CompassLabel(timestamp: now.addingTimeInterval(Double(index) * 900), features: features,
                         actual: state.model.predict(features).mapValues { min(100, $0 + 20) },
                         predicted: state.model.predict(features), modelVersion: 1, quality: 1, kind: "check-in")
        }
        let engine = MoodCompassEngine(state: state)
        let begin = ProcessInfo.processInfo.systemUptime
        for index in 1...1_000 {
            XCTAssertTrue(engine.observe(CompassObservation(timestamp: end.addingTimeInterval(Double(index) * 60), seconds: 60, signals: features)))
        }
        let sampleMilliseconds = (ProcessInfo.processInfo.systemUptime - begin) * 1_000 / 1_000
        state.reviewAnchor = now
        state.observedDays = (0..<7).map { MoodCompassEngine.dayKey(now.addingTimeInterval(Double($0) * 86_400)) }
        let weekly = MoodCompassEngine(state: state), reviewStart = ProcessInfo.processInfo.systemUptime
        weekly.reviewIfDue(at: end)
        let reviewMilliseconds = (ProcessInfo.processInfo.systemUptime - reviewStart) * 1_000
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("readiness-benchmark-\(UUID())")
        let file = directory.appendingPathComponent("state.plist")
        defer { try? FileManager.default.removeItem(at: directory) }
        let saveStart = ProcessInfo.processInfo.systemUptime
        try CompassStorage.save(weekly.state, to: file)
        let saveMilliseconds = (ProcessInfo.processInfo.systemUptime - saveStart) * 1_000
        let size = try Data(contentsOf: file).count
        print(String(format: "MOOD_BENCHMARK: sample %.3f ms; weekly(512 outcomes) %.2f ms; atomic save %.2f ms; full payload %d bytes", sampleMilliseconds, reviewMilliseconds, saveMilliseconds, size))
        XCTAssertLessThan(size, 1_000_000)
        // Generous regression budgets, not promises about other Macs or OS services.
        XCTAssertLessThan(sampleMilliseconds, 50)
        XCTAssertLessThan(reviewMilliseconds, 5_000)
    }
}
