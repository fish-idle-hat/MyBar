import Foundation

enum MetricHistoryRange: Int, CaseIterable {
    case day
    case week
    case month
    case sixMonths

    var title: String {
        switch self {
        case .day: "24H"
        case .week: "1W"
        case .month: "Month"
        case .sixMonths: "6M"
        }
    }

    func startDate(relativeTo date: Date) -> Date {
        switch self {
        case .day:
            return date.addingTimeInterval(-24 * 60 * 60)
        case .week:
            return date.addingTimeInterval(-7 * 24 * 60 * 60)
        case .month:
            let components = Calendar.current.dateComponents([.year, .month], from: date)
            return Calendar.current.date(from: components) ?? date.addingTimeInterval(-31 * 24 * 60 * 60)
        case .sixMonths:
            return Calendar.current.date(byAdding: .month, value: -6, to: date)
                ?? date.addingTimeInterval(-183 * 24 * 60 * 60)
        }
    }
}

enum HistoricalMetric: String, CaseIterable {
    case cpuUsage
    case cpuWatts
    case gpuUsage
    case gpuWatts
    case memoryUsage
    case storageUsage
    case batteryLevel
    case batteryWatts
    case networkUpload
    case networkDownload
    case networkLatency
}

struct HistoricalMetricsPoint: Codable {
    let timestamp: Date
    private let values: [String: Double]

    init(timestamp: Date, values: [HistoricalMetric: Double]) {
        self.timestamp = timestamp
        self.values = Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue, $0.value) })
    }

    fileprivate init(timestamp: Date, rawValues: [String: Double]) {
        self.timestamp = timestamp
        self.values = rawValues
    }

    subscript(metric: HistoricalMetric) -> Double? {
        values[metric.rawValue]
    }

    fileprivate var rawValues: [String: Double] { values }
}

/// Stores only downsampled snapshots. Recording does not perform any sensor reads.
final class HistoricalMetricsStore {
    private struct StoredHistory: Codable {
        var fiveMinute: [HistoricalMetricsPoint] = []
        var hourly: [HistoricalMetricsPoint] = []
        var daily: [HistoricalMetricsPoint] = []
    }

    private struct PendingBucket {
        let start: Date
        var sums: [String: Double] = [:]
        var counts: [String: Int] = [:]

        mutating func add(_ values: [HistoricalMetric: Double]) {
            for (metric, value) in values where value.isFinite {
                sums[metric.rawValue, default: 0] += value
                counts[metric.rawValue, default: 0] += 1
            }
        }

        var point: HistoricalMetricsPoint {
            var averages: [String: Double] = [:]
            for (key, sum) in sums {
                guard let count = counts[key], count > 0 else { continue }
                averages[key] = sum / Double(count)
            }
            return HistoricalMetricsPoint(timestamp: start, rawValues: averages)
        }
    }

    private static let fiveMinutes: TimeInterval = 5 * 60
    private static let hour: TimeInterval = 60 * 60
    private static let day: TimeInterval = 24 * 60 * 60
    private static let historySampleInterval: TimeInterval = 15
    private static let maximumRenderedPoints = 120

    private let storageURL: URL?
    private let saveQueue = DispatchQueue(label: "ThermoBar.history-save", qos: .utility)
    private var stored: StoredHistory
    private var pending: PendingBucket?
    private var lastAcceptedSample: Date?

    init(storageURL: URL? = HistoricalMetricsStore.defaultStorageURL) {
        self.storageURL = storageURL
        if let storageURL,
           let data = try? Data(contentsOf: storageURL),
           let decoded = try? PropertyListDecoder().decode(StoredHistory.self, from: data) {
            stored = decoded
        } else {
            stored = StoredHistory()
        }
    }

    @discardableResult
    func record(_ snapshot: HardwareSnapshot) -> Bool {
        var values: [HistoricalMetric: Double] = [:]
        values[.cpuUsage] = snapshot.cpuUsage
        values[.cpuWatts] = snapshot.powerMetrics?.cpuWatts
        values[.gpuUsage] = snapshot.gpuMetrics?.usage
        values[.gpuWatts] = snapshot.powerMetrics?.gpuWatts
        values[.memoryUsage] = snapshot.memoryUsage
        values[.storageUsage] = snapshot.storageMetrics?.usage
        values[.batteryLevel] = snapshot.batteryMetrics?.level
        values[.batteryWatts] = snapshot.batteryMetrics?.powerWatts
        values[.networkUpload] = snapshot.networkMetrics?.uploadBytesPerSecond
        values[.networkDownload] = snapshot.networkMetrics?.downloadBytesPerSecond
        values[.networkLatency] = snapshot.networkMetrics?.latencyMilliseconds
        return record(values: values, at: snapshot.timestamp)
    }

    @discardableResult
    func record(values: [HistoricalMetric: Double], at date: Date) -> Bool {
        let start = bucketStart(for: date, interval: Self.fiveMinutes)
        let beginsNewBucket = pending?.start != start
        var finalizedBucket = false
        if beginsNewBucket {
            finalizedBucket = finalizePending(at: date)
            pending = PendingBucket(start: start)
        }

        if !beginsNewBucket, let lastAcceptedSample {
            let elapsed = date.timeIntervalSince(lastAcceptedSample)
            if elapsed >= 0, elapsed < Self.historySampleInterval {
                return finalizedBucket
            }
        }
        pending?.add(values)
        lastAcceptedSample = date
        return finalizedBucket
    }

    func history(for range: MetricHistoryRange, at date: Date = Date()) -> [HistoricalMetricsPoint] {
        let source: [HistoricalMetricsPoint]
        switch range {
        case .day:
            source = stored.fiveMinute
        case .week, .month:
            source = stored.hourly
        case .sixMonths:
            source = stored.daily
        }

        let cutoff = range.startDate(relativeTo: date)
        var points = source.filter { $0.timestamp >= cutoff && $0.timestamp <= date }
        if let current = pending?.point, current.timestamp >= cutoff {
            points.removeAll { $0.timestamp == current.timestamp }
            points.append(current)
        }
        return downsample(points.sorted { $0.timestamp < $1.timestamp }, maximum: Self.maximumRenderedPoints)
    }

    func flush(at date: Date = Date()) {
        _ = finalizePending(at: date, persist: false)
        saveSynchronously()
    }

    @discardableResult
    private func finalizePending(at date: Date, persist: Bool = true) -> Bool {
        guard let point = pending?.point, !point.rawValues.isEmpty else { return false }
        pending = nil
        upsert(point, in: &stored.fiveMinute)

        let hourStart = bucketStart(for: point.timestamp, interval: Self.hour)
        if let hourly = averagedPoint(points(since: hourStart, in: stored.fiveMinute), timestamp: hourStart) {
            upsert(hourly, in: &stored.hourly)
        }

        let dayStart = bucketStart(for: point.timestamp, interval: Self.day)
        if let daily = averagedPoint(points(since: dayStart, in: stored.hourly), timestamp: dayStart) {
            upsert(daily, in: &stored.daily)
        }

        prune(at: date)
        if persist { saveAsynchronously() }
        return true
    }

    private func averagedPoint(_ points: [HistoricalMetricsPoint], timestamp: Date) -> HistoricalMetricsPoint? {
        guard !points.isEmpty else { return nil }
        var sums: [HistoricalMetric: Double] = [:]
        var counts: [HistoricalMetric: Int] = [:]
        for point in points {
            for metric in HistoricalMetric.allCases {
                guard let value = point[metric], value.isFinite else { continue }
                sums[metric, default: 0] += value
                counts[metric, default: 0] += 1
            }
        }
        var values: [HistoricalMetric: Double] = [:]
        for (metric, sum) in sums {
            guard let count = counts[metric], count > 0 else { continue }
            values[metric] = sum / Double(count)
        }
        return HistoricalMetricsPoint(timestamp: timestamp, values: values)
    }

    private func downsample(_ points: [HistoricalMetricsPoint], maximum: Int) -> [HistoricalMetricsPoint] {
        guard points.count > maximum else { return points }
        return (0..<maximum).compactMap { index in
            let lower = index * points.count / maximum
            let upper = max(lower + 1, (index + 1) * points.count / maximum)
            let slice = Array(points[lower..<min(points.count, upper)])
            let timestamp = slice.last?.timestamp ?? points[lower].timestamp
            return averagedPoint(slice, timestamp: timestamp)
        }
    }

    private func upsert(_ point: HistoricalMetricsPoint, in points: inout [HistoricalMetricsPoint]) {
        guard let last = points.last else {
            points.append(point)
            return
        }
        if last.timestamp < point.timestamp {
            points.append(point)
            return
        }

        var lower = 0
        var upper = points.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if points[middle].timestamp < point.timestamp {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        if lower < points.count, points[lower].timestamp == point.timestamp {
            points[lower] = point
        } else {
            points.insert(point, at: lower)
        }
    }

    private func points(since date: Date, in points: [HistoricalMetricsPoint]) -> [HistoricalMetricsPoint] {
        var lower = 0
        var upper = points.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if points[middle].timestamp < date {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower < points.count ? Array(points[lower...]) : []
    }

    private func prune(at date: Date) {
        stored.fiveMinute.removeAll { $0.timestamp < date.addingTimeInterval(-8 * Self.day) }
        stored.hourly.removeAll { $0.timestamp < date.addingTimeInterval(-40 * Self.day) }
        stored.daily.removeAll { $0.timestamp < date.addingTimeInterval(-190 * Self.day) }
    }

    private func bucketStart(for date: Date, interval: TimeInterval) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / interval) * interval)
    }

    private func saveAsynchronously() {
        guard let storageURL,
              let data = try? Self.encode(stored)
        else { return }
        saveQueue.async {
            try? FileManager.default.createDirectory(
                at: storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? data.write(to: storageURL, options: .atomic)
        }
    }

    private func saveSynchronously() {
        guard let storageURL,
              let data = try? Self.encode(stored)
        else { return }
        saveQueue.sync {
            try? FileManager.default.createDirectory(
                at: storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? data.write(to: storageURL, options: .atomic)
        }
    }

    private static func encode(_ history: StoredHistory) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(history)
    }

    private static var defaultStorageURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ThermoBar", isDirectory: true)
            .appendingPathComponent("metric-history-v1.plist")
    }
}
