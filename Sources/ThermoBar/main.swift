import AppKit
import Darwin

// A helper may exit between isRunning and a pipe write. Treat that as EPIPE,
// never as a process-terminating signal in the monitoring app.
signal(SIGPIPE, SIG_IGN)

if CommandLine.arguments.contains("--verify-broken-pipe") {
    let pipe = Pipe()
    try pipe.fileHandleForReading.close()
    do {
        try pipe.fileHandleForWriting.write(contentsOf: Data([1]))
        print("ERROR|Closed helper pipe unexpectedly accepted a write")
        exit(4)
    } catch {
        print("VALID|Broken helper pipe cannot terminate MyBar")
        exit(0)
    }
}

if CommandLine.arguments.contains("--validate-pet") {
    let available = PetSpriteAtlas.shared.isAvailable
    print(available ? "VALID|12 cached pet frames|bundled artwork" : "ERROR|Pet artwork unavailable")
    exit(available ? 0 : 4)
}

if let index = CommandLine.arguments.firstIndex(of: "--organizer-self-test"), CommandLine.arguments.indices.contains(index + 1) {
    MenuBarOrganizerProbe.runIsolationCheck(to: CommandLine.arguments[index + 1])
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--organizer-diagnostics"), CommandLine.arguments.indices.contains(index + 1) {
    MenuBarOrganizerProbe.writeDiagnostics(to: CommandLine.arguments[index + 1])
    exit(0)
}

if CommandLine.arguments.contains("--organizer-probe") {
    MenuBarOrganizerProbe.run()
    exit(0)
}

if CommandLine.arguments.contains("--probe") {
    do {
        let monitor = try HardwareMonitor()
        _ = monitor.readSnapshot() // Establish the CPU tick baseline.
        Thread.sleep(forTimeInterval: 2.2)
        let snapshot = monitor.readSnapshot()

        if let temperature = snapshot.chipTemperature {
            print(String(format: "chip_temperature=%.1f C", temperature))
        } else {
            print("chip_temperature=unavailable")
        }
        if let cpu = snapshot.cpu {
            print(String(format: "cpu_max=%.1f C cpu_mean=%.1f C sensors=%d", cpu.maximum, cpu.mean, cpu.count))
        }
        if let gpu = snapshot.gpu {
            print(String(format: "gpu_max=%.1f C gpu_mean=%.1f C sensors=%d", gpu.maximum, gpu.mean, gpu.count))
        }
        for (index, rpm) in snapshot.fanRPM.enumerated() {
            if let rpm {
                print(String(format: "fan_%d=%.0f RPM", index + 1, rpm))
            } else {
                print("fan_\(index + 1)=unavailable")
            }
        }
        print(snapshot.cpuUsage.map { String(format: "cpu_usage=%.1f%%", $0 * 100) } ?? "cpu_usage=warming_up")
        if let cpu = snapshot.cpuBreakdown {
            print(String(format: "cpu_system=%.1f%% cpu_user=%.1f%% cpu_idle=%.1f%%", cpu.system * 100, cpu.user * 100, cpu.idle * 100))
        }
        if let gpu = snapshot.gpuMetrics {
            let renderer = gpu.rendererUsage.map { String(format: "%.1f%%", $0 * 100) } ?? "unavailable"
            let tiler = gpu.tilerUsage.map { String(format: "%.1f%%", $0 * 100) } ?? "unavailable"
            print(String(format: "gpu_usage=%.1f%% renderer=%@ tiler=%@", gpu.usage * 100, renderer, tiler))
        } else {
            print("gpu_usage=unavailable")
        }
        if let power = snapshot.powerMetrics {
            let cpu = power.cpuWatts.map { String(format: "%.2f W", $0) } ?? "unavailable"
            let gpu = power.gpuWatts.map { String(format: "%.2f W", $0) } ?? "unavailable"
            print("power_cpu=\(cpu) power_gpu=\(gpu)")
        } else {
            print("power_cpu=warming_up power_gpu=warming_up")
        }
        for (index, app) in snapshot.topApps.enumerated() {
            print(String(format: "top_app_%d=%@ cpu=%.1f%% memory=%llu energy_impact=%.1f state=%@", index + 1, app.name, app.cpuPercent, app.memoryBytes, app.energyImpact, app.isBackground ? "background" : "active"))
        }
        if let memory = snapshot.memoryMetrics {
            print(String(format: "memory_usage=%.1f%% app=%llu wired=%llu compressed=%llu", memory.usage * 100, memory.appBytes, memory.wiredBytes, memory.compressedBytes))
        }
        if let leak = snapshot.memoryLeakAssessment {
            print(String(format: "memory_leak_suspected=true growth=%llu", leak.growthBytes))
        } else {
            print("memory_leak_suspected=false")
        }
        print("memory_pressure=\(snapshot.memoryPressure.rawValue)")
        if let storage = snapshot.storageMetrics {
            print(String(format: "storage_usage=%.1f%% used=%lld total=%lld", storage.usage * 100, storage.usedBytes, storage.totalBytes))
        }
        if let battery = snapshot.batteryMetrics {
            let health = battery.maximumCapacity.map { String(format: "%.1f%%", $0 * 100) } ?? "unavailable"
            let cycles = battery.cycleCount.map(String.init) ?? "unavailable"
            let temperature = battery.temperature.map { String(format: "%.1f C", $0) } ?? "unavailable"
            let power = battery.powerWatts.map { String(format: "%.2f W", $0) } ?? "unavailable"
            let eta = battery.estimatedMinutesRemaining.map { String(format: "%.0f min", $0) } ?? "unavailable"
            print("battery=\(Int((battery.level * 100).rounded()))% source=\(battery.powerSource) health=\(health) cycles=\(cycles) temperature=\(temperature) power=\(power) eta=\(eta) confidence=\(battery.estimateConfidence.rawValue)")
        }
        if let network = snapshot.networkMetrics {
            let upload = network.uploadBytesPerSecond.map { String(format: "%.0f", $0) } ?? "warming_up"
            let download = network.downloadBytesPerSecond.map { String(format: "%.0f", $0) } ?? "warming_up"
            let signal = network.signalRSSI.map { "\($0) dBm" } ?? "unavailable"
            let latency = network.latencyMilliseconds.map { String(format: "%.0f ms", $0) } ?? "collecting"
            print("network=\(network.displayName) interface=\(network.interfaceName) ip=\(network.localIPAddress) signal=\(signal) latency=\(latency) upload_Bps=\(upload) download_Bps=\(download)")
        }
        print("temperature_sensors=\(snapshot.respondingTemperatureSensors)/\(snapshot.discoveredTemperatureSensors)")
        Darwin.exit(snapshot.chipTemperature == nil || snapshot.fanRPM.compactMap({ $0 }).isEmpty ? 2 : 0)
    } catch {
        fputs("probe_error=\(error)\n", stderr)
        Darwin.exit(1)
    }
} else {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    application.run()
}
