import XCTest
@testable import ThermoBar

final class MonitoringFeaturesTests: XCTestCase {
    func testPersonalBaselineRequiresLearningAndPersists() throws {
        let suite = "ThermoBarTests.Baseline.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let baseline = PersonalBaseline(defaults: defaults)
        let start = Date(timeIntervalSince1970: 20_000)
        for i in 0..<20 {
            baseline.update(snapshot(at: start.addingTimeInterval(Double(i) * 60), temperature: 45 + Double(i % 5)))
        }
        baseline.update(snapshot(at: start.addingTimeInterval(1201), temperature: 90))
        XCTAssertEqual(baseline.current?.low, 45)
        XCTAssertEqual(baseline.current?.high, 49)
        baseline.flush()
        let restored = PersonalBaseline(defaults: defaults)
        restored.update(snapshot(at: start.addingTimeInterval(1260), temperature: 47))
        XCTAssertNotNil(restored.current)
    }

    func testIncidentRecordingRemainsBounded() {
        let recorder = IncidentRecorder(storageURL: nil)
        let start = Date(timeIntervalSince1970: 10_000)
        for i in 0..<1400 {
            recorder.record(snapshot: snapshot(at: start.addingTimeInterval(Double(i)), temperature: 84),
                            alerts: StableAlertState(chipOverheat: true))
        }
        XCTAssertLessThanOrEqual(recorder.visibleIncidents.first?.points.count ?? 0, 600)
    }

    func testThermalPredictionUsesRecentTrend() throws {
        let predictor = ThermalPredictor()
        let start = Date(timeIntervalSince1970: 1_000)
        var prediction: ThermalPrediction?
        for index in 0..<6 {
            prediction = predictor.update(
                temperature: 60 + Double(index),
                at: start.addingTimeInterval(Double(index) * 10)
            )
        }
        XCTAssertGreaterThan(try XCTUnwrap(prediction).slopePerMinute, 0)
        XCTAssertNotNil(prediction?.minutesTo80)
    }

    func testSustainedAlertRequiresThreeSamplesAndThreeClearSamples() {
        let filter = SustainedAlertFilter()
        let start = Date()
        XCTAssertFalse(filter.update(snapshot: snapshot(at: start, temperature: 82), extractionFault: false).chipOverheat)
        XCTAssertFalse(filter.update(snapshot: snapshot(at: start.addingTimeInterval(1), temperature: 82), extractionFault: false).chipOverheat)
        XCTAssertTrue(filter.update(snapshot: snapshot(at: start.addingTimeInterval(2), temperature: 82), extractionFault: false).chipOverheat)
        XCTAssertTrue(filter.update(snapshot: snapshot(at: start.addingTimeInterval(3), temperature: 70), extractionFault: false).chipOverheat)
        XCTAssertTrue(filter.update(snapshot: snapshot(at: start.addingTimeInterval(4), temperature: 70), extractionFault: false).chipOverheat)
        XCTAssertFalse(filter.update(snapshot: snapshot(at: start.addingTimeInterval(5), temperature: 70), extractionFault: false).chipOverheat)
    }

    func testSensorConfidenceDistinguishesStaticAndDelayedReadings() {
        let now = Date()
        XCTAssertEqual(
            TemperatureReading(key: "Tp01", celsius: 60, group: .cpu, sampledAt: now, unchangedSamples: 60)
                .health(at: now).confidence,
            .staticReading
        )
        XCTAssertEqual(
            TemperatureReading(key: "Tp02", celsius: 61, group: .cpu, sampledAt: now.addingTimeInterval(-20))
                .health(at: now).confidence,
            .delayed
        )
    }

    func testSmartRulesNeverSelectManualOrSystemMode() {
        let decision = SmartRuleEngine.decide(snapshot: snapshot(at: Date(), temperature: 84), prediction: nil)
        XCTAssertEqual(decision.profile, .cool)
    }

    func testIncidentRecorderPersistsCompletedIncident() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThermoBar-Incident-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = IncidentRecorder(storageURL: url)
        let start = Date(timeIntervalSince1970: 2_000)
        recorder.record(snapshot: snapshot(at: start, temperature: 84), alerts: StableAlertState(chipOverheat: true))
        recorder.record(snapshot: snapshot(at: start.addingTimeInterval(121), temperature: 70), alerts: StableAlertState())
        recorder.record(snapshot: snapshot(at: start.addingTimeInterval(242), temperature: 70), alerts: StableAlertState())
        XCTAssertEqual(recorder.visibleIncidents.count, 1)
        XCTAssertEqual(IncidentRecorder(storageURL: url).visibleIncidents.count, 1)
    }

    private func snapshot(at date: Date, temperature: Double) -> HardwareSnapshot {
        let reading = TemperatureReading(key: "Tp01", celsius: temperature, group: .cpu, sampledAt: date)
        return HardwareSnapshot(
            timestamp: date,
            temperatureReadings: [reading],
            cpu: TemperatureSummary(maximum: temperature, mean: temperature, count: 1),
            gpu: nil,
            hottest: reading,
            fanRPM: [0, 0],
            cpuUsage: 0.2,
            cpuBreakdown: nil,
            gpuMetrics: GPUMetrics(usage: 0.1, rendererUsage: nil, tilerUsage: nil),
            powerMetrics: nil,
            topApps: [],
            memoryUsage: 0.5,
            memoryMetrics: nil,
            memoryLeakAssessment: nil,
            memoryPressure: .normal,
            storageMetrics: nil,
            batteryMetrics: nil,
            networkMetrics: nil,
            respondingTemperatureSensors: 1,
            discoveredTemperatureSensors: 1,
            thermalState: .nominal
        )
    }
}
