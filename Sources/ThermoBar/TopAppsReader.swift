import AppKit
import Darwin
import Foundation

struct TopAppMetrics {
    let name: String
    let cpuPercent: Double
    let memoryBytes: UInt64
    let isBackground: Bool
    let energyImpact: Double
    let executableURL: URL?
    let applicationURL: URL?

    init(
        name: String,
        cpuPercent: Double,
        memoryBytes: UInt64,
        isBackground: Bool = false,
        energyImpact: Double = 0,
        executableURL: URL? = nil,
        applicationURL: URL? = nil
    ) {
        let cleanedName = name.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }.joined(separator: " ")
        self.name = cleanedName.isEmpty ? "Unknown process" : cleanedName
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.isBackground = isBackground
        self.energyImpact = energyImpact
        self.executableURL = executableURL
        self.applicationURL = applicationURL
    }
}

/// Samples public per-process resource counters and groups helper processes by app bundle.
final class TopAppsReader {
    private struct ProcessSample {
        let startTime: UInt64
        let cpuTime: UInt64
        let energyNanojoules: UInt64?
        let wakeups: UInt64
        let diskBytes: UInt64
    }

    private struct ProcessUsage {
        let startTime: UInt64
        let exitTime: UInt64
        let userTime: UInt64
        let systemTime: UInt64
        let physicalFootprint: UInt64
        let energyNanojoules: UInt64?
        let wakeups: UInt64
        let diskBytes: UInt64
    }

    private struct AppAccumulator {
        var name = ""
        var cpuPercent = 0.0
        var memoryBytes: UInt64 = 0
        var energyImpact = 0.0
        var executableURL: URL?
        var applicationURL: URL?
    }

    private let refreshInterval: TimeInterval = 2
    private let timebase: mach_timebase_info_data_t = {
        var value = mach_timebase_info_data_t()
        mach_timebase_info(&value)
        return value
    }()
    private var previous: [Int32: ProcessSample] = [:]
    private var previousDate: Date?
    private var lastReadDate: Date?
    private var cached: [TopAppMetrics] = []

    func read(at date: Date) -> [TopAppMetrics] {
        if let lastReadDate, date.timeIntervalSince(lastReadDate) < refreshInterval {
            return cached
        }
        lastReadDate = date

        let pidCount = proc_listallpids(nil, 0)
        guard pidCount > 0 else { return cached }
        var pids = [Int32](repeating: 0, count: Int(pidCount) + 64)
        let byteCount = Int32(pids.count * MemoryLayout<Int32>.size)
        let returnedBytes = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, byteCount)
        }
        guard returnedBytes > 0 else { return cached }

        let elapsed = previousDate.map { date.timeIntervalSince($0) }
        var current: [Int32: ProcessSample] = [:]
        var apps: [String: AppAccumulator] = [:]
        let ownPID = Int32(ProcessInfo.processInfo.processIdentifier)

        for pid in pids.prefix(Int(returnedBytes) / MemoryLayout<Int32>.size)
        where pid > 0 && pid != ownPID {
            guard let usage = resourceUsage(pid: pid), usage.exitTime == 0 else { continue }
            let cpuTime = usage.userTime &+ usage.systemTime
            current[pid] = ProcessSample(
                startTime: usage.startTime,
                cpuTime: cpuTime,
                energyNanojoules: usage.energyNanojoules,
                wakeups: usage.wakeups,
                diskBytes: usage.diskBytes
            )

            guard let identity = processIdentity(pid: pid), identity.name != "ThermoBar" else { continue }
            let name = identity.name
            let groupKey = identity.applicationURL?.path ?? identity.executableURL?.path ?? "pid:\(pid)"
            var cpuPercent = 0.0
            if let elapsed, elapsed > 0,
               let old = previous[pid], old.startTime == usage.startTime,
               cpuTime >= old.cpuTime {
                let elapsedCPUSeconds = Double(cpuTime - old.cpuTime)
                    * Double(timebase.numer) / Double(timebase.denom)
                    / 1_000_000_000
                cpuPercent = elapsedCPUSeconds / elapsed * 100
            }

            var aggregate = apps[groupKey, default: AppAccumulator()]
            aggregate.name = name
            aggregate.executableURL = aggregate.executableURL ?? identity.executableURL
            aggregate.applicationURL = aggregate.applicationURL ?? identity.applicationURL
            aggregate.cpuPercent += max(0, cpuPercent)
            aggregate.memoryBytes &+= usage.physicalFootprint
            var energyImpact = max(0, cpuPercent)
            if let elapsed, elapsed > 0,
               let old = previous[pid], old.startTime == usage.startTime {
                if usage.wakeups >= old.wakeups {
                    energyImpact += Double(usage.wakeups - old.wakeups) / elapsed * 0.10
                }
                if usage.diskBytes >= old.diskBytes {
                    let megabytesPerSecond = Double(usage.diskBytes - old.diskBytes) / 1_000_000 / elapsed
                    energyImpact += megabytesPerSecond
                }
                if let currentEnergy = usage.energyNanojoules,
                   let oldEnergy = old.energyNanojoules,
                   currentEnergy >= oldEnergy {
                    let watts = Double(currentEnergy - oldEnergy) / 1_000_000_000 / elapsed
                    energyImpact += watts * 10
                }
            }
            aggregate.energyImpact += min(10_000, energyImpact)
            apps[groupKey] = aggregate
        }

        previous = current
        previousDate = date

        let frontmostName = NSWorkspace.shared.frontmostApplication?.localizedName
        let coreCount = Double(max(1, ProcessInfo.processInfo.activeProcessorCount))
        let physicalMemory = Double(max(1, ProcessInfo.processInfo.physicalMemory))
        cached = apps.map { _, value in
            TopAppMetrics(
                name: value.name,
                cpuPercent: value.cpuPercent,
                memoryBytes: value.memoryBytes,
                isBackground: Self.isBackground(appName: value.name, frontmostName: frontmostName),
                energyImpact: value.energyImpact,
                executableURL: value.executableURL,
                applicationURL: value.applicationURL
            )
        }
        .sorted { left, right in
            let leftScore = Self.resourceScore(left, coreCount: coreCount, physicalMemory: physicalMemory)
            let rightScore = Self.resourceScore(right, coreCount: coreCount, physicalMemory: physicalMemory)
            if leftScore == rightScore { return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending }
            return leftScore > rightScore
        }
        .prefix(8)
        .map { $0 }
        return cached
    }

    static func isBackground(appName: String, frontmostName: String?) -> Bool {
        guard let frontmostName, !frontmostName.isEmpty else { return true }
        return appName.localizedCaseInsensitiveCompare(frontmostName) != .orderedSame
    }

    static func resourceScore(_ app: TopAppMetrics, coreCount: Double, physicalMemory: Double) -> Double {
        let memory = Double(app.memoryBytes) / max(1, physicalMemory) * 100
        let energy = max(0, app.energyImpact) / max(1, coreCount)
        return memory + energy
    }

    private func resourceUsage(pid: Int32) -> ProcessUsage? {
        var current = rusage_info_v6()
        let currentResult = withUnsafeMutablePointer(to: &current) { pointer in
            proc_pid_rusage(
                pid,
                RUSAGE_INFO_V6,
                UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: rusage_info_t?.self)
            )
        }
        if currentResult == 0 {
            return ProcessUsage(
                startTime: current.ri_proc_start_abstime,
                exitTime: current.ri_proc_exit_abstime,
                userTime: current.ri_user_time,
                systemTime: current.ri_system_time,
                physicalFootprint: current.ri_phys_footprint,
                energyNanojoules: current.ri_energy_nj,
                wakeups: current.ri_pkg_idle_wkups &+ current.ri_interrupt_wkups,
                diskBytes: current.ri_diskio_bytesread &+ current.ri_diskio_byteswritten
            )
        }

        var fallback = rusage_info_v2()
        let fallbackResult = withUnsafeMutablePointer(to: &fallback) { pointer in
            proc_pid_rusage(
                pid,
                RUSAGE_INFO_V2,
                UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: rusage_info_t?.self)
            )
        }
        guard fallbackResult == 0 else { return nil }
        return ProcessUsage(
            startTime: fallback.ri_proc_start_abstime,
            exitTime: fallback.ri_proc_exit_abstime,
            userTime: fallback.ri_user_time,
            systemTime: fallback.ri_system_time,
            physicalFootprint: fallback.ri_phys_footprint,
            energyNanojoules: nil,
            wakeups: fallback.ri_pkg_idle_wkups &+ fallback.ri_interrupt_wkups,
            diskBytes: fallback.ri_diskio_bytesread &+ fallback.ri_diskio_byteswritten
        )
    }

    struct ProcessIdentity {
        let name: String
        let executableURL: URL?
        let applicationURL: URL?
    }

    static func identity(forExecutableURL url: URL) -> ProcessIdentity {
        let path = url.path
        if let appRange = path.range(of: ".app/") {
            let applicationURL = URL(fileURLWithPath: String(path[..<appRange.lowerBound]) + ".app")
            return ProcessIdentity(name: applicationURL.deletingPathExtension().lastPathComponent,
                                   executableURL: url, applicationURL: applicationURL)
        }
        return ProcessIdentity(name: url.lastPathComponent, executableURL: url, applicationURL: nil)
    }

    private func processIdentity(pid: Int32) -> ProcessIdentity? {
        var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        if pathLength > 0 {
            let path = String(cString: pathBuffer)
            let identity = Self.identity(forExecutableURL: URL(fileURLWithPath: path))
            if !identity.name.isEmpty { return identity }
        }

        var nameBuffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &nameBuffer, UInt32(nameBuffer.count)) > 0 else { return nil }
        let name = String(cString: nameBuffer)
        return name.isEmpty ? nil : ProcessIdentity(name: name, executableURL: nil, applicationURL: nil)
    }
}
