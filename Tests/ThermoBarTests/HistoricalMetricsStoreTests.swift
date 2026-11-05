import Foundation
import XCTest
@testable import ThermoBar

final class HistoricalMetricsStoreTests: XCTestCase {
    func testHistorySamplingIsThrottledWithoutLosingBucketBoundaries() throws {
        let store = HistoricalMetricsStore(storageURL: nil)
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        XCTAssertFalse(store.record(values: [.cpuUsage: 0.1], at: start))
        XCTAssertFalse(store.record(values: [.cpuUsage: 0.9], at: start.addingTimeInterval(5)))
        XCTAssertFalse(store.record(values: [.cpuUsage: 0.3], at: start.addingTimeInterval(15)))
        let current = try XCTUnwrap(store.history(for: .day, at: start.addingTimeInterval(15)).last)
        XCTAssertEqual(try XCTUnwrap(current[.cpuUsage]), 0.2, accuracy: 0.0001)

        XCTAssertTrue(store.record(values: [.cpuUsage: 0.4], at: start.addingTimeInterval(300)))
    }

    func testHistoryPersistsAcrossRelaunch() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThermoBarHistoryTests-\(UUID().uuidString)", isDirectory: true)
        let storageURL = directory.appendingPathComponent("history.plist")
        defer { try? FileManager.default.removeItem(at: directory) }
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        let writer = HistoricalMetricsStore(storageURL: storageURL)
        writer.record(values: [.cpuUsage: 0.42, .cpuWatts: 8.5], at: start)
        writer.flush(at: start.addingTimeInterval(60))

        let reader = HistoricalMetricsStore(storageURL: storageURL)
        let restored = try XCTUnwrap(reader.history(for: .day, at: start.addingTimeInterval(60)).last)
        XCTAssertEqual(try XCTUnwrap(restored[.cpuUsage]), 0.42, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(restored[.cpuWatts]), 8.5, accuracy: 0.0001)
    }

    func testHistoryIsBucketedAndDownsampled() {
        let store = HistoricalMetricsStore(storageURL: nil)
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        for minute in 0..<(26 * 60) {
            store.record(
                values: [
                    .cpuUsage: Double(minute % 100) / 100,
                    .cpuWatts: 5 + Double(minute % 10),
                    .memoryUsage: 0.5,
                ],
                at: start.addingTimeInterval(Double(minute * 60))
            )
        }

        let history = store.history(for: .day, at: start.addingTimeInterval(26 * 60 * 60))
        XCTAssertLessThanOrEqual(history.count, 120)
        XCTAssertGreaterThan(history.count, 100)
        XCTAssertNotNil(history.last?[.cpuUsage])
        XCTAssertNotNil(history.last?[.cpuWatts])
    }

    func testHourlyAndDailyRollupsRemainAvailable() {
        let store = HistoricalMetricsStore(storageURL: nil)
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        for hour in 0..<(35 * 24) {
            store.record(
                values: [.batteryLevel: max(0.1, 0.9 - Double(hour % 24) / 100)],
                at: start.addingTimeInterval(Double(hour) * 60 * 60)
            )
        }

        let now = start.addingTimeInterval(35 * 24 * 60 * 60)
        XCTAssertGreaterThan(store.history(for: .month, at: now).count, 20)
        XCTAssertGreaterThan(store.history(for: .sixMonths, at: now).count, 20)
    }
}
