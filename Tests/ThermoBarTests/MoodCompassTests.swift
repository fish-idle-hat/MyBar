import AppKit
import CoreGraphics
import XCTest
@testable import ThermoBar

final class MoodCompassTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_780_000_000)
    private let signals = ["activity": 0.5, "switching": 0.5, "streak": 0.5, "breaks": 0.5, "typing": 0.5]

    private func observed(_ engine: MoodCompassEngine, at date: Date) {
        XCTAssertTrue(engine.observe(CompassObservation(timestamp: date, seconds: 60, signals: signals)))
    }
    private func reviewState(holdoutOpposesTraining: Bool = false, quality: Double = 1) -> CompassState {
        var state = CompassState()
        state.reviewAnchor = start
        state.observedDays = (0..<7).map { MoodCompassEngine.dayKey(start.addingTimeInterval(Double($0) * 86_400)) }
        let original = state.model.predict(signals)
        state.labels = (0..<32).map { index in
            let adjustment = holdoutOpposesTraining && index >= 24 ? -20.0 : 20.0
            return CompassLabel(timestamp: start.addingTimeInterval(Double(index / 4) * 86_400 + Double(index % 4) * 900),
                features: signals, actual: original.mapValues { min(100, max(0, $0 + adjustment)) },
                predicted: original, modelVersion: 1, quality: quality, kind: "check-in")
        }
        return state
    }

    func testDefaultIsOffAndHasNoInventedMoodOrHistory() {
        XCTAssertFalse(CompassSettings().enabled)
        XCTAssertFalse(CompassSettings().typing)
        let state = MoodCompassEngine().state
        XCTAssertTrue(state.points.isEmpty)
        XCTAssertTrue(state.labels.isEmpty)
        XCTAssertFalse(CompassPresentation().moodIsCalibrated)
    }

    func testBadDataIsRejectedWithoutMovingBaseline() {
        let engine = MoodCompassEngine()
        for observation in [
            CompassObservation(timestamp: start, seconds: 3_600, signals: signals),
            CompassObservation(timestamp: start, seconds: 60, signals: ["typing": .nan]),
            CompassObservation(timestamp: start, seconds: 60, signals: ["activity": 1.1]),
            CompassObservation(timestamp: start, seconds: 60, signals: ["typedText": 0.5]),
        ] { XCTAssertFalse(engine.observe(observation)) }
        XCTAssertTrue(engine.state.baseline.isEmpty)
        observed(engine, at: start)
        XCTAssertFalse(engine.observe(CompassObservation(timestamp: start, seconds: 60, signals: signals)))
        XCTAssertTrue(engine.state.labels.isEmpty, "Estimates must never create their own training labels")
    }

    func testTimeOnlyDoesNotBecomeBehaviourOrMoodHistory() {
        let engine = MoodCompassEngine()
        XCTAssertTrue(engine.observe(CompassObservation(timestamp: start, seconds: 60, signals: ["hourSin": 0.5, "hourCos": 0.5])))
        XCTAssertEqual(engine.state.latestQuality, 0)
        XCTAssertTrue(engine.state.points.isEmpty)
        XCTAssertTrue(engine.state.observedDays.isEmpty)
    }

    func testManualReportsArePersistableEvenWithNoBehaviouralHistory() {
        let engine = MoodCompassEngine()
        XCTAssertFalse(engine.state.hasData)
        XCTAssertTrue(engine.observe(CompassObservation(timestamp: start, seconds: 60, signals: ["hourSin": 0.5, "hourCos": 0.5])))
        XCTAssertTrue(engine.checkIn(["mood": 75], at: start))
        XCTAssertTrue(engine.state.points.isEmpty)
        XCTAssertTrue(engine.state.hasData, "Manual-only reports must be saved, not silently dropped")
    }

    func testMoodPriorIsNotPlottedAsMeasuredEmotion() {
        let engine = MoodCompassEngine()
        observed(engine, at: start)
        XCTAssertNil(engine.state.points.first?.values["mood"])
        XCTAssertNotNil(engine.state.points.first?.values["energy"])
    }

    func testBaselineLearnsSlowlyAndBucketsStayCompact() {
        let engine = MoodCompassEngine()
        for index in 0..<80 { observed(engine, at: start.addingTimeInterval(Double(index) * 60)) }
        let before = engine.state.baseline["typing"]!.mean
        XCTAssertTrue(engine.observe(CompassObservation(timestamp: start.addingTimeInterval(80 * 60), seconds: 60,
            signals: signals.merging(["typing": 1]) { _, new in new })))
        XCTAssertLessThan(abs(engine.state.baseline["typing"]!.mean - before), 0.002)
        XCTAssertLessThanOrEqual(engine.state.points.count, 18)
        XCTAssertEqual(engine.state.days.count, 1)
    }

    func testCheckInsRequireFreshSamplesAndRejectImpossibleScores() {
        let engine = MoodCompassEngine()
        XCTAssertFalse(engine.checkIn(["mood": 50], at: start))
        observed(engine, at: start)
        XCTAssertFalse(engine.checkIn(["mood": .infinity], at: start))
        XCTAssertFalse(engine.checkIn(["mood": 101], at: start))
        XCTAssertTrue(engine.checkIn(["mood": 75], at: start.addingTimeInterval(1)))
        XCTAssertFalse(engine.checkIn(["mood": 25], at: start.addingTimeInterval(2)))
        XCTAssertFalse(engine.checkIn(["mood": 25], at: start.addingTimeInterval(900)))
        XCTAssertEqual(engine.state.labels.first?.actual["mood"], 75)
        XCTAssertEqual(engine.state.labels.first?.predicted["mood"], 50)
        XCTAssertEqual(engine.meanAbsoluteError(), 25)
    }

    func testFocusOutcomeUsesSessionStartNotLaterFeatures() {
        let engine = MoodCompassEngine()
        observed(engine, at: start)
        XCTAssertTrue(engine.beginFocus(at: start))
        let original = engine.state.focusSession!.features
        XCTAssertFalse(engine.finishFocus(score: 75, at: start.addingTimeInterval(60)))
        XCTAssertTrue(engine.observe(CompassObservation(timestamp: start.addingTimeInterval(600), seconds: 60,
            signals: signals.merging(["typing": 0.9]) { _, new in new })))
        XCTAssertTrue(engine.finishFocus(score: 75, at: start.addingTimeInterval(601)))
        XCTAssertEqual(engine.state.labels.last?.features, original)
        XCTAssertEqual(engine.state.labels.last?.actual, ["readiness": 75])
        XCTAssertNil(engine.state.focusSession)
    }

    func testWeeklyReviewRequiresElapsedTimeAndObservedDays() {
        var state = reviewState()
        let early = MoodCompassEngine(state: state)
        early.reviewIfDue(at: start.addingTimeInterval(6 * 86_400))
        XCTAssertTrue(early.state.reviews.isEmpty)
        state.observedDays = Array(state.observedDays.prefix(3))
        let missing = MoodCompassEngine(state: state)
        missing.reviewIfDue(at: start.addingTimeInterval(9 * 86_400))
        XCTAssertTrue(missing.state.reviews.isEmpty)
    }

    func testNoFeedbackAndLowQualityFeedbackNeverChangeWeights() {
        for quality in [0.0, 0.2] {
            let engine = MoodCompassEngine(state: reviewState(quality: quality))
            engine.reviewIfDue(at: start.addingTimeInterval(8 * 86_400))
            XCTAssertEqual(engine.state.model.version, 1)
            XCTAssertEqual(engine.state.reviews.last?.outcome, "Held steady")
        }
    }

    func testHarmfulChronologicalHoldoutIsRejected() {
        let engine = MoodCompassEngine(state: reviewState(holdoutOpposesTraining: true))
        engine.reviewIfDue(at: start.addingTimeInterval(8 * 86_400))
        XCTAssertEqual(engine.state.model.version, 1)
        XCTAssertEqual(engine.state.reviews.last?.outcome, "Rejected")
    }

    func testSafeWeeklyUpdateIsBoundedAndRetainsPreviousModel() {
        let state = reviewState(), engine = MoodCompassEngine(state: reviewState())
        engine.reviewIfDue(at: start.addingTimeInterval(8 * 86_400))
        XCTAssertEqual(engine.state.model.version, 2)
        XCTAssertEqual(engine.state.guardrail?.previous, state.model)
        XCTAssertEqual(engine.state.previousModels.count, 1)
        XCTAssertEqual(engine.state.reviews.last?.outcome, "Provisional update")
        for metric in CompassMetric.allCases {
            XCTAssertLessThanOrEqual(abs(engine.state.model.bias[metric.rawValue]! - state.model.bias[metric.rawValue]!), 5.001)
        }
    }

    func testNewOutcomesAutomaticallyRollBackHarmfulAdjustment() {
        let state = reviewState(), engine = MoodCompassEngine(state: reviewState())
        let activation = start.addingTimeInterval(8 * 86_400)
        engine.reviewIfDue(at: activation)
        XCTAssertEqual(engine.state.model.version, 2)
        for index in 0..<8 {
            let now = activation.addingTimeInterval(Double(1 + index / 4) * 86_400 + Double(index % 4) * 900)
            observed(engine, at: now)
            XCTAssertTrue(engine.checkIn(state.model.predict(signals), at: now))
        }
        XCTAssertEqual(engine.state.model, state.model)
        XCTAssertNil(engine.state.guardrail)
        XCTAssertEqual(engine.state.reviews.last?.outcome, "Rolled back")
    }

    func testStorageSurvivesRestartAndRejectsSemanticallyCorruptData() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mood-store-\(UUID())")
        let url = directory.appendingPathComponent("state.plist")
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = MoodCompassEngine()
        observed(engine, at: start)
        XCTAssertTrue(engine.checkIn(["energy": 75], at: start))
        try CompassStorage.save(engine.state, to: url)
        let restored = try CompassStorage.load(from: url)
        XCTAssertEqual(restored.labels.count, 1)
        XCTAssertEqual(restored.model, engine.state.model)
        XCTAssertEqual(restored.points.count, 1)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        var invalid = restored
        invalid.baseline["typing"] = CompassBaseline(mean: .nan)
        try CompassStorage.save(invalid, to: url)
        XCTAssertThrowsError(try CompassStorage.load(from: url))
    }

    func testRetentionAndBinaryStorageStayBounded() throws {
        let engine = MoodCompassEngine()
        for index in 0..<2_100 { observed(engine, at: start.addingTimeInterval(Double(index) * 300)) }
        XCTAssertLessThanOrEqual(engine.state.points.count, 2_017)
        XCTAssertLessThanOrEqual(engine.state.days.count, 180)
        XCTAssertTrue(engine.state.labels.isEmpty)
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        XCTAssertLessThan(try encoder.encode(engine.state).count, 1_000_000)
    }

    func testUnvalidatedOutputDoesNotChangeOnOtherFeedback() {
        var state = reviewState()
        state.labels = state.labels.enumerated().map { index, label in
            CompassLabel(timestamp: label.timestamp, features: label.features,
                actual: index < 24 ? label.actual : ["readiness": label.actual["readiness"]!],
                predicted: label.predicted, modelVersion: 1, quality: 1, kind: "check-in")
        }
        let engine = MoodCompassEngine(state: state)
        engine.reviewIfDue(at: start.addingTimeInterval(8 * 86_400))
        XCTAssertEqual(engine.state.model.bias["mood"], state.model.bias["mood"])
        XCTAssertEqual(engine.state.model.bias["energy"], state.model.bias["energy"])
        XCTAssertEqual(engine.state.model.bias["stress"], state.model.bias["stress"])
    }

    @MainActor
    func testDeleteErasesOnlyMoodDataAndDisablesMonitoring() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mood-delete-\(UUID())")
        let url = directory.appendingPathComponent("mood.plist")
        let sibling = directory.appendingPathComponent("existing-history.plist")
        defer { try? FileManager.default.removeItem(at: directory) }
        try CompassStorage.save(CompassState(), to: url)
        try Data("keep".utf8).write(to: sibling)
        let suite = "MoodTests.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = MoodCompassManager(defaults: defaults, storageURL: url)
        let deleted = expectation(description: "deleted")
        manager.deleteAllData { deleted.fulfill() }
        await fulfillment(of: [deleted], timeout: 2)
        XCTAssertFalse(manager.settings.enabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try Data(contentsOf: sibling), Data("keep".utf8))
        manager.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "Shutdown must not resurrect deleted data")
    }

    func testDaylightCalculationIsLocalAndReasonable() {
        XCTAssertTrue(MoodCompassManager.isDaylight(at: Date(timeIntervalSince1970: 1_750_507_200), latitude: 0, longitude: 0))
        XCTAssertNotNil(CGEventType(rawValue: UInt32.max))
    }

    @MainActor
    func testNewTabIsIndependentAndRendersEveryPageInBothAppearances() throws {
        let details = SystemDetailsView(frame: NSRect(origin: .zero, size: SystemDetailsView.preferredSize))
        let view = MoodCompassView(frame: NSRect(origin: .zero, size: MoodCompassView.preferredSize))
        details.installMoodCompassView(view)
        details.selectTab(at: 4)
        details.layoutSubtreeIfNeeded()
        XCTAssertEqual(SystemDetailsView.tabCount, 5)
        XCTAssertTrue(details.isMoodTabSelected)
        XCTAssertEqual(details.frame.height, 440)
        XCTAssertFalse(view.superview?.isHidden ?? true)
        if ProcessInfo.processInfo.environment["MOOD_COMPASS_PREVIEW"] == "1" {
            details.appearance = NSAppearance(named: .aqua)
            view.appearance = NSAppearance(named: .aqua)
            let canvas = NSView(frame: details.bounds)
            canvas.wantsLayer = true; canvas.layer?.backgroundColor = NSColor.white.cgColor
            canvas.addSubview(details)
            let bitmap = try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
            canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: "/private/tmp/mood-compass-integrated.png"))
            details.removeFromSuperview()
        }
        // It must work before any hardware snapshot has been read.
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            view.appearance = NSAppearance(named: appearance)
            let canvas = NSView(frame: view.bounds)
            canvas.wantsLayer = true
            canvas.layer?.backgroundColor = (appearance == .aqua ? NSColor.white : NSColor(calibratedWhite: 0.13, alpha: 1)).cgColor
            canvas.addSubview(view)
            for page in 0..<4 {
                view.selectPage(page)
                let bitmap = try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
                canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                XCTAssertGreaterThan(data.count, 5_000)
                if ProcessInfo.processInfo.environment["MOOD_COMPASS_PREVIEW"] == "1" {
                    try data.write(to: URL(fileURLWithPath: "/private/tmp/mood-\(appearance.rawValue)-\(page).png"))
                }
            }
        }
        details.resizeSelectedSection(to: 520)
        details.selectTab(at: 2)
        XCTAssertFalse(details.isMoodTabSelected)
        XCTAssertEqual(details.frame.height, SoundControlView.preferredSize.height + 50)
        details.selectTab(at: 4)
        XCTAssertEqual(details.frame.height, 520)
    }

    func testFiveTabLabelsFitTheirSegments() {
        for (index, title) in [(0, "System"), (1, "Net+Apps")] {
            let width = (SystemDetailsView.preferredSize.width - 20) * SystemDetailsView.tabWidthWeights[index] / SystemDetailsView.tabWidthWeights.reduce(0, +) - 6
            XCTAssertLessThanOrEqual(NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 9, weight: .semibold)]).size().width, width)
        }
    }
}
