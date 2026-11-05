import Foundation

struct MemoryLeakAssessment {
    let growthBytes: UInt64
}

/// Detects sustained system-wide app-memory growth without treating one large
/// allocation as proof of a leak. The result is intentionally advisory.
final class MemoryLeakDetector {
    private struct Sample {
        let date: Date
        let metrics: MemoryMetrics
    }

    private static let sampleInterval: TimeInterval = 10
    private static let minimumDuration: TimeInterval = 180
    private static let windowDuration: TimeInterval = 300
    private static let minimumAppGrowth: UInt64 = 1_000_000_000
    private static let minimumPressureGrowth: UInt64 = 500_000_000
    private static let meaningfulStep: UInt64 = 8_000_000
    private static let minimumMeaningfulSteps = 6
    private static let minimumUsage = 0.80

    private let totalPhysicalMemory: UInt64
    private var samples: [Sample] = []
    private var latestAssessment: MemoryLeakAssessment?

    init(totalPhysicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) {
        self.totalPhysicalMemory = totalPhysicalMemory
    }

    func update(metrics: MemoryMetrics, at date: Date = Date()) -> MemoryLeakAssessment? {
        if let previous = samples.last,
           date.timeIntervalSince(previous.date) < Self.sampleInterval {
            return latestAssessment
        }

        samples.append(Sample(date: date, metrics: metrics))
        let cutoff = date.addingTimeInterval(-Self.windowDuration)
        samples.removeAll { $0.date < cutoff }
        latestAssessment = assessCurrentWindow()
        return latestAssessment
    }

    private func assessCurrentWindow() -> MemoryLeakAssessment? {
        guard let first = samples.first,
              let latest = samples.last,
              latest.date.timeIntervalSince(first.date) >= Self.minimumDuration,
              latest.metrics.usage >= Self.minimumUsage,
              latest.metrics.appBytes > first.metrics.appBytes
        else { return nil }

        let appGrowth = latest.metrics.appBytes - first.metrics.appBytes
        guard appGrowth >= Self.minimumAppGrowth else { return nil }

        let meaningfulSteps = zip(samples, samples.dropFirst()).filter { previous, current in
            current.metrics.appBytes >= previous.metrics.appBytes + Self.meaningfulStep
        }.count
        guard meaningfulSteps >= Self.minimumMeaningfulSteps else { return nil }

        let usageGrowth = max(0, latest.metrics.usage - first.metrics.usage)
        let loadedGrowth = UInt64(usageGrowth * Double(totalPhysicalMemory))
        let compressedGrowth = latest.metrics.compressedBytes > first.metrics.compressedBytes
            ? latest.metrics.compressedBytes - first.metrics.compressedBytes
            : 0
        guard max(loadedGrowth, compressedGrowth) >= Self.minimumPressureGrowth else { return nil }

        return MemoryLeakAssessment(growthBytes: appGrowth)
    }
}
