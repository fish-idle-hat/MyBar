import Foundation

enum SensorGroup: String {
    case cpu
    case gpu
    case hotspot
    case other

    static let allCasesForTemperatureDisplay: [SensorGroup] = [.cpu, .gpu, .hotspot, .other]

    static func classify(key: String) -> SensorGroup {
        if key.hasPrefix("Tp") || key.hasPrefix("Te") || key.hasPrefix("TCpu") {
            return .cpu
        }
        if key.hasPrefix("Tg") || key.hasPrefix("TG") {
            return .gpu
        }
        if key.hasPrefix("Tf") || key == "TCMz" {
            return .hotspot
        }
        return .other
    }
}

struct TemperatureReading {
    let key: String
    let celsius: Double
    let group: SensorGroup
    let sampledAt: Date
    let unchangedSamples: Int

    init(
        key: String,
        celsius: Double,
        group: SensorGroup,
        sampledAt: Date = Date(),
        unchangedSamples: Int = 0
    ) {
        self.key = key
        self.celsius = celsius
        self.group = group
        self.sampledAt = sampledAt
        self.unchangedSamples = unchangedSamples
    }

    func health(at date: Date = Date()) -> SensorHealth {
        let age = max(0, date.timeIntervalSince(sampledAt))
        let confidence: SensorConfidence
        if !celsius.isFinite || !(1...150).contains(celsius) {
            confidence = .unreliable
        } else if age > 15 {
            confidence = .delayed
        } else if unchangedSamples >= 60 {
            confidence = .staticReading
        } else {
            confidence = .live
        }
        return SensorHealth(confidence: confidence, age: age, unchangedSamples: unchangedSamples)
    }
}

struct TemperatureSummary {
    let maximum: Double
    let mean: Double
    let count: Int
}

struct HardwareSnapshot {
    let timestamp: Date
    let temperatureReadings: [TemperatureReading]
    let cpu: TemperatureSummary?
    let gpu: TemperatureSummary?
    let hottest: TemperatureReading?
    let fanRPM: [Double?]
    let cpuUsage: Double?
    let cpuBreakdown: CPUUsageBreakdown?
    let gpuMetrics: GPUMetrics?
    let powerMetrics: PowerMetrics?
    let topApps: [TopAppMetrics]
    let memoryUsage: Double?
    let memoryMetrics: MemoryMetrics?
    let memoryLeakAssessment: MemoryLeakAssessment?
    let memoryPressure: MemoryPressureLevel
    let storageMetrics: StorageMetrics?
    let batteryMetrics: BatteryMetrics?
    let networkMetrics: NetworkMetrics?
    let respondingTemperatureSensors: Int
    let discoveredTemperatureSensors: Int
    let thermalState: ProcessInfo.ThermalState

    var chipTemperature: Double? {
        [cpu?.maximum, gpu?.maximum].compactMap { $0 }.max() ?? hottest?.celsius
    }
}

/// Discovers available sensors once, then polls only those known-good keys.
/// Every method is called from one serial queue by AppDelegate.
final class HardwareMonitor {
    private struct TemperatureKey {
        let name: String
        let group: SensorGroup
    }

    private static let plausibleTemperature = 1.0...150.0
    private static let maximumFanSlotsToProbe = 8

    /// Some Apple-silicon firmware exports fixed thermal limits through `Tf` keys
    /// using the same type and plausible range as live sensors. Their value varies
    /// by model, so these known metadata keys must be excluded by identity.
    static func isUsableTemperature(key: String, celsius: Double) -> Bool {
        guard celsius.isFinite, plausibleTemperature.contains(celsius) else { return false }
        let firmwareThermalLimitKeys: Set<String> = ["Tf06", "Tf16"]
        return !firmwareThermalLimitKeys.contains(key)
    }

    private let smc: SMC
    private let systemMetrics = SystemMetricsReader()
    private let temperatureKeys: [TemperatureKey]
    private let fanIndices: [Int]
    private var temperatureCache: [String: TemperatureReading] = [:]
    private var temperatureBatchOffset = 0
    private var cachedTopApps: [TopAppMetrics] = []
    private var lastTopAppsRead = Date.distantPast
    private var cachedStorage: StorageMetrics?
    private var lastStorageRead = Date.distantPast

    init() throws {
        let smc = try SMC()
        self.smc = smc

        let allKeys = try smc.allKeys()
        self.temperatureKeys = allKeys.compactMap { key in
            guard key.hasPrefix("T"),
                  let info = try? smc.keyInfo(key),
                  ["flt", "sp78"].contains(info.type.trimmingCharacters(in: .whitespaces))
            else { return nil }
            return TemperatureKey(name: key, group: SensorGroup.classify(key: key))
        }

        if let declared = try? smc.readNumber("FNum"), declared > 0 {
            self.fanIndices = Array(0..<min(Int(declared.rounded()), Self.maximumFanSlotsToProbe))
        } else {
            self.fanIndices = (0..<Self.maximumFanSlotsToProbe).filter { smc.keyExists("F\($0)Ac") }
        }
    }

    func readSnapshot(
        mode: MonitoringMode = .balanced,
        forceFullSensors: Bool = false,
        forceDetails: Bool = false
    ) -> HardwareSnapshot {
        let timestamp = Date()
        let temperatures = readTemperatures(
            at: timestamp,
            mode: mode,
            forceFull: forceFullSensors
        )

        let fans = fanIndices.map { index -> Double? in
            guard let rpm = try? smc.readNumber("F\(index)Ac"),
                  rpm.isFinite,
                  (0...50_000).contains(rpm)
            else { return nil }
            return rpm
        }

        let cpuUsage = systemMetrics.readCPUUsage()
        let gpuMetrics = systemMetrics.readGPUMetrics()
        let memoryMetrics = systemMetrics.readMemoryMetrics()
        if forceDetails || timestamp.timeIntervalSince(lastTopAppsRead) >= mode.topAppsInterval {
            cachedTopApps = systemMetrics.readTopApps(at: timestamp)
            lastTopAppsRead = timestamp
        }
        let topApps = cachedTopApps
        if cachedStorage == nil
            || forceDetails
            || timestamp.timeIntervalSince(lastStorageRead) >= mode.storageInterval {
            cachedStorage = systemMetrics.readStorageMetrics()
            lastStorageRead = timestamp
        }
        let ioPower = systemMetrics.readPowerMetrics()
        let smcCPUPower = ioPower?.cpuWatts == nil
            ? (try? smc.readNumber("PZC0")).flatMap { $0.isFinite && (0...500).contains($0) ? $0 : nil }
            : nil
        let powerMetrics = (ioPower != nil || smcCPUPower != nil)
            ? PowerMetrics(cpuWatts: ioPower?.cpuWatts ?? smcCPUPower, gpuWatts: ioPower?.gpuWatts)
            : nil
        return HardwareSnapshot(
            timestamp: timestamp,
            temperatureReadings: temperatures,
            cpu: Self.summarize(temperatures.filter { $0.group == .cpu }),
            gpu: Self.summarize(temperatures.filter { $0.group == .gpu }),
            hottest: temperatures.max { $0.celsius < $1.celsius },
            fanRPM: fans,
            cpuUsage: cpuUsage?.total,
            cpuBreakdown: cpuUsage,
            gpuMetrics: gpuMetrics,
            powerMetrics: powerMetrics,
            topApps: topApps,
            memoryUsage: memoryMetrics?.usage,
            memoryMetrics: memoryMetrics,
            memoryLeakAssessment: memoryMetrics.flatMap { systemMetrics.assessMemoryLeak($0, at: timestamp) },
            memoryPressure: systemMetrics.readMemoryPressure(),
            storageMetrics: cachedStorage,
            batteryMetrics: systemMetrics.readBatteryMetrics(topApps: topApps, at: timestamp),
            networkMetrics: systemMetrics.readNetworkMetrics(),
            respondingTemperatureSensors: temperatures.count,
            discoveredTemperatureSensors: temperatureKeys.count,
            thermalState: ProcessInfo.processInfo.thermalState
        )
    }

    private func readTemperatures(
        at timestamp: Date,
        mode: MonitoringMode,
        forceFull: Bool
    ) -> [TemperatureReading] {
        let sensorsToRead: [TemperatureKey]
        if forceFull || temperatureCache.isEmpty {
            sensorsToRead = temperatureKeys
            temperatureBatchOffset = 0
        } else {
            let hottestKeys = Set(
                temperatureCache.values
                    .filter { timestamp.timeIntervalSince($0.sampledAt) < 20 }
                    .sorted { $0.celsius > $1.celsius }
                    .prefix(18)
                    .map(\.key)
            )
            let batchCount = min(mode.temperatureBatchSize, temperatureKeys.count)
            let batch = (0..<batchCount).map { index in
                temperatureKeys[(temperatureBatchOffset + index) % temperatureKeys.count]
            }
            temperatureBatchOffset = temperatureKeys.isEmpty
                ? 0
                : (temperatureBatchOffset + batchCount) % temperatureKeys.count
            sensorsToRead = temperatureKeys.filter { hottestKeys.contains($0.name) }
                + batch.filter { !hottestKeys.contains($0.name) }
        }

        for sensor in sensorsToRead {
            guard let value = try? smc.readNumber(sensor.name),
                  Self.isUsableTemperature(key: sensor.name, celsius: value)
            else { continue }
            let previous = temperatureCache[sensor.name]
            let unchanged = previous.map { abs($0.celsius - value) < 0.0001 ? $0.unchangedSamples + 1 : 0 } ?? 0
            temperatureCache[sensor.name] = TemperatureReading(
                key: sensor.name,
                celsius: value,
                group: sensor.group,
                sampledAt: timestamp,
                unchangedSamples: unchanged
            )
        }

        let maximumAge = max(30, mode.refreshInterval * Double(max(1, temperatureKeys.count / max(1, mode.temperatureBatchSize))) * 3)
        temperatureCache = temperatureCache.filter { timestamp.timeIntervalSince($0.value.sampledAt) <= maximumAge }
        return temperatureCache.values.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
    }

    private static func summarize(_ readings: [TemperatureReading]) -> TemperatureSummary? {
        guard !readings.isEmpty else { return nil }
        let values = readings.map(\.celsius)
        return TemperatureSummary(
            maximum: values.max()!,
            mean: values.reduce(0, +) / Double(values.count),
            count: values.count
        )
    }
}
