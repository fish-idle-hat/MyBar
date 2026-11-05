import Darwin
import Foundation
import IOKit
import CoreWLAN

struct CPUUsageBreakdown {
    let total: Double
    let system: Double
    let user: Double
    let idle: Double
}

struct MemoryMetrics {
    let usage: Double
    let appBytes: UInt64
    let wiredBytes: UInt64
    let compressedBytes: UInt64
}

struct GPUMetrics {
    let usage: Double
    let rendererUsage: Double?
    let tilerUsage: Double?
}

struct StorageMetrics {
    let usedBytes: Int64
    let totalBytes: Int64
    let usage: Double
}

struct BatteryMetrics {
    let level: Double
    let powerSource: String
    let maximumCapacity: Double?
    let cycleCount: Int?
    let temperature: Double?
    let powerWatts: Double?
    let isCharging: Bool
    let remainingEnergyWh: Double?
    let estimatedMinutesRemaining: Double?
    let estimateConfidence: BatteryEstimateConfidence
    let history: [BatteryHistoryPoint]
}

struct NetworkMetrics {
    let interfaceName: String
    let displayName: String
    let localIPAddress: String
    let uploadBytesPerSecond: Double?
    let downloadBytesPerSecond: Double?
    let signalRSSI: Int?
    let noiseDBM: Int?
    let transmitRateMbps: Double?
    let latencyMilliseconds: Double?
}

enum MemoryPressureLevel: String {
    case normal
    case warning
    case critical
    case unknown

    var compactLabel: String {
        switch self {
        case .normal: return "OK"
        case .warning: return "WARN"
        case .critical: return "CRIT"
        case .unknown: return "—"
        }
    }

    var displayName: String {
        switch self {
        case .normal: return "Normal"
        case .warning: return "Warning"
        case .critical: return "Critical"
        case .unknown: return "Unknown"
        }
    }
}

/// Reads whole-system CPU and memory utilization from public Mach APIs.
/// Called from HardwareMonitor's serial polling queue.
final class SystemMetricsReader {
    private var previousCPUTicks: [UInt32]?
    private var previousNetworkSample: (name: String, date: Date, received: UInt64, sent: UInt64)?
    private let latencyMonitor = NetworkLatencyMonitor()
    private let memoryLeakDetector = MemoryLeakDetector()
    private let powerReader = PowerMetricsReader()
    private let topAppsReader = TopAppsReader()
    private let batteryEstimator = BatteryLifeEstimator()

    func readCPUUsage() -> CPUUsageBreakdown? {
        var cpuInfo: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        var cpuCount: natural_t = 0

        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &cpuCount,
            &cpuInfo,
            &infoCount
        )
        guard result == KERN_SUCCESS, let info = cpuInfo else { return nil }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(bitPattern: info),
                vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size)
            )
        }

        let stateCount = Int(CPU_STATE_MAX)
        var totals = [UInt32](repeating: 0, count: stateCount)
        for cpu in 0..<Int(cpuCount) {
            for state in 0..<stateCount {
                totals[state] &+= UInt32(bitPattern: info[cpu * stateCount + state])
            }
        }

        guard let previous = previousCPUTicks, previous.count == totals.count else {
            previousCPUTicks = totals
            return nil
        }
        previousCPUTicks = totals

        let deltas = zip(totals, previous).map { Double($0 &- $1) }
        let totalDelta = deltas.reduce(0, +)
        guard totalDelta > 0 else { return nil }
        let idle = deltas[Int(CPU_STATE_IDLE)] / totalDelta
        let system = deltas[Int(CPU_STATE_SYSTEM)] / totalDelta
        let user = (deltas[Int(CPU_STATE_USER)] + deltas[Int(CPU_STATE_NICE)]) / totalDelta
        return CPUUsageBreakdown(
            total: min(1, max(0, 1 - idle)),
            system: min(1, max(0, system)),
            user: min(1, max(0, user)),
            idle: min(1, max(0, idle))
        )
    }

    func readMemoryPressure() -> MemoryPressureLevel {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else {
            return .unknown
        }
        switch level {
        case 1: return .normal
        case 2: return .warning
        case 4: return .critical
        default: return .unknown
        }
    }

    func readGPUMetrics() -> GPUMetrics? {
        guard let statistics = registryProperty(
            matching: "IOAccelerator",
            key: "PerformanceStatistics"
        ) as? [String: Any] else { return nil }
        return Self.gpuMetrics(from: statistics)
    }

    static func gpuMetrics(from statistics: [String: Any]) -> GPUMetrics? {
        func utilization(_ key: String) -> Double? {
            guard let value = (statistics[key] as? NSNumber)?.doubleValue,
                  value.isFinite
            else { return nil }
            return min(1, max(0, value / 100))
        }

        guard let usage = utilization("Device Utilization %") else { return nil }
        return GPUMetrics(
            usage: usage,
            rendererUsage: utilization("Renderer Utilization %"),
            tilerUsage: utilization("Tiler Utilization %")
        )
    }

    /// Active, wired, and physically compressed memory as a fraction of RAM.
    /// Reclaimable file cache is intentionally excluded.
    func readMemoryMetrics() -> MemoryMetrics? {
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let loadedPages = UInt64(statistics.active_count)
            + UInt64(statistics.wire_count)
            + UInt64(statistics.compressor_page_count)
        let loadedBytes = Double(loadedPages) * Double(vm_kernel_page_size)
        let totalBytes = Double(ProcessInfo.processInfo.physicalMemory)
        guard totalBytes > 0 else { return nil }
        let pageSize = UInt64(vm_kernel_page_size)
        return MemoryMetrics(
            usage: min(1, max(0, loadedBytes / totalBytes)),
            appBytes: UInt64(statistics.internal_page_count) * pageSize,
            wiredBytes: UInt64(statistics.wire_count) * pageSize,
            compressedBytes: UInt64(statistics.compressor_page_count) * pageSize
        )
    }

    func assessMemoryLeak(_ metrics: MemoryMetrics, at date: Date) -> MemoryLeakAssessment? {
        memoryLeakDetector.update(metrics: metrics, at: date)
    }

    func readPowerMetrics() -> PowerMetrics? {
        powerReader.read()
    }

    func readTopApps(at date: Date) -> [TopAppMetrics] {
        topAppsReader.read(at: date)
    }

    func readStorageMetrics() -> StorageMetrics? {
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]
        guard let values = try? FileManager.default.homeDirectoryForCurrentUser.resourceValues(forKeys: keys),
              let totalValue = values.volumeTotalCapacity,
              totalValue > 0
        else { return nil }

        let total = Int64(totalValue)
        let reportedAvailable = values.volumeAvailableCapacityForImportantUsage
            ?? values.volumeAvailableCapacity.map(Int64.init)
            ?? 0
        let available = min(total, max(0, reportedAvailable))
        let used = total - available
        return StorageMetrics(
            usedBytes: used,
            totalBytes: total,
            usage: Double(used) / Double(total)
        )
    }

    func readBatteryMetrics(topApps: [TopAppMetrics], at date: Date) -> BatteryMetrics? {
        guard let battery = registryProperties(matching: "AppleSmartBattery") else { return nil }
        let batteryData = battery["BatteryData"] as? [String: Any]
        let currentCapacity = number(battery["CurrentCapacity"])
        let maximumCharge = number(battery["MaxCapacity"])
        guard let currentCapacity, let maximumCharge, maximumCharge > 0 else { return nil }

        let fullChargeCapacity = number(batteryData?["FullChargeCapacity"])
        let designCapacity = number(batteryData?["DesignCapacity"])
        let health = fullChargeCapacity.flatMap { full in
            designCapacity.flatMap { design in design > 0 ? min(1, max(0, full / design)) : nil }
        }
        let packData = (registryProperties(matching: "AppleSmartBatteryPack")?["BatteryData"] as? [String: Any])
        let temperature = number(packData?["Temperature"]).map { $0 / 100 }
        let voltageMillivolts = number(battery["Voltage"])
            ?? number(packData?["AppleRawBatteryVoltage"])
        let signedMilliamps = signedInteger(battery["InstantAmperage"] ?? battery["Amperage"])
        let directMilliwatts = signedInteger(batteryData?["BatteryPower"])
        let powerWatts = directMilliwatts.map { abs(Double($0)) / 1_000 }
            ?? voltageMillivolts.flatMap { voltage in
                signedMilliamps.map { abs(voltage * Double($0)) / 1_000_000 }
            }
        let remainingCapacity = number(batteryData?["RemainingCapacity"])
            ?? number(packData?["AppleRawCurrentCapacity"])
        let remainingEnergyWh = remainingCapacity.flatMap { capacity in
            voltageMillivolts.map { capacity * $0 / 1_000_000 }
        }
        let isCharging = (battery["IsCharging"] as? Bool) == true
        let nativeMinutes = number(battery["TimeRemaining"]).flatMap { (0..<65_535).contains($0) ? $0 : nil }
        let level = min(1, max(0, currentCapacity / maximumCharge))
        let estimate = batteryEstimator.update(
            level: level,
            remainingEnergyWh: remainingEnergyWh,
            dischargeWatts: powerWatts,
            isCharging: isCharging,
            systemMinutesRemaining: nativeMinutes,
            topApps: topApps,
            at: date
        )

        return BatteryMetrics(
            level: level,
            powerSource: (battery["ExternalConnected"] as? Bool) == true ? "Power Adapter" : "Battery",
            maximumCapacity: health,
            cycleCount: number(battery["CycleCount"]).map { Int($0.rounded()) },
            temperature: temperature.flatMap { (0...100).contains($0) ? $0 : nil },
            powerWatts: powerWatts.flatMap { (0...500).contains($0) ? $0 : nil },
            isCharging: isCharging,
            remainingEnergyWh: remainingEnergyWh,
            estimatedMinutesRemaining: estimate.minutesRemaining,
            estimateConfidence: estimate.confidence,
            history: estimate.history
        )
    }

    func readNetworkMetrics() -> NetworkMetrics? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }

        struct InterfaceSample {
            var address: String?
            var received: UInt64?
            var sent: UInt64?
        }
        var samples: [String: InterfaceSample] = [:]
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            let interface = current.pointee
            let name = String(cString: interface.ifa_name)
            let flags = Int32(interface.ifa_flags)
            let isUsable = (flags & IFF_UP) != 0 && (flags & IFF_RUNNING) != 0 && (flags & IFF_LOOPBACK) == 0

            if isUsable, let address = interface.ifa_addr {
                let family = Int32(address.pointee.sa_family)
                if family == AF_INET {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(
                        address,
                        socklen_t(address.pointee.sa_len),
                        &host,
                        socklen_t(host.count),
                        nil,
                        0,
                        NI_NUMERICHOST
                    ) == 0 {
                        samples[name, default: InterfaceSample()].address = String(cString: host)
                    }
                } else if family == AF_LINK, let rawData = interface.ifa_data {
                    let data = rawData.assumingMemoryBound(to: if_data.self).pointee
                    samples[name, default: InterfaceSample()].received = UInt64(data.ifi_ibytes)
                    samples[name, default: InterfaceSample()].sent = UInt64(data.ifi_obytes)
                }
            }
            pointer = interface.ifa_next
        }

        let candidates = samples.filter { $0.value.address != nil && $0.value.received != nil && $0.value.sent != nil }
        guard let selected = candidates.sorted(by: { interfacePriority($0.key) < interfacePriority($1.key) }).first,
              let address = selected.value.address,
              let received = selected.value.received,
              let sent = selected.value.sent
        else { return nil }

        let now = Date()
        var uploadRate: Double?
        var downloadRate: Double?
        if let previous = previousNetworkSample,
           previous.name == selected.key,
           received >= previous.received,
           sent >= previous.sent {
            let elapsed = now.timeIntervalSince(previous.date)
            if elapsed > 0 {
                uploadRate = Double(sent - previous.sent) / elapsed
                downloadRate = Double(received - previous.received) / elapsed
            }
        }
        previousNetworkSample = (selected.key, now, received, sent)

        let displayName = interfaceDisplayName(selected.key)
        let wifiInterface = displayName == "Wi-Fi"
            ? CWWiFiClient.shared().interface(withName: selected.key)
            : nil
        let rawRSSI = wifiInterface?.rssiValue()
        let rawNoise = wifiInterface?.noiseMeasurement()
        let transmitRate = wifiInterface?.transmitRate()

        return NetworkMetrics(
            interfaceName: selected.key,
            displayName: displayName,
            localIPAddress: address,
            uploadBytesPerSecond: uploadRate,
            downloadBytesPerSecond: downloadRate,
            signalRSSI: rawRSSI.flatMap { (-120...(-1)).contains($0) ? $0 : nil },
            noiseDBM: rawNoise.flatMap { (-120...(-1)).contains($0) ? $0 : nil },
            transmitRateMbps: transmitRate.flatMap { $0 > 0 ? $0 : nil },
            latencyMilliseconds: displayName == "Wi-Fi" ? latencyMonitor.readLatency() : nil
        )
    }

    private func registryProperties(matching className: String) -> [String: Any]? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(className))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        var unmanagedProperties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(
            service,
            &unmanagedProperties,
            kCFAllocatorDefault,
            0
        ) == KERN_SUCCESS,
        let properties = unmanagedProperties?.takeRetainedValue() as? [String: Any]
        else { return nil }
        return properties
    }

    private func registryProperty(matching className: String, key: String) -> Any? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(className))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(
            service,
            key as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue()
    }

    private func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private func signedInteger(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber else { return nil }
        return Int64(bitPattern: number.uint64Value)
    }

    private func interfacePriority(_ name: String) -> Int {
        if name == "en0" { return 0 }
        if name.hasPrefix("en") { return 1 }
        if name.hasPrefix("bridge") { return 2 }
        if name.hasPrefix("utun") { return 4 }
        return 3
    }

    private func interfaceDisplayName(_ name: String) -> String {
        if name == "en0" { return "Wi-Fi" }
        if name.hasPrefix("en") { return "Ethernet" }
        if name.hasPrefix("utun") { return "VPN" }
        return name
    }
}
