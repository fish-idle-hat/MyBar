import CPowerMetrics
import Foundation

struct PowerMetrics {
    let cpuWatts: Double?
    let gpuWatts: Double?
}

/// A failure-safe Swift boundary around the private IOReport energy counters.
final class PowerMetricsReader {
    private let sampler = thermobar_power_sampler_create()

    deinit {
        thermobar_power_sampler_destroy(sampler)
    }

    func read() -> PowerMetrics? {
        guard let sampler else { return nil }
        var reading = ThermoBarPowerReading()
        guard thermobar_power_sampler_read(sampler, &reading) != 0 else { return nil }
        return PowerMetrics(
            cpuWatts: reading.has_cpu != 0 ? reading.cpu_watts : nil,
            gpuWatts: reading.has_gpu != 0 ? reading.gpu_watts : nil
        )
    }
}
